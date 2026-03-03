import Foundation

enum NiriStateZigWorkspaceApplier {
    struct ApplyOutcome {
        let applied: Bool
        let newSourceFocusNodeId: NodeId?
        let targetSelectionNodeId: NodeId?
        let movedHandle: WindowHandle?
    }

    private enum SourceSelectionInstruction {
        case clear
        case window(index: Int)
    }

    private enum TargetSelectionInstruction {
        case movedWindow(index: Int)
        case movedColumnFirstWindow(index: Int)
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

    static func apply(
        outcome: NiriStateZigKernel.WorkspaceOutcome,
        request: NiriStateZigKernel.WorkspaceRequest,
        sourceSnapshot: NiriStateZigKernel.Snapshot,
        targetSnapshot: NiriStateZigKernel.Snapshot,
        sourceRoot: NiriRoot,
        targetRoot: NiriRoot,
        engine: NiriLayoutEngine
    ) -> ApplyOutcome {
        guard outcome.rc == 0, outcome.applied else {
            return ApplyOutcome(
                applied: false,
                newSourceFocusNodeId: nil,
                targetSelectionNodeId: nil,
                movedHandle: nil
            )
        }

        var sourceSelectionInstruction: SourceSelectionInstruction?
        var targetSelectionInstruction: TargetSelectionInstruction?
        var reuseTargetEmptyColumn = false
        var createTargetColumnVisibleCount: Int?
        var pruneTargetEmptyColumnsIfNoWindows = false
        var removeSourceColumnIfEmptyIndices: [Int] = []
        var ensureSourcePlaceholderIfNoColumns = false

        for edit in outcome.edits {
            switch edit.kind {
            case .setSourceSelectionWindow:
                guard sourceSnapshot.windowEntries.indices.contains(edit.subjectIndex) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                sourceSelectionInstruction = .window(index: edit.subjectIndex)

            case .setSourceSelectionNone:
                sourceSelectionInstruction = .clear

            case .reuseTargetEmptyColumn:
                guard targetSnapshot.columnEntries.indices.contains(edit.subjectIndex) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                reuseTargetEmptyColumn = true
                createTargetColumnVisibleCount = max(1, edit.valueA)

            case .createTargetColumnAppend:
                createTargetColumnVisibleCount = max(1, edit.valueA)

            case .pruneTargetEmptyColumnsIfNoWindows:
                pruneTargetEmptyColumnsIfNoWindows = true

            case .removeSourceColumnIfEmpty:
                guard sourceSnapshot.columnEntries.indices.contains(edit.subjectIndex) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                removeSourceColumnIfEmptyIndices.append(edit.subjectIndex)

            case .ensureSourcePlaceholderIfNoColumns:
                ensureSourcePlaceholderIfNoColumns = true

            case .setTargetSelectionMovedWindow:
                guard sourceSnapshot.windowEntries.indices.contains(edit.subjectIndex) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                targetSelectionInstruction = .movedWindow(index: edit.subjectIndex)

            case .setTargetSelectionMovedColumnFirstWindow:
                guard sourceSnapshot.columnEntries.indices.contains(edit.subjectIndex) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                targetSelectionInstruction = .movedColumnFirstWindow(index: edit.subjectIndex)
            }
        }

        if pruneTargetEmptyColumnsIfNoWindows {
            engine.removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)
        }

        var movedHandle: WindowHandle?

        switch request.op {
        case .moveWindowToWorkspace:
            guard let movingWindow = window(at: request.sourceWindowIndex, snapshot: sourceSnapshot) else {
                return ApplyOutcome(
                    applied: false,
                    newSourceFocusNodeId: nil,
                    targetSelectionNodeId: nil,
                    movedHandle: nil
                )
            }

            let visibleColumns = max(1, createTargetColumnVisibleCount ?? request.maxVisibleColumns)
            let targetColumn: NiriContainer
            if reuseTargetEmptyColumn {
                guard let existingColumn = engine.claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) else {
                    return ApplyOutcome(
                        applied: false,
                        newSourceFocusNodeId: nil,
                        targetSelectionNodeId: nil,
                        movedHandle: nil
                    )
                }
                existingColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
                targetColumn = existingColumn
            } else {
                let newColumn = NiriContainer()
                newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
                targetRoot.appendChild(newColumn)
                targetColumn = newColumn
            }

            movingWindow.detach()
            targetColumn.appendChild(movingWindow)
            movedHandle = movingWindow.handle

        case .moveColumnToWorkspace:
            guard let movingColumn = column(at: request.sourceColumnIndex, snapshot: sourceSnapshot) else {
                return ApplyOutcome(
                    applied: false,
                    newSourceFocusNodeId: nil,
                    targetSelectionNodeId: nil,
                    movedHandle: nil
                )
            }

            movingColumn.detach()
            targetRoot.appendChild(movingColumn)
            movedHandle = movingColumn.windowNodes.first?.handle
        }

        for columnIndex in removeSourceColumnIfEmptyIndices {
            guard let sourceColumn = column(at: columnIndex, snapshot: sourceSnapshot) else {
                return ApplyOutcome(
                    applied: false,
                    newSourceFocusNodeId: nil,
                    targetSelectionNodeId: nil,
                    movedHandle: movedHandle
                )
            }
            if sourceColumn.children.isEmpty {
                sourceColumn.remove()
                if sourceRoot.columns.isEmpty {
                    sourceRoot.appendChild(NiriContainer())
                }
            }
        }

        if ensureSourcePlaceholderIfNoColumns, sourceRoot.columns.isEmpty {
            sourceRoot.appendChild(NiriContainer())
        }

        let sourceSelectionNodeId: NodeId?
        switch sourceSelectionInstruction {
        case let .some(.window(index)):
            sourceSelectionNodeId = window(at: index, snapshot: sourceSnapshot)?.id
        case .some(.clear):
            sourceSelectionNodeId = nil
        case .none:
            sourceSelectionNodeId = nil
        }

        let targetSelectionNodeId: NodeId?
        switch targetSelectionInstruction {
        case let .movedWindow(index):
            targetSelectionNodeId = window(at: index, snapshot: sourceSnapshot)?.id
        case let .movedColumnFirstWindow(index):
            targetSelectionNodeId = column(at: index, snapshot: sourceSnapshot)?.firstChild()?.id
        case nil:
            targetSelectionNodeId = nil
        }

        return ApplyOutcome(
            applied: true,
            newSourceFocusNodeId: sourceSelectionNodeId,
            targetSelectionNodeId: targetSelectionNodeId,
            movedHandle: movedHandle
        )
    }
}
