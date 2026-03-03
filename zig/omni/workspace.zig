const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");
const state_validation = @import("state_validation.zig");

const OmniNiriStateColumnInput = abi.OmniNiriStateColumnInput;
const OmniNiriStateWindowInput = abi.OmniNiriStateWindowInput;
const OmniNiriWorkspaceRequest = abi.OmniNiriWorkspaceRequest;
const OmniNiriWorkspaceResult = abi.OmniNiriWorkspaceResult;
const OmniNiriWorkspaceEdit = abi.OmniNiriWorkspaceEdit;

const OMNI_OK = abi.OMNI_OK;
const OMNI_ERR_INVALID_ARGS = abi.OMNI_ERR_INVALID_ARGS;

const OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE = abi.OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE;
const OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE = abi.OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE;

const OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW = abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW;
const OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE = abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE;
const OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN = abi.OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN;
const OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND = abi.OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND;
const OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS = abi.OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS;
const OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY = abi.OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY;
const OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS = abi.OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS;
const OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW = abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW;
const OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW = abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW;

const OMNI_NIRI_WORKSPACE_MAX_EDITS = abi.OMNI_NIRI_WORKSPACE_MAX_EDITS;

const SelectedContext = struct {
    column_index: usize,
    row_index: usize,
    window_index: usize,
};

fn initWorkspaceResult(out_result: *OmniNiriWorkspaceResult) void {
    const empty_edit = OmniNiriWorkspaceEdit{
        .kind = OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE,
        .subject_index = -1,
        .related_index = -1,
        .value_a = -1,
        .value_b = -1,
    };
    out_result.* = .{
        .applied = 0,
        .edit_count = 0,
        .edits = [_]OmniNiriWorkspaceEdit{empty_edit} ** OMNI_NIRI_WORKSPACE_MAX_EDITS,
    };
}

fn addWorkspaceEdit(
    out_result: *OmniNiriWorkspaceResult,
    kind: u8,
    subject_index: i64,
    related_index: i64,
    value_a: i64,
    value_b: i64,
) i32 {
    if (out_result.edit_count >= OMNI_NIRI_WORKSPACE_MAX_EDITS) return abi.OMNI_ERR_OUT_OF_RANGE;
    out_result.edits[out_result.edit_count] = .{
        .kind = kind,
        .subject_index = subject_index,
        .related_index = related_index,
        .value_a = value_a,
        .value_b = value_b,
    };
    out_result.edit_count += 1;
    return OMNI_OK;
}

fn snapshotHasAnyWindow(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
) bool {
    for (0..column_count) |idx| {
        if (columns[idx].window_count > 0) return true;
    }
    return false;
}

fn firstEmptyColumnIndex(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
) ?usize {
    for (0..column_count) |idx| {
        if (columns[idx].window_count == 0) return idx;
    }
    return null;
}

fn parseWindowContextByIndexOptional(
    columns: [*c]const OmniNiriStateColumnInput,
    windows: [*c]const OmniNiriStateWindowInput,
    column_count: usize,
    window_count: usize,
    window_index_raw: i64,
) ?SelectedContext {
    const window_index = std.math.cast(usize, window_index_raw) orelse return null;
    if (window_index >= window_count) return null;

    const column_index = windows[window_index].column_index;
    if (column_index >= column_count) return null;

    const column = columns[column_index];
    if (!geometry.rangeContains(column.window_start, column.window_count, window_index)) return null;

    return .{
        .column_index = column_index,
        .row_index = window_index - column.window_start,
        .window_index = window_index,
    };
}

fn parseColumnIndexOptional(raw: i64, column_count: usize) ?usize {
    const idx = std.math.cast(usize, raw) orelse return null;
    if (idx >= column_count) return null;
    return idx;
}

fn fallbackWindowOnRemoval(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
) ?usize {
    const source_column = columns[selected.column_index];
    if (source_column.window_count == 0) return null;

    if (selected.row_index + 1 < source_column.window_count) {
        return selected.window_index + 1;
    }

    if (selected.row_index > 0) {
        return selected.window_index - 1;
    }

    if (selected.column_index > 0) {
        const prev_column = columns[selected.column_index - 1];
        if (prev_column.window_count > 0) return prev_column.window_start;
    }

    if (selected.column_index + 1 < column_count) {
        const next_column = columns[selected.column_index + 1];
        if (next_column.window_count > 0) return next_column.window_start;
    }

    var idx: usize = 0;
    while (idx < column_count) : (idx += 1) {
        if (idx == selected.column_index) continue;
        const column = columns[idx];
        if (column.window_count > 0) return column.window_start;
    }

    return null;
}

