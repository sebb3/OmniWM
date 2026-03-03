import CZigLayout
import Foundation

@testable import OmniWM

private let mutationOK: Int32 = 0
private let mutationErrInvalidArgs: Int32 = -1
private let mutationErrOutOfRange: Int32 = -2

enum NiriReferenceColumnOps {
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

    private static func parseColumnIndex(
        snapshot: NiriStateZigKernel.Snapshot,
        columnIndex: Int
    ) -> Int? {
        guard snapshot.columns.indices.contains(columnIndex) else { return nil }
        return columnIndex
    }

    private static func wrappedColumnIndex(
        _ idx: Int,
        total: Int,
        infiniteLoop: Bool
    ) -> Int? {
        guard total > 0 else { return nil }
        if infiniteLoop {
            return ((idx % total) + total) % total
        }
        return (0 ..< total).contains(idx) ? idx : nil
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

    private static func clampedActiveAfterRemoval(
        activeTileIdx: Int,
        windowCount: Int
    ) -> Int {
        guard windowCount > 1 else { return 0 }
        return min(activeTileIdx, windowCount - 2)
    }

    private static func makeEdit(
        _ kind: NiriStateZigKernel.MutationEditKind,
        subject: Int,
        related: Int = -1,
        valueA: Int = -1,
        valueB: Int = -1,
        scalarA: Double = 0,
        scalarB: Double = 0
    ) -> NiriStateZigKernel.MutationEdit {
        NiriStateZigKernel.MutationEdit(
            kind: kind,
            subjectIndex: subject,
            relatedIndex: related,
            valueA: valueA,
            valueB: valueB,
            scalarA: scalarA,
            scalarB: scalarB
        )
    }

    private static func outcome(
        rc: Int32 = mutationOK,
        applied: Bool = false,
        targetWindowIndex: Int? = nil,
        edits: [NiriStateZigKernel.MutationEdit] = []
    ) -> NiriStateZigKernel.MutationOutcome {
        NiriStateZigKernel.MutationOutcome(
            rc: rc,
            applied: applied,
            targetWindowIndex: targetWindowIndex,
            edits: edits
        )
    }

    private static func appendSourceRemovalEdits(
        column: OmniNiriStateColumnInput,
        columnIndex: Int,
        removedRow: Int,
        into edits: inout [NiriStateZigKernel.MutationEdit]
    ) {
        let windowCount = Int(column.window_count)
        let remaining = windowCount - 1
        guard remaining > 0 else { return }

        if column.is_tabbed != 0 {
            let newActive = adjustedTabbedActiveAfterRemoval(
                activeTileIdx: Int(column.active_tile_idx),
                windowCount: windowCount,
                removedRow: removedRow
            )
            edits.append(makeEdit(.setActiveTile, subject: columnIndex, valueA: newActive))
            edits.append(makeEdit(.refreshTabbedVisibility, subject: columnIndex))
            return
        }

        let clamped = clampedActiveAfterRemoval(
            activeTileIdx: Int(column.active_tile_idx),
            windowCount: windowCount
        )
        edits.append(makeEdit(.setActiveTile, subject: columnIndex, valueA: clamped))
    }

    static func resolve(
        snapshot: NiriStateZigKernel.Snapshot,
        request: NiriStateZigKernel.MutationRequest
    ) -> NiriStateZigKernel.MutationOutcome {
        switch request.op {
        case .moveWindowToColumn:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard let targetColumnIndex = parseColumnIndex(snapshot: snapshot, columnIndex: request.targetColumnIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            if targetColumnIndex == source.columnIndex {
                return outcome()
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let targetColumn = snapshot.columns[targetColumnIndex]
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .moveWindowToColumnIndex,
                    subject: source.windowIndex,
                    related: targetColumnIndex,
                    valueA: Int(targetColumn.window_count)
                )
            ]

            appendSourceRemovalEdits(
                column: sourceColumn,
                columnIndex: source.columnIndex,
                removedRow: source.rowIndex,
                into: &edits
            )

            if targetColumn.is_tabbed != 0 {
                edits.append(makeEdit(.refreshTabbedVisibility, subject: targetColumnIndex))
            }

            edits.append(makeEdit(.removeColumnIfEmpty, subject: source.columnIndex))
            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .createColumnAndMove:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard let direction = request.direction, direction == .left || direction == .right else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            guard request.maxVisibleColumns > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .createColumnAdjacentAndMoveWindow,
                    subject: source.windowIndex,
                    related: source.columnIndex,
                    valueA: direction == .left ? 0 : 1,
                    valueB: request.maxVisibleColumns
                )
            ]

            appendSourceRemovalEdits(
                column: sourceColumn,
                columnIndex: source.columnIndex,
                removedRow: source.rowIndex,
                into: &edits
            )

            edits.append(makeEdit(.removeColumnIfEmpty, subject: source.columnIndex))
            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .insertWindowInNewColumn:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard request.maxVisibleColumns > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let clampedInsertIndex = max(0, min(request.insertColumnIndex, snapshot.columns.count))
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .insertNewColumnAtIndexAndMoveWindow,
                    subject: source.windowIndex,
                    related: clampedInsertIndex,
                    valueA: request.maxVisibleColumns
                )
            ]

            appendSourceRemovalEdits(
                column: sourceColumn,
                columnIndex: source.columnIndex,
                removedRow: source.rowIndex,
                into: &edits
            )

            edits.append(makeEdit(.removeColumnIfEmpty, subject: source.columnIndex))
            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .moveColumn:
            guard let direction = request.direction, direction == .left || direction == .right else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            guard let sourceColumnIndex = parseColumnIndex(snapshot: snapshot, columnIndex: request.sourceColumnIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }

            let step = direction == .right ? 1 : -1
            guard let targetColumnIndex = wrappedColumnIndex(
                sourceColumnIndex + step,
                total: snapshot.columns.count,
                infiniteLoop: request.infiniteLoop
            ) else {
                return outcome()
            }
            if targetColumnIndex == sourceColumnIndex {
                return outcome()
            }

            return outcome(
                applied: true,
                edits: [makeEdit(.swapColumns, subject: sourceColumnIndex, related: targetColumnIndex)]
            )

        case .consumeWindow:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard let direction = request.direction, direction == .left || direction == .right else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            guard request.maxWindowsPerColumn > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let currentColumn = snapshot.columns[source.columnIndex]
            if Int(currentColumn.window_count) >= request.maxWindowsPerColumn {
                return outcome()
            }

            let step = direction == .right ? 1 : -1
            guard let neighborIndex = wrappedColumnIndex(
                source.columnIndex + step,
                total: snapshot.columns.count,
                infiniteLoop: request.infiniteLoop
            ), neighborIndex != source.columnIndex
            else {
                return outcome()
            }

            let neighborColumn = snapshot.columns[neighborIndex]
            if neighborColumn.window_count == 0 {
                return outcome()
            }

            let consumedRow = direction == .right ? 0 : Int(neighborColumn.window_count) - 1
            let consumedWindowIndex = Int(neighborColumn.window_start) + consumedRow
            let insertRow = direction == .right ? Int(currentColumn.window_count) : 0

            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .moveWindowToColumnIndex,
                    subject: consumedWindowIndex,
                    related: source.columnIndex,
                    valueA: insertRow
                )
            ]

            appendSourceRemovalEdits(
                column: neighborColumn,
                columnIndex: neighborIndex,
                removedRow: consumedRow,
                into: &edits
            )

            if currentColumn.is_tabbed != 0 {
                if direction == .left {
                    edits.append(
                        makeEdit(
                            .setActiveTile,
                            subject: source.columnIndex,
                            valueA: Int(currentColumn.active_tile_idx) + 1
                        )
                    )
                }
                edits.append(makeEdit(.refreshTabbedVisibility, subject: source.columnIndex))
            }

            edits.append(makeEdit(.removeColumnIfEmpty, subject: neighborIndex))
            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .expelWindow:
            guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard let direction = request.direction, direction == .left || direction == .right else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            guard request.maxVisibleColumns > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .createColumnAdjacentAndMoveWindow,
                    subject: source.windowIndex,
                    related: source.columnIndex,
                    valueA: direction == .left ? 0 : 1,
                    valueB: request.maxVisibleColumns
                )
            ]

            appendSourceRemovalEdits(
                column: sourceColumn,
                columnIndex: source.columnIndex,
                removedRow: source.rowIndex,
                into: &edits
            )

            edits.append(makeEdit(.removeColumnIfEmpty, subject: source.columnIndex))
            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .cleanupEmptyColumn:
            guard let sourceColumnIndex = parseColumnIndex(snapshot: snapshot, columnIndex: request.sourceColumnIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            let sourceColumn = snapshot.columns[sourceColumnIndex]
            guard sourceColumn.window_count == 0 else {
                return outcome()
            }
            // Preserve the root placeholder invariant in planner decisions.
            guard snapshot.columns.count > 1 else {
                return outcome()
            }
            return outcome(
                applied: true,
                edits: [makeEdit(.removeColumnIfEmpty, subject: sourceColumnIndex)]
            )

        case .normalizeColumnSizes:
            guard snapshot.columns.count > 1 else {
                return outcome()
            }

            let total = snapshot.columns.reduce(0.0) { $0 + $1.size_value }
            guard total > 0 else {
                return outcome()
            }

            let avg = total / Double(snapshot.columns.count)
            guard avg > 0 else {
                return outcome()
            }

            return outcome(
                applied: true,
                edits: [makeEdit(.normalizeColumnsByFactor, subject: -1, scalarA: 1.0 / avg)]
            )

        case .normalizeWindowSizes:
            guard let sourceColumnIndex = parseColumnIndex(snapshot: snapshot, columnIndex: request.sourceColumnIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }

            let sourceColumn = snapshot.columns[sourceColumnIndex]
            let count = Int(sourceColumn.window_count)
            guard count > 0 else {
                return outcome()
            }

            let start = Int(sourceColumn.window_start)
            let end = start + count
            guard start >= 0, end <= snapshot.windows.count else {
                return outcome(rc: mutationErrOutOfRange)
            }

            let total = snapshot.windows[start ..< end].reduce(0.0) { $0 + $1.size_value }
            guard total > 0 else {
                return outcome()
            }

            let avg = total / Double(count)
            guard avg > 0 else {
                return outcome()
            }

            return outcome(
                applied: true,
                edits: [makeEdit(.normalizeColumnWindowsByFactor, subject: sourceColumnIndex, scalarA: 1.0 / avg)]
            )

        case .balanceSizes:
            guard !snapshot.columns.isEmpty else {
                return outcome()
            }
            guard request.maxVisibleColumns > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let width = 1.0 / Double(request.maxVisibleColumns)
            return outcome(
                applied: true,
                edits: [
                    makeEdit(
                        .balanceColumns,
                        subject: -1,
                        valueA: request.maxVisibleColumns,
                        scalarA: width
                    )
                ]
            )

        case .moveWindowVertical,
             .swapWindowVertical,
             .moveWindowHorizontal,
             .swapWindowHorizontal,
             .swapWindowsByMove,
             .insertWindowByMove,
             .addWindow,
             .removeWindow,
             .validateSelection,
             .fallbackSelectionOnRemoval:
            return outcome(rc: mutationErrInvalidArgs)
        }
    }
}
