import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private struct LifecycleLCG {
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

private struct LifecycleWindowSignature: Equatable {
    let pid: Int32
    let hiddenInTabbedMode: Bool
}

private struct LifecycleColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let cachedWidth: Double
    let windows: [LifecycleWindowSignature]
}

private struct LifecycleLayoutSignature: Equatable {
    let columns: [LifecycleColumnSignature]
}

private func layoutSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> LifecycleLayoutSignature {
    LifecycleLayoutSignature(
        columns: engine.columns(in: workspaceId).map { column in
            LifecycleColumnSignature(
                isTabbed: column.isTabbed,
                activeTileIdx: column.activeTileIdx,
                cachedWidth: quantize(Double(column.cachedWidth)),
                windows: column.windowNodes.map { window in
                    LifecycleWindowSignature(
                        pid: window.handle.pid,
                        hiddenInTabbedMode: window.isHiddenInTabbedMode
                    )
                }
            )
        }
    )
}

private struct LifecycleDualEngines {
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
    referenceEngine: NiriLayoutEngine
) {
    let zigHandle = makeTestHandle(pid: pid)
    let referenceHandle = makeTestHandle(pid: pid)
    let zigWindow = NiriWindow(handle: zigHandle)
    let referenceWindow = NiriWindow(handle: referenceHandle)
    zigColumn.appendChild(zigWindow)
    referenceColumn.appendChild(referenceWindow)
    zigEngine.handleToNode[zigHandle] = zigWindow
    referenceEngine.handleToNode[referenceHandle] = referenceWindow
}

private func makeThreeColumnDual() -> LifecycleDualEngines {
    let workspaceId = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)

    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let referenceRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = referenceRoot

    let zigColumns = (0 ..< 3).map { _ in NiriContainer() }
    let referenceColumns = (0 ..< 3).map { _ in NiriContainer() }
    for idx in 0 ..< 3 {
        zigRoot.appendChild(zigColumns[idx])
        referenceRoot.appendChild(referenceColumns[idx])
    }

    appendMirroredWindow(
        pid: 110_001,
        zigColumn: zigColumns[0],
        referenceColumn: referenceColumns[0],
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 110_002,
        zigColumn: zigColumns[1],
        referenceColumn: referenceColumns[1],
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )
    appendMirroredWindow(
        pid: 110_003,
        zigColumn: zigColumns[2],
        referenceColumn: referenceColumns[2],
        zigEngine: zigEngine,
        referenceEngine: referenceEngine
    )

    return LifecycleDualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func makeRandomDualEngines(seed: UInt64) -> LifecycleDualEngines {
    var rng = LifecycleLCG(seed: seed)
    let workspaceId = WorkspaceDescriptor.ID()

    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: rng.nextBool(0.5))
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: zigEngine.infiniteLoop)

    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let referenceRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = referenceRoot

    let columnCount = rng.nextInt(2 ... 5)
    for columnIdx in 0 ..< columnCount {
        let zigColumn = NiriContainer()
        let referenceColumn = NiriContainer()
        let tabbed = rng.nextBool(0.3)
        zigColumn.displayMode = tabbed ? .tabbed : .normal
        referenceColumn.displayMode = tabbed ? .tabbed : .normal

        zigRoot.appendChild(zigColumn)
        referenceRoot.appendChild(referenceColumn)

        let windowCount = rng.nextInt(1 ... 4)
        for row in 0 ..< windowCount {
            let pid = pid_t(120_000 + columnIdx * 100 + row)
            appendMirroredWindow(
                pid: pid,
                zigColumn: zigColumn,
                referenceColumn: referenceColumn,
                zigEngine: zigEngine,
                referenceEngine: referenceEngine
            )
        }

        let activeTile = rng.nextInt(0 ... max(0, windowCount - 1))
        zigColumn.setActiveTileIdx(activeTile)
        referenceColumn.setActiveTileIdx(activeTile)
        zigColumn.cachedWidth = CGFloat(rng.nextInt(250 ... 450))
        referenceColumn.cachedWidth = zigColumn.cachedWidth
        if tabbed {
            zigEngine.updateTabbedColumnVisibility(column: zigColumn)
            referenceEngine.updateTabbedColumnVisibility(column: referenceColumn)
        }
    }

    return LifecycleDualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func targetNodeEqual(
    _ lhs: NiriStateZigKernel.MutationNodeTarget?,
    _ rhs: NiriStateZigKernel.MutationNodeTarget?
) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return lhs.kind == rhs.kind && lhs.index == rhs.index
}

