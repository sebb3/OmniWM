import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func dwindleFuzzUUID(_ rng: inout DwindleMutationLCG) -> UUID {
    var hi = rng.next()
    let lo = rng.next()
    if hi == 0, lo == 0 {
        hi = 1
    }
    let tuple: uuid_t = (
        UInt8(truncatingIfNeeded: hi >> 56),
        UInt8(truncatingIfNeeded: hi >> 48),
        UInt8(truncatingIfNeeded: hi >> 40),
        UInt8(truncatingIfNeeded: hi >> 32),
        UInt8(truncatingIfNeeded: hi >> 24),
        UInt8(truncatingIfNeeded: hi >> 16),
        UInt8(truncatingIfNeeded: hi >> 8),
        UInt8(truncatingIfNeeded: hi),
        UInt8(truncatingIfNeeded: lo >> 56),
        UInt8(truncatingIfNeeded: lo >> 48),
        UInt8(truncatingIfNeeded: lo >> 40),
        UInt8(truncatingIfNeeded: lo >> 32),
        UInt8(truncatingIfNeeded: lo >> 24),
        UInt8(truncatingIfNeeded: lo >> 16),
        UInt8(truncatingIfNeeded: lo >> 8),
        UInt8(truncatingIfNeeded: lo)
    )
    return UUID(uuid: tuple)
}

private func dwindleFuzzDedupOrder(_ ids: [UUID]) -> [UUID] {
    var seen: Set<UUID> = []
    var ordered: [UUID] = []
    ordered.reserveCapacity(ids.count)
    for id in ids where !seen.contains(id) {
        seen.insert(id)
        ordered.append(id)
    }
    return ordered
}

private func dwindleFuzzDirection(_ rng: inout DwindleMutationLCG) -> Direction {
    switch rng.nextInt(0 ... 3) {
    case 0: return .left
    case 1: return .right
    case 2: return .up
    default: return .down
    }
}

private func applyReferenceFuzzOp(
    _ op: DwindleZigKernel.Op,
    engine: DwindleLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    handlePool: inout [UUID: WindowHandle],
    nextPid: inout pid_t
) -> [UUID] {
    let currentHandles = engine.root(for: workspaceId)?.collectAllWindows() ?? []

    switch op {
    case let .addWindow(windowId):
        if currentHandles.contains(where: { $0.id == windowId }) {
            return []
        }
        if handlePool[windowId] == nil {
            nextPid += 1
            handlePool[windowId] = dwindleMutationMakeHandle(id: windowId, pid: nextPid)
        }
        if let handle = handlePool[windowId] {
            _ = engine.addWindow(handle: handle, to: workspaceId, activeWindowFrame: nil)
        }
        return []

    case let .removeWindow(windowId):
        guard let existingHandle = currentHandles.first(where: { $0.id == windowId }) else {
            return []
        }
        engine.removeWindow(handle: existingHandle, from: workspaceId)
        return [windowId]

    case let .syncWindows(windowIds):
        let deduped = dwindleFuzzDedupOrder(windowIds)
        var seenCurrent: Set<UUID> = []
        let currentOrder = currentHandles.compactMap { handle in
            if seenCurrent.insert(handle.id).inserted {
                return handle.id
            }
            return nil
        }
        let incomingSet = Set(deduped)
        let expectedRemoved = currentOrder.filter { !incomingSet.contains($0) }

        var handles: [WindowHandle] = []
        handles.reserveCapacity(deduped.count)
        for windowId in deduped {
            if let existing = handlePool[windowId] {
                handles.append(existing)
            } else {
                nextPid += 1
                let created = dwindleMutationMakeHandle(id: windowId, pid: nextPid)
                handlePool[windowId] = created
                handles.append(created)
            }
        }
        _ = engine.syncWindows(handles, in: workspaceId, focusedHandle: nil)
        return expectedRemoved

    case let .moveFocus(direction):
        _ = engine.moveFocus(direction: direction, in: workspaceId)
        return []

    case let .swapWindows(direction):
        _ = engine.swapWindows(direction: direction, in: workspaceId)
        return []

    case .toggleFullscreen:
        _ = engine.toggleFullscreen(in: workspaceId)
        return []

    case .toggleOrientation:
        engine.toggleOrientation(in: workspaceId)
        return []

    case let .resizeSelected(delta, direction):
        engine.resizeSelected(by: delta, direction: direction, in: workspaceId)
        return []

    case .balanceSizes:
        engine.balanceSizes(in: workspaceId)
        return []

    case let .cycleSplitRatio(forward):
        engine.cycleSplitRatio(forward: forward, in: workspaceId)
        return []

    case let .moveSelectionToRoot(stable):
        engine.moveSelectionToRoot(stable: stable, in: workspaceId)
        return []

    case .swapSplit:
        engine.swapSplit(in: workspaceId)
        return []

    case let .setPreselection(direction):
        engine.setPreselection(direction, in: workspaceId)
        return []

    case .clearPreselection:
        engine.setPreselection(nil, in: workspaceId)
        return []

    case .validateSelection:
        _ = dwindleMutationNormalizeSelectionReference(engine: engine, workspaceId: workspaceId)
        return []
    }
}

