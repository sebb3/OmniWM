/// omni_layout.zig
///
/// ABI facade for the OmniWM Zig kernel.
/// Internal logic lives in `zig/omni/` modules:
/// - `abi_types.zig`: C ABI structs/constants
/// - `geometry.zig`: shared numeric/geometry helpers
/// - `axis_solver.zig`: axis solving logic
/// - `state_validation.zig`: snapshot validation
/// - `navigation.zig`: navigation resolver
/// - `mutation.zig`: mutation planner
/// - `workspace.zig`: workspace transfer planner
/// - `layout_pass.zig`: tiled layout pass
/// - `interaction.zig`: hit-testing/dropzone/resize math
/// - `viewport.zig`: viewport offset/snap math

const abi = @import("omni/abi_types.zig");
const axis_solver = @import("omni/axis_solver.zig");
const state_validation = @import("omni/state_validation.zig");
const navigation = @import("omni/navigation.zig");
const mutation = @import("omni/mutation.zig");
const workspace = @import("omni/workspace.zig");
const layout_pass = @import("omni/layout_pass.zig");
const interaction = @import("omni/interaction.zig");
const viewport = @import("omni/viewport.zig");

/// Solve axis layout for `window_count` windows.
///
/// Returns `OMNI_OK` on success and `OMNI_ERR_INVALID_ARGS` for invalid pointer/count combinations.
export fn omni_axis_solve(
    windows: [*c]const abi.OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    is_tabbed: u8,
    out: [*c]abi.OmniAxisOutput,
    out_count: usize,
) i32 {
    return axis_solver.omni_axis_solve_impl(
        windows,
        window_count,
        available_space,
        gap_size,
        is_tabbed,
        out,
        out_count,
    );
}

/// Solve tabbed axis layout where all windows share one span.
///
/// Returns `OMNI_OK` on success and `OMNI_ERR_INVALID_ARGS` for invalid pointer/count combinations.
export fn omni_axis_solve_tabbed(
    windows: [*c]const abi.OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    out: [*c]abi.OmniAxisOutput,
    out_count: usize,
) i32 {
    return axis_solver.omni_axis_solve_tabbed_impl(
        windows,
        window_count,
        available_space,
        gap_size,
        out,
        out_count,
    );
}

/// Validate a Niri state snapshot for bounds, ownership, and assignment consistency.
///
/// Populates `out_result` and returns `OMNI_OK` when valid, otherwise an error code.
export fn omni_niri_validate_state_snapshot(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    out_result: [*c]abi.OmniNiriStateValidationResult,
) i32 {
    return state_validation.omni_niri_validate_state_snapshot_impl(
        columns,
        column_count,
        windows,
        window_count,
        out_result,
    );
}

/// Resolve navigation behavior for a snapshot and request.
///
/// Returns `OMNI_OK` and fills `out_result` even when no target is resolved.
export fn omni_niri_navigation_resolve(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    request: [*c]const abi.OmniNiriNavigationRequest,
    out_result: [*c]abi.OmniNiriNavigationResult,
) i32 {
    return navigation.omni_niri_navigation_resolve_impl(
        columns,
        column_count,
        windows,
        window_count,
        request,
        out_result,
    );
}

/// Build a mutation edit plan for a snapshot and request.
///
/// Returns `OMNI_OK` when planning succeeds and fills `out_result`.
export fn omni_niri_mutation_plan(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    request: [*c]const abi.OmniNiriMutationRequest,
    out_result: [*c]abi.OmniNiriMutationResult,
) i32 {
    return mutation.omni_niri_mutation_plan_impl(
        columns,
        column_count,
        windows,
        window_count,
        request,
        out_result,
    );
}

