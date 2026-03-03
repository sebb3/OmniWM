import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private struct WorkspaceLCG {
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

private func isWorkspacePerfGateEnabled() -> Bool {
    ProcessInfo.processInfo.environment["OMNI_ENABLE_WORKSPACE_PERF_GATES"] == "1"
}

private func proportionalSignature(_ value: ProportionalSize) -> (kind: Int, value: Double) {
    switch value {
    case let .proportion(v):
        return (0, quantize(Double(v)))
    case let .fixed(v):
        return (1, quantize(Double(v)))
    }
}

private struct WorkspaceWindowSignature: Equatable {
    let pid: Int32
    let hiddenInTabbedMode: Bool
}

private struct WorkspaceColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let widthKind: Int
    let widthValue: Double
    let windows: [WorkspaceWindowSignature]
}

private struct WorkspaceLayoutSignature: Equatable {
    let perWorkspaceColumns: [[WorkspaceColumnSignature]]
}

private enum SelectionSignature: Equatable {
    case none
    case window(pid: Int32)
    case column(index: Int)
}

private struct WorkspaceDualEngines {
    let zigEngine: NiriLayoutEngine
    let referenceEngine: NiriLayoutEngine
    let workspaceA: WorkspaceDescriptor.ID
    let workspaceB: WorkspaceDescriptor.ID
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

private func appendMirroredColumn(
    pids: [Int32],
    to zigRoot: NiriRoot,
    and referenceRoot: NiriRoot,
    zigEngine: NiriLayoutEngine,
    referenceEngine: NiriLayoutEngine
) {
    let zigColumn = NiriContainer()
    let referenceColumn = NiriContainer()
    zigRoot.appendChild(zigColumn)
    referenceRoot.appendChild(referenceColumn)
    for pid in pids {
        appendMirroredWindow(
            pid: pid_t(pid),
            zigColumn: zigColumn,
            referenceColumn: referenceColumn,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )
    }
    if !pids.isEmpty {
        zigColumn.setActiveTileIdx(0)
        referenceColumn.setActiveTileIdx(0)
    }
}

private func setupWorkspaceRoots(
    maxVisibleColumns: Int = 3,
    workspaceAColumns: [[Int32]],
    workspaceBColumns: [[Int32]]
) -> WorkspaceDualEngines {
    let workspaceA = WorkspaceDescriptor.ID()
    let workspaceB = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: maxVisibleColumns, infiniteLoop: false)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: maxVisibleColumns, infiniteLoop: false)

    let zigRootA = NiriRoot(workspaceId: workspaceA)
    let zigRootB = NiriRoot(workspaceId: workspaceB)
    let referenceRootA = NiriRoot(workspaceId: workspaceA)
    let referenceRootB = NiriRoot(workspaceId: workspaceB)
    zigEngine.roots[workspaceA] = zigRootA
    zigEngine.roots[workspaceB] = zigRootB
    referenceEngine.roots[workspaceA] = referenceRootA
    referenceEngine.roots[workspaceB] = referenceRootB

    for column in workspaceAColumns {
        appendMirroredColumn(
            pids: column,
            to: zigRootA,
            and: referenceRootA,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )
    }
    for column in workspaceBColumns {
        appendMirroredColumn(
            pids: column,
            to: zigRootB,
            and: referenceRootB,
            zigEngine: zigEngine,
            referenceEngine: referenceEngine
        )
    }

    if zigRootA.columns.isEmpty {
        zigRootA.appendChild(NiriContainer())
        referenceRootA.appendChild(NiriContainer())
    }
    if zigRootB.columns.isEmpty {
        zigRootB.appendChild(NiriContainer())
        referenceRootB.appendChild(NiriContainer())
    }

    return WorkspaceDualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceA: workspaceA,
        workspaceB: workspaceB
    )
}

private func layoutSignature(
    engine: NiriLayoutEngine,
    workspaceIds: [WorkspaceDescriptor.ID]
) -> WorkspaceLayoutSignature {
    WorkspaceLayoutSignature(
        perWorkspaceColumns: workspaceIds.map { workspaceId in
            engine.columns(in: workspaceId).map { column in
                let width = proportionalSignature(column.width)
                let hasWindows = !column.windowNodes.isEmpty
                return WorkspaceColumnSignature(
                    isTabbed: column.isTabbed,
                    activeTileIdx: column.activeTileIdx,
                    widthKind: hasWindows ? width.kind : -1,
                    widthValue: hasWindows ? width.value : 0,
                    windows: column.windowNodes.map { window in
                        WorkspaceWindowSignature(
                            pid: window.handle.pid,
                            hiddenInTabbedMode: window.isHiddenInTabbedMode
                        )
                    }
                )
            }
        }
    )
}