private func assertMutationOutcomeParity(
    zig: NiriStateZigKernel.MutationOutcome,
    reference: NiriStateZigKernel.MutationOutcome
) {
    #expect(zig.rc == reference.rc)
    #expect(zig.applied == reference.applied)
    #expect(zig.targetWindowIndex == reference.targetWindowIndex)
    #expect(targetNodeEqual(zig.targetNode, reference.targetNode))
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
        #expect(quantize(lhs.scalarA) == quantize(rhs.scalarA))
        #expect(quantize(lhs.scalarB) == quantize(rhs.scalarB))
    }
}

private func applyMutationOutcome(
    engine: NiriLayoutEngine,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome,
    incomingWindowHandle: WindowHandle? = nil
) -> Bool {
    guard outcome.rc == 0 else { return false }
    guard outcome.applied else { return true }
    let applyOutcome = NiriStateZigMutationApplier.apply(
        outcome: outcome,
        snapshot: snapshot,
        engine: engine,
        incomingWindowHandle: incomingWindowHandle
    )
    return applyOutcome.applied
}

private func applyReferenceMutationOutcome(
    engine: NiriLayoutEngine,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome,
    incomingWindowHandle: WindowHandle? = nil
) -> Bool {
    guard outcome.rc == 0 else { return false }
    guard outcome.applied else { return true }
    let applyOutcome = NiriReferenceLifecycleRuntimeApplier.apply(
        outcome: outcome,
        snapshot: snapshot,
        engine: engine,
        incomingWindowHandle: incomingWindowHandle
    )
    return applyOutcome.applied
}

private func assertMutationInvariants(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    let validation = NiriStateZigKernel.validate(snapshot: snapshot)
    #expect(validation.isValid)

    guard let root = engine.root(for: workspaceId) else { return }
    #expect(!root.columns.isEmpty)
    for column in root.columns {
        if column.windowNodes.isEmpty {
            #expect(column.activeTileIdx == 0)
        } else {
            #expect(column.activeTileIdx >= 0)
            #expect(column.activeTileIdx < column.windowNodes.count)
        }
    }
    for window in root.allWindows {
        #expect(engine.handleToNode[window.handle] === window)
    }
}

private func referenceMutationNodeTarget(
    for nodeId: NodeId?,
    snapshot: NiriStateZigKernel.Snapshot
) -> NiriStateZigKernel.MutationNodeTarget {
    guard let nodeId else {
        return NiriStateZigKernel.MutationNodeTarget(kind: .none, index: -1)
    }

    if let windowIndex = snapshot.windowIndexByNodeId[nodeId],
       snapshot.windowEntries.indices.contains(windowIndex)
    {
        return NiriStateZigKernel.MutationNodeTarget(kind: .window, index: windowIndex)
    }

    if let columnIndex = snapshot.columnIndexByNodeId[nodeId],
       snapshot.columnEntries.indices.contains(columnIndex)
    {
        return NiriStateZigKernel.MutationNodeTarget(kind: .column, index: columnIndex)
    }

    return NiriStateZigKernel.MutationNodeTarget(kind: .none, index: -1)
}

private func addRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    engine: NiriLayoutEngine,
    selectedNodeId: NodeId?,
    focusedHandle: WindowHandle?
) -> NiriStateZigKernel.MutationRequest {
    let selectedTarget = referenceMutationNodeTarget(
        for: selectedNodeId,
        snapshot: snapshot
    )

    let focusedWindowIndex: Int
    if let focusedHandle,
       let focusedNode = engine.handleToNode[focusedHandle],
       let resolvedFocusedIndex = snapshot.windowIndexByNodeId[focusedNode.id]
    {
        focusedWindowIndex = resolvedFocusedIndex
    } else {
        focusedWindowIndex = -1
    }

    return NiriStateZigKernel.MutationRequest(
        op: .addWindow,
        maxVisibleColumns: engine.maxVisibleColumns,
        selectedNodeKind: selectedTarget.kind,
        selectedNodeIndex: selectedTarget.index,
        focusedWindowIndex: focusedWindowIndex
    )
}

private func removeRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    handle: WindowHandle
) -> NiriStateZigKernel.MutationRequest? {
    guard let window = snapshot.windowEntries.first(where: { $0.window.handle === handle }) else {
        return nil
    }
    guard let sourceWindowIndex = snapshot.windowIndexByNodeId[window.window.id] else { return nil }
    return NiriStateZigKernel.MutationRequest(
        op: .removeWindow,
        sourceWindowIndex: sourceWindowIndex
    )
}

