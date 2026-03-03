import Foundation

@testable import OmniWM

private let lifecycleMutationOK: Int32 = 0
private let lifecycleMutationErrInvalidArgs: Int32 = -1

enum NiriReferenceLifecycleOps {
    private struct SelectedContext {
        let windowIndex: Int
        let columnIndex: Int
        let rowIndex: Int
    }

    private static func parseWindowContext(
        snapshot: NiriStateZigKernel.Snapshot,
        windowIndex: Int
    ) -> SelectedContext? {
        guard snapshot.windowEntries.indices.contains(windowIndex) else { return nil }
        let entry = snapshot.windowEntries[windowIndex]
        return SelectedContext(
            windowIndex: windowIndex,
            columnIndex: entry.columnIndex,
            rowIndex: entry.rowIndex
        )
    }

    private static func makeEdit(
        _ kind: NiriStateZigKernel.MutationEditKind,
        subject: Int,
        related: Int = -1,
        valueA: Int = -1,
        valueB: Int = -1
    ) -> NiriStateZigKernel.MutationEdit {
        NiriStateZigKernel.MutationEdit(
            kind: kind,
            subjectIndex: subject,
            relatedIndex: related,
            valueA: valueA,
            valueB: valueB
        )
    }

    private static func outcome(
        rc: Int32 = lifecycleMutationOK,
        applied: Bool = false,
        targetWindowIndex: Int? = nil,
        targetNode: NiriStateZigKernel.MutationNodeTarget? = nil,
        edits: [NiriStateZigKernel.MutationEdit] = []
    ) -> NiriStateZigKernel.MutationOutcome {
        NiriStateZigKernel.MutationOutcome(
            rc: rc,
            applied: applied,
            targetWindowIndex: targetWindowIndex,
            targetNode: targetNode,
            edits: edits
        )
    }

    private static func adjustedTabbedActiveAfterRemoval(
        activeTileIdx: Int,
        windowCount: Int,
        removedRow: Int
    ) -> Int {
        var active = activeTileIdx
        if removedRow == active {
            if windowCount > 1, removedRow >= windowCount - 1 {
                active = max(0, removedRow - 1)
            }
        } else if removedRow < active {
            active = max(0, active - 1)
        }
        return active
    }

    private static func selectedNodeTarget(
        snapshot: NiriStateZigKernel.Snapshot,
        request: NiriStateZigKernel.MutationRequest
    ) -> NiriStateZigKernel.MutationNodeTarget? {
        switch request.selectedNodeKind {
        case .none:
            return nil
        case .window:
            guard snapshot.windowEntries.indices.contains(request.selectedNodeIndex) else { return nil }
            return .init(kind: .window, index: request.selectedNodeIndex)
        case .column:
            guard snapshot.columnEntries.indices.contains(request.selectedNodeIndex) else { return nil }
            return .init(kind: .column, index: request.selectedNodeIndex)
        }
    }