private func selectionSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: ViewportState
) -> SelectionSignature {
    guard let selectedNodeId = state.selectedNodeId,
          let node = engine.findNode(by: selectedNodeId)
    else {
        return .none
    }
    if let window = node as? NiriWindow {
        return .window(pid: window.handle.pid)
    }
    if let column = node as? NiriContainer,
       let index = engine.columnIndex(of: column, in: workspaceId)
    {
        return .column(index: index)
    }
    return .none
}

private func assertWorkspaceInvariants(
    engine: NiriLayoutEngine,
    workspaceIds: [WorkspaceDescriptor.ID]
) {
    for workspaceId in workspaceIds {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
        #expect(NiriStateZigKernel.validate(snapshot: snapshot).isValid)

        guard let root = engine.root(for: workspaceId) else { continue }
        #expect(!root.columns.isEmpty)
        for column in root.columns {
            if column.windowNodes.isEmpty {
                #expect(column.activeTileIdx == 0)
            } else {
                #expect(column.activeTileIdx >= 0)
                #expect(column.activeTileIdx < column.windowNodes.count)
            }
        }
    }

    for (handle, node) in engine.handleToNode {
        #expect(engine.findNode(for: handle) === node)
        #expect(node.findRoot() != nil)
    }
}

private func findWindow(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    pid: Int32
) -> NiriWindow? {
    engine.root(for: workspaceId)?.allWindows.first(where: { $0.handle.pid == pid })
}

private func chooseRandomWindowPid(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    rng: inout WorkspaceLCG
) -> Int32? {
    guard let windows = engine.root(for: workspaceId)?.allWindows, !windows.isEmpty else { return nil }
    let idx = rng.nextInt(0 ... windows.count - 1)
    return windows[idx].handle.pid
}

private func chooseRandomMovableColumnIndex(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    rng: inout WorkspaceLCG
) -> Int? {
    let columns = engine.columns(in: workspaceId)
    let movable = columns.enumerated().filter { !$0.element.windowNodes.isEmpty }.map(\.offset)
    guard !movable.isEmpty else { return nil }
    return movable[rng.nextInt(0 ... movable.count - 1)]
}

private func applyWindowMoveParity(
    dual: WorkspaceDualEngines,
    sourceWorkspaceId: WorkspaceDescriptor.ID,
    targetWorkspaceId: WorkspaceDescriptor.ID,
    pid: Int32,
    zigStates: inout [WorkspaceDescriptor.ID: ViewportState],
    referenceStates: inout [WorkspaceDescriptor.ID: ViewportState]
) {
    guard let zigWindow = findWindow(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, pid: pid),
          let referenceWindow = findWindow(engine: dual.referenceEngine, workspaceId: sourceWorkspaceId, pid: pid)
    else {
        return
    }

    var zigSourceState = zigStates[sourceWorkspaceId] ?? ViewportState()
    var zigTargetState = zigStates[targetWorkspaceId] ?? ViewportState()
    var referenceSourceState = referenceStates[sourceWorkspaceId] ?? ViewportState()
    var referenceTargetState = referenceStates[targetWorkspaceId] ?? ViewportState()

    let zigResult = dual.zigEngine.moveWindowToWorkspace(
        zigWindow,
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &zigSourceState,
        targetState: &zigTargetState
    )
    let referenceResult = NiriReferenceWorkspaceOps.moveWindowToWorkspace(
        referenceWindow,
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &referenceSourceState,
        targetState: &referenceTargetState,
        engine: dual.referenceEngine
    )

    zigStates[sourceWorkspaceId] = zigSourceState
    zigStates[targetWorkspaceId] = zigTargetState
    referenceStates[sourceWorkspaceId] = referenceSourceState
    referenceStates[targetWorkspaceId] = referenceTargetState

    #expect((zigResult != nil) == (referenceResult != nil))
    #expect(
        selectionSignature(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, state: zigSourceState) ==
            selectionSignature(engine: dual.referenceEngine, workspaceId: sourceWorkspaceId, state: referenceSourceState)
    )
    #expect(
        selectionSignature(engine: dual.zigEngine, workspaceId: targetWorkspaceId, state: zigTargetState) ==
            selectionSignature(engine: dual.referenceEngine, workspaceId: targetWorkspaceId, state: referenceTargetState)
    )
}

