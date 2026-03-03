import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private struct ColumnMutationLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }

    mutating func nextBool(_ trueProbability: Double = 0.5) -> Bool {
        let value = Double(next() % 10_000) / 10_000.0
        return value < trueProbability
    }

    mutating func nextInt(_ range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func nextDouble(_ range: ClosedRange<Double>) -> Double {
        let raw = Double(next() % 1_000_000) / 1_000_000.0
        return range.lowerBound + raw * (range.upperBound - range.lowerBound)
    }
}

private func percentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

private func quantize(_ value: Double) -> Double {
    (value * 1_000_000_000).rounded() / 1_000_000_000
}

private func proportionalSignature(_ value: ProportionalSize) -> (kind: Int, value: Double) {
    switch value {
    case let .proportion(v):
        return (0, quantize(Double(v)))
    case let .fixed(v):
        return (1, quantize(Double(v)))
    }
}

private func weightedSignature(_ value: WeightedSize) -> (kind: Int, value: Double) {
    switch value {
    case let .auto(weight: w):
        return (0, quantize(Double(w)))
    case let .fixed(v):
        return (1, quantize(Double(v)))
    }
}

private struct ColumnWindowSignature: Equatable {
    let pid: Int32
    let size: Double
    let hiddenInTabbedMode: Bool
    let heightKind: Int
    let heightValue: Double
}

private struct ColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let widthKind: Int
    let widthValue: Double
    let isFullWidth: Bool
    let savedWidthKind: Int
    let savedWidthValue: Double
    let windows: [ColumnWindowSignature]
}

private struct ColumnLayoutSignature: Equatable {
    let columns: [ColumnSignature]
}

private func layoutSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> ColumnLayoutSignature {
    let columns = engine.columns(in: workspaceId).map { column -> ColumnSignature in
        let width = proportionalSignature(column.width)
        let savedWidth = proportionalSignature(column.savedWidth ?? .proportion(-1))
        let windows = column.windowNodes.map { window in
            let height = weightedSignature(window.height)
            return ColumnWindowSignature(
                pid: window.handle.pid,
                size: quantize(Double(window.size)),
                hiddenInTabbedMode: window.isHiddenInTabbedMode,
                heightKind: height.kind,
                heightValue: height.value
            )
        }

        return ColumnSignature(
            isTabbed: column.isTabbed,
            activeTileIdx: column.activeTileIdx,
            widthKind: width.kind,
            widthValue: width.value,
            isFullWidth: column.isFullWidth,
            savedWidthKind: savedWidth.kind,
            savedWidthValue: savedWidth.value,
            windows: windows
        )
    }

    return ColumnLayoutSignature(columns: columns)
}

private struct ColumnDualEngines {
    let zigEngine: NiriLayoutEngine
    let referenceEngine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let workingFrame: CGRect
    let gaps: CGFloat
}

private func appendMirroredWindow(
    pid: pid_t,
    zigColumn: NiriContainer,
    referenceColumn: NiriContainer,
    zigEngine: NiriLayoutEngine,
    referenceEngine: NiriLayoutEngine,
    size: CGFloat,
    height: WeightedSize
) {
    let zigHandle = makeTestHandle(pid: pid)
    let referenceHandle = makeTestHandle(pid: pid)
    let zigWindow = NiriWindow(handle: zigHandle)
    let referenceWindow = NiriWindow(handle: referenceHandle)

    zigWindow.size = size
    referenceWindow.size = size
    zigWindow.height = height
    referenceWindow.height = height

    zigColumn.appendChild(zigWindow)
    referenceColumn.appendChild(referenceWindow)
    zigEngine.handleToNode[zigHandle] = zigWindow
    referenceEngine.handleToNode[referenceHandle] = referenceWindow
}

