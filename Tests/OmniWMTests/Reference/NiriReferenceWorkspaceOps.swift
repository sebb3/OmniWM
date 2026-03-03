import Foundation

@testable import OmniWM

enum NiriReferenceWorkspaceOps {
    static func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState,
        engine: NiriLayoutEngine
    ) -> NiriLayoutEngine.WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard engine.roots[sourceWorkspaceId] != nil,
              let sourceColumn = engine.findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let targetRoot = engine.ensureRoot(for: targetWorkspaceId)
        let fallbackSelection = engine.fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        window.detach()

        let targetColumn: NiriContainer
        if let existingColumn = engine.claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            existingColumn.width = .proportion(1.0 / CGFloat(engine.maxVisibleColumns))
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            newColumn.width = .proportion(1.0 / CGFloat(engine.maxVisibleColumns))
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        targetColumn.appendChild(window)

        engine.cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)
        sourceState.selectedNodeId = fallbackSelection
        targetState.selectedNodeId = window.id

        return NiriLayoutEngine.WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: window.handle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    static func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState,
        engine: NiriLayoutEngine
    ) -> NiriLayoutEngine.WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = engine.roots[sourceWorkspaceId],
              engine.columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = engine.ensureRoot(for: targetWorkspaceId)
        engine.removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        let allCols = engine.columns(in: sourceWorkspaceId)
        var fallbackSelection: NodeId?
        if let colIdx = engine.columnIndex(of: column, in: sourceWorkspaceId) {
            if colIdx > 0 {
                fallbackSelection = allCols[colIdx - 1].firstChild()?.id
            } else if allCols.count > 1 {
                fallbackSelection = allCols[1].firstChild()?.id
            }
        }

        column.detach()
        targetRoot.appendChild(column)

        if sourceRoot.columns.isEmpty {
            sourceRoot.appendChild(NiriContainer())
        }

        sourceState.selectedNodeId = fallbackSelection
        targetState.selectedNodeId = column.firstChild()?.id

        return NiriLayoutEngine.WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: column.windowNodes.first?.handle,
            targetWorkspaceId: targetWorkspaceId
        )
    }
}
