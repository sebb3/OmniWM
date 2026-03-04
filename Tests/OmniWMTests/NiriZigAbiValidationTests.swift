import CZigLayout
import Foundation
import Testing

@testable import OmniWM

private let abiOK: Int32 = 0
private let abiErrInvalidArgs: Int32 = -1
private let abiErrOutOfRange: Int32 = -2

private func makeUUID(_ marker: UInt8) -> OmniUuid128 {
    var value = OmniUuid128()
    withUnsafeMutableBytes(of: &value) { raw in
        for idx in raw.indices {
            raw[idx] = 0
        }
        raw[0] = marker
    }
    return value
}

private func validateState(
    columns: [OmniNiriStateColumnInput],
    windows: [OmniNiriStateWindowInput]
) -> (rc: Int32, result: OmniNiriStateValidationResult) {
    var result = OmniNiriStateValidationResult(
        column_count: 0,
        window_count: 0,
        first_invalid_column_index: -1,
        first_invalid_window_index: -1,
        first_error_code: abiOK
    )

    let rc: Int32 = columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            withUnsafeMutablePointer(to: &result) { resultPtr in
                omni_niri_validate_state_snapshot(
                    columnBuf.baseAddress,
                    columnBuf.count,
                    windowBuf.baseAddress,
                    windowBuf.count,
                    resultPtr
                )
            }
        }
    }

    return (rc: rc, result: result)
}

private func runLayoutPass(columns: [OmniNiriColumnInput], windows: [OmniNiriWindowInput]) -> Int32 {
    var outWindows = [OmniNiriWindowOutput](
        repeating: OmniNiriWindowOutput(
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0,
            animated_x: 0,
            animated_y: 0,
            animated_width: 0,
            animated_height: 0,
            resolved_span: 0,
            was_constrained: 0,
            hide_side: 0,
            column_index: 0
        ),
        count: windows.count
    )

    return columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            outWindows.withUnsafeMutableBufferPointer { outBuf in
                omni_niri_layout_pass_v2(
                    columnBuf.baseAddress,
                    columnBuf.count,
                    windowBuf.baseAddress,
                    windowBuf.count,
                    0,
                    0,
                    1920,
                    1080,
                    0,
                    0,
                    1920,
                    1080,
                    0,
                    0,
                    1920,
                    1080,
                    16,
                    12,
                    0,
                    1920,
                    0,
                    2,
                    0,
                    outBuf.baseAddress,
                    outBuf.count,
                    nil,
                    0
                )
            }
        }
    }
}

private func runMutationPlan(
    columns: [OmniNiriStateColumnInput],
    windows: [OmniNiriStateWindowInput],
    request: OmniNiriMutationRequest
) -> (rc: Int32, result: OmniNiriMutationResult) {
    var result = OmniNiriMutationResult()
    result.applied = 0
    result.has_target_window = 0
    result.target_window_index = -1
    result.has_target_node = 0
    result.target_node_kind = UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_NONE.rawValue)
    result.target_node_index = -1
    result.edit_count = 0

    let rc: Int32 = columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            var mutableRequest = request
            return withUnsafePointer(to: &mutableRequest) { requestPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    omni_niri_mutation_plan(
                        columnBuf.baseAddress,
                        columnBuf.count,
                        windowBuf.baseAddress,
                        windowBuf.count,
                        requestPtr,
                        resultPtr
                    )
                }
            }
        }
    }

    return (rc: rc, result: result)
}

private func runWorkspacePlan(
    sourceColumns: [OmniNiriStateColumnInput],
    sourceWindows: [OmniNiriStateWindowInput],
    targetColumns: [OmniNiriStateColumnInput],
    targetWindows: [OmniNiriStateWindowInput],
    request: OmniNiriWorkspaceRequest
) -> (rc: Int32, result: OmniNiriWorkspaceResult) {
    var result = OmniNiriWorkspaceResult()
    result.applied = 0
    result.edit_count = 0

    let rc: Int32 = sourceColumns.withUnsafeBufferPointer { sourceColumnBuf in
        sourceWindows.withUnsafeBufferPointer { sourceWindowBuf in
            targetColumns.withUnsafeBufferPointer { targetColumnBuf in
                targetWindows.withUnsafeBufferPointer { targetWindowBuf in
                    var mutableRequest = request
                    return withUnsafePointer(to: &mutableRequest) { requestPtr in
                        withUnsafeMutablePointer(to: &result) { resultPtr in
                            omni_niri_workspace_plan(
                                sourceColumnBuf.baseAddress,
                                sourceColumnBuf.count,
                                sourceWindowBuf.baseAddress,
                                sourceWindowBuf.count,
                                targetColumnBuf.baseAddress,
                                targetColumnBuf.count,
                                targetWindowBuf.baseAddress,
                                targetWindowBuf.count,
                                requestPtr,
                                resultPtr
                            )
                        }
                    }
                }
            }
        }
    }

    return (rc: rc, result: result)
}