private func referenceSyncWindows(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    handles: [WindowHandle],
    selectedNodeId: NodeId?,
    focusedHandle: WindowHandle?
) -> Set<Int32> {
    let root = engine.ensureRoot(for: workspaceId)
    let existingIdSet = root.windowIdSet

    var currentIdSet = Set<UUID>(minimumCapacity: handles.count)
    for handle in handles {
        currentIdSet.insert(handle.id)
    }

    var removedPids = Set<Int32>()

    for window in root.allWindows {
        if !currentIdSet.contains(window.windowId) {
            let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
            let request = NiriStateZigKernel.MutationRequest(
                op: .removeWindow,
                sourceWindowIndex: snapshot.windowIndexByNodeId[window.id] ?? -1
            )
            let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
            _ = applyReferenceMutationOutcome(engine: engine, snapshot: snapshot, outcome: outcome)
            removedPids.insert(window.handle.pid)
        }
    }

    for handle in handles where !existingIdSet.contains(handle.id) {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
        let request = addRequest(
            snapshot: snapshot,
            engine: engine,
            selectedNodeId: selectedNodeId,
            focusedHandle: focusedHandle
        )
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        _ = applyReferenceMutationOutcome(
            engine: engine,
            snapshot: snapshot,
            outcome: outcome,
            incomingWindowHandle: handle
        )
    }

    return removedPids
}

private func makeRandomPlannerRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    engine: NiriLayoutEngine,
    rng: inout LifecycleLCG
) -> NiriStateZigKernel.MutationRequest {
    let opChoice = rng.nextInt(0 ... 3)
    switch opChoice {
    case 0:
        let selectedMode = rng.nextInt(0 ... 3)
        let selectedKind: NiriStateZigKernel.MutationNodeKind
        let selectedIndex: Int
        switch selectedMode {
        case 1 where !snapshot.windowEntries.isEmpty:
            selectedKind = .window
            selectedIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
        case 2 where !snapshot.columnEntries.isEmpty:
            selectedKind = .column
            selectedIndex = rng.nextInt(0 ... snapshot.columnEntries.count - 1)
        case 3:
            selectedKind = .window
            selectedIndex = snapshot.windowEntries.count + 7
        default:
            selectedKind = .none
            selectedIndex = -1
        }

        let focusedWindowIndex: Int
        if !snapshot.windowEntries.isEmpty, rng.nextBool(0.7) {
            focusedWindowIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
        } else if rng.nextBool(0.5) {
            focusedWindowIndex = snapshot.windowEntries.count + 9
        } else {
            focusedWindowIndex = -1
        }

        return NiriStateZigKernel.MutationRequest(
            op: .addWindow,
            maxVisibleColumns: engine.maxVisibleColumns,
            selectedNodeKind: selectedKind,
            selectedNodeIndex: selectedIndex,
            focusedWindowIndex: focusedWindowIndex
        )

    case 1:
        let sourceWindowIndex: Int
        if snapshot.windowEntries.isEmpty {
            sourceWindowIndex = -1
        } else {
            sourceWindowIndex = rng.nextBool(0.8)
                ? rng.nextInt(0 ... snapshot.windowEntries.count - 1)
                : snapshot.windowEntries.count + 3
        }
        return NiriStateZigKernel.MutationRequest(
            op: .removeWindow,
            sourceWindowIndex: sourceWindowIndex
        )

    case 2:
        let selectedMode = rng.nextInt(0 ... 3)
        let selectedKind: NiriStateZigKernel.MutationNodeKind
        let selectedIndex: Int
        switch selectedMode {
        case 1 where !snapshot.windowEntries.isEmpty:
            selectedKind = .window
            selectedIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
        case 2 where !snapshot.columnEntries.isEmpty:
            selectedKind = .column
            selectedIndex = rng.nextInt(0 ... snapshot.columnEntries.count - 1)
        case 3:
            selectedKind = .column
            selectedIndex = snapshot.columnEntries.count + 5
        default:
            selectedKind = .none
            selectedIndex = -1
        }
        return NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeKind: selectedKind,
            selectedNodeIndex: selectedIndex
        )

    default:
        let sourceWindowIndex: Int
        if snapshot.windowEntries.isEmpty {
            sourceWindowIndex = -1
        } else {
            sourceWindowIndex = rng.nextBool(0.8)
                ? rng.nextInt(0 ... snapshot.windowEntries.count - 1)
                : snapshot.windowEntries.count + 11
        }
        return NiriStateZigKernel.MutationRequest(
            op: .fallbackSelectionOnRemoval,
            sourceWindowIndex: sourceWindowIndex
        )
    }
}

