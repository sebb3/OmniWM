import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private func rectsApproximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect?, epsilon: CGFloat = 0.001) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (.some(a), .some(b)):
        abs(a.origin.x - b.origin.x) <= epsilon &&
            abs(a.origin.y - b.origin.y) <= epsilon &&
            abs(a.width - b.width) <= epsilon &&
            abs(a.height - b.height) <= epsilon
    default:
        false
    }
}

private func percentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

private struct PreflightInteractionBaseline: Decodable {
    let layout_p95_sec: Double
    let interaction_uncached_tiled_p95_sec: Double
    let interaction_uncached_resize_p95_sec: Double
    let interaction_uncached_move_p95_sec: Double
    let interaction_context_tiled_p95_sec: Double
    let interaction_context_resize_p95_sec: Double
    let interaction_context_move_p95_sec: Double
}

private func loadPreflightInteractionBaseline() -> PreflightInteractionBaseline? {
    let benchmarksDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Benchmarks")
    let baselinePath = benchmarksDir.appendingPathComponent("preflight-baseline-2026-03-03.json")
    guard let data = try? Data(contentsOf: baselinePath) else { return nil }
    return try? JSONDecoder().decode(PreflightInteractionBaseline.self, from: data)
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1
        let value = state >> 11
        return Double(value) / Double(1 << 53)
    }
}

private func referenceMoveHoverTarget(
    columns: [NiriContainer],
    point: CGPoint,
    excludingWindowId: NodeId,
    isInsertMode: Bool
) -> MoveHoverTarget? {
    for column in columns {
        for child in column.children {
            guard let window = child as? NiriWindow,
                  window.id != excludingWindowId,
                  let frame = window.frame else { continue }

            if frame.contains(point) {
                let position: InsertPosition = if isInsertMode {
                    point.y < frame.midY ? .before : .after
                } else {
                    .swap
                }
                return .window(
                    nodeId: window.id,
                    handle: window.handle,
                    insertPosition: position
                )
            }
        }
    }
    return nil
}

private func referenceInsertionDropzone(
    columns: [NiriContainer],
    targetWindowId: NodeId,
    position: InsertPosition,
    gap: CGFloat
) -> CGRect? {
    var targetWindow: NiriWindow?
    var targetColumn: NiriContainer?
    for column in columns {
        for child in column.children {
            guard let window = child as? NiriWindow else { continue }
            if window.id == targetWindowId {
                targetWindow = window
                targetColumn = column
                break
            }
        }
        if targetWindow != nil {
            break
        }
    }

    guard let targetWindow,
          let targetFrame = targetWindow.frame,
          let targetColumn else {
        return nil
    }

    let windows = targetColumn.windowNodes
    let postInsertionCount = windows.count + 1
    guard let bottom = windows.first?.frame?.minY,
          let top = windows.last?.frame?.maxY else {
        return nil
    }

    let columnHeight = top - bottom
    let totalGaps = CGFloat(postInsertionCount - 1) * gap
    let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
    let x = targetFrame.minX
    let width = targetFrame.width

    let y: CGFloat = switch position {
    case .before:
        {
            let unclamped = targetFrame.minY - gap - newHeight
            let maxY = max(bottom, top - newHeight)
            return min(max(bottom, unclamped), maxY)
        }()
    case .after:
        targetFrame.maxY + gap
    case .swap:
        targetFrame.minY
    }

    return CGRect(x: x, y: y, width: width, height: newHeight)
}

@MainActor
@discardableResult
private func seedInteractionContextFromCurrentFrames(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    guard let root = engine.root(for: workspaceId),
          let context = engine.ensureLayoutContext(for: workspaceId)
    else {
        return false
    }

    let snapshot = NiriLayoutZigKernel.makeInteractionSnapshot(columns: root.columns)
    guard NiriLayoutZigKernel.seedInteractionContext(context: context, snapshot: snapshot) else {
        return false
    }

    engine.interactionIndexes[workspaceId] = NiriLayoutZigKernel.InteractionIndex(
        windowEntries: snapshot.windowEntries,
        windowIndexByNodeId: snapshot.windowIndexByNodeId
    )
    return true
}

