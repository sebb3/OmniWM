const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");
const interaction = @import("interaction.zig");
const layout_pass = @import("layout_pass.zig");
const state_validation = @import("state_validation.zig");
const navigation = @import("navigation.zig");
const mutation = @import("mutation.zig");
const workspace = @import("workspace.zig");

pub const OmniNiriLayoutContext = extern struct {
    interaction_window_count: usize,
    interaction_windows: [abi.MAX_WINDOWS]abi.OmniNiriHitTestWindow,
    column_count: usize,
    column_dropzones: [abi.MAX_WINDOWS]abi.OmniNiriColumnDropzoneMeta,
    state_column_count: usize,
    state_columns: [abi.MAX_WINDOWS]abi.OmniNiriStateColumnInput,
    state_window_count: usize,
    state_windows: [abi.MAX_WINDOWS]abi.OmniNiriStateWindowInput,
};

fn resetContext(ctx: *OmniNiriLayoutContext) void {
    ctx.interaction_window_count = 0;
    ctx.column_count = 0;
    ctx.state_column_count = 0;
    ctx.state_window_count = 0;
}

fn asMutableContext(context: [*c]OmniNiriLayoutContext) ?*OmniNiriLayoutContext {
    if (context == null) return null;
    const ptr: *OmniNiriLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn asConstContext(context: [*c]const OmniNiriLayoutContext) ?*const OmniNiriLayoutContext {
    if (context == null) return null;
    const ptr: *const OmniNiriLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn contextHitWindowsPtr(ctx: *const OmniNiriLayoutContext) [*c]const abi.OmniNiriHitTestWindow {
    if (ctx.interaction_window_count == 0) return null;
    const ptr: *const abi.OmniNiriHitTestWindow = &ctx.interaction_windows[0];
    return @ptrCast(ptr);
}

fn contextStateColumnsPtr(ctx: *const OmniNiriLayoutContext) [*c]const abi.OmniNiriStateColumnInput {
    if (ctx.state_column_count == 0) return null;
    const ptr: *const abi.OmniNiriStateColumnInput = &ctx.state_columns[0];
    return @ptrCast(ptr);
}

fn contextStateWindowsPtr(ctx: *const OmniNiriLayoutContext) [*c]const abi.OmniNiriStateWindowInput {
    if (ctx.state_window_count == 0) return null;
    const ptr: *const abi.OmniNiriStateWindowInput = &ctx.state_windows[0];
    return @ptrCast(ptr);
}

fn updateInteractionContextFromLayout(
    ctx: *OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    out_windows: [*c]const abi.OmniNiriWindowOutput,
) i32 {
    if (column_count > abi.MAX_WINDOWS or window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and out_windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    ctx.interaction_window_count = window_count;
    ctx.column_count = column_count;

    for (0..column_count) |idx| {
        ctx.column_dropzones[idx] = .{
            .is_valid = 0,
            .min_y = 0,
            .max_y = 0,
            .post_insertion_count = 0,
        };
    }

    for (0..column_count) |column_idx| {
        const column = columns[column_idx];
        if (!geometry.isSubrangeWithinTotal(window_count, column.window_start, column.window_count)) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        if (column.window_count == 0) continue;

        const first_window_idx = column.window_start;
        const last_window_idx = column.window_start + column.window_count - 1;
        const first_window = out_windows[first_window_idx];
        const last_window = out_windows[last_window_idx];

        ctx.column_dropzones[column_idx] = .{
            .is_valid = 1,
            .min_y = first_window.frame_y,
            .max_y = last_window.frame_y + last_window.frame_height,
            .post_insertion_count = column.window_count + 1,
        };

        for (0..column.window_count) |local_window_idx| {
            const global_window_idx = column.window_start + local_window_idx;
            const window_output = out_windows[global_window_idx];
            const window_input = windows[global_window_idx];
            ctx.interaction_windows[global_window_idx] = .{
                .window_index = global_window_idx,
                .column_index = column_idx,
                .frame_x = window_output.frame_x,
                .frame_y = window_output.frame_y,
                .frame_width = window_output.frame_width,
                .frame_height = window_output.frame_height,
                .is_fullscreen = @intFromBool(window_input.sizing_mode == abi.OMNI_NIRI_SIZING_FULLSCREEN),
            };
        }
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_layout_context_create_impl() [*c]OmniNiriLayoutContext {
    const ctx = std.heap.c_allocator.create(OmniNiriLayoutContext) catch return null;
    ctx.* = undefined;
    resetContext(ctx);
    return @ptrCast(ctx);
}

pub fn omni_niri_layout_context_destroy_impl(context: [*c]OmniNiriLayoutContext) void {
    const ctx = asMutableContext(context) orelse return;
    std.heap.c_allocator.destroy(ctx);
}

pub fn omni_niri_layout_context_set_interaction_impl(
    context: [*c]OmniNiriLayoutContext,
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    column_dropzones: [*c]const abi.OmniNiriColumnDropzoneMeta,
    column_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > abi.MAX_WINDOWS or column_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and column_dropzones == null) return abi.OMNI_ERR_INVALID_ARGS;

    ctx.interaction_window_count = window_count;
    ctx.column_count = column_count;

    for (0..window_count) |idx| {
        ctx.interaction_windows[idx] = windows[idx];
    }
    for (0..column_count) |idx| {
        ctx.column_dropzones[idx] = column_dropzones[idx];
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_layout_pass_v3_impl(
    context: [*c]OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    fullscreen_x: f64,
    fullscreen_y: f64,
    fullscreen_width: f64,
    fullscreen_height: f64,
    primary_gap: f64,
    secondary_gap: f64,
    view_start: f64,
    viewport_span: f64,
    workspace_offset: f64,
    scale: f64,
    orientation: u8,
    out_windows: [*c]abi.OmniNiriWindowOutput,
    out_window_count: usize,
    out_columns: [*c]abi.OmniNiriColumnOutput,
    out_column_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;

    const rc = layout_pass.omni_niri_layout_pass_v2_impl(
        columns,
        column_count,
        windows,
        window_count,
        working_x,
        working_y,
        working_width,
        working_height,
        view_x,
        view_y,
        view_width,
        view_height,
        fullscreen_x,
        fullscreen_y,
        fullscreen_width,
        fullscreen_height,
        primary_gap,
        secondary_gap,
        view_start,
        viewport_span,
        workspace_offset,
        scale,
        orientation,
        out_windows,
        out_window_count,
        out_columns,
        out_column_count,
    );
    if (rc != abi.OMNI_OK) return rc;

    return updateInteractionContextFromLayout(
        ctx,
        columns,
        column_count,
        windows,
        window_count,
        out_windows,
    );
}

pub fn omni_niri_ctx_hit_test_tiled_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_tiled_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        out_window_index,
    );
}

pub fn omni_niri_ctx_hit_test_resize_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]abi.OmniNiriResizeHitResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_resize_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        threshold,
        out_result,
    );
}

pub fn omni_niri_ctx_hit_test_move_target_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    excluding_window_index: i64,
    is_insert_mode: u8,
    out_result: [*c]abi.OmniNiriMoveTargetResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_move_target_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        excluding_window_index,
        is_insert_mode,
        out_result,
    );
}

