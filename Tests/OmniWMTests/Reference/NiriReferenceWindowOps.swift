import Foundation

@testable import OmniWM

private let mutationOK: Int32 = 0
private let mutationErrInvalidArgs: Int32 = -1
private let mutationErrOutOfRange: Int32 = -2

enum NiriReferenceWindowOps {
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

    static func resolve(
        snapshot: NiriStateZigKernel.Snapshot,
        request: NiriStateZigKernel.MutationRequest
    ) -> NiriStateZigKernel.MutationOutcome {
        guard let source = parseWindowContext(snapshot: snapshot, windowIndex: request.sourceWindowIndex) else {
            return outcome(rc: mutationErrOutOfRange)
        }

        switch request.op {
        case .moveWindowVertical, .swapWindowVertical:
            guard let direction = request.direction else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            let sourceColumn = snapshot.columns[source.columnIndex]
            let sourceCount = Int(sourceColumn.window_count)
            guard sourceCount > 0 else { return outcome() }

            let targetRow: Int?
            switch direction {
            case .up:
                targetRow = source.rowIndex + 1 < sourceCount ? source.rowIndex + 1 : nil
            case .down:
                targetRow = source.rowIndex > 0 ? source.rowIndex - 1 : nil
            default:
                return outcome(rc: mutationErrInvalidArgs)
            }

            guard let targetRow else { return outcome() }
            let targetWindowIndex = Int(sourceColumn.window_start) + targetRow
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(.swapWindows, subject: source.windowIndex, related: targetWindowIndex)
            ]

            if sourceColumn.is_tabbed != 0 {
                if source.rowIndex == Int(sourceColumn.active_tile_idx) {
                    edits.append(
                        makeEdit(.setActiveTile, subject: source.columnIndex, valueA: targetRow)
                    )
                } else if targetRow == Int(sourceColumn.active_tile_idx) {
                    edits.append(
                        makeEdit(.setActiveTile, subject: source.columnIndex, valueA: source.rowIndex)
                    )
                }
            }

            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .moveWindowHorizontal:
            guard let direction = request.direction else {
                return outcome(rc: mutationErrInvalidArgs)
            }
            guard request.maxWindowsPerColumn > 0 else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let step: Int
            switch direction {
            case .right:
                step = 1
            case .left:
                step = -1
            default:
                return outcome(rc: mutationErrInvalidArgs)
            }

            guard let targetColumnIndex = wrappedColumnIndex(
                source.columnIndex + step,
                total: snapshot.columns.count,
                infiniteLoop: request.infiniteLoop
            ), targetColumnIndex != source.columnIndex
            else {
                return outcome()
            }

            let targetColumn = snapshot.columns[targetColumnIndex]
            if Int(targetColumn.window_count) >= request.maxWindowsPerColumn {
                return outcome()
            }

            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .moveWindowToColumnIndex,
                    subject: source.windowIndex,
                    related: targetColumnIndex,
                    valueA: Int(targetColumn.window_count)
                )
            ]

            if sourceColumn.is_tabbed != 0 {
                let remaining = Int(sourceColumn.window_count) - 1
                if remaining > 0 {
                    let newActive = adjustedTabbedActiveAfterRemoval(
                        activeTileIdx: Int(sourceColumn.active_tile_idx),
                        windowCount: Int(sourceColumn.window_count),
                        removedRow: source.rowIndex
                    )
                    edits.append(
                        makeEdit(.setActiveTile, subject: source.columnIndex, valueA: newActive)
                    )
                    edits.append(
                        makeEdit(.refreshTabbedVisibility, subject: source.columnIndex)
                    )
                }
            } else {
                let remaining = Int(sourceColumn.window_count) - 1
                if remaining > 0 {
                    edits.append(
                        makeEdit(
                            .setActiveTile,
                            subject: source.columnIndex,
                            valueA: min(Int(sourceColumn.active_tile_idx), remaining - 1)
                        )
                    )
                }
            }

            if targetColumn.is_tabbed != 0 {
                edits.append(
                    makeEdit(.refreshTabbedVisibility, subject: targetColumnIndex)
                )
            }

            edits.append(
                makeEdit(.removeColumnIfEmpty, subject: source.columnIndex)
            )

            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .swapWindowHorizontal:
            guard let direction = request.direction else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let step: Int
            switch direction {
            case .right:
                step = 1
            case .left:
                step = -1
            default:
                return outcome(rc: mutationErrInvalidArgs)
            }

            guard let targetColumnIndex = wrappedColumnIndex(
                source.columnIndex + step,
                total: snapshot.columns.count,
                infiniteLoop: request.infiniteLoop
            ), targetColumnIndex != source.columnIndex
            else {
                return outcome()
            }

            let targetColumn = snapshot.columns[targetColumnIndex]
            let targetCount = Int(targetColumn.window_count)
            guard targetCount > 0 else { return outcome() }

            let sourceCount = Int(sourceColumn.window_count)
            if sourceCount == 1, targetCount == 1 {
                return outcome(
                    applied: true,
                    edits: [
                        makeEdit(
                            .delegateMoveColumn,
                            subject: source.columnIndex,
                            valueA: direction == .left ? 0 : 1
                        )
                    ]
                )
            }

            let sourceActive = min(Int(sourceColumn.active_tile_idx), sourceCount - 1)
            let targetActive = min(Int(targetColumn.active_tile_idx), targetCount - 1)
            let sourceActiveWindow = Int(sourceColumn.window_start) + sourceActive
            let targetActiveWindow = Int(targetColumn.window_start) + targetActive

            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(.swapWindows, subject: sourceActiveWindow, related: targetActiveWindow),
                makeEdit(.swapColumnWidthState, subject: source.columnIndex, related: targetColumnIndex),
                makeEdit(.setActiveTile, subject: source.columnIndex, valueA: sourceActive),
                makeEdit(.setActiveTile, subject: targetColumnIndex, valueA: targetActive),
            ]

            if sourceColumn.is_tabbed != 0 {
                edits.append(makeEdit(.refreshTabbedVisibility, subject: source.columnIndex))
            }
            if targetColumn.is_tabbed != 0 {
                edits.append(makeEdit(.refreshTabbedVisibility, subject: targetColumnIndex))
            }

            return outcome(applied: true, targetWindowIndex: sourceActiveWindow, edits: edits)

        case .swapWindowsByMove:
            guard let target = parseWindowContext(snapshot: snapshot, windowIndex: request.targetWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let targetColumn = snapshot.columns[target.columnIndex]
            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(.swapWindows, subject: source.windowIndex, related: target.windowIndex)
            ]

            if source.columnIndex != target.columnIndex {
                edits.append(
                    makeEdit(.swapWindowSizeHeight, subject: source.windowIndex, related: target.windowIndex)
                )
            }

            if sourceColumn.is_tabbed != 0 {
                edits.append(
                    makeEdit(
                        .setActiveTile,
                        subject: source.columnIndex,
                        valueA: min(Int(sourceColumn.active_tile_idx), Int(sourceColumn.window_count) - 1)
                    )
                )
            }

            if source.columnIndex != target.columnIndex, targetColumn.is_tabbed != 0 {
                edits.append(
                    makeEdit(
                        .setActiveTile,
                        subject: target.columnIndex,
                        valueA: min(Int(targetColumn.active_tile_idx), Int(targetColumn.window_count) - 1)
                    )
                )
            }

            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .insertWindowByMove:
            guard let target = parseWindowContext(snapshot: snapshot, windowIndex: request.targetWindowIndex) else {
                return outcome(rc: mutationErrOutOfRange)
            }
            guard let position = request.insertPosition, position == .before || position == .after else {
                return outcome(rc: mutationErrInvalidArgs)
            }

            let sourceColumn = snapshot.columns[source.columnIndex]
            let targetColumn = snapshot.columns[target.columnIndex]
            let sameColumn = source.columnIndex == target.columnIndex

            let insertIndex: Int
            if sameColumn {
                var currentTargetRow = target.rowIndex
                if source.rowIndex < target.rowIndex, currentTargetRow > 0 {
                    currentTargetRow -= 1
                }
                insertIndex = position == .before ? currentTargetRow : currentTargetRow + 1
            } else {
                insertIndex = position == .before ? target.rowIndex : target.rowIndex + 1
            }

            var edits: [NiriStateZigKernel.MutationEdit] = [
                makeEdit(
                    .moveWindowToColumnIndex,
                    subject: source.windowIndex,
                    related: target.columnIndex,
                    valueA: insertIndex
                ),
                makeEdit(.resetWindowSizeHeight, subject: source.windowIndex)
            ]

            if !sameColumn, Int(sourceColumn.window_count) == 1 {
                edits.append(makeEdit(.removeColumnIfEmpty, subject: source.columnIndex))
            }

            if sameColumn {
                if sourceColumn.is_tabbed != 0 {
                    edits.append(
                        makeEdit(
                            .setActiveTile,
                            subject: source.columnIndex,
                            valueA: min(Int(sourceColumn.active_tile_idx), Int(sourceColumn.window_count) - 1)
                        )
                    )
                }
            } else if Int(sourceColumn.window_count) > 1 {
                edits.append(
                    makeEdit(
                        .setActiveTile,
                        subject: source.columnIndex,
                        valueA: clampedActiveAfterRemoval(
                            activeTileIdx: Int(sourceColumn.active_tile_idx),
                            windowCount: Int(sourceColumn.window_count)
                        )
                    )
                )
            }

            if targetColumn.is_tabbed != 0 {
                edits.append(
                    makeEdit(
                        .setActiveTile,
                        subject: target.columnIndex,
                        valueA: min(Int(targetColumn.active_tile_idx), Int(targetColumn.window_count) - 1)
                    )
                )
            }

            return outcome(applied: true, targetWindowIndex: source.windowIndex, edits: edits)

        case .moveWindowToColumn,
             .createColumnAndMove,
             .insertWindowInNewColumn,
             .moveColumn,
             .consumeWindow,
             .expelWindow,
             .cleanupEmptyColumn,
             .normalizeColumnSizes,
             .normalizeWindowSizes,
             .balanceSizes,
             .addWindow,
             .removeWindow,
             .validateSelection,
             .fallbackSelectionOnRemoval:
            return outcome(rc: mutationErrInvalidArgs)
        }
    }
}