private func randomFuzzOp(
    rng: inout DwindleMutationLCG,
    existingWindowIds: [UUID],
    nextNewId: inout UUID
) -> DwindleZigKernel.Op {
    let opChoice = rng.nextInt(0 ... 12)
    switch opChoice {
    case 0:
        let id = nextNewId
        nextNewId = dwindleFuzzUUID(&rng)
        return .addWindow(windowId: id)

    case 1:
        if !existingWindowIds.isEmpty {
            let idx = rng.nextInt(0 ... existingWindowIds.count - 1)
            return .removeWindow(windowId: existingWindowIds[idx])
        }
        return .removeWindow(windowId: dwindleFuzzUUID(&rng))

    case 2:
        var syncIds: [UUID] = []
        let existing = existingWindowIds
        if !existing.isEmpty {
            let keepCount = min(existing.count, rng.nextInt(0 ... max(0, existing.count)))
            if keepCount > 0 {
                var available = existing
                for _ in 0 ..< keepCount where !available.isEmpty {
                    let idx = rng.nextInt(0 ... available.count - 1)
                    syncIds.append(available.remove(at: idx))
                }
            }
        }
        let addCount = rng.nextInt(0 ... 2)
        for _ in 0 ..< addCount {
            syncIds.append(dwindleFuzzUUID(&rng))
        }
        if rng.nextBool(0.2), let duplicate = syncIds.first {
            syncIds.append(duplicate)
        }
        return .syncWindows(windowIds: syncIds)

    case 3:
        return .moveFocus(direction: dwindleFuzzDirection(&rng))

    case 4:
        return .swapWindows(direction: dwindleFuzzDirection(&rng))

    case 5:
        return .toggleFullscreen

    case 6:
        return .toggleOrientation

    case 7:
        return .resizeSelected(delta: rng.nextCGFloat(-0.25 ... 0.25), direction: dwindleFuzzDirection(&rng))

    case 8:
        return .balanceSizes

    case 9:
        return .cycleSplitRatio(forward: rng.nextBool())

    case 10:
        return .setPreselection(direction: dwindleFuzzDirection(&rng))

    case 11:
        return .clearPreselection

    default:
        return .validateSelection
    }
}