private func makeMutationRequest(
    op: UInt8,
    sourceWindowIndex: Int64 = -1,
    selectedNodeKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_NONE.rawValue),
    selectedNodeIndex: Int64 = -1
) -> OmniNiriMutationRequest {
    OmniNiriMutationRequest(
        op: op,
        direction: 0,
        infinite_loop: 0,
        insert_position: 0,
        source_window_index: sourceWindowIndex,
        target_window_index: -1,
        max_windows_per_column: 1,
        source_column_index: -1,
        target_column_index: -1,
        insert_column_index: -1,
        max_visible_columns: 3,
        selected_node_kind: selectedNodeKind,
        selected_node_index: selectedNodeIndex,
        focused_window_index: -1
    )
}

private func makeWorkspaceRequest(
    op: UInt8,
    sourceWindowIndex: Int64 = -1,
    sourceColumnIndex: Int64 = -1,
    maxVisibleColumns: Int64 = 3
) -> OmniNiriWorkspaceRequest {
    OmniNiriWorkspaceRequest(
        op: op,
        source_window_index: sourceWindowIndex,
        source_column_index: sourceColumnIndex,
        max_visible_columns: maxVisibleColumns
    )
}

private func runtimeColumn(
    id: OmniUuid128,
    windowStart: Int,
    windowCount: Int,
    activeTileIdx: Int = 0,
    isTabbed: Bool = false,
    sizeValue: Double = 1.0
) -> OmniNiriRuntimeColumnState {
    OmniNiriRuntimeColumnState(
        column_id: id,
        window_start: windowStart,
        window_count: windowCount,
        active_tile_idx: activeTileIdx,
        is_tabbed: isTabbed ? 1 : 0,
        size_value: sizeValue
    )
}

private func runtimeWindow(
    id: OmniUuid128,
    columnId: OmniUuid128,
    columnIndex: Int,
    sizeValue: Double = 1.0
) -> OmniNiriRuntimeWindowState {
    OmniNiriRuntimeWindowState(
        window_id: id,
        column_id: columnId,
        column_index: columnIndex,
        size_value: sizeValue
    )
}

private func withContext<T>(_ body: (OpaquePointer) -> T) -> T {
    guard let context = omni_niri_layout_context_create() else {
        fatalError("Failed to create OmniNiriLayoutContext")
    }
    defer {
        omni_niri_layout_context_destroy(context)
    }
    return body(context)
}

private func seedRuntimeState(
    context: OpaquePointer,
    columns: [OmniNiriRuntimeColumnState],
    windows: [OmniNiriRuntimeWindowState]
) -> Int32 {
    columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            omni_niri_ctx_seed_runtime_state(
                context,
                columnBuf.baseAddress,
                columnBuf.count,
                windowBuf.baseAddress,
                windowBuf.count
            )
        }
    }
}

private func exportRuntimeState(
    context: OpaquePointer
) -> (rc: Int32, columns: [OmniNiriRuntimeColumnState], windows: [OmniNiriRuntimeWindowState]) {
    var exported = OmniNiriRuntimeStateExport(
        columns: nil,
        column_count: 0,
        windows: nil,
        window_count: 0
    )

    let rc = withUnsafeMutablePointer(to: &exported) { exportPtr in
        omni_niri_ctx_export_runtime_state(context, exportPtr)
    }

    let columns: [OmniNiriRuntimeColumnState]
    if let base = exported.columns, exported.column_count > 0 {
        columns = Array(UnsafeBufferPointer(start: base, count: exported.column_count))
    } else {
        columns = []
    }

    let windows: [OmniNiriRuntimeWindowState]
    if let base = exported.windows, exported.window_count > 0 {
        windows = Array(UnsafeBufferPointer(start: base, count: exported.window_count))
    } else {
        windows = []
    }

    return (rc: rc, columns: columns, windows: windows)
}

