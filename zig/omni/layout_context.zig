const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");
const interaction = @import("interaction.zig");
const layout_pass = @import("layout_pass.zig");
const state_validation = @import("state_validation.zig");
const navigation = @import("navigation.zig");
const mutation = @import("mutation.zig");
const workspace = @import("workspace.zig");

const ID_SLOT_COUNT: usize = abi.MAX_WINDOWS * 2;
const EMPTY_SLOT: i64 = -1;

pub const OmniNiriLayoutContext = extern struct {
    interaction_window_count: usize,
    interaction_windows: [abi.MAX_WINDOWS]abi.OmniNiriHitTestWindow,
    column_count: usize,
    column_dropzones: [abi.MAX_WINDOWS]abi.OmniNiriColumnDropzoneMeta,

    runtime_column_count: usize,
    runtime_columns: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeColumnState,
    runtime_window_count: usize,
    runtime_windows: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,

    runtime_column_id_slots: [ID_SLOT_COUNT]i64,
    runtime_window_id_slots: [ID_SLOT_COUNT]i64,
};

const RuntimeState = struct {
    column_count: usize,
    columns: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeColumnState,
    window_count: usize,
    windows: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
    column_id_slots: [ID_SLOT_COUNT]i64,
    window_id_slots: [ID_SLOT_COUNT]i64,
};

const MutationApplyHints = struct {
    refresh_count: usize,
    refresh_column_ids: [abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]abi.OmniUuid128,
    reset_all_column_cached_widths: bool,
    has_delegate_move_column: bool,
    delegate_move_column_id: abi.OmniUuid128,
    delegate_move_direction: u8,
};

fn zeroUuid() abi.OmniUuid128 {
    return .{ .bytes = [_]u8{0} ** 16 };
}

fn initMutationApplyHints() MutationApplyHints {
    return .{
        .refresh_count = 0,
        .refresh_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS,
        .reset_all_column_cached_widths = false,
        .has_delegate_move_column = false,
        .delegate_move_column_id = zeroUuid(),
        .delegate_move_direction = 0,
    };
}

fn initMutationApplyResult(out_result: [*c]abi.OmniNiriMutationApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_target_window_id = 0,
        .target_window_id = zeroUuid(),
        .has_target_node_id = 0,
        .target_node_kind = abi.OMNI_NIRI_MUTATION_NODE_NONE,
        .target_node_id = zeroUuid(),
        .refresh_tabbed_visibility_count = 0,
        .refresh_tabbed_visibility_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS,
        .reset_all_column_cached_widths = 0,
        .has_delegate_move_column = 0,
        .delegate_move_column_id = zeroUuid(),
        .delegate_move_direction = 0,
    };
}

fn initWorkspaceApplyResult(out_result: [*c]abi.OmniNiriWorkspaceApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_source_selection_window_id = 0,
        .source_selection_window_id = zeroUuid(),
        .has_target_selection_window_id = 0,
        .target_selection_window_id = zeroUuid(),
        .has_moved_window_id = 0,
        .moved_window_id = zeroUuid(),
    };
}

fn initNavigationApplyResult(out_result: [*c]abi.OmniNiriNavigationApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_target_window_id = 0,
        .target_window_id = zeroUuid(),
        .update_source_active_tile = 0,
        .source_column_id = zeroUuid(),
        .source_active_tile_idx = -1,
        .update_target_active_tile = 0,
        .target_column_id = zeroUuid(),
        .target_active_tile_idx = -1,
        .refresh_tabbed_visibility_source = 0,
        .refresh_source_column_id = zeroUuid(),
        .refresh_tabbed_visibility_target = 0,
        .refresh_target_column_id = zeroUuid(),
    };
}