pub fn omni_niri_ctx_insertion_dropzone_impl(
    context: [*c]const OmniNiriLayoutContext,
    target_window_index: i64,
    gap: f64,
    insert_position: u8,
    out_result: [*c]abi.OmniNiriDropzoneResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    out_result[0] = .{
        .frame_x = 0,
        .frame_y = 0,
        .frame_width = 0,
        .frame_height = 0,
        .is_valid = 0,
    };

    const target_idx = std.math.cast(usize, target_window_index) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (target_idx >= ctx.interaction_window_count) return abi.OMNI_ERR_INVALID_ARGS;

    const target = ctx.interaction_windows[target_idx];
    if (target.column_index >= ctx.column_count) return abi.OMNI_ERR_INVALID_ARGS;

    const column_meta = ctx.column_dropzones[target.column_index];
    if (column_meta.is_valid == 0) return abi.OMNI_OK;

    var input = abi.OmniNiriDropzoneInput{
        .target_frame_x = target.frame_x,
        .target_frame_y = target.frame_y,
        .target_frame_width = target.frame_width,
        .target_frame_height = target.frame_height,
        .column_min_y = column_meta.min_y,
        .column_max_y = column_meta.max_y,
        .gap = gap,
        .insert_position = insert_position,
        .post_insertion_count = column_meta.post_insertion_count,
    };
    return interaction.omni_niri_insertion_dropzone_impl(&input, out_result);
}

pub fn omni_niri_ctx_encode_state_impl(
    context: [*c]OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > abi.MAX_WINDOWS or window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    var validation = abi.OmniNiriStateValidationResult{
        .column_count = 0,
        .window_count = 0,
        .first_invalid_column_index = -1,
        .first_invalid_window_index = -1,
        .first_error_code = abi.OMNI_OK,
    };
    const rc = state_validation.omni_niri_validate_state_snapshot_impl(
        columns,
        column_count,
        windows,
        window_count,
        &validation,
    );
    if (rc != abi.OMNI_OK) return rc;

    ctx.state_column_count = column_count;
    ctx.state_window_count = window_count;
    for (0..column_count) |idx| {
        ctx.state_columns[idx] = columns[idx];
    }
    for (0..window_count) |idx| {
        ctx.state_windows[idx] = windows[idx];
    }
    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_resolve_navigation_impl(
    context: [*c]const OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriNavigationRequest,
    out_result: [*c]abi.OmniNiriNavigationResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return navigation.omni_niri_navigation_resolve_impl(
        contextStateColumnsPtr(ctx),
        ctx.state_column_count,
        contextStateWindowsPtr(ctx),
        ctx.state_window_count,
        request,
        out_result,
    );
}

pub fn omni_niri_ctx_resolve_mutation_impl(
    context: [*c]const OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriMutationRequest,
    out_result: [*c]abi.OmniNiriMutationResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return mutation.omni_niri_mutation_plan_impl(
        contextStateColumnsPtr(ctx),
        ctx.state_column_count,
        contextStateWindowsPtr(ctx),
        ctx.state_window_count,
        request,
        out_result,
    );
}

pub fn omni_niri_ctx_resolve_workspace_impl(
    source_context: [*c]const OmniNiriLayoutContext,
    target_context: [*c]const OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriWorkspaceRequest,
    out_result: [*c]abi.OmniNiriWorkspaceResult,
) i32 {
    const source = asConstContext(source_context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    const target = asConstContext(target_context) orelse return abi.OMNI_ERR_INVALID_ARGS;

    return workspace.omni_niri_workspace_plan_impl(
        contextStateColumnsPtr(source),
        source.state_column_count,
        contextStateWindowsPtr(source),
        source.state_window_count,
        contextStateColumnsPtr(target),
        target.state_column_count,
        contextStateWindowsPtr(target),
        target.state_window_count,
        request,
        out_result,
    );
}
