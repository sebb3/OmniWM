import Foundation

@testable import OmniWM

enum NiriReferenceLifecycleRuntimeApplier {
    struct ApplyOutcome {
        let applied: Bool
        let targetWindow: NiriWindow?
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

    static func apply(
        outcome: NiriStateZigKernel.MutationOutcome,
        snapshot: NiriStateZigKernel.Snapshot,
        engine: NiriLayoutEngine,
        incomingWindowHandle: WindowHandle? = nil
    ) -> ApplyOutcome {
        guard outcome.rc == 0 else {
            return ApplyOutcome(applied: false, targetWindow: nil)
        }
        guard outcome.applied else {
            return ApplyOutcome(applied: true, targetWindow: nil)
        }

        var targetWindow: NiriWindow?
        if let targetIndex = outcome.targetWindowIndex {
            targetWindow = window(at: targetIndex, snapshot: snapshot)
        }

        for edit in outcome.edits {
            switch edit.kind {
            case .setActiveTile:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }
                targetColumn.setActiveTileIdx(edit.valueA)

            case .removeColumnIfEmpty:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }
                if targetColumn.children.isEmpty {
                    let parentRoot = targetColumn.parent as? NiriRoot
                    targetColumn.remove()
                    if let parentRoot, parentRoot.columns.isEmpty {
                        parentRoot.appendChild(NiriContainer())
                    }
                }

            case .refreshTabbedVisibility:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }
                engine.updateTabbedColumnVisibility(column: targetColumn)

            case .insertIncomingWindowIntoColumn:
                guard let incomingWindowHandle,
                      let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
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
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }

                let visibleColumns = max(1, edit.valueA)
                let newColumn = NiriContainer()
                newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))

                if edit.subjectIndex >= 0 {
                    guard let referenceColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                        return ApplyOutcome(applied: false, targetWindow: targetWindow)
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
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }
                engine.closingHandles.remove(removedWindow.handle)
                removedWindow.remove()
                engine.handleToNode.removeValue(forKey: removedWindow.handle)

            case .resetAllColumnCachedWidths:
                guard let targetRoot = root(snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow)
                }
                for column in targetRoot.columns {
                    column.cachedWidth = 0
                }

            default:
                return ApplyOutcome(applied: false, targetWindow: targetWindow)
            }
        }

        return ApplyOutcome(applied: true, targetWindow: targetWindow)
    }
}