fn resetContext(ctx: *OmniNiriLayoutContext) void {
    ctx.interaction_window_count = 0;
    ctx.column_count = 0;

    ctx.runtime_column_count = 0;
    ctx.runtime_window_count = 0;

    for (0..ID_SLOT_COUNT) |idx| {
        ctx.runtime_column_id_slots[idx] = EMPTY_SLOT;
        ctx.runtime_window_id_slots[idx] = EMPTY_SLOT;
    }
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

fn runtimeColumnsStatePtr(state: *const RuntimeState) [*c]const abi.OmniNiriStateColumnInput {
    if (state.column_count == 0) return null;
    const ptr: *const abi.OmniNiriStateColumnInput = @ptrCast(&state.columns[0]);
    return @ptrCast(ptr);
}

fn runtimeWindowsStatePtr(state: *const RuntimeState) [*c]const abi.OmniNiriStateWindowInput {
    if (state.window_count == 0) return null;
    const ptr: *const abi.OmniNiriStateWindowInput = @ptrCast(&state.windows[0]);
    return @ptrCast(ptr);
}

fn clearSlots(slots: *[ID_SLOT_COUNT]i64) void {
    for (0..ID_SLOT_COUNT) |idx| {
        slots[idx] = EMPTY_SLOT;
    }
}

fn uuidEqual(a: abi.OmniUuid128, b: abi.OmniUuid128) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

fn uuidHash(uuid: abi.OmniUuid128) u64 {
    var hash: u64 = 1469598103934665603;
    for (uuid.bytes) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash;
}

fn slotForUuid(uuid: abi.OmniUuid128) usize {
    const hashed = uuidHash(uuid) % @as(u64, ID_SLOT_COUNT);
    return @intCast(hashed);
}

fn insertColumnIdSlot(state: *RuntimeState, column_index: usize) i32 {
    const column_id = state.columns[column_index].column_id;
    var slot = slotForUuid(column_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.column_id_slots[slot];
        if (raw == EMPTY_SLOT) {
            state.column_id_slots[slot] = std.math.cast(i64, column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            return abi.OMNI_OK;
        }

        const existing_index = std.math.cast(usize, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (existing_index >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        if (uuidEqual(state.columns[existing_index].column_id, column_id)) return abi.OMNI_ERR_INVALID_ARGS;

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return abi.OMNI_ERR_OUT_OF_RANGE;
}

fn insertWindowIdSlot(state: *RuntimeState, window_index: usize) i32 {
    const window_id = state.windows[window_index].window_id;
    var slot = slotForUuid(window_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.window_id_slots[slot];
        if (raw == EMPTY_SLOT) {
            state.window_id_slots[slot] = std.math.cast(i64, window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            return abi.OMNI_OK;
        }

        const existing_index = std.math.cast(usize, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (existing_index >= state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        if (uuidEqual(state.windows[existing_index].window_id, window_id)) return abi.OMNI_ERR_INVALID_ARGS;

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return abi.OMNI_ERR_OUT_OF_RANGE;
}

fn rebuildRuntimeIdCaches(state: *RuntimeState) i32 {
    clearSlots(&state.column_id_slots);
    clearSlots(&state.window_id_slots);

    for (0..state.column_count) |idx| {
        const rc = insertColumnIdSlot(state, idx);
        if (rc != abi.OMNI_OK) return rc;
    }

    for (0..state.window_count) |idx| {
        const rc = insertWindowIdSlot(state, idx);
        if (rc != abi.OMNI_OK) return rc;
    }

    return abi.OMNI_OK;
}

fn findColumnIndexById(state: *const RuntimeState, column_id: abi.OmniUuid128) ?usize {
    if (state.column_count == 0) return null;
    var slot = slotForUuid(column_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.column_id_slots[slot];
        if (raw == EMPTY_SLOT) return null;

        const idx = std.math.cast(usize, raw) orelse return null;
        if (idx < state.column_count and uuidEqual(state.columns[idx].column_id, column_id)) {
            return idx;
        }

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return null;
}

fn findWindowIndexById(state: *const RuntimeState, window_id: abi.OmniUuid128) ?usize {
    if (state.window_count == 0) return null;
    var slot = slotForUuid(window_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.window_id_slots[slot];
        if (raw == EMPTY_SLOT) return null;

        const idx = std.math.cast(usize, raw) orelse return null;
        if (idx < state.window_count and uuidEqual(state.windows[idx].window_id, window_id)) {
            return idx;
        }

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return null;
}

fn runtimeStateFromContext(ctx: *const OmniNiriLayoutContext) RuntimeState {
    return .{
        .column_count = ctx.runtime_column_count,
        .columns = ctx.runtime_columns,
        .window_count = ctx.runtime_window_count,
        .windows = ctx.runtime_windows,
        .column_id_slots = ctx.runtime_column_id_slots,
        .window_id_slots = ctx.runtime_window_id_slots,
    };
}

fn commitRuntimeState(ctx: *OmniNiriLayoutContext, state: *const RuntimeState) void {
    ctx.runtime_column_count = state.column_count;
    ctx.runtime_columns = state.columns;
    ctx.runtime_window_count = state.window_count;
    ctx.runtime_windows = state.windows;
    ctx.runtime_column_id_slots = state.column_id_slots;
    ctx.runtime_window_id_slots = state.window_id_slots;
}

fn validateRuntimeState(state: *RuntimeState) i32 {
    var validation = abi.OmniNiriStateValidationResult{
        .column_count = 0,
        .window_count = 0,
        .first_invalid_column_index = -1,
        .first_invalid_window_index = -1,
        .first_error_code = abi.OMNI_OK,
    };

    return state_validation.omni_niri_validate_state_snapshot_impl(
        runtimeColumnsStatePtr(state),
        state.column_count,
        runtimeWindowsStatePtr(state),
        state.window_count,
        &validation,
    );
}

fn recomputeRuntimeTopology(state: *RuntimeState) i32 {
    if (state.column_count > abi.MAX_WINDOWS or state.window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    var cursor: usize = 0;
    for (0..state.column_count) |column_idx| {
        var column = &state.columns[column_idx];
        if (column.window_count > state.window_count - cursor) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        column.window_start = cursor;
        if (column.window_count == 0) {
            column.active_tile_idx = 0;
        } else if (column.active_tile_idx >= column.window_count) {
            column.active_tile_idx = column.window_count - 1;
        }

        for (0..column.window_count) |row_idx| {
            const window_idx = cursor + row_idx;
            state.windows[window_idx].column_index = column_idx;
            state.windows[window_idx].column_id = column.column_id;
        }

        cursor += column.window_count;
    }

    if (cursor != state.window_count) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn refreshRuntimeState(state: *RuntimeState) i32 {
    const topology_rc = recomputeRuntimeTopology(state);
    if (topology_rc != abi.OMNI_OK) return topology_rc;

    const validation_rc = validateRuntimeState(state);
    if (validation_rc != abi.OMNI_OK) return validation_rc;

    return rebuildRuntimeIdCaches(state);
}

fn removeWindowAt(state: *RuntimeState, index: usize) abi.OmniNiriRuntimeWindowState {
    const removed = state.windows[index];
    var cursor = index;
    while (cursor + 1 < state.window_count) : (cursor += 1) {
        state.windows[cursor] = state.windows[cursor + 1];
    }
    state.window_count -= 1;
    return removed;
}

fn insertWindowAt(state: *RuntimeState, index: usize, window: abi.OmniNiriRuntimeWindowState) i32 {
    if (state.window_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (index > state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var cursor = state.window_count;
    while (cursor > index) : (cursor -= 1) {
        state.windows[cursor] = state.windows[cursor - 1];
    }

    state.windows[index] = window;
    state.window_count += 1;
    return abi.OMNI_OK;
}

fn removeColumnAt(state: *RuntimeState, index: usize) abi.OmniNiriRuntimeColumnState {
    const removed = state.columns[index];
    var cursor = index;
    while (cursor + 1 < state.column_count) : (cursor += 1) {
        state.columns[cursor] = state.columns[cursor + 1];
    }
    state.column_count -= 1;
    return removed;
}

fn insertColumnAt(state: *RuntimeState, index: usize, column: abi.OmniNiriRuntimeColumnState) i32 {
    if (state.column_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (index > state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var cursor = state.column_count;
    while (cursor > index) : (cursor -= 1) {
        state.columns[cursor] = state.columns[cursor - 1];
    }

    state.columns[index] = column;
    state.column_count += 1;
    return abi.OMNI_OK;
}

fn removeWindowRange(
    state: *RuntimeState,
    start_index: usize,
    count: usize,
    out_removed: *[abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
) i32 {
    if (count == 0) return abi.OMNI_OK;
    if (start_index > state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (count > state.window_count - start_index) return abi.OMNI_ERR_OUT_OF_RANGE;

    for (0..count) |idx| {
        out_removed[idx] = state.windows[start_index + idx];
    }

    var cursor = start_index;
    while (cursor + count < state.window_count) : (cursor += 1) {
        state.windows[cursor] = state.windows[cursor + count];
    }

    state.window_count -= count;
    return abi.OMNI_OK;
}

fn appendWindowBatch(
    state: *RuntimeState,
    windows: *const [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
    count: usize,
) i32 {
    if (state.window_count > abi.MAX_WINDOWS - count) return abi.OMNI_ERR_OUT_OF_RANGE;
    for (0..count) |idx| {
        state.windows[state.window_count + idx] = windows[idx];
    }
    state.window_count += count;
    return abi.OMNI_OK;
}

fn clampSizeValue(value: f64) f64 {
    return @max(0.5, @min(2.0, value));
}

fn visibleCountFromRaw(raw_count: i64) i32 {
    const count = std.math.cast(usize, raw_count) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (count == 0) return abi.OMNI_ERR_INVALID_ARGS;
    return std.math.cast(i32, count) orelse abi.OMNI_ERR_OUT_OF_RANGE;
}

fn proportionalSizeForVisibleCount(raw_count: i64) i32 {
    const count_i32 = visibleCountFromRaw(raw_count);
    if (count_i32 < 0) return count_i32;
    return count_i32;
}

fn preColumnId(
    ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    count: usize,
    raw_index: i64,
) ?abi.OmniUuid128 {
    const idx = std.math.cast(usize, raw_index) orelse return null;
    if (idx >= count) return null;
    return ids[idx];
}

fn preWindowId(
    ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    count: usize,
    raw_index: i64,
) ?abi.OmniUuid128 {
    const idx = std.math.cast(usize, raw_index) orelse return null;
    if (idx >= count) return null;
    return ids[idx];
}

fn capturePreIds(
    state: *const RuntimeState,
    out_column_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_window_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
) void {
    for (0..state.column_count) |idx| {
        out_column_ids[idx] = state.columns[idx].column_id;
    }

    for (0..state.window_count) |idx| {
        out_window_ids[idx] = state.windows[idx].window_id;
    }
}

fn ensureUniqueColumnId(state: *const RuntimeState, column_id: abi.OmniUuid128) i32 {
    if (findColumnIndexById(state, column_id) != null) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn ensureUniqueWindowId(state: *const RuntimeState, window_id: abi.OmniUuid128) i32 {
    if (findWindowIndexById(state, window_id) != null) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn appendRefreshHint(hints: *MutationApplyHints, column_id: abi.OmniUuid128) void {
    var idx: usize = 0;
    while (idx < hints.refresh_count) : (idx += 1) {
        if (uuidEqual(hints.refresh_column_ids[idx], column_id)) return;
    }

    if (hints.refresh_count >= abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS) return;
    hints.refresh_column_ids[hints.refresh_count] = column_id;
    hints.refresh_count += 1;
}

fn i64ToU8(raw: i64) i32 {
    const value = std.math.cast(u8, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    return std.math.cast(i32, value) orelse abi.OMNI_ERR_OUT_OF_RANGE;
}

fn workspaceFail(code: i32, tag: []const u8) i32 {
    _ = tag;
    return code;
}

fn applyMutationEdit(
    state: *RuntimeState,
    apply_request: abi.OmniNiriMutationApplyRequest,
    edit: abi.OmniNiriMutationEdit,
    pre_column_ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    pre_window_ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    pre_column_count: usize,
    pre_window_count: usize,
    hints: *MutationApplyHints,
) i32 {
    var mutated = false;

    switch (edit.kind) {
        abi.OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx = findColumnIndexById(state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            var next_active: usize = 0;
            if (edit.value_a >= 0) {
                next_active = std.math.cast(usize, edit.value_a) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            }
            state.columns[column_idx].active_tile_idx = next_active;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS => {
            const lhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findWindowIndexById(state, lhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findWindowIndexById(state, rhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.windows[lhs_idx];
            state.windows[lhs_idx] = state.windows[rhs_idx];
            state.windows[rhs_idx] = temp;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX => {
            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const moving_idx = findWindowIndexById(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[moving_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_column_idx = findColumnIndexById(state, target_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_column_idx];
            const source_column = state.columns[source_column_idx];

            var insert_row: usize = 0;
            if (edit.value_a >= 0) {
                const raw_row = std.math.cast(usize, edit.value_a) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_row = @min(raw_row, target_column.window_count);
            }

            var target_abs = target_column.window_start + insert_row;
            if (source_column_idx == target_column_idx) {
                if (moving_idx < target_abs and target_abs > 0) {
                    target_abs -= 1;
                }
            } else if (source_column_idx < target_column_idx and target_abs > 0) {
                target_abs -= 1;
            }

            const moved = removeWindowAt(state, moving_idx);
            if (source_column.window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, target_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[target_column_idx].window_count += 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE => {
            const lhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findColumnIndexById(state, lhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findColumnIndexById(state, rhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.columns[lhs_idx].size_value;
            state.columns[lhs_idx].size_value = state.columns[rhs_idx].size_value;
            state.columns[rhs_idx].size_value = temp;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT => {
            const lhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findWindowIndexById(state, lhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findWindowIndexById(state, rhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.windows[lhs_idx].size_value;
            state.windows[lhs_idx].size_value = state.windows[rhs_idx].size_value;
            state.windows[rhs_idx].size_value = temp;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT => {
            const window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const window_idx = findWindowIndexById(state, window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            state.windows[window_idx].size_value = 1.0;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx_opt = findColumnIndexById(state, column_id);

            if (column_idx_opt) |column_idx| {
                if (state.columns[column_idx].window_count == 0) {
                    _ = removeColumnAt(state, column_idx);
                    mutated = true;

                    if (state.column_count == 0) {
                        if (apply_request.has_placeholder_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
                        const placeholder_id = apply_request.placeholder_column_id;
                        const unique_rc = ensureUniqueColumnId(state, placeholder_id);
                        if (unique_rc != abi.OMNI_OK) return unique_rc;

                        const add_rc = insertColumnAt(state, 0, .{
                            .column_id = placeholder_id,
                            .window_start = 0,
                            .window_count = 0,
                            .active_tile_idx = 0,
                            .is_tabbed = 0,
                            .size_value = 1.0,
                        });
                        if (add_rc != abi.OMNI_OK) return add_rc;
                    }
                }
            }
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            appendRefreshHint(hints, column_id);
        },
        abi.OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const direction_i32 = i64ToU8(edit.value_a);
            if (direction_i32 < 0) return direction_i32;

            hints.has_delegate_move_column = true;
            hints.delegate_move_column_id = column_id;
            hints.delegate_move_direction = @intCast(direction_i32);
        },
        abi.OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW => {
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const source_column_idx_initial = findColumnIndexById(state, source_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const direction_i32 = i64ToU8(edit.value_a);
            if (direction_i32 < 0) return direction_i32;
            const direction: u8 = @intCast(direction_i32);
            if (direction != abi.OMNI_NIRI_DIRECTION_LEFT and direction != abi.OMNI_NIRI_DIRECTION_RIGHT) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }

            const visible_i32 = proportionalSizeForVisibleCount(edit.value_b);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            const insert_index = if (direction == abi.OMNI_NIRI_DIRECTION_RIGHT)
                source_column_idx_initial + 1
            else
                source_column_idx_initial;

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
            });
            if (add_rc != abi.OMNI_OK) return add_rc;
            const cache_rc = refreshRuntimeState(state);
            if (cache_rc != abi.OMNI_OK) return cache_rc;

            const moving_idx = findWindowIndexById(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = findColumnIndexById(state, source_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_column_idx = findColumnIndexById(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_start = state.columns[new_column_idx].window_start;
            var insert_abs = target_start;
            if (moving_idx < insert_abs and insert_abs > 0) insert_abs -= 1;

            const moved = removeWindowAt(state, moving_idx);
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, insert_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[new_column_idx].window_count += 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW => {
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const visible_i32 = proportionalSizeForVisibleCount(edit.value_a);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            var insert_index: usize = 0;
            if (edit.related_index > 0) {
                const raw_index = std.math.cast(usize, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_index = @min(raw_index, state.column_count);
            }

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
            });
            if (add_rc != abi.OMNI_OK) return add_rc;
            const cache_rc = refreshRuntimeState(state);
            if (cache_rc != abi.OMNI_OK) return cache_rc;

            const moving_idx = findWindowIndexById(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[moving_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_column_idx = findColumnIndexById(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_start = state.columns[new_column_idx].window_start;
            var insert_abs = target_start;
            if (moving_idx < insert_abs and insert_abs > 0) insert_abs -= 1;

            const moved = removeWindowAt(state, moving_idx);
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, insert_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[new_column_idx].window_count += 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS => {
            const lhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findColumnIndexById(state, lhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findColumnIndexById(state, rhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (lhs_idx == rhs_idx) {
                // no-op
            } else {
                const old = state.*;
                const temp = state.columns[lhs_idx];
                state.columns[lhs_idx] = state.columns[rhs_idx];
                state.columns[rhs_idx] = temp;

                var dst_cursor: usize = 0;
                for (0..state.column_count) |column_idx| {
                    const column_id = state.columns[column_idx].column_id;

                    var old_index_opt: ?usize = null;
                    for (0..old.column_count) |old_idx| {
                        if (uuidEqual(old.columns[old_idx].column_id, column_id)) {
                            old_index_opt = old_idx;
                            break;
                        }
                    }
                    const old_index = old_index_opt orelse return abi.OMNI_ERR_INVALID_ARGS;
                    const old_column = old.columns[old_index];

                    for (0..old_column.window_count) |row_idx| {
                        state.windows[dst_cursor + row_idx] = old.windows[old_column.window_start + row_idx];
                    }
                    dst_cursor += old_column.window_count;
                }

                mutated = true;
            }
        },
        abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;
            for (0..state.column_count) |idx| {
                state.columns[idx].size_value = clampSizeValue(state.columns[idx].size_value * edit.scalar_a);
            }
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx = findColumnIndexById(state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column = state.columns[column_idx];

            for (0..column.window_count) |row_idx| {
                const window_idx = column.window_start + row_idx;
                state.windows[window_idx].size_value = clampSizeValue(state.windows[window_idx].size_value * edit.scalar_a);
            }
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;

            for (0..state.column_count) |col_idx| {
                state.columns[col_idx].size_value = edit.scalar_a;
                const column = state.columns[col_idx];
                for (0..column.window_count) |row_idx| {
                    const window_idx = column.window_start + row_idx;
                    state.windows[window_idx].size_value = 1.0;
                }
            }

            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN => {
            if (apply_request.has_incoming_window_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueWindowId(state, apply_request.incoming_window_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const target_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column_idx = findColumnIndexById(state, target_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_column_idx];

            const insert_abs = target_column.window_start + target_column.window_count;
            const insert_rc = insertWindowAt(state, insert_abs, .{
                .window_id = apply_request.incoming_window_id,
                .column_id = target_column.column_id,
                .column_index = target_column_idx,
                .size_value = 1.0,
            });
            if (insert_rc != abi.OMNI_OK) return insert_rc;

            state.columns[target_column_idx].window_count += 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN => {
            if (apply_request.has_incoming_window_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;

            const unique_window_rc = ensureUniqueWindowId(state, apply_request.incoming_window_id);
            if (unique_window_rc != abi.OMNI_OK) return unique_window_rc;
            const unique_column_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_column_rc != abi.OMNI_OK) return unique_column_rc;

            const visible_i32 = proportionalSizeForVisibleCount(edit.value_a);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            var insert_index = state.column_count;
            if (edit.subject_index >= 0) {
                const reference_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                const reference_index = findColumnIndexById(state, reference_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_index = reference_index + 1;
            }

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
            });
            if (add_rc != abi.OMNI_OK) return add_rc;
            const cache_rc = refreshRuntimeState(state);
            if (cache_rc != abi.OMNI_OK) return cache_rc;

            const target_idx = findColumnIndexById(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_idx];
            const insert_abs = target_column.window_start + target_column.window_count;

            const insert_window_rc = insertWindowAt(state, insert_abs, .{
                .window_id = apply_request.incoming_window_id,
                .column_id = target_column.column_id,
                .column_index = target_idx,
                .size_value = 1.0,
            });
            if (insert_window_rc != abi.OMNI_OK) return insert_window_rc;

            state.columns[target_idx].window_count += 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX => {
            const window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const window_idx = findWindowIndexById(state, window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[window_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;

            _ = removeWindowAt(state, window_idx);
            state.columns[source_column_idx].window_count -= 1;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS => {
            hints.reset_all_column_cached_widths = true;
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    if (mutated) {
        return refreshRuntimeState(state);
    }

    return abi.OMNI_OK;
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

pub fn omni_niri_ctx_seed_runtime_state_impl(
    context: [*c]OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriRuntimeColumnState,
    column_count: usize,
    windows: [*c]const abi.OmniNiriRuntimeWindowState,
    window_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > abi.MAX_WINDOWS or window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    var runtime_state: RuntimeState = undefined;
    runtime_state.column_count = column_count;
    runtime_state.window_count = window_count;
    clearSlots(&runtime_state.column_id_slots);
    clearSlots(&runtime_state.window_id_slots);

    for (0..column_count) |idx| {
        runtime_state.columns[idx] = columns[idx];
    }
    for (0..window_count) |idx| {
        runtime_state.windows[idx] = windows[idx];
    }

    const refresh_rc = refreshRuntimeState(&runtime_state);
    if (refresh_rc != abi.OMNI_OK) return refresh_rc;

    commitRuntimeState(ctx, &runtime_state);
    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_export_runtime_state_impl(
    context: [*c]const OmniNiriLayoutContext,
    out_export: [*c]abi.OmniNiriRuntimeStateExport,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_export == null) return abi.OMNI_ERR_INVALID_ARGS;

    out_export[0] = .{
        .columns = if (ctx.runtime_column_count > 0) @ptrCast(&ctx.runtime_columns[0]) else null,
        .column_count = ctx.runtime_column_count,
        .windows = if (ctx.runtime_window_count > 0) @ptrCast(&ctx.runtime_windows[0]) else null,
        .window_count = ctx.runtime_window_count,
    };

    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_apply_mutation_impl(
    context: [*c]OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriMutationApplyRequest,
    out_result: [*c]abi.OmniNiriMutationApplyResult,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    initMutationApplyResult(out_result);

    var runtime_state = runtimeStateFromContext(ctx);

    var plan_result: abi.OmniNiriMutationResult = undefined;
    const planner_rc = mutation.omni_niri_mutation_plan_impl(
        runtimeColumnsStatePtr(&runtime_state),
        runtime_state.column_count,
        runtimeWindowsStatePtr(&runtime_state),
        runtime_state.window_count,
        &request[0].request,
        &plan_result,
    );
    if (planner_rc != abi.OMNI_OK) return workspaceFail(planner_rc, "planner_rc");

    var pre_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var pre_window_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    capturePreIds(&runtime_state, &pre_column_ids, &pre_window_ids);

    if (plan_result.has_target_window != 0) {
        const target_window_id = preWindowId(&pre_window_ids, runtime_state.window_count, plan_result.target_window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].has_target_window_id = 1;
        out_result[0].target_window_id = target_window_id;
    }

    if (plan_result.has_target_node != 0) {
        out_result[0].target_node_kind = plan_result.target_node_kind;
        switch (plan_result.target_node_kind) {
            abi.OMNI_NIRI_MUTATION_NODE_WINDOW => {
                const target_window_id = preWindowId(&pre_window_ids, runtime_state.window_count, plan_result.target_node_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                out_result[0].has_target_node_id = 1;
                out_result[0].target_node_id = target_window_id;
            },
            abi.OMNI_NIRI_MUTATION_NODE_COLUMN => {
                const target_column_id = preColumnId(&pre_column_ids, runtime_state.column_count, plan_result.target_node_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                out_result[0].has_target_node_id = 1;
                out_result[0].target_node_id = target_column_id;
            },
            else => return abi.OMNI_ERR_INVALID_ARGS,
        }
    }

    if (plan_result.applied == 0) {
        out_result[0].applied = 0;
        return abi.OMNI_OK;
    }

    var hints = initMutationApplyHints();

    const max_edits = @min(plan_result.edit_count, abi.OMNI_NIRI_MUTATION_MAX_EDITS);
    for (0..max_edits) |idx| {
        const apply_rc = applyMutationEdit(
            &runtime_state,
            request[0],
            plan_result.edits[idx],
            &pre_column_ids,
            &pre_window_ids,
            runtime_state.column_count,
            runtime_state.window_count,
            &hints,
        );
        if (apply_rc != abi.OMNI_OK) return apply_rc;
    }

    const final_validation_rc = validateRuntimeState(&runtime_state);
    if (final_validation_rc != abi.OMNI_OK) return final_validation_rc;

    commitRuntimeState(ctx, &runtime_state);

    out_result[0].applied = 1;
    out_result[0].refresh_tabbed_visibility_count = std.math.cast(u8, hints.refresh_count) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    for (0..hints.refresh_count) |idx| {
        out_result[0].refresh_tabbed_visibility_column_ids[idx] = hints.refresh_column_ids[idx];
    }
    out_result[0].reset_all_column_cached_widths = @intFromBool(hints.reset_all_column_cached_widths);
    out_result[0].has_delegate_move_column = @intFromBool(hints.has_delegate_move_column);
    out_result[0].delegate_move_column_id = hints.delegate_move_column_id;
    out_result[0].delegate_move_direction = hints.delegate_move_direction;

    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_apply_workspace_impl(
    source_context: [*c]OmniNiriLayoutContext,
    target_context: [*c]OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriWorkspaceApplyRequest,
    out_result: [*c]abi.OmniNiriWorkspaceApplyResult,
) i32 {
    const source_ctx = asMutableContext(source_context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    const target_ctx = asMutableContext(target_context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    initWorkspaceApplyResult(out_result);

    var source_state = runtimeStateFromContext(source_ctx);
    var target_state = runtimeStateFromContext(target_ctx);

    var plan_result: abi.OmniNiriWorkspaceResult = undefined;
    const planner_rc = workspace.omni_niri_workspace_plan_impl(
        runtimeColumnsStatePtr(&source_state),
        source_state.column_count,
        runtimeWindowsStatePtr(&source_state),
        source_state.window_count,
        runtimeColumnsStatePtr(&target_state),
        target_state.column_count,
        runtimeWindowsStatePtr(&target_state),
        target_state.window_count,
        &request[0].request,
        &plan_result,
    );
    if (planner_rc != abi.OMNI_OK) return planner_rc;

    if (plan_result.applied == 0) return abi.OMNI_OK;

    var pre_source_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var pre_source_window_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var pre_target_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var pre_target_window_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    capturePreIds(&source_state, &pre_source_column_ids, &pre_source_window_ids);
    capturePreIds(&target_state, &pre_target_column_ids, &pre_target_window_ids);

    var remove_source_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_WORKSPACE_MAX_EDITS;
    var remove_source_column_count: usize = 0;

    var has_source_selection_window_id = false;
    var source_selection_window_id = zeroUuid();
    var source_selection_cleared = false;

    var has_target_selection_moved_window = false;
    var target_selection_moved_window_id = zeroUuid();
    var has_target_selection_moved_column = false;
    var target_selection_moved_column_id = zeroUuid();

    var has_reuse_target_column = false;
    var reuse_target_column_id = zeroUuid();
    var create_target_visible_count: i64 = request[0].request.max_visible_columns;
    var prune_target_empty_columns_if_no_windows = false;
    var ensure_source_placeholder_if_no_columns = false;

    const max_edits = @min(plan_result.edit_count, abi.OMNI_NIRI_WORKSPACE_MAX_EDITS);
    for (0..max_edits) |idx| {
        const edit = plan_result.edits[idx];
        switch (edit.kind) {
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW => {
                source_selection_window_id = preWindowId(
                    &pre_source_window_ids,
                    source_state.window_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_source_selection_window_id = true;
                source_selection_cleared = false;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE => {
                has_source_selection_window_id = false;
                source_selection_cleared = true;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN => {
                reuse_target_column_id = preColumnId(
                    &pre_target_column_ids,
                    target_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_reuse_target_column = true;
                create_target_visible_count = edit.value_a;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND => {
                create_target_visible_count = edit.value_a;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS => {
                prune_target_empty_columns_if_no_windows = true;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY => {
                if (remove_source_column_count >= abi.OMNI_NIRI_WORKSPACE_MAX_EDITS) return abi.OMNI_ERR_OUT_OF_RANGE;
                remove_source_column_ids[remove_source_column_count] = preColumnId(
                    &pre_source_column_ids,
                    source_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                remove_source_column_count += 1;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS => {
                ensure_source_placeholder_if_no_columns = true;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW => {
                target_selection_moved_window_id = preWindowId(
                    &pre_source_window_ids,
                    source_state.window_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_target_selection_moved_window = true;
                has_target_selection_moved_column = false;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW => {
                target_selection_moved_column_id = preColumnId(
                    &pre_source_column_ids,
                    source_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_target_selection_moved_column = true;
                has_target_selection_moved_window = false;
            },
            else => return abi.OMNI_ERR_INVALID_ARGS,
        }
    }

    if (prune_target_empty_columns_if_no_windows and target_state.window_count == 0) {
        var idx: usize = 0;
        while (idx < target_state.column_count) {
            if (target_state.columns[idx].window_count == 0) {
                _ = removeColumnAt(&target_state, idx);
            } else {
                idx += 1;
            }
        }
        const refresh_target_rc = refreshRuntimeState(&target_state);
        if (refresh_target_rc != abi.OMNI_OK) return refresh_target_rc;
    }

    var moved_window_id_opt: ?abi.OmniUuid128 = null;

    switch (request[0].request.op) {
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE => {
            const moving_window_id = preWindowId(
                &pre_source_window_ids,
                source_state.window_count,
                request[0].request.source_window_index,
            ) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "moving_window_id");

            const source_window_idx = findWindowIndexById(&source_state, moving_window_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_window_idx");
            const source_column_idx = source_state.windows[source_window_idx].column_index;
            if (source_column_idx >= source_state.column_count) return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_column_idx");

            var target_column_id: abi.OmniUuid128 = undefined;
            if (has_reuse_target_column) {
                const target_column_idx = findColumnIndexById(&target_state, reuse_target_column_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "reuse_target_column_idx");
                if (target_state.columns[target_column_idx].window_count != 0) return workspaceFail(abi.OMNI_ERR_INVALID_ARGS, "reuse_target_not_empty");
                target_column_id = reuse_target_column_id;
            } else {
                if (request[0].has_target_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
                const unique_target_rc = ensureUniqueColumnId(&target_state, request[0].target_created_column_id);
                if (unique_target_rc != abi.OMNI_OK) return unique_target_rc;

                const visible_count_i32 = visibleCountFromRaw(create_target_visible_count);
                if (visible_count_i32 < 0) return workspaceFail(visible_count_i32, "visible_count_i32");
                const visible_count: usize = @intCast(visible_count_i32);

                const add_column_rc = insertColumnAt(&target_state, target_state.column_count, .{
                    .column_id = request[0].target_created_column_id,
                    .window_start = 0,
                    .window_count = 0,
                    .active_tile_idx = 0,
                    .is_tabbed = 0,
                    .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
                });
                if (add_column_rc != abi.OMNI_OK) return workspaceFail(add_column_rc, "add_target_column");
                const cache_rc = refreshRuntimeState(&target_state);
                if (cache_rc != abi.OMNI_OK) return workspaceFail(cache_rc, "rebuild_target_cache_after_add");
                target_column_id = request[0].target_created_column_id;
            }

            const moved_window = removeWindowAt(&source_state, source_window_idx);
            if (source_state.columns[source_column_idx].window_count == 0) return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_window_count_zero");
            source_state.columns[source_column_idx].window_count -= 1;

            const target_column_idx = findColumnIndexById(&target_state, target_column_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "target_column_idx_after_add");
            const target_column = target_state.columns[target_column_idx];
            const target_insert_idx = target_column.window_start + target_column.window_count;

            const insert_window_rc = insertWindowAt(&target_state, target_insert_idx, moved_window);
            if (insert_window_rc != abi.OMNI_OK) return workspaceFail(insert_window_rc, "insert_window_into_target");
            target_state.columns[target_column_idx].window_count += 1;

            moved_window_id_opt = moving_window_id;
        },
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE => {
            const moving_column_id = preColumnId(
                &pre_source_column_ids,
                source_state.column_count,
                request[0].request.source_column_index,
            ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const source_column_idx = findColumnIndexById(&source_state, moving_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const moving_column = source_state.columns[source_column_idx];

            var moved_windows = [_]abi.OmniNiriRuntimeWindowState{.{
                .window_id = zeroUuid(),
                .column_id = zeroUuid(),
                .column_index = 0,
                .size_value = 0,
            }} ** abi.MAX_WINDOWS;
            const remove_window_rc = removeWindowRange(
                &source_state,
                moving_column.window_start,
                moving_column.window_count,
                &moved_windows,
            );
            if (remove_window_rc != abi.OMNI_OK) return remove_window_rc;

            _ = removeColumnAt(&source_state, source_column_idx);

            const add_column_rc = insertColumnAt(&target_state, target_state.column_count, moving_column);
            if (add_column_rc != abi.OMNI_OK) return add_column_rc;

            const append_windows_rc = appendWindowBatch(&target_state, &moved_windows, moving_column.window_count);
            if (append_windows_rc != abi.OMNI_OK) return append_windows_rc;

            if (moving_column.window_count > 0) {
                moved_window_id_opt = moved_windows[0].window_id;
            }
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    const source_post_move_rc = refreshRuntimeState(&source_state);
    if (source_post_move_rc != abi.OMNI_OK) return workspaceFail(source_post_move_rc, "source_post_move_refresh");

    const target_post_move_rc = refreshRuntimeState(&target_state);
    if (target_post_move_rc != abi.OMNI_OK) return workspaceFail(target_post_move_rc, "target_post_move_refresh");

    for (0..remove_source_column_count) |idx| {
        const remove_id = remove_source_column_ids[idx];
        const remove_idx_opt = findColumnIndexById(&source_state, remove_id);
        if (remove_idx_opt) |remove_idx| {
            if (source_state.columns[remove_idx].window_count == 0) {
                _ = removeColumnAt(&source_state, remove_idx);
            }
        }
    }

    if (ensure_source_placeholder_if_no_columns and source_state.column_count == 0) {
        if (request[0].has_source_placeholder_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
        const unique_placeholder_rc = ensureUniqueColumnId(&source_state, request[0].source_placeholder_column_id);
        if (unique_placeholder_rc != abi.OMNI_OK) return unique_placeholder_rc;

        const add_placeholder_rc = insertColumnAt(&source_state, 0, .{
            .column_id = request[0].source_placeholder_column_id,
            .window_start = 0,
            .window_count = 0,
            .active_tile_idx = 0,
            .is_tabbed = 0,
            .size_value = 1.0,
        });
        if (add_placeholder_rc != abi.OMNI_OK) return add_placeholder_rc;
    }

    const source_refresh_rc = refreshRuntimeState(&source_state);
    if (source_refresh_rc != abi.OMNI_OK) return workspaceFail(source_refresh_rc, "source_final_refresh");

    const target_refresh_rc = refreshRuntimeState(&target_state);
    if (target_refresh_rc != abi.OMNI_OK) return workspaceFail(target_refresh_rc, "target_final_refresh");

    if (source_selection_cleared) {
        out_result[0].has_source_selection_window_id = 0;
    } else if (has_source_selection_window_id) {
        if (findWindowIndexById(&source_state, source_selection_window_id) != null) {
            out_result[0].has_source_selection_window_id = 1;
            out_result[0].source_selection_window_id = source_selection_window_id;
        }
    }

    if (has_target_selection_moved_window) {
        if (findWindowIndexById(&target_state, target_selection_moved_window_id) != null) {
            out_result[0].has_target_selection_window_id = 1;
            out_result[0].target_selection_window_id = target_selection_moved_window_id;
        }
    } else if (has_target_selection_moved_column) {
        if (findColumnIndexById(&target_state, target_selection_moved_column_id)) |column_idx| {
            const column = target_state.columns[column_idx];
            if (column.window_count > 0) {
                out_result[0].has_target_selection_window_id = 1;
                out_result[0].target_selection_window_id = target_state.windows[column.window_start].window_id;
            }
        }
    }

    if (moved_window_id_opt) |moved_window_id| {
        if (findWindowIndexById(&target_state, moved_window_id) != null) {
            out_result[0].has_moved_window_id = 1;
            out_result[0].moved_window_id = moved_window_id;
        }
    }

    commitRuntimeState(source_ctx, &source_state);
    commitRuntimeState(target_ctx, &target_state);
    out_result[0].applied = 1;

    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_apply_navigation_impl(
    context: [*c]OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriNavigationApplyRequest,
    out_result: [*c]abi.OmniNiriNavigationApplyResult,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    initNavigationApplyResult(out_result);

    var runtime_state = runtimeStateFromContext(ctx);

    var nav_result: abi.OmniNiriNavigationResult = undefined;
    const nav_rc = navigation.omni_niri_navigation_resolve_impl(
        runtimeColumnsStatePtr(&runtime_state),
        runtime_state.column_count,
        runtimeWindowsStatePtr(&runtime_state),
        runtime_state.window_count,
        &request[0].request,
        &nav_result,
    );
    if (nav_rc != abi.OMNI_OK) return nav_rc;

    var pre_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    var pre_window_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.MAX_WINDOWS;
    capturePreIds(&runtime_state, &pre_column_ids, &pre_window_ids);

    if (nav_result.has_target != 0) {
        const target_window_id = preWindowId(&pre_window_ids, runtime_state.window_count, nav_result.target_window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].has_target_window_id = 1;
        out_result[0].target_window_id = target_window_id;
    }

    var mutated = false;

    if (nav_result.update_source_active_tile != 0) {
        const column_id = preColumnId(&pre_column_ids, runtime_state.column_count, nav_result.source_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].update_source_active_tile = 1;
        out_result[0].source_column_id = column_id;
        out_result[0].source_active_tile_idx = nav_result.source_active_tile_idx;

        const column_idx = findColumnIndexById(&runtime_state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const row_idx = std.math.cast(usize, nav_result.source_active_tile_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (runtime_state.columns[column_idx].active_tile_idx != row_idx) {
            runtime_state.columns[column_idx].active_tile_idx = row_idx;
            mutated = true;
        }
    }

    if (nav_result.update_target_active_tile != 0) {
        const column_id = preColumnId(&pre_column_ids, runtime_state.column_count, nav_result.target_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].update_target_active_tile = 1;
        out_result[0].target_column_id = column_id;
        out_result[0].target_active_tile_idx = nav_result.target_active_tile_idx;

        const column_idx = findColumnIndexById(&runtime_state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const row_idx = std.math.cast(usize, nav_result.target_active_tile_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (runtime_state.columns[column_idx].active_tile_idx != row_idx) {
            runtime_state.columns[column_idx].active_tile_idx = row_idx;
            mutated = true;
        }
    }

    if (nav_result.refresh_tabbed_visibility_source != 0) {
        const column_id = preColumnId(&pre_column_ids, runtime_state.column_count, nav_result.source_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].refresh_tabbed_visibility_source = 1;
        out_result[0].refresh_source_column_id = column_id;
    }

    if (nav_result.refresh_tabbed_visibility_target != 0) {
        const column_id = preColumnId(&pre_column_ids, runtime_state.column_count, nav_result.target_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].refresh_tabbed_visibility_target = 1;
        out_result[0].refresh_target_column_id = column_id;
    }

    if (mutated) {
        const refresh_rc = refreshRuntimeState(&runtime_state);
        if (refresh_rc != abi.OMNI_OK) return refresh_rc;

        commitRuntimeState(ctx, &runtime_state);
        out_result[0].applied = 1;
    }

    return abi.OMNI_OK;
}