fn fallbackWindowOnColumnMove(
    source_columns: [*c]const OmniNiriStateColumnInput,
    source_column_count: usize,
    source_column_index: usize,
) ?usize {
    if (source_column_index > 0) {
        const prev_column = source_columns[source_column_index - 1];
        if (prev_column.window_count > 0) return prev_column.window_start;
    }

    if (source_column_index + 1 < source_column_count) {
        const next_column = source_columns[source_column_index + 1];
        if (next_column.window_count > 0) return next_column.window_start;
    }

    return null;
}

fn addSourceSelectionEdit(
    out_result: *OmniNiriWorkspaceResult,
    window_index: ?usize,
) i32 {
    if (window_index) |idx| {
        const idx_i64 = std.math.cast(i64, idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        return addWorkspaceEdit(
            out_result,
            OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW,
            idx_i64,
            -1,
            -1,
            -1,
        );
    }

    return addWorkspaceEdit(
        out_result,
        OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE,
        -1,
        -1,
        -1,
        -1,
    );
}

fn planMoveWindowToWorkspace(
    source_columns: [*c]const OmniNiriStateColumnInput,
    source_column_count: usize,
    source_windows: [*c]const OmniNiriStateWindowInput,
    source_window_count: usize,
    target_columns: [*c]const OmniNiriStateColumnInput,
    target_column_count: usize,
    request: OmniNiriWorkspaceRequest,
    out_result: *OmniNiriWorkspaceResult,
) i32 {
    const max_visible_columns = std.math.cast(usize, request.max_visible_columns) orelse return OMNI_ERR_INVALID_ARGS;
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;

    const source = parseWindowContextByIndexOptional(
        source_columns,
        source_windows,
        source_column_count,
        source_window_count,
        request.source_window_index,
    ) orelse return OMNI_OK;

    const target_has_windows = snapshotHasAnyWindow(target_columns, target_column_count);
    if (!target_has_windows) {
        if (firstEmptyColumnIndex(target_columns, target_column_count)) |empty_idx| {
            const empty_idx_i64 = std.math.cast(i64, empty_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const visible_i64 = std.math.cast(i64, max_visible_columns) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const reuse_rc = addWorkspaceEdit(
                out_result,
                OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN,
                empty_idx_i64,
                -1,
                visible_i64,
                -1,
            );
            if (reuse_rc != OMNI_OK) return reuse_rc;
        } else {
            const visible_i64 = std.math.cast(i64, max_visible_columns) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const create_rc = addWorkspaceEdit(
                out_result,
                OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND,
                -1,
                -1,
                visible_i64,
                -1,
            );
            if (create_rc != OMNI_OK) return create_rc;
        }
    } else {
        const visible_i64 = std.math.cast(i64, max_visible_columns) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const create_rc = addWorkspaceEdit(
            out_result,
            OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND,
            -1,
            -1,
            visible_i64,
            -1,
        );
        if (create_rc != OMNI_OK) return create_rc;
    }

    const source_column_i64 = std.math.cast(i64, source.column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const cleanup_rc = addWorkspaceEdit(
        out_result,
        OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY,
        source_column_i64,
        -1,
        -1,
        -1,
    );
    if (cleanup_rc != OMNI_OK) return cleanup_rc;

    const fallback = fallbackWindowOnRemoval(source_columns, source_column_count, source);
    const source_selection_rc = addSourceSelectionEdit(out_result, fallback);
    if (source_selection_rc != OMNI_OK) return source_selection_rc;

    const source_window_i64 = std.math.cast(i64, source.window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const target_selection_rc = addWorkspaceEdit(
        out_result,
        OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW,
        source_window_i64,
        -1,
        -1,
        -1,
    );
    if (target_selection_rc != OMNI_OK) return target_selection_rc;

    out_result.applied = 1;
    return OMNI_OK;
}

fn planMoveColumnToWorkspace(
    source_columns: [*c]const OmniNiriStateColumnInput,
    source_column_count: usize,
    target_columns: [*c]const OmniNiriStateColumnInput,
    target_column_count: usize,
    request: OmniNiriWorkspaceRequest,
    out_result: *OmniNiriWorkspaceResult,
) i32 {
    const source_column_index = parseColumnIndexOptional(request.source_column_index, source_column_count) orelse return OMNI_OK;

    if (!snapshotHasAnyWindow(target_columns, target_column_count)) {
        const prune_rc = addWorkspaceEdit(
            out_result,
            OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS,
            -1,
            -1,
            -1,
            -1,
        );
        if (prune_rc != OMNI_OK) return prune_rc;
    }

    if (source_column_count == 1) {
        const placeholder_rc = addWorkspaceEdit(
            out_result,
            OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS,
            -1,
            -1,
            -1,
            -1,
        );
        if (placeholder_rc != OMNI_OK) return placeholder_rc;
    }

    const fallback = fallbackWindowOnColumnMove(source_columns, source_column_count, source_column_index);
    const source_selection_rc = addSourceSelectionEdit(out_result, fallback);
    if (source_selection_rc != OMNI_OK) return source_selection_rc;

    const source_column_i64 = std.math.cast(i64, source_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const target_selection_rc = addWorkspaceEdit(
        out_result,
        OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW,
        source_column_i64,
        -1,
        -1,
        -1,
    );
    if (target_selection_rc != OMNI_OK) return target_selection_rc;

    out_result.applied = 1;
    return OMNI_OK;
}

fn validateSnapshot(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const OmniNiriStateWindowInput,
    window_count: usize,
) i32 {
    var validation = abi.OmniNiriStateValidationResult{
        .column_count = 0,
        .window_count = 0,
        .first_invalid_column_index = -1,
        .first_invalid_window_index = -1,
        .first_error_code = OMNI_OK,
    };
    return state_validation.omni_niri_validate_state_snapshot_impl(
        columns,
        column_count,
        windows,
        window_count,
        &validation,
    );
}

pub fn omni_niri_workspace_plan_impl(
    source_columns: [*c]const OmniNiriStateColumnInput,
    source_column_count: usize,
    source_windows: [*c]const OmniNiriStateWindowInput,
    source_window_count: usize,
    target_columns: [*c]const OmniNiriStateColumnInput,
    target_column_count: usize,
    target_windows: [*c]const OmniNiriStateWindowInput,
    target_window_count: usize,
    request: [*c]const OmniNiriWorkspaceRequest,
    out_result: [*c]OmniNiriWorkspaceResult,
) i32 {
    if (request == null or out_result == null) return OMNI_ERR_INVALID_ARGS;
    if (source_column_count > 0 and source_columns == null) return OMNI_ERR_INVALID_ARGS;
    if (source_window_count > 0 and source_windows == null) return OMNI_ERR_INVALID_ARGS;
    if (target_column_count > 0 and target_columns == null) return OMNI_ERR_INVALID_ARGS;
    if (target_window_count > 0 and target_windows == null) return OMNI_ERR_INVALID_ARGS;

    const source_validation_rc = validateSnapshot(
        source_columns,
        source_column_count,
        source_windows,
        source_window_count,
    );
    if (source_validation_rc != OMNI_OK) return source_validation_rc;

    const target_validation_rc = validateSnapshot(
        target_columns,
        target_column_count,
        target_windows,
        target_window_count,
    );
    if (target_validation_rc != OMNI_OK) return target_validation_rc;

    var resolved_result: OmniNiriWorkspaceResult = undefined;
    initWorkspaceResult(&resolved_result);

    const req = request[0];
    const rc: i32 = switch (req.op) {
        OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE => planMoveWindowToWorkspace(
            source_columns,
            source_column_count,
            source_windows,
            source_window_count,
            target_columns,
            target_column_count,
            req,
            &resolved_result,
        ),
        OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE => planMoveColumnToWorkspace(
            source_columns,
            source_column_count,
            target_columns,
            target_column_count,
            req,
            &resolved_result,
        ),
        else => OMNI_ERR_INVALID_ARGS,
    };
    if (rc != OMNI_OK) return rc;

    out_result[0] = resolved_result;
    return OMNI_OK;
}