    private static func columnIndex(
        for target: NiriStateZigKernel.MutationNodeTarget,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> Int? {
        switch target.kind {
        case .window:
            guard snapshot.windowEntries.indices.contains(target.index) else { return nil }
            return snapshot.windowEntries[target.index].columnIndex
        case .column:
            guard snapshot.columnEntries.indices.contains(target.index) else { return nil }
            return target.index
        case .none:
            return nil
        }
    }

    static func resolve(
        snapshot: NiriStateZigKernel.Snapshot,
        request: NiriStateZigKernel.MutationRequest
    ) -> NiriStateZigKernel.MutationOutcome {
        switch request.op {
        case .addWindow:
            guard request.maxVisibleColumns > 0 else {
                return outcome(rc: lifecycleMutationErrInvalidArgs)
            }
            guard !snapshot.columnEntries.isEmpty else { return outcome() }

            if snapshot.windowEntries.isEmpty,
               let emptyColumnIdx = snapshot.columnEntries.firstIndex(where: { $0.windowCount == 0 })
            {
                return outcome(
                    applied: true,
                    edits: [
                        makeEdit(
                            .insertIncomingWindowIntoColumn,
                            subject: emptyColumnIdx,
                            valueA: request.maxVisibleColumns
                        )
                    ]
                )
            }

            let referenceColumnIndex: Int
            if snapshot.windowEntries.indices.contains(request.focusedWindowIndex) {
                referenceColumnIndex = snapshot.windowEntries[request.focusedWindowIndex].columnIndex
            } else if let selectedTarget = selectedNodeTarget(snapshot: snapshot, request: request),
                      let selectedColumnIndex = columnIndex(for: selectedTarget, snapshot: snapshot)
            {
                referenceColumnIndex = selectedColumnIndex
            } else if let fallbackColumn = snapshot.columnEntries.last?.columnIndex {
                referenceColumnIndex = fallbackColumn
            } else {
                return outcome()
            }

            return outcome(
                applied: true,
                edits: [
                    makeEdit(
                        .insertIncomingWindowInNewColumn,
                        subject: referenceColumnIndex,
                        valueA: request.maxVisibleColumns
                    )
                ]
            )

        case .removeWindow:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome()
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(.removeWindowByIndex, subject: source.windowIndex),
            ]

            if sourceColumn.is_tabbed != 0, sourceColumn.window_count > 1 {
                let updatedActive = adjustedTabbedActiveAfterRemoval(
                    activeTileIdx: Int(sourceColumn.active_tile_idx),
                    windowCount: Int(sourceColumn.window_count),
                    removedRow: source.rowIndex
                )
                edits.append(
                    makeEdit(.setActiveTile, subject: source.columnIndex, valueA: updatedActive)
                )
                edits.append(
                    makeEdit(.refreshTabbedVisibility, subject: source.columnIndex)
                )
            } else if sourceColumn.window_count > 1 {
                let clampedActive = min(Int(sourceColumn.active_tile_idx), Int(sourceColumn.window_count) - 2)
                edits.append(
                    makeEdit(.setActiveTile, subject: source.columnIndex, valueA: clampedActive)
                )
            }

            edits.append(
                makeEdit(.removeColumnIfEmpty, subject: source.columnIndex)
            )

            if sourceColumn.window_count == 1, snapshot.columns.count > 1 {
                edits.append(
                    makeEdit(.resetAllColumnCachedWidths, subject: -1)
                )
            }

            return outcome(applied: true, edits: edits)

        case .validateSelection:
            if let selectedTarget = selectedNodeTarget(snapshot: snapshot, request: request) {
                let targetWindowIndex = selectedTarget.kind == .window ? selectedTarget.index : nil
                return outcome(
                    targetWindowIndex: targetWindowIndex,
                    targetNode: selectedTarget
                )
            }

            for column in snapshot.columns where column.window_count > 0 {
                let firstWindowIndex = Int(column.window_start)
                return outcome(
                    targetWindowIndex: firstWindowIndex,
                    targetNode: .init(kind: .window, index: firstWindowIndex)
                )
            }

            return outcome()

        case .fallbackSelectionOnRemoval:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome()
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let sourceColumnCount = Int(sourceColumn.window_count)
            if source.rowIndex + 1 < sourceColumnCount {
                let target = source.windowIndex + 1
                return outcome(
                    targetWindowIndex: target,
                    targetNode: .init(kind: .window, index: target)
                )
            }

            if source.rowIndex > 0 {
                let target = source.windowIndex - 1
                return outcome(
                    targetWindowIndex: target,
                    targetNode: .init(kind: .window, index: target)
                )
            }

            if source.columnIndex > 0 {
                let leftColumn = snapshot.columns[source.columnIndex - 1]
                if leftColumn.window_count > 0 {
                    let target = Int(leftColumn.window_start)
                    return outcome(
                        targetWindowIndex: target,
                        targetNode: .init(kind: .window, index: target)
                    )
                }
            }

            if source.columnIndex + 1 < snapshot.columns.count {
                let rightColumn = snapshot.columns[source.columnIndex + 1]
                if rightColumn.window_count > 0 {
                    let target = Int(rightColumn.window_start)
                    return outcome(
                        targetWindowIndex: target,
                        targetNode: .init(kind: .window, index: target)
                    )
                }
            }

            for idx in snapshot.columns.indices where idx != source.columnIndex {
                let column = snapshot.columns[idx]
                if column.window_count > 0 {
                    let target = Int(column.window_start)
                    return outcome(
                        targetWindowIndex: target,
                        targetNode: .init(kind: .window, index: target)
                    )
                }
            }

            return outcome()

        case .moveWindowVertical,
             .swapWindowVertical,
             .moveWindowHorizontal,
             .swapWindowHorizontal,
             .swapWindowsByMove,
             .insertWindowByMove,
             .moveWindowToColumn,
             .createColumnAndMove,
             .insertWindowInNewColumn,
             .moveColumn,
             .consumeWindow,
             .expelWindow,
             .cleanupEmptyColumn,
             .normalizeColumnSizes,
             .normalizeWindowSizes,
             .balanceSizes:
            return outcome(rc: lifecycleMutationErrInvalidArgs)
        }
    }
}