@Suite struct NiriZigInteractionTests {
    @MainActor
    @Test func layoutPassV2PopulatesColumnFramesAndHiddenSides() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 8)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        for i in 0 ..< 3 {
            let column = NiriContainer()
            column.cachedWidth = 620
            root.appendChild(column)

            let handle = makeTestHandle(pid: pid_t(6000 + i))
            let window = NiriWindow(handle: handle)
            engine.handleToNode[handle] = window
            column.appendChild(window)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        var frames: [WindowHandle: CGRect] = [:]
        var hidden: [WindowHandle: HideSide] = [:]

        let monitorFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let area = WorkingAreaContext(
            workingFrame: monitorFrame,
            viewFrame: monitorFrame,
            scale: 2.0
        )

        engine.calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hidden,
            state: state,
            workspaceId: wsId,
            monitorFrame: monitorFrame,
            screenFrame: monitorFrame,
            gaps: (horizontal: 16, vertical: 12),
            scale: 2.0,
            workingArea: area,
            orientation: .horizontal,
            animationTime: CACurrentMediaTime()
        )

        let columns = engine.columns(in: wsId)
        #expect(columns.count == 3)
        #expect(columns.allSatisfy { $0.frame != nil })
        #expect(hidden.values.contains(.left))
        #expect(hidden.values.contains(.right))
    }

    @MainActor
    @Test func zigTiledHitTestReturnsMatchingWindow() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let h1 = makeTestHandle(pid: 1001)
        let h2 = makeTestHandle(pid: 1002)
        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        w1.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        w2.frame = CGRect(x: 220, y: 0, width: 200, height: 200)
        column.appendChild(w1)
        column.appendChild(w2)
        engine.handleToNode[h1] = w1
        engine.handleToNode[h2] = w2

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))

        let hit = engine.hitTestTiled(point: CGPoint(x: 350, y: 50), in: wsId)
        #expect(hit?.id == w2.id)

        let miss = engine.hitTestTiled(point: CGPoint(x: 999, y: 999), in: wsId)
        #expect(miss == nil)
    }

    @MainActor
    @Test func zigResizeHitTestDetectsEdgesAndSkipsFullscreen() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let fullscreenHandle = makeTestHandle(pid: 1101)
        let fullscreenWindow = NiriWindow(handle: fullscreenHandle)
        fullscreenWindow.sizingMode = .fullscreen
        fullscreenWindow.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        column.appendChild(fullscreenWindow)
        engine.handleToNode[fullscreenHandle] = fullscreenWindow

        let normalHandle = makeTestHandle(pid: 1102)
        let normalWindow = NiriWindow(handle: normalHandle)
        normalWindow.frame = CGRect(x: 220, y: 20, width: 240, height: 220)
        column.appendChild(normalWindow)
        engine.handleToNode[normalHandle] = normalWindow

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))

        let fullscreenEdgeHit = engine.hitTestResize(
            point: CGPoint(x: 1, y: 1),
            in: wsId,
            threshold: 8
        )
        #expect(fullscreenEdgeHit == nil)

        let normalEdgeHit = engine.hitTestResize(
            point: CGPoint(x: 460, y: 120),
            in: wsId,
            threshold: 8
        )
        #expect(normalEdgeHit != nil)
        #expect(normalEdgeHit?.nodeId == normalWindow.id)
        #expect(normalEdgeHit?.edges.contains(.right) == true)
    }

    @MainActor
    @Test func zigResizeComputeClampsWidthAndAdjustsViewportOffset() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        column.cachedWidth = 400
        root.appendChild(column)

        let handle = makeTestHandle(pid: 1201)
        let window = NiriWindow(handle: handle)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.size = 1.0
        column.appendChild(window)
        engine.handleToNode[handle] = window

        let began = engine.interactiveResizeBegin(
            windowId: window.id,
            edges: [.left, .top],
            startLocation: .zero,
            in: wsId,
            viewOffset: 10
        )
        #expect(began)

        var viewport = ViewportState()
        let changed = engine.interactiveResizeUpdate(
            currentLocation: CGPoint(x: -1000, y: 300),
            monitorFrame: CGRect(x: 0, y: 0, width: 800, height: 1000),
            gaps: LayoutGaps(horizontal: 16, vertical: 16),
            viewportState: { mutate in
                mutate(&viewport)
            }
        )
        #expect(changed)
        #expect(abs(column.cachedWidth - 784) < 0.01)
        #expect(abs(viewport.viewOffsetPixels.current() - 394) < 0.01)
        #expect(window.size > 1.2)
    }

    @MainActor
    @Test func zigMoveTargetParityMatchesReference() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 5)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        var windows: [NiriWindow] = []
        for columnIndex in 0 ..< 3 {
            let column = NiriContainer()
            root.appendChild(column)

            for rowIndex in 0 ..< 4 {
                let handle = makeTestHandle(pid: pid_t(7000 + columnIndex * 10 + rowIndex))
                let window = NiriWindow(handle: handle)
                window.frame = CGRect(
                    x: CGFloat(columnIndex) * 260,
                    y: CGFloat(rowIndex) * 150,
                    width: 240,
                    height: 140
                )
                column.appendChild(window)
                engine.handleToNode[handle] = window
                windows.append(window)
            }
        }

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))
        let excludedId = windows[0].id

        var rng = LCG(seed: 0xCAFE_F00D)
        for _ in 0 ..< 1000 {
            let point = CGPoint(
                x: 780 * rng.nextUnit(),
                y: 600 * rng.nextUnit()
            )

            for isInsertMode in [false, true] {
                let referenceTarget = referenceMoveHoverTarget(
                    columns: root.columns,
                    point: point,
                    excludingWindowId: excludedId,
                    isInsertMode: isInsertMode
                )

                let zigTarget = engine.hitTestMoveTarget(
                    point: point,
                    excludingWindowId: excludedId,
                    isInsertMode: isInsertMode,
                    in: wsId
                )

                #expect(zigTarget == referenceTarget)
            }
        }
    }

    @MainActor
    @Test func zigInsertionDropzoneParityMatchesReference() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 6)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        var windows: [NiriWindow] = []
        let heights: [CGFloat] = [22, 28, 24]
        var y: CGFloat = 100
        for (index, height) in heights.enumerated() {
            let handle = makeTestHandle(pid: pid_t(8000 + index))
            let window = NiriWindow(handle: handle)
            window.frame = CGRect(x: 40, y: y, width: 180, height: height)
            y += height + 30
            column.appendChild(window)
            engine.handleToNode[handle] = window
            windows.append(window)
        }

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))

        let targets = [windows.first, windows.last].compactMap { $0 }
        let positions: [InsertPosition] = [.before, .after, .swap]
        let gaps: [CGFloat] = [2, 30, 52]

        for target in targets {
            for position in positions {
                for gap in gaps {
                    let referenceDropzone = referenceInsertionDropzone(
                        columns: root.columns,
                        targetWindowId: target.id,
                        position: position,
                        gap: gap
                    )

                    let zigDropzone = engine.insertionDropzoneFrame(
                        targetWindowId: target.id,
                        position: position,
                        in: wsId,
                        gaps: gap
                    )

                    #expect(rectsApproximatelyEqual(zigDropzone, referenceDropzone))
                }
            }
        }
    }

    @MainActor
    @Test func zigInsertionDropzoneBeforeClampsToColumnBounds() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 6)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let lowerHandle = makeTestHandle(pid: 8102)
        let lowerWindow = NiriWindow(handle: lowerHandle)
        lowerWindow.frame = CGRect(x: 40, y: 100, width: 180, height: 20)
        column.appendChild(lowerWindow)
        engine.handleToNode[lowerHandle] = lowerWindow

        let upperHandle = makeTestHandle(pid: 8101)
        let upperWindow = NiriWindow(handle: upperHandle)
        upperWindow.frame = CGRect(x: 40, y: 200, width: 180, height: 20)
        column.appendChild(upperWindow)
        engine.handleToNode[upperHandle] = upperWindow

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))

        let lowerDropzone = engine.insertionDropzoneFrame(
            targetWindowId: lowerWindow.id,
            position: .before,
            in: wsId,
            gaps: 0
        )
        let upperDropzone = engine.insertionDropzoneFrame(
            targetWindowId: upperWindow.id,
            position: .before,
            in: wsId,
            gaps: 0
        )

        #expect(lowerDropzone != nil)
        #expect(upperDropzone != nil)
        if let lowerDropzone {
            #expect(abs(lowerDropzone.minY - 100) < 0.001)
        }
        if let upperDropzone {
            #expect(abs(upperDropzone.minY - 160) < 0.001)
        }
    }

    @MainActor
    @Test func interactionKernelBenchmarkHarnessP95() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 12)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        var allWindows: [NiriWindow] = []
        let columns = 12
        let rows = 10
        let windowWidth: CGFloat = 220
        let windowHeight: CGFloat = 96
        let gapX: CGFloat = 14
        let gapY: CGFloat = 8

        for colIndex in 0 ..< columns {
            let column = NiriContainer()
            root.appendChild(column)
            for rowIndex in 0 ..< rows {
                let handle = makeTestHandle(pid: pid_t(9000 + colIndex * 100 + rowIndex))
                let window = NiriWindow(handle: handle)
                window.frame = CGRect(
                    x: CGFloat(colIndex) * (windowWidth + gapX),
                    y: CGFloat(rowIndex) * (windowHeight + gapY),
                    width: windowWidth,
                    height: windowHeight
                )
                column.appendChild(window)
                engine.handleToNode[handle] = window
                allWindows.append(window)
            }
        }

        #expect(seedInteractionContextFromCurrentFrames(engine: engine, workspaceId: wsId))

        var rng = LCG(seed: 0xDEAD_BEEF)
        var points: [CGPoint] = []
        points.reserveCapacity(10_000)
        for _ in 0 ..< 10_000 {
            points.append(
                CGPoint(
                    x: (windowWidth + gapX) * CGFloat(columns) * rng.nextUnit(),
                    y: (windowHeight + gapY) * CGFloat(rows) * rng.nextUnit()
                )
            )
        }

        let excludedId = allWindows[0].id

        func benchmark(_ run: (CGPoint) -> Void) -> Double {
            var samples: [Double] = []
            samples.reserveCapacity(points.count)
            for point in points {
                let t0 = CACurrentMediaTime()
                run(point)
                samples.append(CACurrentMediaTime() - t0)
            }
            return percentile(samples, 0.95)
        }

        let zigSnapshotTiledP95 = benchmark { _ = engine.hitTestTiled(point: $0, in: wsId) }
        let zigSnapshotResizeP95 = benchmark { _ = engine.hitTestResize(point: $0, in: wsId, threshold: 8) }
        let zigSnapshotMoveP95 = benchmark {
            _ = engine.hitTestMoveTarget(point: $0, excludingWindowId: excludedId, isInsertMode: true, in: wsId)
        }

        let zigUncachedTiledP95 = benchmark { point in
            let snapshot = NiriLayoutZigKernel.makeInteractionSnapshot(columns: root.columns)
            _ = NiriLayoutZigKernel.hitTestTiled(snapshot: snapshot, point: point)
        }
        let zigUncachedResizeP95 = benchmark { point in
            let snapshot = NiriLayoutZigKernel.makeInteractionSnapshot(columns: root.columns)
            _ = NiriLayoutZigKernel.hitTestResize(snapshot: snapshot, point: point, threshold: 8)
        }
        let zigUncachedMoveP95 = benchmark { point in
            let snapshot = NiriLayoutZigKernel.makeInteractionSnapshot(columns: root.columns)
            _ = NiriLayoutZigKernel.hitTestMoveTarget(
                snapshot: snapshot,
                point: point,
                excludingWindowId: excludedId,
                isInsertMode: true
            )
        }

        print(
            String(
                format: "Niri interaction benchmark p95 (zig context): tiled=%.9f resize=%.9f move=%.9f",
                zigSnapshotTiledP95,
                zigSnapshotResizeP95,
                zigSnapshotMoveP95
            )
        )
        print(
            String(
                format: "Niri interaction benchmark p95 (zig uncached): tiled=%.9f resize=%.9f move=%.9f",
                zigUncachedTiledP95,
                zigUncachedResizeP95,
                zigUncachedMoveP95
            )
        )

        #expect(zigSnapshotTiledP95 > 0)
        #expect(zigSnapshotResizeP95 > 0)
        #expect(zigSnapshotMoveP95 > 0)
        #expect(zigUncachedTiledP95 > 0)
        #expect(zigUncachedResizeP95 > 0)
        #expect(zigUncachedMoveP95 > 0)

        if let baseline = loadPreflightInteractionBaseline() {
            // Context hit-tests should remain close to fast-path floor.
            #expect(zigSnapshotTiledP95 <= baseline.interaction_context_tiled_p95_sec * 1.25)
            #expect(zigSnapshotResizeP95 <= baseline.interaction_context_resize_p95_sec * 1.25)
            #expect(zigSnapshotMoveP95 <= baseline.interaction_context_move_p95_sec * 1.25)

            // Uncached interaction path guards the feed-build overhead.
            #expect(zigUncachedTiledP95 <= baseline.interaction_uncached_tiled_p95_sec * 2.5)
            #expect(zigUncachedResizeP95 <= baseline.interaction_uncached_resize_p95_sec * 2.5)
            #expect(zigUncachedMoveP95 <= baseline.interaction_uncached_move_p95_sec * 2.5)
        }
    }

    @Test func layoutContextLifecycleCreateDestroyRecreate() {
        weak var released: AnyObject?
        do {
            let context = NiriLayoutZigKernel.LayoutContext()
            #expect(context != nil)
            released = context
        }
        #expect(released == nil)

        let recreated = NiriLayoutZigKernel.LayoutContext()
        #expect(recreated != nil)
    }

    @MainActor
    @Test func contextInteractionParityMatchesSnapshotPath() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 6)
        let wsId = WorkspaceDescriptor.ID()
        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        var windows: [NiriWindow] = []
        for columnIndex in 0 ..< 3 {
            let column = NiriContainer()
            root.appendChild(column)
            for rowIndex in 0 ..< 3 {
                let handle = makeTestHandle(pid: pid_t(12_000 + columnIndex * 10 + rowIndex))
                let window = NiriWindow(handle: handle)
                window.frame = CGRect(
                    x: CGFloat(columnIndex) * 260,
                    y: CGFloat(rowIndex) * 120,
                    width: 240,
                    height: 100
                )
                column.appendChild(window)
                engine.handleToNode[handle] = window
                windows.append(window)
            }
        }

        let snapshot = NiriLayoutZigKernel.makeInteractionSnapshot(columns: root.columns)
        guard let context = NiriLayoutZigKernel.LayoutContext() else {
            Issue.record("failed to create layout context")
            return
        }
        #expect(NiriLayoutZigKernel.seedInteractionContext(context: context, snapshot: snapshot))

        let interaction = NiriLayoutZigKernel.InteractionIndex(
            windowEntries: snapshot.windowEntries,
            windowIndexByNodeId: snapshot.windowIndexByNodeId
        )

        var rng = LCG(seed: 0xBEEF_CAFE)
        let excludedId = windows[0].id
        for _ in 0 ..< 1_000 {
            let point = CGPoint(
                x: 780 * rng.nextUnit(),
                y: 420 * rng.nextUnit()
            )

            let snapshotTiled = NiriLayoutZigKernel.hitTestTiled(snapshot: snapshot, point: point)
            let contextTiled = NiriLayoutZigKernel.hitTestTiled(context: context, interaction: interaction, point: point)
            #expect(snapshotTiled?.id == contextTiled?.id)

            let snapshotResize = NiriLayoutZigKernel.hitTestResize(snapshot: snapshot, point: point, threshold: 8)
            let contextResize = NiriLayoutZigKernel.hitTestResize(
                context: context,
                interaction: interaction,
                point: point,
                threshold: 8
            )
            #expect(snapshotResize?.window.id == contextResize?.window.id)
            #expect(snapshotResize?.edges == contextResize?.edges)

            for isInsertMode in [false, true] {
                let snapshotMove = NiriLayoutZigKernel.hitTestMoveTarget(
                    snapshot: snapshot,
                    point: point,
                    excludingWindowId: excludedId,
                    isInsertMode: isInsertMode
                )
                let contextMove = NiriLayoutZigKernel.hitTestMoveTarget(
                    context: context,
                    interaction: interaction,
                    point: point,
                    excludingWindowId: excludedId,
                    isInsertMode: isInsertMode
                )
                #expect(snapshotMove?.window.id == contextMove?.window.id)
                #expect(snapshotMove?.insertPosition == contextMove?.insertPosition)
            }
        }

        for window in windows {
            guard let windowIndex = snapshot.windowIndexByNodeId[window.id],
                  snapshot.windowEntries.indices.contains(windowIndex)
            else {
                continue
            }
            let entry = snapshot.windowEntries[windowIndex]
            guard snapshot.columnDropzoneMeta.indices.contains(entry.columnIndex),
                  let columnMeta = snapshot.columnDropzoneMeta[entry.columnIndex]
            else {
                continue
            }

            for position in [InsertPosition.before, .after, .swap] {
                let snapshotDropzone = NiriLayoutZigKernel.computeInsertionDropzone(
                    .init(
                        targetFrame: entry.frame,
                        columnIndex: entry.columnIndex,
                        columnMinY: columnMeta.minY,
                        columnMaxY: columnMeta.maxY,
                        postInsertionCount: columnMeta.postInsertionCount,
                        gap: 24,
                        position: position
                    )
                )
                let contextDropzone = NiriLayoutZigKernel.insertionDropzoneFrame(
                    context: context,
                    interaction: interaction,
                    targetWindowId: window.id,
                    position: position,
                    gap: 24
                )
                #expect(rectsApproximatelyEqual(snapshotDropzone, contextDropzone))
            }
        }
    }
}
