import Foundation

enum NiriStateZigMutationApplier {
    struct ApplyOutcome {
        let applied: Bool
        let targetWindow: NiriWindow?
        let delegatedMoveColumn: (column: NiriContainer, direction: Direction)?
    }

    private static func direction(from rawCode: Int) -> Direction? {
        switch rawCode {
        case 0:
            return .left
        case 1:
            return .right
        case 2:
            return .up
        case 3:
            return .down
        default:
            return nil
        }
    }

    private static func window(
        at index: Int,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriWindow? {
        guard snapshot.windowEntries.indices.contains(index) else { return nil }
        return snapshot.windowEntries[index].window
    }

    private static func column(
        at index: Int,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriContainer? {
        guard snapshot.columnEntries.indices.contains(index) else { return nil }
        return snapshot.columnEntries[index].column
    }

    private static func root(snapshot: NiriStateZigKernel.Snapshot) -> NiriRoot? {
        for entry in snapshot.columnEntries {
            if let root = entry.column.findRoot() {
                return root
            }
        }
        for entry in snapshot.windowEntries {
            if let root = entry.window.findRoot() {
                return root
            }
        }
        return nil
    }

    private static func clampedNormalizedSize(_ value: CGFloat) -> CGFloat {
        max(0.5, min(2.0, value))
    }

    static func apply(
        outcome: NiriStateZigKernel.MutationOutcome,
        snapshot: NiriStateZigKernel.Snapshot,
        engine: NiriLayoutEngine,
        incomingWindowHandle: WindowHandle? = nil
    ) -> ApplyOutcome {
        guard outcome.rc == 0, outcome.applied else {
            return ApplyOutcome(applied: false, targetWindow: nil, delegatedMoveColumn: nil)
        }

        var targetWindow: NiriWindow?
        if let targetIndex = outcome.targetWindowIndex {
            targetWindow = window(at: targetIndex, snapshot: snapshot)
        } else {
            targetWindow = nil
        }

        var delegatedMoveColumn: (column: NiriContainer, direction: Direction)?

        for edit in outcome.edits {
            switch edit.kind {
            case .setActiveTile:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                targetColumn.setActiveTileIdx(edit.valueA)

            case .swapWindows:
                guard let lhs = window(at: edit.subjectIndex, snapshot: snapshot),
                      let rhs = window(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                if lhs.parent === rhs.parent {
                    lhs.swapWith(rhs)
                } else if let lhsParent = lhs.parent as? NiriContainer,
                          let rhsParent = rhs.parent as? NiriContainer,
                          let lhsIndex = lhsParent.children.firstIndex(where: { $0 === lhs }),
                          let rhsIndex = rhsParent.children.firstIndex(where: { $0 === rhs })
                {
                    lhs.detach()
                    rhs.detach()
                    lhsParent.insertChild(rhs, at: lhsIndex)
                    rhsParent.insertChild(lhs, at: rhsIndex)
                } else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

            case .moveWindowToColumnIndex:
                guard let movingWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let targetColumn = column(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                movingWindow.detach()
                let insertRow = max(0, edit.valueA)
                targetColumn.insertChild(movingWindow, at: insertRow)

            case .swapColumnWidthState:
                guard let lhsColumn = column(at: edit.subjectIndex, snapshot: snapshot),
                      let rhsColumn = column(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let lhsWidth = lhsColumn.width
                let lhsIsFullWidth = lhsColumn.isFullWidth
                let lhsSavedWidth = lhsColumn.savedWidth
                let rhsWidth = rhsColumn.width
                let rhsIsFullWidth = rhsColumn.isFullWidth
                let rhsSavedWidth = rhsColumn.savedWidth

                lhsColumn.width = rhsWidth
                lhsColumn.isFullWidth = rhsIsFullWidth
                lhsColumn.savedWidth = rhsSavedWidth

                rhsColumn.width = lhsWidth
                rhsColumn.isFullWidth = lhsIsFullWidth
                rhsColumn.savedWidth = lhsSavedWidth

            case .swapWindowSizeHeight:
                guard let lhsWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let rhsWindow = window(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let lhsSize = lhsWindow.size
                let lhsHeight = lhsWindow.height
                lhsWindow.size = rhsWindow.size
                lhsWindow.height = rhsWindow.height
                rhsWindow.size = lhsSize
                rhsWindow.height = lhsHeight

            case .resetWindowSizeHeight:
                guard let targetWindow = window(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                targetWindow.size = 1.0
                targetWindow.height = .default

            case .removeColumnIfEmpty:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                if targetColumn.children.isEmpty {
                    let parentRoot = targetColumn.parent as? NiriRoot
                    targetColumn.remove()
                    if let parentRoot, parentRoot.columns.isEmpty {
                        // Planner should keep at least one placeholder column; this is a defensive backstop.
                        parentRoot.appendChild(NiriContainer())
                    }
                }

            case .refreshTabbedVisibility:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                engine.updateTabbedColumnVisibility(column: targetColumn)

            case .delegateMoveColumn:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot),
                      let direction = direction(from: edit.valueA)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                delegatedMoveColumn = (targetColumn, direction)

            case .createColumnAdjacentAndMoveWindow:
                guard let movingWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let sourceColumn = movingWindow.parent as? NiriContainer,
                      let root = sourceColumn.parent as? NiriRoot,
                      let insertDirection = direction(from: edit.valueA),
                      (insertDirection == .left || insertDirection == .right)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let visibleColumns = max(1, edit.valueB)
                let newColumn = NiriContainer()
                newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
                if insertDirection == .right {
                    root.insertAfter(newColumn, reference: sourceColumn)
                } else {
                    root.insertBefore(newColumn, reference: sourceColumn)
                }

                movingWindow.detach()
                newColumn.appendChild(movingWindow)
                movingWindow.isHiddenInTabbedMode = false

            case .insertNewColumnAtIndexAndMoveWindow:
                guard let movingWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let currentColumn = movingWindow.parent as? NiriContainer,
                      let root = currentColumn.parent as? NiriRoot
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let visibleColumns = max(1, edit.valueA)
                let newColumn = NiriContainer()
                newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))

                let cols = root.columns
                let clampedIndex = max(0, min(edit.relatedIndex, cols.count))
                if clampedIndex >= cols.count {
                    root.appendChild(newColumn)
                } else {
                    root.insertBefore(newColumn, reference: cols[clampedIndex])
                }

                movingWindow.detach()
                newColumn.appendChild(movingWindow)
                movingWindow.isHiddenInTabbedMode = false

            case .swapColumns:
                guard let lhsColumn = column(at: edit.subjectIndex, snapshot: snapshot),
                      let rhsColumn = column(at: edit.relatedIndex, snapshot: snapshot),
                      let root = lhsColumn.parent as? NiriRoot,
                      let rhsRoot = rhsColumn.parent as? NiriRoot,
                      root === rhsRoot
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                root.swapChildren(lhsColumn, rhsColumn)

            case .normalizeColumnsByFactor:
                guard let root = root(snapshot: snapshot), edit.scalarA > 0 else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                let factor = CGFloat(edit.scalarA)
                for column in root.columns {
                    let normalized = column.size * factor
                    column.size = clampedNormalizedSize(normalized)
                }

            case .normalizeColumnWindowsByFactor:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot), edit.scalarA > 0 else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                let factor = CGFloat(edit.scalarA)
                for window in targetColumn.windowNodes {
                    let normalized = window.size * factor
                    window.size = clampedNormalizedSize(normalized)
                }

            case .balanceColumns:
                guard let root = root(snapshot: snapshot), edit.scalarA > 0 else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                let balancedWidth = CGFloat(edit.scalarA)
                for column in root.columns {
                    column.width = .proportion(balancedWidth)
                    column.isFullWidth = false
                    column.savedWidth = nil
                    column.presetWidthIdx = nil
                    for window in column.windowNodes {
                        window.size = 1.0
                    }
                }

            case .insertIncomingWindowIntoColumn:
                guard let incomingWindowHandle,
                      let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let visibleColumns = max(1, edit.valueA)
                targetColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
                let windowNode = NiriWindow(handle: incomingWindowHandle)
                targetColumn.appendChild(windowNode)
                engine.handleToNode[incomingWindowHandle] = windowNode
                targetWindow = windowNode

            case .insertIncomingWindowInNewColumn:
                guard let incomingWindowHandle,
                      let targetRoot = root(snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let visibleColumns = max(1, edit.valueA)
                let newColumn = NiriContainer()
                newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
                if edit.subjectIndex >= 0 {
                    guard let referenceColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                        return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                    }
                    targetRoot.insertAfter(newColumn, reference: referenceColumn)
                } else {
                    targetRoot.appendChild(newColumn)
                }

                let windowNode = NiriWindow(handle: incomingWindowHandle)
                newColumn.appendChild(windowNode)
                engine.handleToNode[incomingWindowHandle] = windowNode
                targetWindow = windowNode

            case .removeWindowByIndex:
                guard let removedWindow = window(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                engine.closingHandles.remove(removedWindow.handle)
                removedWindow.remove()
                engine.handleToNode.removeValue(forKey: removedWindow.handle)

            case .resetAllColumnCachedWidths:
                guard let root = root(snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                for column in root.columns {
                    column.cachedWidth = 0
                }
            }
        }

        return ApplyOutcome(
            applied: true,
            targetWindow: targetWindow,
            delegatedMoveColumn: delegatedMoveColumn
        )
    }
}