private func applyColumnMoveParity(
    dual: WorkspaceDualEngines,
    sourceWorkspaceId: WorkspaceDescriptor.ID,
    targetWorkspaceId: WorkspaceDescriptor.ID,
    sourceColumnIndex: Int,
    zigStates: inout [WorkspaceDescriptor.ID: ViewportState],
    referenceStates: inout [WorkspaceDescriptor.ID: ViewportState]
) {
    let zigColumns = dual.zigEngine.columns(in: sourceWorkspaceId)
    let referenceColumns = dual.referenceEngine.columns(in: sourceWorkspaceId)
    guard zigColumns.indices.contains(sourceColumnIndex),
          referenceColumns.indices.contains(sourceColumnIndex)
    else {
        return
    }

    var zigSourceState = zigStates[sourceWorkspaceId] ?? ViewportState()
    var zigTargetState = zigStates[targetWorkspaceId] ?? ViewportState()
    var referenceSourceState = referenceStates[sourceWorkspaceId] ?? ViewportState()
    var referenceTargetState = referenceStates[targetWorkspaceId] ?? ViewportState()

    let zigResult = dual.zigEngine.moveColumnToWorkspace(
        zigColumns[sourceColumnIndex],
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &zigSourceState,
        targetState: &zigTargetState
    )
    let referenceResult = NiriReferenceWorkspaceOps.moveColumnToWorkspace(
        referenceColumns[sourceColumnIndex],
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &referenceSourceState,
        targetState: &referenceTargetState,
        engine: dual.referenceEngine
    )

    zigStates[sourceWorkspaceId] = zigSourceState
    zigStates[targetWorkspaceId] = zigTargetState
    referenceStates[sourceWorkspaceId] = referenceSourceState
    referenceStates[targetWorkspaceId] = referenceTargetState

    #expect((zigResult != nil) == (referenceResult != nil))
    #expect(
        selectionSignature(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, state: zigSourceState) ==
            selectionSignature(engine: dual.referenceEngine, workspaceId: sourceWorkspaceId, state: referenceSourceState)
    )
    #expect(
        selectionSignature(engine: dual.zigEngine, workspaceId: targetWorkspaceId, state: zigTargetState) ==
            selectionSignature(engine: dual.referenceEngine, workspaceId: targetWorkspaceId, state: referenceTargetState)
    )
}

