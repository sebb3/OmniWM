import AppKit
import Foundation

extension NiriLayoutEngine {
    private func lifecycleContractFailure(
        op: NiriStateZigKernel.MutationOp,
        workspaceId: WorkspaceDescriptor.ID?,
        sourceHandle: WindowHandle? = nil,
        reason: String
    ) -> Never {
        let workspaceDescription = workspaceId.map { String(describing: $0) } ?? "nil"
        let sourceDescription: String
        if let sourceHandle {
            sourceDescription = "pid=\(sourceHandle.pid) id=\(sourceHandle.id)"
        } else {
            sourceDescription = "nil"
        }
        preconditionFailure(
            "Niri lifecycle \(op) contract failed: workspace=\(workspaceDescription), source=\(sourceDescription), reason=\(reason)"
        )
    }

    func hiddenWindowHandles(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect? = nil,
        gaps: CGFloat = 0
    ) -> [WindowHandle: HideSide] {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return [:] }

        guard let workingFrame else {
            return [:]
        }

        let viewOffset = state.viewOffsetPixels.current()
        let viewLeft = -viewOffset
        let viewRight = viewLeft + workingFrame.width

        var columnPositions = [CGFloat]()
        columnPositions.reserveCapacity(cols.count)
        var runningX: CGFloat = 0
        for column in cols {
            columnPositions.append(runningX)
            runningX += column.cachedWidth + gaps
        }

        var hiddenHandles = [WindowHandle: HideSide]()
        for (colIdx, column) in cols.enumerated() {
            let colX = columnPositions[colIdx]
            let colRight = colX + column.cachedWidth

            if colRight <= viewLeft {
                for window in column.windowNodes {
                    hiddenHandles[window.handle] = .left
                }
            } else if colX >= viewRight {
                for window in column.windowNodes {
                    hiddenHandles[window.handle] = .right
                }
            } else {
                for window in column.windowNodes {
                    if let windowFrame = window.frame {
                        let visibleWidth = min(windowFrame.maxX, workingFrame.maxX) - max(
                            windowFrame.minX,
                            workingFrame.minX
                        )
                        if visibleWidth < 1.0 {
                            let side: HideSide = windowFrame.midX < workingFrame.midX ? .left : .right
                            hiddenHandles[window.handle] = side
                        }
                    }
                }
            }
        }
        return hiddenHandles
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        guard let node = handleToNode[handle] else { return }
        node.constraints = constraints
    }

    private func planLifecycleMutation(
        op: NiriStateZigKernel.MutationOp,
        in workspaceId: WorkspaceDescriptor.ID,
        sourceWindow: NiriWindow? = nil,
        selectedNodeId: NodeId? = nil,
        focusedHandle: WindowHandle? = nil
    ) -> (snapshot: NiriStateZigKernel.Snapshot, outcome: NiriStateZigKernel.MutationOutcome)? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))

        let sourceWindowIndex: Int
        if let sourceWindow {
            guard let resolvedIndex = snapshot.windowIndexByNodeId[sourceWindow.id] else {
                return nil
            }
            sourceWindowIndex = resolvedIndex
        } else {
            sourceWindowIndex = -1
        }

        let focusedWindowIndex: Int
        if let focusedHandle,
           let focusedNode = handleToNode[focusedHandle],
           let resolvedFocusedIndex = snapshot.windowIndexByNodeId[focusedNode.id]
        {
            focusedWindowIndex = resolvedFocusedIndex
        } else {
            focusedWindowIndex = -1
        }

        let selectedTarget = NiriStateZigKernel.mutationNodeTarget(
            for: selectedNodeId,
            snapshot: snapshot
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: op,
            sourceWindowIndex: sourceWindowIndex,
            maxVisibleColumns: maxVisibleColumns,
            selectedNodeKind: selectedTarget.kind,
            selectedNodeIndex: selectedTarget.index,
            focusedWindowIndex: focusedWindowIndex
        )

        let outcome = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
        guard outcome.rc == 0 else {
            return nil
        }

        return (snapshot, outcome)
    }

    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> NiriWindow {
        _ = ensureRoot(for: workspaceId)

        guard let plan = planLifecycleMutation(
            op: .addWindow,
            in: workspaceId,
            selectedNodeId: selectedNodeId,
            focusedHandle: focusedHandle
        ) else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "planner returned nil"
            )
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self,
            incomingWindowHandle: handle
        )
        guard applyOutcome.applied, let targetWindow = applyOutcome.targetWindow else {
            lifecycleContractFailure(
                op: .addWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "applier returned applied=false or missing target window"
            )
        }
        return targetWindow
    }

    func removeWindow(handle: WindowHandle) {
        guard let node = handleToNode[handle] else { return }
        guard let workspaceId = node.findRoot()?.workspaceId else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: nil,
                sourceHandle: handle,
                reason: "source node has no root workspace"
            )
        }
        guard let plan = planLifecycleMutation(
            op: .removeWindow,
            in: workspaceId,
            sourceWindow: node
        ) else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "planner returned nil"
            )
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            lifecycleContractFailure(
                op: .removeWindow,
                workspaceId: workspaceId,
                sourceHandle: handle,
                reason: "applier returned applied=false"
            )
        }
    }

    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> Set<WindowHandle> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet

        var currentIdSet = Set<UUID>(minimumCapacity: handles.count)
        for handle in handles {
            currentIdSet.insert(handle.id)
        }

        var removedHandles = Set<WindowHandle>()

        for window in root.allWindows {
            if !currentIdSet.contains(window.windowId) {
                removedHandles.insert(window.handle)
                removeWindow(handle: window.handle)
            }
        }

        for handle in handles {
            if !existingIdSet.contains(handle.id) {
                _ = addWindow(
                    handle: handle,
                    to: workspaceId,
                    afterSelection: selectedNodeId,
                    focusedHandle: focusedHandle
                )
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        let selectedTarget = NiriStateZigKernel.mutationNodeTarget(
            for: selectedNodeId,
            snapshot: snapshot
        )
        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeKind: selectedTarget.kind,
            selectedNodeIndex: selectedTarget.index
        )
        let outcome = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
        guard outcome.rc == 0 else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }
        return NiriStateZigKernel.nodeId(from: outcome.targetNode, snapshot: snapshot)
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard let sourceWindowIndex = snapshot.windowIndexByNodeId[removingNodeId] else {
            return nil
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .fallbackSelectionOnRemoval,
            sourceWindowIndex: sourceWindowIndex
        )
        let outcome = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
        guard outcome.rc == 0 else { return nil }
        return NiriStateZigKernel.nodeId(from: outcome.targetNode, snapshot: snapshot)
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for handle: WindowHandle) {
        guard let node = findNode(for: handle) else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(roots.values.flatMap(\.allWindows))
        }

        let candidates = allWindows.filter { window in
            window.id != excludingNodeId && window.lastFocusedTime != nil
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }

}