private func runMutationApply(
    context: OpaquePointer,
    request: OmniNiriMutationApplyRequest
) -> (rc: Int32, result: OmniNiriMutationApplyResult) {
    var mutableRequest = request
    var result = OmniNiriMutationApplyResult(
        applied: 0,
        has_target_window_id: 0,
        target_window_id: makeUUID(0),
        has_target_node_id: 0,
        target_node_kind: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_NONE.rawValue),
        target_node_id: makeUUID(0),
        refresh_tabbed_visibility_count: 0,
        refresh_tabbed_visibility_column_ids: (
            makeUUID(0), makeUUID(0)
        ),
        reset_all_column_cached_widths: 0,
        has_delegate_move_column: 0,
        delegate_move_column_id: makeUUID(0),
        delegate_move_direction: 0
    )

    let rc = withUnsafePointer(to: &mutableRequest) { requestPtr in
        withUnsafeMutablePointer(to: &result) { resultPtr in
            omni_niri_ctx_apply_mutation(context, requestPtr, resultPtr)
        }
    }

    return (rc: rc, result: result)
}

private func runWorkspaceApply(
    sourceContext: OpaquePointer,
    targetContext: OpaquePointer,
    request: OmniNiriWorkspaceApplyRequest
) -> (rc: Int32, result: OmniNiriWorkspaceApplyResult) {
    var mutableRequest = request
    var result = OmniNiriWorkspaceApplyResult(
        applied: 0,
        has_source_selection_window_id: 0,
        source_selection_window_id: makeUUID(0),
        has_target_selection_window_id: 0,
        target_selection_window_id: makeUUID(0),
        has_moved_window_id: 0,
        moved_window_id: makeUUID(0)
    )

    let rc = withUnsafePointer(to: &mutableRequest) { requestPtr in
        withUnsafeMutablePointer(to: &result) { resultPtr in
            omni_niri_ctx_apply_workspace(sourceContext, targetContext, requestPtr, resultPtr)
        }
    }

    return (rc: rc, result: result)
}

private func runNavigationApply(
    context: OpaquePointer,
    request: OmniNiriNavigationApplyRequest
) -> (rc: Int32, result: OmniNiriNavigationApplyResult) {
    var mutableRequest = request
    var result = OmniNiriNavigationApplyResult(
        applied: 0,
        has_target_window_id: 0,
        target_window_id: makeUUID(0),
        update_source_active_tile: 0,
        source_column_id: makeUUID(0),
        source_active_tile_idx: -1,
        update_target_active_tile: 0,
        target_column_id: makeUUID(0),
        target_active_tile_idx: -1,
        refresh_tabbed_visibility_source: 0,
        refresh_source_column_id: makeUUID(0),
        refresh_tabbed_visibility_target: 0,
        refresh_target_column_id: makeUUID(0)
    )

    let rc = withUnsafePointer(to: &mutableRequest) { requestPtr in
        withUnsafeMutablePointer(to: &result) { resultPtr in
            omni_niri_ctx_apply_navigation(context, requestPtr, resultPtr)
        }
    }

    return (rc: rc, result: result)
}