private func makeRandomDualEngines(seed: UInt64) -> ColumnDualEngines {
    var rng = ColumnMutationLCG(seed: seed)
    let workspaceId = WorkspaceDescriptor.ID()
    let maxWindowsPerColumn = 8
    let maxVisibleColumns = 3
    let infiniteLoop = rng.nextBool(0.5)

    let zigEngine = NiriLayoutEngine(
        maxWindowsPerColumn: maxWindowsPerColumn,
        maxVisibleColumns: maxVisibleColumns,
        infiniteLoop: infiniteLoop
    )
    let referenceEngine = NiriLayoutEngine(
        maxWindowsPerColumn: maxWindowsPerColumn,
        maxVisibleColumns: maxVisibleColumns,
        infiniteLoop: infiniteLoop
    )

    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let referenceRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = referenceRoot

    let columnCount = rng.nextInt(2 ... 5)
    for col in 0 ..< columnCount {
        let zigColumn = NiriContainer()
        let referenceColumn = NiriContainer()
        let isTabbed = rng.nextBool(0.35)
        zigColumn.displayMode = isTabbed ? .tabbed : .normal
        referenceColumn.displayMode = isTabbed ? .tabbed : .normal

        let widthValue = CGFloat(rng.nextDouble(0.2 ... 0.9))
        zigColumn.width = .proportion(widthValue)
        referenceColumn.width = .proportion(widthValue)

        if rng.nextBool(0.2) {
            let saved = CGFloat(rng.nextDouble(0.2 ... 0.9))
            zigColumn.savedWidth = .proportion(saved)
            referenceColumn.savedWidth = .proportion(saved)
        }
        if rng.nextBool(0.15) {
            zigColumn.isFullWidth = true
            referenceColumn.isFullWidth = true
        }

        zigRoot.appendChild(zigColumn)
        referenceRoot.appendChild(referenceColumn)

        let windowCount = rng.nextInt(1 ... 4)
        for row in 0 ..< windowCount {
            let pid = pid_t(90_000 + col * 100 + row)
            let size = CGFloat(rng.nextDouble(0.5 ... 2.0))
            let height: WeightedSize = if rng.nextBool(0.3) {
                .fixed(CGFloat(rng.nextDouble(0.5 ... 1.8)))
            } else {
                .auto(weight: CGFloat(rng.nextDouble(0.5 ... 2.0)))
            }
            appendMirroredWindow(
                pid: pid,
                zigColumn: zigColumn,
                referenceColumn: referenceColumn,
                zigEngine: zigEngine,
                referenceEngine: referenceEngine,
                size: size,
                height: height
            )
        }

        let active = rng.nextInt(0 ... max(0, windowCount - 1))
        zigColumn.setActiveTileIdx(active)
        referenceColumn.setActiveTileIdx(active)
    }

    for column in zigEngine.columns(in: workspaceId).filter(\.isTabbed) {
        zigEngine.updateTabbedColumnVisibility(column: column)
    }
    for column in referenceEngine.columns(in: workspaceId).filter(\.isTabbed) {
        referenceEngine.updateTabbedColumnVisibility(column: column)
    }

    return ColumnDualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func windowIndex(
    in snapshot: NiriStateZigKernel.Snapshot,
    pid: Int32
) -> Int? {
    snapshot.windowEntries.firstIndex(where: { $0.window.handle.pid == pid })
}

private func assertMutationOutcomeParity(
    zig: NiriStateZigKernel.MutationOutcome,
    reference: NiriStateZigKernel.MutationOutcome
) {
    #expect(zig.rc == reference.rc)
    #expect(zig.applied == reference.applied)
    #expect(zig.targetWindowIndex == reference.targetWindowIndex)
    #expect(zig.edits.count == reference.edits.count)
    guard zig.edits.count == reference.edits.count else { return }

    for idx in 0 ..< zig.edits.count {
        let lhs = zig.edits[idx]
        let rhs = reference.edits[idx]
        #expect(lhs.kind == rhs.kind)
        #expect(lhs.subjectIndex == rhs.subjectIndex)
        #expect(lhs.relatedIndex == rhs.relatedIndex)
        #expect(lhs.valueA == rhs.valueA)
        #expect(lhs.valueB == rhs.valueB)
        #expect(abs(lhs.scalarA - rhs.scalarA) < 1e-12)
        #expect(abs(lhs.scalarB - rhs.scalarB) < 1e-12)
    }
}

private func applyZigMutationOutcome(
    engine: NiriLayoutEngine,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome
) -> Bool {
    guard outcome.rc == 0 else { return false }
    guard outcome.applied else { return false }

    let applyOutcome = NiriStateZigMutationApplier.apply(
        outcome: outcome,
        snapshot: snapshot,
        engine: engine
    )
    return applyOutcome.applied
}

private func applyReferenceMutationOutcome(
    engine: NiriLayoutEngine,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome
) -> Bool {
    guard outcome.rc == 0, outcome.applied else { return false }

    func window(at index: Int) -> NiriWindow? {
        guard snapshot.windowEntries.indices.contains(index) else { return nil }
        return snapshot.windowEntries[index].window
    }

    func column(at index: Int) -> NiriContainer? {
        guard snapshot.columnEntries.indices.contains(index) else { return nil }
        return snapshot.columnEntries[index].column
    }

    func root() -> NiriRoot? {
        if let root = snapshot.columnEntries.first?.column.findRoot() {
            return root
        }
        if let root = snapshot.windowEntries.first?.window.findRoot() {
            return root
        }
        return nil
    }

    func clampedNormalizedSize(_ value: CGFloat) -> CGFloat {
        max(0.5, min(2.0, value))
    }

    for edit in outcome.edits {
        switch edit.kind {
        case .setActiveTile:
            guard let targetColumn = column(at: edit.subjectIndex) else { return false }
            targetColumn.setActiveTileIdx(edit.valueA)

        case .moveWindowToColumnIndex:
            guard let movingWindow = window(at: edit.subjectIndex),
                  let targetColumn = column(at: edit.relatedIndex)
            else {
                return false
            }
            movingWindow.detach()
            targetColumn.insertChild(movingWindow, at: max(0, edit.valueA))

        case .removeColumnIfEmpty:
            guard let targetColumn = column(at: edit.subjectIndex) else { return false }
            if targetColumn.children.isEmpty {
                let parentRoot = targetColumn.parent as? NiriRoot
                targetColumn.remove()
                if let parentRoot, parentRoot.columns.isEmpty {
                    parentRoot.appendChild(NiriContainer())
                }
            }

        case .refreshTabbedVisibility:
            guard let targetColumn = column(at: edit.subjectIndex) else { return false }
            engine.updateTabbedColumnVisibility(column: targetColumn)

        case .createColumnAdjacentAndMoveWindow:
            guard let movingWindow = window(at: edit.subjectIndex),
                  let sourceColumn = movingWindow.parent as? NiriContainer,
                  let root = sourceColumn.parent as? NiriRoot
            else {
                return false
            }

            let direction: Direction
            switch edit.valueA {
            case 0:
                direction = .left
            case 1:
                direction = .right
            default:
                return false
            }

            let visibleColumns = max(1, edit.valueB)
            let newColumn = NiriContainer()
            newColumn.width = .proportion(1.0 / CGFloat(visibleColumns))
            if direction == .right {
                root.insertAfter(newColumn, reference: sourceColumn)
            } else {
                root.insertBefore(newColumn, reference: sourceColumn)
            }

            movingWindow.detach()
            newColumn.appendChild(movingWindow)
            movingWindow.isHiddenInTabbedMode = false

        case .insertNewColumnAtIndexAndMoveWindow:
            guard let movingWindow = window(at: edit.subjectIndex),
                  let currentColumn = movingWindow.parent as? NiriContainer,
                  let root = currentColumn.parent as? NiriRoot
            else {
                return false
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
            guard let lhsColumn = column(at: edit.subjectIndex),
                  let rhsColumn = column(at: edit.relatedIndex),
                  let root = lhsColumn.parent as? NiriRoot,
                  let rhsRoot = rhsColumn.parent as? NiriRoot,
                  root === rhsRoot
            else {
                return false
            }
            root.swapChildren(lhsColumn, rhsColumn)

        case .normalizeColumnsByFactor:
            guard let root = root(), edit.scalarA > 0 else { return false }
            let factor = CGFloat(edit.scalarA)
            for column in root.columns {
                column.size = clampedNormalizedSize(column.size * factor)
            }

        case .normalizeColumnWindowsByFactor:
            guard let targetColumn = column(at: edit.subjectIndex), edit.scalarA > 0 else { return false }
            let factor = CGFloat(edit.scalarA)
            for window in targetColumn.windowNodes {
                window.size = clampedNormalizedSize(window.size * factor)
            }

        case .balanceColumns:
            guard let root = root(), edit.scalarA > 0 else { return false }
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

        case .swapWindows,
             .swapColumnWidthState,
             .swapWindowSizeHeight,
             .resetWindowSizeHeight,
             .delegateMoveColumn,
             .insertIncomingWindowIntoColumn,
             .insertIncomingWindowInNewColumn,
             .removeWindowByIndex,
             .resetAllColumnCachedWidths:
            return false
        }
    }

    return true
}

private func assertMutationInvariants(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    let validation = NiriStateZigKernel.validate(snapshot: snapshot)
    #expect(validation.isValid)

    guard let root = engine.root(for: workspaceId) else {
        #expect(Bool(false), "missing root for invariants")
        return
    }

    #expect(!root.columns.isEmpty)
    #expect(root.allWindows.count == snapshot.windowEntries.count)

    for column in root.columns {
        if column.windowNodes.isEmpty {
            #expect(column.activeTileIdx == 0)
        } else {
            #expect(column.activeTileIdx >= 0)
            #expect(column.activeTileIdx < column.windowNodes.count)
        }

        if column.isTabbed {
            for (idx, window) in column.windowNodes.enumerated() {
                #expect(window.isHiddenInTabbedMode == (idx != column.activeTileIdx))
            }
        }
    }
}

@discardableResult
private func runMutationParityStep(
    dual: ColumnDualEngines,
    request: NiriStateZigKernel.MutationRequest
) -> (zig: NiriStateZigKernel.MutationOutcome, reference: NiriStateZigKernel.MutationOutcome) {
    let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
    let referenceSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.referenceEngine.columns(in: dual.workspaceId))

    let zigOutcome = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
    let referenceOutcome = NiriReferenceColumnOps.resolve(snapshot: referenceSnapshot, request: request)
    assertMutationOutcomeParity(zig: zigOutcome, reference: referenceOutcome)

    let zigApplied = applyZigMutationOutcome(
        engine: dual.zigEngine,
        snapshot: zigSnapshot,
        outcome: zigOutcome
    )
    let referenceApplied = applyReferenceMutationOutcome(
        engine: dual.referenceEngine,
        snapshot: referenceSnapshot,
        outcome: referenceOutcome
    )
    #expect(zigApplied == referenceApplied)

    assertMutationInvariants(engine: dual.zigEngine, workspaceId: dual.workspaceId)
    assertMutationInvariants(engine: dual.referenceEngine, workspaceId: dual.workspaceId)
    #expect(
        layoutSignature(engine: dual.zigEngine, workspaceId: dual.workspaceId) ==
            layoutSignature(engine: dual.referenceEngine, workspaceId: dual.workspaceId)
    )

    return (zig: zigOutcome, reference: referenceOutcome)
}