private func pickSeededWindow(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    rng: inout LifecycleLCG
) -> NiriWindow? {
    let windows = engine.root(for: workspaceId)?.allWindows ?? []
    guard !windows.isEmpty else { return nil }
    let index = rng.nextInt(0 ... windows.count - 1)
    return windows[index]
}

private func pickSeededColumn(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    rng: inout LifecycleLCG
) -> NiriContainer? {
    let columns = engine.columns(in: workspaceId)
    guard !columns.isEmpty else { return nil }
    let index = rng.nextInt(0 ... columns.count - 1)
    return columns[index]
}

@Suite(.serialized) struct NiriZigLifecycleOpsParityTests {
    @Test func phase5ScenarioAddWindowPlacementPrefersFocusedOverSelected() {
        let dual = makeThreeColumnDual()
        let wsId = dual.workspaceId
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine

        let zigSelected = zigEngine.columns(in: wsId)[0].windowNodes[0]
        let zigFocusedHandle = zigEngine.columns(in: wsId)[1].windowNodes[0].handle
        let referenceSelected = referenceEngine.columns(in: wsId)[0].windowNodes[0]
        let referenceFocusedHandle = referenceEngine.columns(in: wsId)[1].windowNodes[0].handle

        let newZigHandle = makeTestHandle(pid: 130_001)
        let newRefHandle = makeTestHandle(pid: 130_001)

        let zigAdded = zigEngine.addWindow(
            handle: newZigHandle,
            to: wsId,
            afterSelection: zigSelected.id,
            focusedHandle: zigFocusedHandle
        )

        let referenceSnapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: wsId))
        let referenceRequest = addRequest(
            snapshot: referenceSnapshot,
            engine: referenceEngine,
            selectedNodeId: referenceSelected.id,
            focusedHandle: referenceFocusedHandle
        )
        let referenceOutcome = NiriReferenceLifecycleOps.resolve(snapshot: referenceSnapshot, request: referenceRequest)
        _ = applyReferenceMutationOutcome(
            engine: referenceEngine,
            snapshot: referenceSnapshot,
            outcome: referenceOutcome,
            incomingWindowHandle: newRefHandle
        )

        #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: referenceEngine, workspaceId: wsId))
        let zigNewColIdx = zigEngine.column(of: zigAdded).flatMap { zigEngine.columnIndex(of: $0, in: wsId) }
        #expect(zigNewColIdx == 2)
    }

    @Test func phase5ScenarioAddWindowReusesPlaceholderOnEmptyWorkspace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        _ = zigEngine.ensureRoot(for: workspaceId)
        _ = referenceEngine.ensureRoot(for: workspaceId)

        let zigHandle = makeTestHandle(pid: 130_010)
        let refHandle = makeTestHandle(pid: 130_010)

        let _ = zigEngine.addWindow(handle: zigHandle, to: workspaceId, afterSelection: nil)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: workspaceId))
        let request = NiriStateZigKernel.MutationRequest(op: .addWindow, maxVisibleColumns: referenceEngine.maxVisibleColumns)
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        _ = applyReferenceMutationOutcome(
            engine: referenceEngine,
            snapshot: snapshot,
            outcome: outcome,
            incomingWindowHandle: refHandle
        )

        #expect(layoutSignature(engine: zigEngine, workspaceId: workspaceId) == layoutSignature(engine: referenceEngine, workspaceId: workspaceId))
        #expect(zigEngine.columns(in: workspaceId).count == 1)
    }

    @Test func phase5ScenarioRemoveWindowTabbedActiveTileAndVisibilityParity() {
        let dual = makeThreeColumnDual()
        let wsId = dual.workspaceId
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine

        let zigColumn = zigEngine.columns(in: wsId)[1]
        let referenceColumn = referenceEngine.columns(in: wsId)[1]
        zigColumn.displayMode = .tabbed
        referenceColumn.displayMode = .tabbed
        appendMirroredWindow(
            pid: 130_021,
            zigColumn: zigColumn,
            referenceColumn: referenceColumn,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )
        appendMirroredWindow(
            pid: 130_022,
            zigColumn: zigColumn,
            referenceColumn: referenceColumn,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )
        zigColumn.setActiveTileIdx(1)
        referenceColumn.setActiveTileIdx(1)
        zigEngine.updateTabbedColumnVisibility(column: zigColumn)
        referenceEngine.updateTabbedColumnVisibility(column: referenceColumn)

        let removingZig = zigColumn.windowNodes[1]
        let removingRefPid = removingZig.handle.pid

        zigEngine.removeWindow(handle: removingZig.handle)

        let referenceSnapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: wsId))
        guard let removingRef = referenceSnapshot.windowEntries.first(where: { $0.window.handle.pid == removingRefPid })?.window else {
            #expect(Bool(false), "missing mirrored tabbed removal window")
            return
        }
        let request = removeRequest(snapshot: referenceSnapshot, handle: removingRef.handle)!
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: referenceSnapshot, request: request)
        _ = applyReferenceMutationOutcome(engine: referenceEngine, snapshot: referenceSnapshot, outcome: outcome)

        #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: referenceEngine, workspaceId: wsId))
        assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
        assertMutationInvariants(engine: referenceEngine, workspaceId: wsId)
    }

    @Test func phase5ScenarioRemoveLastWindowPreservesPlaceholderInvariant() {
        let workspaceId = WorkspaceDescriptor.ID()
        let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let zigRoot = zigEngine.ensureRoot(for: workspaceId)
        let referenceRoot = referenceEngine.ensureRoot(for: workspaceId)

        let zigColumn = zigRoot.columns[0]
        let referenceColumn = referenceRoot.columns[0]
        appendMirroredWindow(
            pid: 130_030,
            zigColumn: zigColumn,
            referenceColumn: referenceColumn,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )

        let removingZig = zigColumn.windowNodes[0]
        zigEngine.removeWindow(handle: removingZig.handle)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: workspaceId))
        let request = removeRequest(snapshot: snapshot, handle: referenceColumn.windowNodes[0].handle)!
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        _ = applyReferenceMutationOutcome(engine: referenceEngine, snapshot: snapshot, outcome: outcome)

        #expect(layoutSignature(engine: zigEngine, workspaceId: workspaceId) == layoutSignature(engine: referenceEngine, workspaceId: workspaceId))
        #expect(zigEngine.columns(in: workspaceId).count == 1)
        #expect(zigEngine.columns(in: workspaceId)[0].windowNodes.isEmpty)
    }

    @Test func phase5ScenarioValidateSelectionColumnPassThroughParity() {
        let dual = makeThreeColumnDual()
        let wsId = dual.workspaceId
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine

        let selectedColumnId = zigEngine.columns(in: wsId)[1].id
        let zigResult = zigEngine.validateSelection(selectedColumnId, in: wsId)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: wsId))
        let selectedTarget = referenceMutationNodeTarget(
            for: referenceEngine.columns(in: wsId)[1].id,
            snapshot: snapshot
        )
        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeKind: selectedTarget.kind,
            selectedNodeIndex: selectedTarget.index
        )
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        let referenceResult = NiriStateZigKernel.nodeId(from: outcome.targetNode, snapshot: snapshot)

        #expect(outcome.targetNode?.kind == .column)
        #expect(outcome.targetNode?.index == 1)
        #expect(zigResult == selectedColumnId)
        #expect(referenceResult == referenceEngine.columns(in: wsId)[1].id)
    }

    @Test func phase5ScenarioValidateSelectionSkipsLeadingEmptyColumnParity() {
        let workspaceId = WorkspaceDescriptor.ID()
        let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)

        let zigRoot = zigEngine.ensureRoot(for: workspaceId)
        let referenceRoot = referenceEngine.ensureRoot(for: workspaceId)
        let zigLeadingEmpty = zigRoot.columns[0]
        let referenceLeadingEmpty = referenceRoot.columns[0]
        #expect(zigLeadingEmpty.windowNodes.isEmpty)
        #expect(referenceLeadingEmpty.windowNodes.isEmpty)

        let zigFilledColumn = NiriContainer()
        let referenceFilledColumn = NiriContainer()
        zigRoot.appendChild(zigFilledColumn)
        referenceRoot.appendChild(referenceFilledColumn)
        appendMirroredWindow(
            pid: 130_041,
            zigColumn: zigFilledColumn,
            referenceColumn: referenceFilledColumn,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )

        let zigResult = zigEngine.validateSelection(nil, in: workspaceId)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: workspaceId))
        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeKind: .none,
            selectedNodeIndex: -1
        )
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        let referenceResult = NiriStateZigKernel.nodeId(from: outcome.targetNode, snapshot: snapshot)

        #expect(zigResult == zigFilledColumn.windowNodes[0].id)
        #expect(referenceResult == referenceFilledColumn.windowNodes[0].id)
    }

    @Test func phase5ScenarioFallbackSelectionOrderingParity() {
        let dual = makeThreeColumnDual()
        let wsId = dual.workspaceId
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine

        let removingId = zigEngine.columns(in: wsId)[1].windowNodes[0].id
        let zigFallback = zigEngine.fallbackSelectionOnRemoval(removing: removingId, in: wsId)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: referenceEngine.columns(in: wsId))
        let removingIndex = snapshot.windowEntries.first(where: { $0.window.id == referenceEngine.columns(in: wsId)[1].windowNodes[0].id }).map {
            snapshot.windowIndexByNodeId[$0.window.id] ?? -1
        } ?? -1
        let request = NiriStateZigKernel.MutationRequest(
            op: .fallbackSelectionOnRemoval,
            sourceWindowIndex: removingIndex
        )
        let outcome = NiriReferenceLifecycleOps.resolve(snapshot: snapshot, request: request)
        let referenceFallback = NiriStateZigKernel.nodeId(from: outcome.targetNode, snapshot: snapshot)

        let zigFallbackPid = zigFallback.flatMap { (zigEngine.findNode(by: $0) as? NiriWindow)?.handle.pid }
        let referenceFallbackPid = referenceFallback.flatMap { (referenceEngine.findNode(by: $0) as? NiriWindow)?.handle.pid }
        #expect(zigFallbackPid == referenceFallbackPid)
    }

    @Test func blackBoxAddWindowPlacementPrecedenceFocusedThenSelectedThenLast() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspaceId)
        let columns = (0 ..< 3).map { _ in NiriContainer() }
        for column in columns {
            root.appendChild(column)
        }
        for (idx, column) in columns.enumerated() {
            let handle = makeTestHandle(pid: pid_t(130_100 + idx))
            let window = NiriWindow(handle: handle)
            column.appendChild(window)
            engine.handleToNode[handle] = window
        }

        let selectedNodeId = columns[0].windowNodes[0].id
        let focusedHandle = columns[1].windowNodes[0].handle
        let newHandle = makeTestHandle(pid: 130_111)
        let inserted = engine.addWindow(
            handle: newHandle,
            to: workspaceId,
            afterSelection: selectedNodeId,
            focusedHandle: focusedHandle
        )

        guard let insertedColumn = engine.column(of: inserted),
              let insertedColumnIndex = engine.columnIndex(of: insertedColumn, in: workspaceId)
        else {
            #expect(Bool(false), "added window should be attached to a column")
            return
        }

        #expect(insertedColumnIndex == 3)
        #expect(engine.columns(in: workspaceId).count == 5)
        #expect(engine.handleToNode[newHandle] === inserted)
        assertMutationInvariants(engine: engine, workspaceId: workspaceId)
    }

    @Test func blackBoxFallbackSelectionPrefersLeftAdjacentColumnAfterSiblingChecks() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspaceId)
        let columns = (0 ..< 3).map { _ in NiriContainer() }
        for column in columns {
            root.appendChild(column)
        }

        let leftHandle = makeTestHandle(pid: 130_201)
        let middleHandle = makeTestHandle(pid: 130_202)
        let rightHandle = makeTestHandle(pid: 130_203)
        let leftWindow = NiriWindow(handle: leftHandle)
        let middleWindow = NiriWindow(handle: middleHandle)
        let rightWindow = NiriWindow(handle: rightHandle)
        columns[0].appendChild(leftWindow)
        columns[1].appendChild(middleWindow)
        columns[2].appendChild(rightWindow)
        engine.handleToNode[leftHandle] = leftWindow
        engine.handleToNode[middleHandle] = middleWindow
        engine.handleToNode[rightHandle] = rightWindow

        let fallback = engine.fallbackSelectionOnRemoval(removing: middleWindow.id, in: workspaceId)
        #expect(fallback == leftWindow.id)
    }

    @Test func blackBoxRemoveWindowResetsCachedWidthsWhenColumnRemoved() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspaceId)
        let firstColumn = root.columns[0]
        let secondColumn = NiriContainer()
        root.appendChild(secondColumn)

        firstColumn.cachedWidth = 420
        secondColumn.cachedWidth = 375

        let firstHandle = makeTestHandle(pid: 130_301)
        let secondHandle = makeTestHandle(pid: 130_302)
        let firstWindow = NiriWindow(handle: firstHandle)
        let secondWindow = NiriWindow(handle: secondHandle)
        firstColumn.appendChild(firstWindow)
        secondColumn.appendChild(secondWindow)
        engine.handleToNode[firstHandle] = firstWindow
        engine.handleToNode[secondHandle] = secondWindow

        engine.removeWindow(handle: firstHandle)

        #expect(engine.root(for: workspaceId)?.columns.count == 1)
        #expect(engine.columns(in: workspaceId)[0].windowNodes.first === secondWindow)
        #expect(engine.columns(in: workspaceId)[0].cachedWidth == 0)
        #expect(engine.handleToNode[firstHandle] == nil)
        #expect(engine.handleToNode[secondHandle] === secondWindow)
        assertMutationInvariants(engine: engine, workspaceId: workspaceId)
    }

    @Test func phase5ScenarioSyncWindowsMixedAddRemoveChurnParity() {
        let dual = makeRandomDualEngines(seed: 0xA5A5_B4B4_C3C3_D2D2)
        let wsId = dual.workspaceId
        let zigEngine = dual.zigEngine
        let referenceEngine = dual.referenceEngine

        var rng = LifecycleLCG(seed: 0x1122_3344_5566_7788)
        var pidToZigHandle: [Int32: WindowHandle] = [:]
        var pidToRefHandle: [Int32: WindowHandle] = [:]

        for window in zigEngine.root(for: wsId)?.allWindows ?? [] {
            pidToZigHandle[window.handle.pid] = window.handle
        }
        for window in referenceEngine.root(for: wsId)?.allWindows ?? [] {
            pidToRefHandle[window.handle.pid] = window.handle
        }

        var nextPid: Int32 = 140_000
        for _ in 0 ..< 200 {
            let currentPids = (zigEngine.root(for: wsId)?.allWindows ?? []).map(\.handle.pid)
            var targetPids = currentPids

            if !targetPids.isEmpty, rng.nextBool(0.7) {
                let removals = min(targetPids.count, rng.nextInt(1 ... 2))
                for _ in 0 ..< removals where !targetPids.isEmpty {
                    let removeIdx = rng.nextInt(0 ... targetPids.count - 1)
                    targetPids.remove(at: removeIdx)
                }
            }

            if rng.nextBool(0.8) {
                let additions = rng.nextInt(0 ... 2)
                for _ in 0 ..< additions {
                    nextPid += 1
                    let insertIdx = targetPids.isEmpty ? 0 : rng.nextInt(0 ... targetPids.count)
                    targetPids.insert(nextPid, at: insertIdx)
                }
            }

            var zigHandles: [WindowHandle] = []
            var referenceHandles: [WindowHandle] = []
            zigHandles.reserveCapacity(targetPids.count)
            referenceHandles.reserveCapacity(targetPids.count)

            for pid in targetPids {
                let zigHandle = pidToZigHandle[pid] ?? {
                    let handle = makeTestHandle(pid: pid)
                    pidToZigHandle[pid] = handle
                    return handle
                }()
                let refHandle = pidToRefHandle[pid] ?? {
                    let handle = makeTestHandle(pid: pid)
                    pidToRefHandle[pid] = handle
                    return handle
                }()
                zigHandles.append(zigHandle)
                referenceHandles.append(refHandle)
            }

            let zigRemoved = zigEngine.syncWindows(zigHandles, in: wsId, selectedNodeId: nil, focusedHandle: nil)
            let referenceRemovedPids = referenceSyncWindows(
                engine: referenceEngine,
                workspaceId: wsId,
                handles: referenceHandles,
                selectedNodeId: nil,
                focusedHandle: nil
            )

            let zigRemovedPids = Set(zigRemoved.map(\.pid))
            #expect(zigRemovedPids == referenceRemovedPids)
            #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: referenceEngine, workspaceId: wsId))
            assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
            assertMutationInvariants(engine: referenceEngine, workspaceId: wsId)
        }
    }

    @Test func randomizedLifecycleTraceParityMatchesReferenceModel() {
        let dual = makeRandomDualEngines(seed: 0xCAFEBABE12345678)
        let wsId = dual.workspaceId
        var rng = LifecycleLCG(seed: 0xABCDEF1200345678)
        var nextPid: Int32 = 150_000

        for _ in 0 ..< 1_500 {
            let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: wsId))
            let referenceSnapshot = NiriStateZigKernel.makeSnapshot(columns: dual.referenceEngine.columns(in: wsId))
            let request = makeRandomPlannerRequest(snapshot: zigSnapshot, engine: dual.zigEngine, rng: &rng)

            let zigOutcome = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
            let referenceOutcome = NiriReferenceLifecycleOps.resolve(snapshot: referenceSnapshot, request: request)
            assertMutationOutcomeParity(zig: zigOutcome, reference: referenceOutcome)

            switch request.op {
            case .addWindow:
                if zigOutcome.applied {
                    nextPid += 1
                    let zigIncoming = makeTestHandle(pid: nextPid)
                    let refIncoming = makeTestHandle(pid: nextPid)
                    _ = applyMutationOutcome(
                        engine: dual.zigEngine,
                        snapshot: zigSnapshot,
                        outcome: zigOutcome,
                        incomingWindowHandle: zigIncoming
                    )
                    _ = applyReferenceMutationOutcome(
                        engine: dual.referenceEngine,
                        snapshot: referenceSnapshot,
                        outcome: referenceOutcome,
                        incomingWindowHandle: refIncoming
                    )
                }

            case .removeWindow:
                _ = applyMutationOutcome(engine: dual.zigEngine, snapshot: zigSnapshot, outcome: zigOutcome)
                _ = applyReferenceMutationOutcome(engine: dual.referenceEngine, snapshot: referenceSnapshot, outcome: referenceOutcome)

            case .validateSelection, .fallbackSelectionOnRemoval:
                break

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
                #expect(Bool(false), "unexpected non-lifecycle op in lifecycle trace")
            }

            #expect(layoutSignature(engine: dual.zigEngine, workspaceId: wsId) == layoutSignature(engine: dual.referenceEngine, workspaceId: wsId))
            assertMutationInvariants(engine: dual.zigEngine, workspaceId: wsId)
            assertMutationInvariants(engine: dual.referenceEngine, workspaceId: wsId)
        }
    }

    @Test func lifecycleOpsMutationPlannerBenchmarkHarnessP95() throws {
        let dual = makeRandomDualEngines(seed: 0xDEADBEEF00112233)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))

        var rng = LifecycleLCG(seed: 0x0102_0304_0506_0708)
        var requests: [NiriStateZigKernel.MutationRequest] = []
        requests.reserveCapacity(10_000)
        for _ in 0 ..< 10_000 {
            requests.append(makeRandomPlannerRequest(snapshot: snapshot, engine: dual.zigEngine, rng: &rng))
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)
        for request in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri lifecycle-ops mutation planner p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase5LifecycleOps()
        let perfLimit = baseline.lifecycle_ops_planner_p95_sec * 1.10
        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }

    @Test func lifecycleOpsRuntimeFullPathBenchmarkHarnessP95() throws {
        let dual = makeRandomDualEngines(seed: 0x9988_7766_5544_3322)
        let engine = dual.zigEngine
        let wsId = dual.workspaceId
        var rng = LifecycleLCG(seed: 0x2026_0303_1234_5678)
        var nextPid: Int32 = 160_000

        var samples: [Double] = []
        samples.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: wsId))
            let op = rng.nextInt(0 ... 3)

            let t0 = CACurrentMediaTime()
            switch op {
            case 0:
                nextPid += 1
                let handle = makeTestHandle(pid: nextPid)
                let selectedNodeId: NodeId? = if rng.nextBool(0.4), let firstWindow = engine.root(for: wsId)?.allWindows.first {
                    firstWindow.id
                } else if rng.nextBool(0.2), let firstColumn = engine.columns(in: wsId).first {
                    firstColumn.id
                } else {
                    nil
                }
                let focusedHandle: WindowHandle? = if rng.nextBool(0.5), let focused = engine.root(for: wsId)?.allWindows.last?.handle {
                    focused
                } else {
                    nil
                }
                _ = engine.addWindow(
                    handle: handle,
                    to: wsId,
                    afterSelection: selectedNodeId,
                    focusedHandle: focusedHandle
                )

            case 1:
                if let removing = pickSeededWindow(engine: engine, workspaceId: wsId, rng: &rng) {
                    engine.removeWindow(handle: removing.handle)
                }

            case 2:
                let selectedNodeId: NodeId? = if rng.nextBool(0.5),
                                                 let randomWindow = pickSeededWindow(
                                                     engine: engine,
                                                     workspaceId: wsId,
                                                     rng: &rng
                                                 ) {
                    randomWindow.id
                } else if rng.nextBool(0.2),
                          let randomColumn = pickSeededColumn(
                              engine: engine,
                              workspaceId: wsId,
                              rng: &rng
                          )
                {
                    randomColumn.id
                } else if rng.nextBool(0.2) {
                    NodeId()
                } else {
                    nil
                }
                _ = engine.validateSelection(selectedNodeId, in: wsId)

            default:
                if !snapshot.windowEntries.isEmpty {
                    let idx = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
                    let id = snapshot.windowEntries[idx].window.id
                    _ = engine.fallbackSelectionOnRemoval(removing: id, in: wsId)
                } else {
                    _ = engine.validateSelection(nil, in: wsId)
                }
            }
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri lifecycle-ops runtime full-path p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase5LifecycleOps()
        let perfLimit = baseline.lifecycle_ops_full_path_p95_sec * 1.10
        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}