@Suite(.serialized) struct DwindleZigFuzzParityTests {
    @MainActor
    @Test func fuzzParityAcrossHundredSeedsAndOneHundredFiftyOps() {
        for seed in 0 ..< 100 {
            var rng = DwindleMutationLCG(seed: UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15)
            let engine = DwindleLayoutEngine(backend: .legacyDeterministic)

            engine.settings.defaultSplitRatio = 1.0
            engine.settings.smartSplit = true
            engine.settings.splitWidthMultiplier = 1.0
            engine.settings.singleWindowAspectRatio = CGSize(width: rng.nextCGFloat(3 ... 21), height: rng.nextCGFloat(2 ... 12))
            engine.settings.singleWindowAspectRatioTolerance = rng.nextCGFloat(0.01 ... 0.2)
            engine.settings.innerGap = rng.nextCGFloat(0 ... 24)
            engine.settings.outerGapTop = rng.nextCGFloat(0 ... 18)
            engine.settings.outerGapBottom = rng.nextCGFloat(0 ... 18)
            engine.settings.outerGapLeft = rng.nextCGFloat(0 ... 18)
            engine.settings.outerGapRight = rng.nextCGFloat(0 ... 18)

            let workspaceId = WorkspaceDescriptor.ID()
            let screen = CGRect(
                x: rng.nextCGFloat(-200 ... 200),
                y: rng.nextCGFloat(-120 ... 120),
                width: rng.nextCGFloat(900 ... 2800),
                height: rng.nextCGFloat(600 ... 1600)
            )

            var nextPid: pid_t = pid_t(300_000 + seed * 1000)
            var handlePool: [UUID: WindowHandle] = [:]

            let initialCount = rng.nextInt(1 ... 4)
            for _ in 0 ..< initialCount {
                let id = dwindleFuzzUUID(&rng)
                nextPid += 1
                let handle = dwindleMutationMakeHandle(id: id, pid: nextPid)
                handlePool[id] = handle
                _ = engine.addWindow(handle: handle, to: workspaceId, activeWindowFrame: nil)
                engine.updateWindowConstraints(
                    for: handle,
                    constraints: WindowSizeConstraints(
                        minSize: CGSize(width: rng.nextCGFloat(1 ... 180), height: rng.nextCGFloat(1 ... 180)),
                        maxSize: CGSize(width: 0, height: 0),
                        isFixed: false
                    )
                )
            }

            guard let context = DwindleZigKernel.LayoutContext() else {
                #expect(Bool(false))
                continue
            }
            let seedRC = dwindleMutationSeedContext(engine: engine, workspaceId: workspaceId, context: context)
            #expect(seedRC == 0)
            guard seedRC == 0 else { continue }

            dwindleMutationAssertLayoutAndNeighborParity(
                engine: engine,
                context: context,
                workspaceId: workspaceId,
                screen: screen
            )

            var nextSyntheticId = dwindleFuzzUUID(&rng)

            for _ in 0 ..< 150 {
                let existingIds = engine.root(for: workspaceId)?.collectAllWindows().map(\.id) ?? []
                let op = randomFuzzOp(rng: &rng, existingWindowIds: existingIds, nextNewId: &nextSyntheticId)

                let expectedRemoved = applyReferenceFuzzOp(
                    op,
                    engine: engine,
                    workspaceId: workspaceId,
                    handlePool: &handlePool,
                    nextPid: &nextPid
                )

                let zigResult = DwindleZigKernel.applyOp(
                    context: context,
                    op: op,
                    runtimeSettings: engine.settings
                )
                #expect(zigResult.rc == 0)
                guard zigResult.rc == 0 else { continue }

                if case .removeWindow = op {
                    #expect(zigResult.removedWindowIds == expectedRemoved)
                }
                if case .syncWindows = op {
                    #expect(zigResult.removedWindowIds == expectedRemoved)
                }

                _ = dwindleMutationNormalizeSelectionReference(engine: engine, workspaceId: workspaceId)
                let normalized = DwindleZigKernel.applyOp(
                    context: context,
                    op: .validateSelection,
                    runtimeSettings: engine.settings
                )
                #expect(normalized.rc == 0)
                let expectedSelected = dwindleMutationSelectedWindowId(engine: engine, workspaceId: workspaceId)
                #expect(normalized.selectedWindowId == expectedSelected)
                #expect(normalized.focusedWindowId == expectedSelected)
                #expect(normalized.preselection == engine.getPreselection(in: workspaceId))

                dwindleMutationAssertLayoutAndNeighborParity(
                    engine: engine,
                    context: context,
                    workspaceId: workspaceId,
                    screen: screen
                )
            }
        }
    }
}