@Suite struct NiriZigAbiValidationTests {
    @Test func mutationConstantsStayAlignedAcrossKernelAndCABI() {
        #expect(Int32(NiriStateZigKernel.MutationOp.addWindow.rawValue) == OMNI_NIRI_MUTATION_OP_ADD_WINDOW.rawValue)
        #expect(Int32(NiriStateZigKernel.MutationOp.removeWindow.rawValue) == OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW.rawValue)
        #expect(
            Int32(NiriStateZigKernel.MutationOp.validateSelection.rawValue) ==
                OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.MutationOp.fallbackSelectionOnRemoval.rawValue) ==
                OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL.rawValue
        )

        #expect(Int32(NiriStateZigKernel.MutationNodeKind.none.rawValue) == OMNI_NIRI_MUTATION_NODE_NONE.rawValue)
        #expect(Int32(NiriStateZigKernel.MutationNodeKind.window.rawValue) == OMNI_NIRI_MUTATION_NODE_WINDOW.rawValue)
        #expect(Int32(NiriStateZigKernel.MutationNodeKind.column.rawValue) == OMNI_NIRI_MUTATION_NODE_COLUMN.rawValue)

        #expect(
            Int32(NiriStateZigKernel.MutationEditKind.insertIncomingWindowIntoColumn.rawValue) ==
                OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.MutationEditKind.insertIncomingWindowInNewColumn.rawValue) ==
                OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.MutationEditKind.removeWindowByIndex.rawValue) ==
                OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.MutationEditKind.resetAllColumnCachedWidths.rawValue) ==
                OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS.rawValue
        )

        #expect(
            Int32(NiriStateZigKernel.WorkspaceOp.moveWindowToWorkspace.rawValue) ==
                OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceOp.moveColumnToWorkspace.rawValue) ==
                OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.setSourceSelectionWindow.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.setSourceSelectionNone.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.reuseTargetEmptyColumn.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.createTargetColumnAppend.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.pruneTargetEmptyColumnsIfNoWindows.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.removeSourceColumnIfEmpty.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.ensureSourcePlaceholderIfNoColumns.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.setTargetSelectionMovedWindow.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW.rawValue
        )
        #expect(
            Int32(NiriStateZigKernel.WorkspaceEditKind.setTargetSelectionMovedColumnFirstWindow.rawValue) ==
                OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW.rawValue
        )
        #expect(Int(OMNI_NIRI_WORKSPACE_MAX_EDITS) == 16)
    }

    @Test func workspacePlannerRejectsInvalidOpCode() {
        let sourceColumnId = makeUUID(1)
        let sourceColumns = [
            OmniNiriStateColumnInput(
                column_id: sourceColumnId,
                window_start: 0,
                window_count: 1,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            )
        ]
        let sourceWindows = [
            OmniNiriStateWindowInput(
                window_id: makeUUID(10),
                column_id: sourceColumnId,
                column_index: 0,
                size_value: 1
            )
        ]
        let targetColumns = [
            OmniNiriStateColumnInput(
                column_id: makeUUID(2),
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            )
        ]
        let request = makeWorkspaceRequest(op: 0xFF)

        let outcome = runWorkspacePlan(
            sourceColumns: sourceColumns,
            sourceWindows: sourceWindows,
            targetColumns: targetColumns,
            targetWindows: [],
            request: request
        )
        #expect(outcome.rc == abiErrInvalidArgs)
    }

    @Test func workspacePlannerTreatsMissingSourceContextAsNoOp() {
        let sourceColumnId = makeUUID(1)
        let sourceColumns = [
            OmniNiriStateColumnInput(
                column_id: sourceColumnId,
                window_start: 0,
                window_count: 1,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            )
        ]
        let sourceWindows = [
            OmniNiriStateWindowInput(
                window_id: makeUUID(10),
                column_id: sourceColumnId,
                column_index: 0,
                size_value: 1
            )
        ]
        let targetColumns = [
            OmniNiriStateColumnInput(
                column_id: makeUUID(2),
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            )
        ]
        let request = makeWorkspaceRequest(
            op: UInt8(truncatingIfNeeded: OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE.rawValue),
            sourceWindowIndex: 10
        )

        let outcome = runWorkspacePlan(
            sourceColumns: sourceColumns,
            sourceWindows: sourceWindows,
            targetColumns: targetColumns,
            targetWindows: [],
            request: request
        )
        #expect(outcome.rc == abiOK)
        #expect(outcome.result.applied == 0)
        #expect(outcome.result.edit_count == 0)
    }

    @Test func layoutPassRejectsOverflowProneColumnRange() {
        let columns = [
            OmniNiriColumnInput(
                span: 600,
                render_offset_x: 0,
                render_offset_y: 0,
                is_tabbed: 0,
                tab_indicator_width: 0,
                window_start: Int.max,
                window_count: 1
            )
        ]
        let windows = [
            OmniNiriWindowInput(
                weight: 1,
                min_constraint: 1,
                max_constraint: 0,
                has_max_constraint: 0,
                is_constraint_fixed: 0,
                has_fixed_value: 0,
                fixed_value: 0,
                sizing_mode: 0,
                render_offset_x: 0,
                render_offset_y: 0
            )
        ]

        let rc = runLayoutPass(columns: columns, windows: windows)
        #expect(rc == abiErrOutOfRange)
    }

    @Test func stateValidationRejectsOverlappingCoverage() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 2, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 2, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(12), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsMissingCoverage() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 2, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(12), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsWindowColumnOwnershipMismatch() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 1, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsWindowColumnIdMismatch() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c1, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsDuplicateColumnIds() {
        let duplicate = makeUUID(7)
        let columns = [
            OmniNiriStateColumnInput(column_id: duplicate, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: duplicate, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: duplicate, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: duplicate, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsDuplicateWindowIds() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let duplicateWindow = makeUUID(9)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: duplicateWindow, column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: duplicateWindow, column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func mutationPlanRejectsInvalidNodeKindEvenWithNegativeIndex() {
        let columns = [
            OmniNiriStateColumnInput(
                column_id: makeUUID(1),
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            )
        ]
        let request = makeMutationRequest(
            op: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION.rawValue),
            selectedNodeKind: 0xFF,
            selectedNodeIndex: -1
        )

        let outcome = runMutationPlan(columns: columns, windows: [], request: request)
        #expect(outcome.rc == abiErrInvalidArgs)
    }

    @Test func mutationPlanValidateSelectionReturnsColumnNodeTargetWithoutWindowCompatibilityTarget() {
        let columns = [
            OmniNiriStateColumnInput(
                column_id: makeUUID(1),
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            ),
            OmniNiriStateColumnInput(
                column_id: makeUUID(2),
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            ),
        ]
        let request = makeMutationRequest(
            op: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION.rawValue),
            selectedNodeKind: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_COLUMN.rawValue),
            selectedNodeIndex: 1
        )

        let outcome = runMutationPlan(columns: columns, windows: [], request: request)
        #expect(outcome.rc == abiOK)
        #expect(outcome.result.has_target_node == 1)
        #expect(
            outcome.result.target_node_kind ==
                UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_COLUMN.rawValue)
        )
        #expect(outcome.result.target_node_index == 1)
        #expect(outcome.result.has_target_window == 0)
        #expect(outcome.result.target_window_index == -1)
    }

    @Test func mutationPlanValidateSelectionFindsFirstWindowBeyondLeadingEmptyColumn() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(
                column_id: c0,
                window_start: 0,
                window_count: 0,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            ),
            OmniNiriStateColumnInput(
                column_id: c1,
                window_start: 0,
                window_count: 1,
                active_tile_idx: 0,
                is_tabbed: 0,
                size_value: 1
            ),
        ]
        let windows = [
            OmniNiriStateWindowInput(
                window_id: makeUUID(10),
                column_id: c1,
                column_index: 1,
                size_value: 1
            )
        ]
        let request = makeMutationRequest(
            op: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION.rawValue)
        )

        let outcome = runMutationPlan(columns: columns, windows: windows, request: request)
        #expect(outcome.rc == abiOK)
        #expect(outcome.result.has_target_node == 1)
        #expect(
            outcome.result.target_node_kind ==
                UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_WINDOW.rawValue)
        )
        #expect(outcome.result.target_node_index == 0)
        #expect(outcome.result.has_target_window == 1)
        #expect(outcome.result.target_window_index == 0)
    }

    @Test func runtimeApplyABITypesStayAligned() {
        #expect(Int(OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS) == 2)

        #expect(MemoryLayout<OmniNiriRuntimeColumnState>.size == MemoryLayout<OmniNiriStateColumnInput>.size)
        #expect(MemoryLayout<OmniNiriRuntimeColumnState>.stride == MemoryLayout<OmniNiriStateColumnInput>.stride)
        #expect(MemoryLayout<OmniNiriRuntimeColumnState>.alignment == MemoryLayout<OmniNiriStateColumnInput>.alignment)

        #expect(MemoryLayout<OmniNiriRuntimeWindowState>.size == MemoryLayout<OmniNiriStateWindowInput>.size)
        #expect(MemoryLayout<OmniNiriRuntimeWindowState>.stride == MemoryLayout<OmniNiriStateWindowInput>.stride)
        #expect(MemoryLayout<OmniNiriRuntimeWindowState>.alignment == MemoryLayout<OmniNiriStateWindowInput>.alignment)

        #expect(MemoryLayout<OmniNiriMutationApplyRequest>.size > 0)
        #expect(MemoryLayout<OmniNiriMutationApplyResult>.size > 0)
        #expect(MemoryLayout<OmniNiriWorkspaceApplyRequest>.size > 0)
        #expect(MemoryLayout<OmniNiriWorkspaceApplyResult>.size > 0)
        #expect(MemoryLayout<OmniNiriNavigationApplyRequest>.size > 0)
        #expect(MemoryLayout<OmniNiriNavigationApplyResult>.size > 0)
    }

    @Test func runtimeContextApisRejectInvalidArgs() {
        var export = OmniNiriRuntimeStateExport(columns: nil, column_count: 0, windows: nil, window_count: 0)
        let exportNilContextRC = withUnsafeMutablePointer(to: &export) { exportPtr in
            omni_niri_ctx_export_runtime_state(nil, exportPtr)
        }
        #expect(exportNilContextRC == abiErrInvalidArgs)

        let seedNilContextRC = omni_niri_ctx_seed_runtime_state(nil, nil, 0, nil, 0)
        #expect(seedNilContextRC == abiErrInvalidArgs)

        withContext { context in
            let exportNilOutRC = omni_niri_ctx_export_runtime_state(context, nil)
            #expect(exportNilOutRC == abiErrInvalidArgs)

            let tooManyColumns = [OmniNiriRuntimeColumnState](
                repeating: runtimeColumn(id: makeUUID(1), windowStart: 0, windowCount: 0),
                count: 513
            )
            let seedTooManyRC = tooManyColumns.withUnsafeBufferPointer { columnBuf in
                omni_niri_ctx_seed_runtime_state(context, columnBuf.baseAddress, columnBuf.count, nil, 0)
            }
            #expect(seedTooManyRC == abiErrOutOfRange)
        }
    }

    @Test func mutationApplyUsesDeterministicIncomingWindowId() {
        withContext { context in
            let columnID = makeUUID(1)
            let seedRC = seedRuntimeState(
                context: context,
                columns: [runtimeColumn(id: columnID, windowStart: 0, windowCount: 0)],
                windows: []
            )
            #expect(seedRC == abiOK)

            let request = OmniNiriMutationApplyRequest(
                request: makeMutationRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_ADD_WINDOW.rawValue)
                ),
                has_incoming_window_id: 1,
                incoming_window_id: makeUUID(42),
                has_created_column_id: 0,
                created_column_id: makeUUID(0),
                has_placeholder_column_id: 0,
                placeholder_column_id: makeUUID(0)
            )
            let apply = runMutationApply(context: context, request: request)
            #expect(apply.rc == abiOK)
            #expect(apply.result.applied == 1)

            let exported = exportRuntimeState(context: context)
            #expect(exported.rc == abiOK)
            #expect(exported.columns.count == 1)
            #expect(exported.windows.count == 1)
            #expect(exported.windows[0].window_id.bytes.0 == 42)
            #expect(exported.windows[0].column_id.bytes.0 == columnID.bytes.0)
            #expect(exported.windows[0].column_index == 0)
        }
    }

    @Test func mutationApplyRollsBackWhenCreatedColumnIDIsMissing() {
        withContext { context in
            let columnID = makeUUID(1)
            let windowID = makeUUID(10)
            let seedRC = seedRuntimeState(
                context: context,
                columns: [runtimeColumn(id: columnID, windowStart: 0, windowCount: 1)],
                windows: [runtimeWindow(id: windowID, columnId: columnID, columnIndex: 0)]
            )
            #expect(seedRC == abiOK)

            let before = exportRuntimeState(context: context)
            #expect(before.rc == abiOK)

            let request = OmniNiriMutationApplyRequest(
                request: makeMutationRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_ADD_WINDOW.rawValue),
                    selectedNodeKind: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_WINDOW.rawValue),
                    selectedNodeIndex: 0
                ),
                has_incoming_window_id: 1,
                incoming_window_id: makeUUID(77),
                has_created_column_id: 0,
                created_column_id: makeUUID(0),
                has_placeholder_column_id: 0,
                placeholder_column_id: makeUUID(0)
            )
            let apply = runMutationApply(context: context, request: request)
            #expect(apply.rc == abiErrInvalidArgs)

            let after = exportRuntimeState(context: context)
            #expect(after.rc == abiOK)
            #expect(after.columns.count == before.columns.count)
            #expect(after.windows.count == before.windows.count)
            #expect(after.columns[0].column_id.bytes.0 == before.columns[0].column_id.bytes.0)
            #expect(after.windows[0].window_id.bytes.0 == before.windows[0].window_id.bytes.0)
        }
    }

    @Test func workspaceApplyUsesDeterministicTargetCreatedColumnId() {
        withContext { sourceContext in
            withContext { targetContext in
                let sourceCol = makeUUID(1)
                let sourceWin = makeUUID(10)
                let targetCol = makeUUID(2)
                let targetWin = makeUUID(20)
                let createdTargetCol = makeUUID(99)

                let sourceSeedRC = seedRuntimeState(
                    context: sourceContext,
                    columns: [runtimeColumn(id: sourceCol, windowStart: 0, windowCount: 1)],
                    windows: [runtimeWindow(id: sourceWin, columnId: sourceCol, columnIndex: 0)]
                )
                #expect(sourceSeedRC == abiOK)

                let targetSeedRC = seedRuntimeState(
                    context: targetContext,
                    columns: [runtimeColumn(id: targetCol, windowStart: 0, windowCount: 1)],
                    windows: [runtimeWindow(id: targetWin, columnId: targetCol, columnIndex: 0)]
                )
                #expect(targetSeedRC == abiOK)

                let request = OmniNiriWorkspaceApplyRequest(
                    request: makeWorkspaceRequest(
                        op: UInt8(truncatingIfNeeded: OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE.rawValue),
                        sourceWindowIndex: 0,
                        maxVisibleColumns: 3
                    ),
                    has_target_created_column_id: 1,
                    target_created_column_id: createdTargetCol,
                    has_source_placeholder_column_id: 0,
                    source_placeholder_column_id: makeUUID(0)
                )

                let plannerCheck = runWorkspacePlan(
                    sourceColumns: [
                        OmniNiriStateColumnInput(
                            column_id: sourceCol,
                            window_start: 0,
                            window_count: 1,
                            active_tile_idx: 0,
                            is_tabbed: 0,
                            size_value: 1
                        )
                    ],
                    sourceWindows: [
                        OmniNiriStateWindowInput(
                            window_id: sourceWin,
                            column_id: sourceCol,
                            column_index: 0,
                            size_value: 1
                        )
                    ],
                    targetColumns: [
                        OmniNiriStateColumnInput(
                            column_id: targetCol,
                            window_start: 0,
                            window_count: 1,
                            active_tile_idx: 0,
                            is_tabbed: 0,
                            size_value: 1
                        )
                    ],
                    targetWindows: [
                        OmniNiriStateWindowInput(
                            window_id: targetWin,
                            column_id: targetCol,
                            column_index: 0,
                            size_value: 1
                        )
                    ],
                    request: request.request
                )
                #expect(plannerCheck.rc == abiOK)
                #expect(plannerCheck.result.applied == 1)

                let apply = runWorkspaceApply(
                    sourceContext: sourceContext,
                    targetContext: targetContext,
                    request: request
                )
                #expect(apply.rc == abiOK)
                #expect(apply.result.applied == 1)

                let targetExport = exportRuntimeState(context: targetContext)
                #expect(targetExport.rc == abiOK)
                #expect(targetExport.columns.count == 2)
                #expect(targetExport.windows.count == 2)
                if targetExport.columns.count > 1 {
                    #expect(targetExport.columns[1].column_id.bytes.0 == createdTargetCol.bytes.0)
                }
                let movedWindow = targetExport.windows.first { $0.window_id.bytes.0 == sourceWin.bytes.0 }
                #expect(movedWindow != nil)
                #expect(movedWindow?.column_id.bytes.0 == createdTargetCol.bytes.0)
            }
        }
    }

    @Test func workspaceApplyUsesDeterministicSourcePlaceholderColumnId() {
        withContext { sourceContext in
            withContext { targetContext in
                let sourceCol = makeUUID(1)
                let sourceWin = makeUUID(10)
                let targetCol = makeUUID(2)
                let targetWin = makeUUID(20)
                let placeholderCol = makeUUID(77)

                let sourceSeedRC = seedRuntimeState(
                    context: sourceContext,
                    columns: [runtimeColumn(id: sourceCol, windowStart: 0, windowCount: 1)],
                    windows: [runtimeWindow(id: sourceWin, columnId: sourceCol, columnIndex: 0)]
                )
                #expect(sourceSeedRC == abiOK)

                let targetSeedRC = seedRuntimeState(
                    context: targetContext,
                    columns: [runtimeColumn(id: targetCol, windowStart: 0, windowCount: 1)],
                    windows: [runtimeWindow(id: targetWin, columnId: targetCol, columnIndex: 0)]
                )
                #expect(targetSeedRC == abiOK)

                let request = OmniNiriWorkspaceApplyRequest(
                    request: makeWorkspaceRequest(
                        op: UInt8(truncatingIfNeeded: OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE.rawValue),
                        sourceColumnIndex: 0
                    ),
                    has_target_created_column_id: 0,
                    target_created_column_id: makeUUID(0),
                    has_source_placeholder_column_id: 1,
                    source_placeholder_column_id: placeholderCol
                )

                let apply = runWorkspaceApply(
                    sourceContext: sourceContext,
                    targetContext: targetContext,
                    request: request
                )
                #expect(apply.rc == abiOK)
                #expect(apply.result.applied == 1)

                let sourceExport = exportRuntimeState(context: sourceContext)
                #expect(sourceExport.rc == abiOK)
                #expect(sourceExport.columns.count == 1)
                #expect(sourceExport.columns[0].column_id.bytes.0 == placeholderCol.bytes.0)
                #expect(sourceExport.windows.isEmpty)
            }
        }
    }

    @Test func navigationApplyReturnsTargetAndMutatesActiveTileByColumnId() {
        withContext { context in
            let columnID = makeUUID(1)
            let firstWindowID = makeUUID(10)
            let secondWindowID = makeUUID(11)

            let seedRC = seedRuntimeState(
                context: context,
                columns: [runtimeColumn(id: columnID, windowStart: 0, windowCount: 2, activeTileIdx: 0, isTabbed: true)],
                windows: [
                    runtimeWindow(id: firstWindowID, columnId: columnID, columnIndex: 0),
                    runtimeWindow(id: secondWindowID, columnId: columnID, columnIndex: 0),
                ]
            )
            #expect(seedRC == abiOK)

            let request = OmniNiriNavigationApplyRequest(
                request: OmniNiriNavigationRequest(
                    op: UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_MOVE_VERTICAL.rawValue),
                    direction: UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_UP.rawValue),
                    orientation: UInt8(truncatingIfNeeded: OMNI_NIRI_ORIENTATION_HORIZONTAL.rawValue),
                    infinite_loop: 0,
                    selected_window_index: 0,
                    selected_column_index: 0,
                    selected_row_index: 0,
                    step: 0,
                    target_row_index: -1,
                    target_column_index: -1,
                    target_window_index: -1
                )
            )

            let apply = runNavigationApply(context: context, request: request)
            #expect(apply.rc == abiOK)
            #expect(apply.result.applied == 1)
            #expect(apply.result.has_target_window_id == 1)
            #expect(apply.result.target_window_id.bytes.0 == secondWindowID.bytes.0)
            #expect(apply.result.update_target_active_tile == 1)
            #expect(apply.result.target_column_id.bytes.0 == columnID.bytes.0)
            #expect(apply.result.target_active_tile_idx == 1)
            #expect(apply.result.refresh_tabbed_visibility_target == 1)
            #expect(apply.result.refresh_target_column_id.bytes.0 == columnID.bytes.0)

            let exported = exportRuntimeState(context: context)
            #expect(exported.rc == abiOK)
            #expect(exported.columns.count == 1)
            #expect(exported.columns[0].active_tile_idx == 1)
        }
    }
}