private func makeRandomMutationRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    engine: NiriLayoutEngine,
    rng: inout ColumnMutationLCG
) -> NiriStateZigKernel.MutationRequest {
    let hasWindows = !snapshot.windowEntries.isEmpty
    let hasColumns = !snapshot.columns.isEmpty

    let sourceWindowIndex = hasWindows ? rng.nextInt(0 ... snapshot.windowEntries.count - 1) : -1
    let targetColumnIndex = hasColumns ? rng.nextInt(0 ... snapshot.columns.count - 1) : -1
    let sourceColumnIndex = hasColumns ? rng.nextInt(0 ... snapshot.columns.count - 1) : -1
    let insertColumnIndex = hasColumns ? rng.nextInt(-2 ... snapshot.columns.count + 2) : -1

    let opChoice = rng.nextInt(0 ... 9)
    switch opChoice {
    case 0:
        if !hasWindows || !hasColumns {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .moveWindowToColumn,
            sourceWindowIndex: sourceWindowIndex,
            infiniteLoop: engine.infiniteLoop,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            targetColumnIndex: targetColumnIndex,
        )
    case 1:
        if !hasWindows {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .createColumnAndMove,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: engine.infiniteLoop,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            maxVisibleColumns: engine.maxVisibleColumns
        )
    case 2:
        if !hasWindows {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .insertWindowInNewColumn,
            sourceWindowIndex: sourceWindowIndex,
            infiniteLoop: engine.infiniteLoop,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            insertColumnIndex: insertColumnIndex,
            maxVisibleColumns: engine.maxVisibleColumns
        )
    case 3:
        if !hasColumns {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .moveColumn,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: engine.infiniteLoop,
            sourceColumnIndex: sourceColumnIndex
        )
    case 4:
        if !hasWindows {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .consumeWindow,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: engine.infiniteLoop,
            maxWindowsPerColumn: engine.maxWindowsPerColumn
        )
    case 5:
        if !hasWindows {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(
            op: .expelWindow,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: engine.infiniteLoop,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            maxVisibleColumns: engine.maxVisibleColumns
        )
    case 6:
        if !hasColumns {
            return .init(op: .normalizeColumnSizes)
        }
        let emptyColumns = snapshot.columnEntries.enumerated().compactMap { idx, entry in
            entry.windowCount == 0 ? idx : nil
        }
        let cleanupIdx = emptyColumns.isEmpty ? sourceColumnIndex : emptyColumns[rng.nextInt(0 ... emptyColumns.count - 1)]
        return .init(op: .cleanupEmptyColumn, sourceColumnIndex: cleanupIdx)
    case 7:
        return .init(op: .normalizeColumnSizes)
    case 8:
        if !hasColumns {
            return .init(op: .normalizeColumnSizes)
        }
        return .init(op: .normalizeWindowSizes, sourceColumnIndex: sourceColumnIndex)
    default:
        return .init(
            op: .balanceSizes,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            maxVisibleColumns: engine.maxVisibleColumns
        )
    }
}

private func executeRuntimeMutation(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    request: NiriStateZigKernel.MutationRequest,
    snapshot: NiriStateZigKernel.Snapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) -> Bool {
    switch request.op {
    case .moveWindowToColumn:
        guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex),
              snapshot.columnEntries.indices.contains(request.targetColumnIndex)
        else { return false }
        let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window
        guard let sourceColumn = engine.findColumn(containing: sourceWindow, in: workspaceId) else { return false }
        let targetColumn = snapshot.columnEntries[request.targetColumnIndex].column
        engine.moveWindowToColumn(
            sourceWindow,
            from: sourceColumn,
            to: targetColumn,
            in: workspaceId,
            state: &state
        )
        return true

    case .createColumnAndMove:
        guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex),
              let direction = request.direction
        else { return false }
        let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window
        guard let sourceColumn = engine.findColumn(containing: sourceWindow, in: workspaceId) else { return false }
        engine.createColumnAndMove(
            sourceWindow,
            from: sourceColumn,
            direction: direction,
            in: workspaceId,
            state: &state,
            gaps: gaps,
            workingAreaWidth: workingFrame.width
        )
        return true

    case .insertWindowInNewColumn:
        guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex) else { return false }
        let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window
        return engine.insertWindowInNewColumn(
            sourceWindow,
            insertIndex: request.insertColumnIndex,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .moveColumn:
        guard snapshot.columnEntries.indices.contains(request.sourceColumnIndex),
              let direction = request.direction
        else { return false }
        let column = snapshot.columnEntries[request.sourceColumnIndex].column
        return engine.moveColumn(
            column,
            direction: direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .consumeWindow:
        guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex),
              let direction = request.direction
        else { return false }
        let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window
        return engine.consumeWindow(
            into: sourceWindow,
            from: direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .expelWindow:
        guard snapshot.windowEntries.indices.contains(request.sourceWindowIndex),
              let direction = request.direction
        else { return false }
        let sourceWindow = snapshot.windowEntries[request.sourceWindowIndex].window
        return engine.expelWindow(
            sourceWindow,
            to: direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .cleanupEmptyColumn:
        guard snapshot.columnEntries.indices.contains(request.sourceColumnIndex) else { return false }
        let column = snapshot.columnEntries[request.sourceColumnIndex].column
        engine.cleanupEmptyColumn(column, in: workspaceId, state: &state)
        return true

    case .normalizeColumnSizes:
        engine.normalizeColumnSizes(in: workspaceId)
        return true

    case .normalizeWindowSizes:
        guard snapshot.columnEntries.indices.contains(request.sourceColumnIndex) else { return false }
        let column = snapshot.columnEntries[request.sourceColumnIndex].column
        engine.normalizeWindowSizes(in: column)
        return true

    case .balanceSizes:
        engine.balanceSizes(
            in: workspaceId,
            workingAreaWidth: workingFrame.width,
            gaps: gaps
        )
        return true

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
        return false
    }
}

@Suite(.serialized) struct NiriZigColumnOpsParityTests {
    @Test func phase4ScenarioMoveColumnWrapAndNoWrap() {
        let wrapDual = makeRandomDualEngines(seed: 0xAAA1)
        wrapDual.zigEngine.infiniteLoop = true
        wrapDual.referenceEngine.infiniteLoop = true

        let wrapSnapshot = NiriStateZigKernel.makeSnapshot(columns: wrapDual.zigEngine.columns(in: wrapDual.workspaceId))
        guard !wrapSnapshot.columns.isEmpty else {
            #expect(Bool(false), "missing columns for moveColumn wrap scenario")
            return
        }

        let wrapRequest = NiriStateZigKernel.MutationRequest(
            op: .moveColumn,
            direction: .left,
            infiniteLoop: true,
            sourceColumnIndex: 0
        )
        let wrapOutcome = runMutationParityStep(dual: wrapDual, request: wrapRequest)
        #expect(wrapOutcome.zig.applied)

        let noWrapDual = makeRandomDualEngines(seed: 0xAAA2)
        noWrapDual.zigEngine.infiniteLoop = false
        noWrapDual.referenceEngine.infiniteLoop = false
        let noWrapRequest = NiriStateZigKernel.MutationRequest(
            op: .moveColumn,
            direction: .left,
            infiniteLoop: false,
            sourceColumnIndex: 0
        )
        let noWrapOutcome = runMutationParityStep(dual: noWrapDual, request: noWrapRequest)
        #expect(!noWrapOutcome.zig.applied)
    }

    @Test func phase4ScenarioTabbedConsumeWindowUpdatesActiveTile() {
        let dual = makeRandomDualEngines(seed: 0xBEEF_B001)
        let wsId = dual.workspaceId

        let cols = dual.zigEngine.columns(in: wsId)
        guard cols.count >= 2 else {
            #expect(Bool(false), "need at least two columns for consume scenario")
            return
        }

        cols[0].displayMode = .normal
        cols[1].displayMode = .tabbed
        dual.referenceEngine.columns(in: wsId)[0].displayMode = .normal
        dual.referenceEngine.columns(in: wsId)[1].displayMode = .tabbed

        while cols[0].windowNodes.count < 2 {
            let nextPid = pid_t(95_000 + cols[0].windowNodes.count)
            appendMirroredWindow(
                pid: nextPid,
                zigColumn: cols[0],
                referenceColumn: dual.referenceEngine.columns(in: wsId)[0],
                zigEngine: dual.zigEngine,
                referenceEngine: dual.referenceEngine,
                size: 1.0,
                height: .auto(weight: 1.0)
            )
        }
        while cols[1].windowNodes.count < 2 {
            let nextPid = pid_t(95_100 + cols[1].windowNodes.count)
            appendMirroredWindow(
                pid: nextPid,
                zigColumn: cols[1],
                referenceColumn: dual.referenceEngine.columns(in: wsId)[1],
                zigEngine: dual.zigEngine,
                referenceEngine: dual.referenceEngine,
                size: 1.0,
                height: .auto(weight: 1.0)
            )
        }

        cols[1].setActiveTileIdx(1)
        dual.referenceEngine.columns(in: wsId)[1].setActiveTileIdx(1)
        dual.zigEngine.updateTabbedColumnVisibility(column: cols[1])
        dual.referenceEngine.updateTabbedColumnVisibility(column: dual.referenceEngine.columns(in: wsId)[1])

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: wsId))
        guard let sourceWindowIndex = windowIndex(in: snapshot, pid: cols[1].windowNodes[0].handle.pid) else {
            #expect(Bool(false), "missing tabbed source window")
            return
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .consumeWindow,
            sourceWindowIndex: sourceWindowIndex,
            direction: .left,
            infiniteLoop: dual.zigEngine.infiniteLoop,
            maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn
        )

        let _ = runMutationParityStep(dual: dual, request: request)
        let updated = dual.zigEngine.columns(in: wsId)[1]
        #expect(updated.activeTileIdx == 2)
    }

    @Test func phase4ScenarioExpelWindowCreatesAdjacentColumn() {
        let dual = makeRandomDualEngines(seed: 0xC001)
        let wsId = dual.workspaceId

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: wsId))
        guard let sourceWindowIndex = snapshot.windowEntries.indices.first else {
            #expect(Bool(false), "missing source window for expel scenario")
            return
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .expelWindow,
            sourceWindowIndex: sourceWindowIndex,
            direction: .right,
            infiniteLoop: dual.zigEngine.infiniteLoop,
            maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn,
            maxVisibleColumns: dual.zigEngine.maxVisibleColumns
        )
        let outcome = runMutationParityStep(dual: dual, request: request)
        #expect(outcome.zig.applied)

        let cols = dual.zigEngine.columns(in: wsId)
        #expect(cols.count >= 2)
    }

    @Test func phase4ScenarioInsertWindowInNewColumnClampsIndex() {
        let dual = makeRandomDualEngines(seed: 0xC002)
        let wsId = dual.workspaceId

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: wsId))
        guard let sourceWindowIndex = snapshot.windowEntries.indices.first else {
            #expect(Bool(false), "missing source window for insert clamp scenario")
            return
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: .insertWindowInNewColumn,
            sourceWindowIndex: sourceWindowIndex,
            infiniteLoop: dual.zigEngine.infiniteLoop,
            maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn,
            insertColumnIndex: snapshot.columns.count + 99,
            maxVisibleColumns: dual.zigEngine.maxVisibleColumns
        )
        let outcome = runMutationParityStep(dual: dual, request: request)
        #expect(outcome.zig.applied)

        let cols = dual.zigEngine.columns(in: wsId)
        #expect(cols.count == snapshot.columns.count + 1)
    }

    @Test func phase4ScenarioCleanupPreservesPlaceholderInvariant() {
        let workspaceId = WorkspaceDescriptor.ID()
        let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let zigRoot = NiriRoot(workspaceId: workspaceId)
        let referenceRoot = NiriRoot(workspaceId: workspaceId)
        zigEngine.roots[workspaceId] = zigRoot
        referenceEngine.roots[workspaceId] = referenceRoot
        zigRoot.appendChild(NiriContainer())
        referenceRoot.appendChild(NiriContainer())

        let dual = ColumnDualEngines(
            zigEngine: zigEngine,
            referenceEngine: referenceEngine,
            workspaceId: workspaceId,
            workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            gaps: 8
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .cleanupEmptyColumn,
            sourceColumnIndex: 0
        )
        let outcome = runMutationParityStep(dual: dual, request: request)
        #expect(!outcome.zig.applied)
        #expect(outcome.zig.edits.isEmpty)

        let cols = dual.zigEngine.columns(in: workspaceId)
        #expect(cols.count == 1)
        #expect(cols[0].windowNodes.isEmpty)
    }

    @Test func phase4ScenarioNormalizeAndBalanceParity() {
        let dual = makeRandomDualEngines(seed: 0xD00D)

        let normalizeColumns = NiriStateZigKernel.MutationRequest(op: .normalizeColumnSizes)
        _ = runMutationParityStep(dual: dual, request: normalizeColumns)

        let normalizeWindows = NiriStateZigKernel.MutationRequest(
            op: .normalizeWindowSizes,
            sourceColumnIndex: 0
        )
        _ = runMutationParityStep(dual: dual, request: normalizeWindows)

        let balance = NiriStateZigKernel.MutationRequest(
            op: .balanceSizes,
            maxVisibleColumns: dual.zigEngine.maxVisibleColumns
        )
        _ = runMutationParityStep(dual: dual, request: balance)

        let widths = dual.zigEngine.columns(in: dual.workspaceId).map(\.width)
        for width in widths {
            #expect(width == .proportion(1.0 / CGFloat(dual.zigEngine.maxVisibleColumns)))
        }
    }

    @Test func phase4ScenarioMissingDirectionRejectedForDirectionalOps() {
        let dual = makeRandomDualEngines(seed: 0xD00E)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
        guard let sourceWindowIndex = snapshot.windowEntries.indices.first else {
            #expect(Bool(false), "missing source window for direction validation scenario")
            return
        }
        guard let sourceColumnIndex = snapshot.columnEntries.indices.first else {
            #expect(Bool(false), "missing source column for direction validation scenario")
            return
        }

        let requests: [NiriStateZigKernel.MutationRequest] = [
            .init(
                op: .createColumnAndMove,
                sourceWindowIndex: sourceWindowIndex,
                maxVisibleColumns: dual.zigEngine.maxVisibleColumns
            ),
            .init(
                op: .moveColumn,
                sourceColumnIndex: sourceColumnIndex
            ),
            .init(
                op: .consumeWindow,
                sourceWindowIndex: sourceWindowIndex,
                maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn
            ),
            .init(
                op: .expelWindow,
                sourceWindowIndex: sourceWindowIndex,
                maxVisibleColumns: dual.zigEngine.maxVisibleColumns
            )
        ]

        for request in requests {
            let outcome = runMutationParityStep(dual: dual, request: request)
            #expect(outcome.zig.rc == -1)
            #expect(!outcome.zig.applied)
        }
    }

    @Test func phase4ScenarioTargetProducingOpsAlwaysResolveTarget() {
        let moveDual = makeRandomDualEngines(seed: 0xD00F_1)
        let moveSnapshot = NiriStateZigKernel.makeSnapshot(columns: moveDual.zigEngine.columns(in: moveDual.workspaceId))
        guard moveSnapshot.columnEntries.count >= 2,
              let moveSourceWindowIndex = moveSnapshot.windowEntries.indices.first
        else {
            #expect(Bool(false), "insufficient state for moveWindowToColumn target scenario")
            return
        }
        let moveOutcome = runMutationParityStep(
            dual: moveDual,
            request: .init(
                op: .moveWindowToColumn,
                sourceWindowIndex: moveSourceWindowIndex,
                targetColumnIndex: 1
            )
        )
        #expect(moveOutcome.zig.applied)
        #expect(moveOutcome.zig.targetWindowIndex != nil)

        let createDual = makeRandomDualEngines(seed: 0xD00F_2)
        let createSnapshot = NiriStateZigKernel.makeSnapshot(columns: createDual.zigEngine.columns(in: createDual.workspaceId))
        guard let createSourceWindowIndex = createSnapshot.windowEntries.indices.first else {
            #expect(Bool(false), "insufficient state for createColumnAndMove target scenario")
            return
        }
        let createOutcome = runMutationParityStep(
            dual: createDual,
            request: .init(
                op: .createColumnAndMove,
                sourceWindowIndex: createSourceWindowIndex,
                direction: .right,
                maxVisibleColumns: createDual.zigEngine.maxVisibleColumns
            )
        )
        #expect(createOutcome.zig.applied)
        #expect(createOutcome.zig.targetWindowIndex != nil)

        let insertDual = makeRandomDualEngines(seed: 0xD00F_3)
        let insertSnapshot = NiriStateZigKernel.makeSnapshot(columns: insertDual.zigEngine.columns(in: insertDual.workspaceId))
        guard let insertSourceWindowIndex = insertSnapshot.windowEntries.indices.first else {
            #expect(Bool(false), "insufficient state for insertWindowInNewColumn target scenario")
            return
        }
        let insertOutcome = runMutationParityStep(
            dual: insertDual,
            request: .init(
                op: .insertWindowInNewColumn,
                sourceWindowIndex: insertSourceWindowIndex,
                insertColumnIndex: insertSnapshot.columnEntries.count,
                maxVisibleColumns: insertDual.zigEngine.maxVisibleColumns
            )
        )
        #expect(insertOutcome.zig.applied)
        #expect(insertOutcome.zig.targetWindowIndex != nil)

        let expelDual = makeRandomDualEngines(seed: 0xD00F_4)
        let expelSnapshot = NiriStateZigKernel.makeSnapshot(columns: expelDual.zigEngine.columns(in: expelDual.workspaceId))
        guard let expelSourceWindowIndex = expelSnapshot.windowEntries.indices.first else {
            #expect(Bool(false), "insufficient state for expelWindow target scenario")
            return
        }
        let expelOutcome = runMutationParityStep(
            dual: expelDual,
            request: .init(
                op: .expelWindow,
                sourceWindowIndex: expelSourceWindowIndex,
                direction: .right,
                maxVisibleColumns: expelDual.zigEngine.maxVisibleColumns
            )
        )
        #expect(expelOutcome.zig.applied)
        #expect(expelOutcome.zig.targetWindowIndex != nil)
    }

    @Test func randomizedMutationTraceParityMatchesReferenceModel() {
        let traceCount = 5_000
        let opsPerTrace = 10
        var rng = ColumnMutationLCG(seed: 0x1234_ABCD_5678_EF01)

        for trace in 0 ..< traceCount {
            let dual = makeRandomDualEngines(seed: UInt64(100_000 + trace))

            for _ in 0 ..< opsPerTrace {
                let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
                let request = makeRandomMutationRequest(snapshot: snapshot, engine: dual.zigEngine, rng: &rng)
                let _ = runMutationParityStep(dual: dual, request: request)
            }
        }
    }

    @Test func columnOpsMutationPlannerBenchmarkHarnessP95() throws {
        let dual = makeRandomDualEngines(seed: 0xCAFE_BABE)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))

        var rng = ColumnMutationLCG(seed: 0xABCDEF0123456789)
        var requests: [NiriStateZigKernel.MutationRequest] = []
        requests.reserveCapacity(10_000)
        for _ in 0 ..< 10_000 {
            requests.append(makeRandomMutationRequest(snapshot: snapshot, engine: dual.zigEngine, rng: &rng))
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)

        for request in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri column-ops mutation planner p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase4ColumnOps()
        let perfLimit = baseline.column_ops_planner_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }

    @Test func columnOpsRuntimeFullPathBenchmarkHarnessP95() throws {
        let dual = makeRandomDualEngines(seed: 0x5566_7788)
        let engine = dual.zigEngine
        let wsId = dual.workspaceId

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        var rng = ColumnMutationLCG(seed: 0x99AA_BBCC_DDEE_FF00)
        var samples: [Double] = []
        samples.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: wsId))
            let request = makeRandomMutationRequest(snapshot: snapshot, engine: engine, rng: &rng)

            let t0 = CACurrentMediaTime()
            _ = executeRuntimeMutation(
                engine: engine,
                workspaceId: wsId,
                request: request,
                snapshot: snapshot,
                state: &state,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri column-ops runtime full-path p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase4ColumnOps()
        let perfLimit = baseline.column_ops_full_path_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}
