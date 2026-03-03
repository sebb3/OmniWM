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
}