@Suite struct NiriZigWorkspaceOpsParityTests {
    @Test func phase6ScenarioMoveWindowToEmptyWorkspaceReusesPlaceholderAndResetsWidth() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[210_001]],
            workspaceBColumns: [[], []]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        dual.zigEngine.columns(in: dual.workspaceB)[0].width = .proportion(0.75)
        dual.referenceEngine.columns(in: dual.workspaceB)[0].width = .proportion(0.75)

        applyWindowMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            pid: 210_001,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        #expect(dual.zigEngine.columns(in: dual.workspaceB).count == 1)
        let width = proportionalSignature(dual.zigEngine.columns(in: dual.workspaceB)[0].width)
        #expect(width.kind == 0)
        #expect(width.value == quantize(1.0 / 3.0))
        assertWorkspaceInvariants(engine: dual.zigEngine, workspaceIds: workspaceIds)
        assertWorkspaceInvariants(engine: dual.referenceEngine, workspaceIds: workspaceIds)
    }

    @Test func phase6ScenarioMoveWindowToNonEmptyWorkspaceCreatesColumnAtEnd() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[220_001]],
            workspaceBColumns: [[220_002]]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        applyWindowMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            pid: 220_001,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        let targetColumns = dual.zigEngine.columns(in: dual.workspaceB)
        #expect(targetColumns.count == 2)
        #expect(targetColumns[1].windowNodes.first?.handle.pid == 220_001)
        assertWorkspaceInvariants(engine: dual.zigEngine, workspaceIds: workspaceIds)
        assertWorkspaceInvariants(engine: dual.referenceEngine, workspaceIds: workspaceIds)
    }

    @Test func phase6ScenarioMoveWindowCleansEmptiedSourceAndPreservesPlaceholder() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[230_001]],
            workspaceBColumns: [[230_002]]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        applyWindowMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            pid: 230_001,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        #expect(dual.zigEngine.columns(in: dual.workspaceA).count == 1)
        #expect(dual.zigEngine.columns(in: dual.workspaceA)[0].windowNodes.isEmpty)
    }

    @Test func phase6ScenarioMoveColumnUsesPrevThenNextFallbackSelectionParity() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[240_001], [240_002], [240_003]],
            workspaceBColumns: [[240_101]]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        applyColumnMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            sourceColumnIndex: 1,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        let zigSourceSelection = selectionSignature(
            engine: dual.zigEngine,
            workspaceId: dual.workspaceA,
            state: zigStates[dual.workspaceA] ?? ViewportState()
        )
        #expect(zigSourceSelection == .window(pid: 240_001))
        let zigTargetSelection = selectionSignature(
            engine: dual.zigEngine,
            workspaceId: dual.workspaceB,
            state: zigStates[dual.workspaceB] ?? ViewportState()
        )
        #expect(zigTargetSelection == .window(pid: 240_002))
    }

    @Test func phase6ScenarioMoveColumnToEmptyWorkspacePrunesPlaceholderColumns() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[250_001]],
            workspaceBColumns: [[], []]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        applyColumnMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            sourceColumnIndex: 0,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        #expect(dual.zigEngine.columns(in: dual.workspaceB).count == 1)
        #expect(dual.zigEngine.columns(in: dual.workspaceB)[0].windowNodes.first?.handle.pid == 250_001)
    }

    @Test func phase6ScenarioMoveLastSourceColumnEnsuresPlaceholder() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[260_001]],
            workspaceBColumns: [[260_101]]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

        applyColumnMoveParity(
            dual: dual,
            sourceWorkspaceId: dual.workspaceA,
            targetWorkspaceId: dual.workspaceB,
            sourceColumnIndex: 0,
            zigStates: &zigStates,
            referenceStates: &referenceStates
        )

        #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
        #expect(dual.zigEngine.columns(in: dual.workspaceA).count == 1)
        #expect(dual.zigEngine.columns(in: dual.workspaceA)[0].windowNodes.isEmpty)
    }

    @Test func randomizedWorkspaceTransferTraceParityMatchesReferenceModel() {
        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[310_001, 310_002], [310_003], [310_004, 310_005]],
            workspaceBColumns: [[320_001], [320_002, 320_003]]
        )
        let workspaceIds = [dual.workspaceA, dual.workspaceB]
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var referenceStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var rng = WorkspaceLCG(seed: 0xC0DE_CAFE_0000_0006)

        for _ in 0 ..< 2_000 {
            let sourceWorkspaceId: WorkspaceDescriptor.ID = if rng.nextBool(0.5) {
                dual.workspaceA
            } else {
                dual.workspaceB
            }
            let targetWorkspaceId: WorkspaceDescriptor.ID = sourceWorkspaceId == dual.workspaceA ? dual.workspaceB : dual.workspaceA
            let doWindowMove = rng.nextBool(0.65)

            if doWindowMove,
               let pid = chooseRandomWindowPid(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, rng: &rng)
            {
                applyWindowMoveParity(
                    dual: dual,
                    sourceWorkspaceId: sourceWorkspaceId,
                    targetWorkspaceId: targetWorkspaceId,
                    pid: pid,
                    zigStates: &zigStates,
                    referenceStates: &referenceStates
                )
            } else if let sourceColumnIndex = chooseRandomMovableColumnIndex(
                engine: dual.zigEngine,
                workspaceId: sourceWorkspaceId,
                rng: &rng
            ) {
                applyColumnMoveParity(
                    dual: dual,
                    sourceWorkspaceId: sourceWorkspaceId,
                    targetWorkspaceId: targetWorkspaceId,
                    sourceColumnIndex: sourceColumnIndex,
                    zigStates: &zigStates,
                    referenceStates: &referenceStates
                )
            } else {
                continue
            }

            #expect(layoutSignature(engine: dual.zigEngine, workspaceIds: workspaceIds) == layoutSignature(engine: dual.referenceEngine, workspaceIds: workspaceIds))
            assertWorkspaceInvariants(engine: dual.zigEngine, workspaceIds: workspaceIds)
            assertWorkspaceInvariants(engine: dual.referenceEngine, workspaceIds: workspaceIds)

            for workspaceId in workspaceIds {
                #expect(
                    selectionSignature(
                        engine: dual.zigEngine,
                        workspaceId: workspaceId,
                        state: zigStates[workspaceId] ?? ViewportState()
                    ) ==
                        selectionSignature(
                            engine: dual.referenceEngine,
                            workspaceId: workspaceId,
                            state: referenceStates[workspaceId] ?? ViewportState()
                        )
                )
            }
        }
    }

    @Test func workspaceOpsPlannerBenchmarkHarnessP95() throws {
        guard isWorkspacePerfGateEnabled() else { return }

        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[410_001, 410_002], [410_003]],
            workspaceBColumns: [[420_001], [420_002, 420_003]]
        )

        let sourceSnapshotA = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceA))
        let sourceSnapshotB = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceB))

        var rng = WorkspaceLCG(seed: 0xAAAA_BBBB_CCCC_DDDD)
        var requests: [(source: NiriStateZigKernel.Snapshot, target: NiriStateZigKernel.Snapshot, request: NiriStateZigKernel.WorkspaceRequest)] = []
        requests.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let useAAsSource = rng.nextBool(0.5)
            let sourceSnapshot = useAAsSource ? sourceSnapshotA : sourceSnapshotB
            let targetSnapshot = useAAsSource ? sourceSnapshotB : sourceSnapshotA

            if rng.nextBool(0.65), !sourceSnapshot.windowEntries.isEmpty {
                let sourceWindowIndex = rng.nextInt(0 ... sourceSnapshot.windowEntries.count - 1)
                requests.append(
                    (
                        sourceSnapshot,
                        targetSnapshot,
                        NiriStateZigKernel.WorkspaceRequest(
                            op: .moveWindowToWorkspace,
                            sourceWindowIndex: sourceWindowIndex,
                            maxVisibleColumns: dual.zigEngine.maxVisibleColumns
                        )
                    )
                )
            } else if !sourceSnapshot.columnEntries.isEmpty {
                let sourceColumnIndex = rng.nextInt(0 ... sourceSnapshot.columnEntries.count - 1)
                requests.append(
                    (
                        sourceSnapshot,
                        targetSnapshot,
                        NiriStateZigKernel.WorkspaceRequest(
                            op: .moveColumnToWorkspace,
                            sourceColumnIndex: sourceColumnIndex
                        )
                    )
                )
            }
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)
        for case let (source, target, request) in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveWorkspace(
                sourceSnapshot: source,
                targetSnapshot: target,
                request: request
            )
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri workspace-ops planner p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase6WorkspaceOps()
        let perfLimit = baseline.workspace_ops_planner_p95_sec * 1.10
        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }

    @Test func workspaceOpsRuntimeFullPathBenchmarkHarnessP95() throws {
        guard isWorkspacePerfGateEnabled() else { return }

        let dual = setupWorkspaceRoots(
            workspaceAColumns: [[510_001, 510_002], [510_003], [510_004]],
            workspaceBColumns: [[520_001], [520_002, 520_003]]
        )
        var rng = WorkspaceLCG(seed: 0x1357_2468_ACE0_BDF1)
        var zigStates: [WorkspaceDescriptor.ID: ViewportState] = [:]
        var samples: [Double] = []
        samples.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let sourceWorkspaceId: WorkspaceDescriptor.ID = if rng.nextBool(0.5) {
                dual.workspaceA
            } else {
                dual.workspaceB
            }
            let targetWorkspaceId: WorkspaceDescriptor.ID = sourceWorkspaceId == dual.workspaceA ? dual.workspaceB : dual.workspaceA

            let t0 = CACurrentMediaTime()
            if rng.nextBool(0.65),
               let pid = chooseRandomWindowPid(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, rng: &rng),
               let window = findWindow(engine: dual.zigEngine, workspaceId: sourceWorkspaceId, pid: pid)
            {
                var sourceState = zigStates[sourceWorkspaceId] ?? ViewportState()
                var targetState = zigStates[targetWorkspaceId] ?? ViewportState()
                _ = dual.zigEngine.moveWindowToWorkspace(
                    window,
                    from: sourceWorkspaceId,
                    to: targetWorkspaceId,
                    sourceState: &sourceState,
                    targetState: &targetState
                )
                zigStates[sourceWorkspaceId] = sourceState
                zigStates[targetWorkspaceId] = targetState
            } else if let sourceColumnIndex = chooseRandomMovableColumnIndex(
                engine: dual.zigEngine,
                workspaceId: sourceWorkspaceId,
                rng: &rng
            ) {
                let sourceColumns = dual.zigEngine.columns(in: sourceWorkspaceId)
                if sourceColumns.indices.contains(sourceColumnIndex) {
                    var sourceState = zigStates[sourceWorkspaceId] ?? ViewportState()
                    var targetState = zigStates[targetWorkspaceId] ?? ViewportState()
                    _ = dual.zigEngine.moveColumnToWorkspace(
                        sourceColumns[sourceColumnIndex],
                        from: sourceWorkspaceId,
                        to: targetWorkspaceId,
                        sourceState: &sourceState,
                        targetState: &targetState
                    )
                    zigStates[sourceWorkspaceId] = sourceState
                    zigStates[targetWorkspaceId] = targetState
                }
            }
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri workspace-ops runtime full-path p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase6WorkspaceOps()
        let perfLimit = baseline.workspace_ops_full_path_p95_sec * 1.10
        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}
