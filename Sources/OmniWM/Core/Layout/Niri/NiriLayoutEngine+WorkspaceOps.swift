import AppKit
import Foundation

extension NiriLayoutEngine {
    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              findColumn(containing: window, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceWindowIndex = sourceSnapshot.windowIndexByNodeId[window.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowIndex: sourceWindowIndex,
            maxVisibleColumns: maxVisibleColumns
        )
        let outcome = NiriStateZigKernel.resolveWorkspace(
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
        guard outcome.rc == 0 else { return nil }

        let applyOutcome = NiriStateZigWorkspaceApplier.apply(
            outcome: outcome,
            request: request,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            engine: self
        )
        guard applyOutcome.applied else { return nil }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceColumnIndex = sourceSnapshot.columnIndexByNodeId[column.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveColumnToWorkspace,
            sourceColumnIndex: sourceColumnIndex
        )
        let outcome = NiriStateZigKernel.resolveWorkspace(
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
        guard outcome.rc == 0 else { return nil }

        let applyOutcome = NiriStateZigWorkspaceApplier.apply(
            outcome: outcome,
            request: request,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            engine: self
        )
        guard applyOutcome.applied else { return nil }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }
}