/// Build workspace transfer edit plan between source and target snapshots.
///
/// Returns `OMNI_OK` when planning succeeds and fills `out_result`.
export fn omni_niri_workspace_plan(
    source_columns: [*c]const abi.OmniNiriStateColumnInput,
    source_column_count: usize,
    source_windows: [*c]const abi.OmniNiriStateWindowInput,
    source_window_count: usize,
    target_columns: [*c]const abi.OmniNiriStateColumnInput,
    target_column_count: usize,
    target_windows: [*c]const abi.OmniNiriStateWindowInput,
    target_window_count: usize,
    request: [*c]const abi.OmniNiriWorkspaceRequest,
    out_result: [*c]abi.OmniNiriWorkspaceResult,
) i32 {
    return workspace.omni_niri_workspace_plan_impl(
        source_columns,
        source_column_count,
        source_windows,
        source_window_count,
        target_columns,
        target_column_count,
        target_windows,
        target_window_count,
        request,
        out_result,
    );
}

/// Run Niri tiled layout pass (v1 compatibility entrypoint).
///
/// Equivalent to `omni_niri_layout_pass_v2` without column outputs.
export fn omni_niri_layout_pass(
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
) i32 {
    return layout_pass.omni_niri_layout_pass_impl(
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
    );
}

/// Run Niri tiled layout pass and optionally emit column frames.
///
/// Returns `OMNI_OK` on success or an error code for invalid arguments and range failures.
export fn omni_niri_layout_pass_v2(
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
    return layout_pass.omni_niri_layout_pass_v2_impl(
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
}

/// Hit-test tiled windows and return the first window index containing the point.
export fn omni_niri_hit_test_tiled(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    return interaction.omni_niri_hit_test_tiled_impl(
        windows,
        window_count,
        point_x,
        point_y,
        out_window_index,
    );
}

/// Hit-test resize edges for tiled windows.
export fn omni_niri_hit_test_resize(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]abi.OmniNiriResizeHitResult,
) i32 {
    return interaction.omni_niri_hit_test_resize_impl(
        windows,
        window_count,
        point_x,
        point_y,
        threshold,
        out_result,
    );
}

/// Hit-test a move target and insertion position for a drag point.
export fn omni_niri_hit_test_move_target(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    excluding_window_index: i64,
    is_insert_mode: u8,
    out_result: [*c]abi.OmniNiriMoveTargetResult,
) i32 {
    return interaction.omni_niri_hit_test_move_target_impl(
        windows,
        window_count,
        point_x,
        point_y,
        excluding_window_index,
        is_insert_mode,
        out_result,
    );
}

/// Compute insertion dropzone frame for before/after/swap placement.
export fn omni_niri_insertion_dropzone(
    input: [*c]const abi.OmniNiriDropzoneInput,
    out_result: [*c]abi.OmniNiriDropzoneResult,
) i32 {
    return interaction.omni_niri_insertion_dropzone_impl(input, out_result);
}

/// Compute interactive resize result for column width/window weight.
export fn omni_niri_resize_compute(
    input: [*c]const abi.OmniNiriResizeInput,
    out_result: [*c]abi.OmniNiriResizeResult,
) i32 {
    return interaction.omni_niri_resize_compute_impl(input, out_result);
}

/// Compute the viewport offset needed to reveal a target container.
export fn omni_viewport_compute_visible_offset(
    spans: [*c]const f64,
    span_count: usize,
    container_index: usize,
    gap: f64,
    viewport_span: f64,
    current_view_start: f64,
    center_mode: u8,
    always_center_single_column: u8,
    from_container_index: i64,
    out_target_offset: [*c]f64,
) i32 {
    return viewport.omni_viewport_compute_visible_offset_impl(
        spans,
        span_count,
        container_index,
        gap,
        viewport_span,
        current_view_start,
        center_mode,
        always_center_single_column,
        from_container_index,
        out_target_offset,
    );
}

/// Find the nearest viewport snap target based on projected view position.
export fn omni_viewport_find_snap_target(
    spans: [*c]const f64,
    span_count: usize,
    gap: f64,
    viewport_span: f64,
    projected_view_pos: f64,
    current_view_pos: f64,
    center_mode: u8,
    always_center_single_column: u8,
    out_result: [*c]abi.OmniSnapResult,
) i32 {
    return viewport.omni_viewport_find_snap_target_impl(
        spans,
        span_count,
        gap,
        viewport_span,
        projected_view_pos,
        current_view_pos,
        center_mode,
        always_center_single_column,
        out_result,
    );
}
