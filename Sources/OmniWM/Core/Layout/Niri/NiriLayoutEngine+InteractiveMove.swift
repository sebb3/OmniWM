import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowHandle: windowHandle,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            animate: false,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            in: workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            case .before, .after:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }

        case .columnGap, .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let interaction = interactionState(for: workspaceId) else { return nil }
        guard let result = NiriLayoutZigKernel.hitTestMoveTarget(
            context: interaction.context,
            interaction: interaction.index,
            point: point,
            excludingWindowId: excludingWindowId,
            isInsertMode: isInsertMode
        ) else {
            return nil
        }

        return .window(
            nodeId: result.window.id,
            handle: result.window.handle,
            insertPosition: result.insertPosition
        )
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let plan = planMutation(
            op: .swapWindowsByMove,
            sourceWindow: sourceWindow,
            targetWindow: targetWindow,
            in: workspaceId
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        ensureSelectionVisible(
            node: applyOutcome.targetWindow ?? sourceWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let plan = planMutation(
            op: .insertWindowByMove,
            sourceWindow: sourceWindow,
            targetWindow: targetWindow,
            insertPosition: position,
            in: workspaceId
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        ensureSelectionVisible(
            node: applyOutcome.targetWindow ?? sourceWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat
    ) -> CGRect? {
        guard let interaction = interactionState(for: workspaceId) else { return nil }
        return NiriLayoutZigKernel.insertionDropzoneFrame(
            context: interaction.context,
            interaction: interaction.index,
            targetWindowId: targetWindowId,
            position: position,
            gap: gaps
        )
    }
}
