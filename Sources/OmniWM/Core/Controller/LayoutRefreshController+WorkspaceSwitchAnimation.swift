// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import QuartzCore
import ScreenCaptureKit

/// A vertical slide when switching workspaces, mirroring niri's own
/// `workspace-switch` animation: workspaces are a vertical stack per monitor,
/// and switching between them slides the viewport, the same way horizontal
/// column scrolling already animates within one workspace.
///
/// Mechanism — yabai's proxy-window animation, the only one that survives the
/// evidence. Every alternative was tried live and eliminated:
/// - Cross-process `SLSTransactionMoveWindowWithGroup` on foreign windows is a
///   connection-local no-op: it reads back through this process's connection
///   and never renders (the same trap `SLSSetWindowLevel` proved for window
///   levels). The park/reveal system's physical effect comes from its AX
///   writes, not its SLS writes.
/// - Per-tick AX writes are physical but macOS clamps AX positioning at the
///   menu bar (a from-above entry stops ~30pt in), and they interleave with
///   the engine's own AX writes mid-flight.
/// So: capture both workspaces' full window images through ScreenCaptureKit's
/// desktop-independent window filter, hide the real windows behind proxies via the scripting addition
/// (`swapProxiesIn`, privileged system-alpha + group ordering inside Dock),
/// and slide the *OmniWM-owned* proxy with `SLSTransactionSetWindowTransform`
/// — own-window presentation transforms are real, unclamped, and
/// GPU-composited. On completion the proxy is swapped out and destroyed; the
/// real window has been sitting at its authoritative final frame all along.
///
/// Degrades to today's instant switch when the scripting addition or the
/// capture/transform symbols are unavailable.
@MainActor
final class WorkspaceSwitchProxyResource {
    let windowId: UInt32
    private var context: CGContext?
    private var image: CGImage?
    private var destroyed = false

    init(windowId: UInt32, context: CGContext, image: CGImage) {
        self.windowId = windowId
        self.context = context
        self.image = image
    }

    func destroy(using connection: SkyLight.AnimationConnection) {
        guard !destroyed else { return }
        destroyed = true
        context = nil
        image = nil
        connection.releaseWindow(windowId)
    }
}

struct WorkspaceSwitchTransition {
    struct Member {
        let entry: WindowState
        /// The window's authoritative frame (AppKit coordinates): its resting
        /// point for incoming windows, or its pre-switch position when outgoing.
        let baseFrame: CGRect
        let isIncoming: Bool
    }

    struct Proxy {
        let realWindowId: UInt32
        let proxyWindowId: UInt32
        let baseFrame: CGRect
        let isIncoming: Bool
        let resource: WorkspaceSwitchProxyResource?

        init(
            realWindowId: UInt32,
            proxyWindowId: UInt32,
            baseFrame: CGRect,
            isIncoming: Bool,
            resource: WorkspaceSwitchProxyResource? = nil
        ) {
            self.realWindowId = realWindowId
            self.proxyWindowId = proxyWindowId
            self.baseFrame = baseFrame
            self.isIncoming = isIncoming
            self.resource = resource
        }
    }

    let monitorId: Monitor.ID
    let targetWorkspaceId: WorkspaceDescriptor.ID
    /// Drives a 0→1 progress value. `value(at:)` returns exactly `target` once
    /// complete, so the proxy's final presentation matches the real window's
    /// frame exactly before the swap back.
    let spring: SpringAnimation
    /// Signed vertical start offset in AppKit (Y-up) coordinates: incoming
    /// content begins `travel` points from its resting frame and converges to
    /// zero offset. Next (down the stack) = enters from below = negative.
    let travel: CGFloat
    let proxies: [Proxy]
    let connection: SkyLight.AnimationConnection?

    init(
        monitorId: Monitor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        spring: SpringAnimation,
        travel: CGFloat,
        proxies: [Proxy],
        connection: SkyLight.AnimationConnection? = nil
    ) {
        self.monitorId = monitorId
        self.targetWorkspaceId = targetWorkspaceId
        self.spring = spring
        self.travel = travel
        self.proxies = proxies
        self.connection = connection
    }

    var swapPairs: [(windowId: UInt32, proxyId: UInt32)] {
        proxies.map { (windowId: $0.realWindowId, proxyId: $0.proxyWindowId) }
    }

    /// AppKit-space frame for a proxy at `progress`.
    func frame(for proxy: Proxy, progress: CGFloat) -> CGRect {
        let dy = proxy.isIncoming ? travel * (1 - progress) : -travel * progress
        return proxy.baseFrame.offsetBy(dx: 0, dy: dy)
    }
}

/// What the background capture pass needs to know about one window.
struct WorkspaceSwitchCaptureRequest: Sendable {
    let windowId: UInt32
    let baseFrame: CGRect
    let isIncoming: Bool
}

struct WorkspaceSwitchCaptureItem: @unchecked Sendable {
    let index: Int
    let request: WorkspaceSwitchCaptureRequest
    let window: SCWindow
}

/// `CGImage` is immutable; the annotation just carries it back across the
/// background-capture boundary.
struct WorkspaceSwitchCaptureResult: @unchecked Sendable {
    let request: WorkspaceSwitchCaptureRequest
    let image: CGImage?
}

struct WorkspaceSwitchPreparation {
    let connection: SkyLight.AnimationConnection
    let results: [WorkspaceSwitchCaptureResult]
}

/// Proxies already swapped in before the virtual-workspace mutation. Outgoing
/// proxies cover the currently visible windows; incoming proxies are parked
/// vertically off-screen until post-layout supplies their final on-screen frames.
struct WorkspaceSwitchStagedTransition {
    let monitorId: Monitor.ID
    let targetWorkspaceId: WorkspaceDescriptor.ID
    let direction: CGFloat
    let proxies: [WorkspaceSwitchTransition.Proxy]
    let connection: SkyLight.AnimationConnection?

    init(
        monitorId: Monitor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        direction: CGFloat,
        proxies: [WorkspaceSwitchTransition.Proxy],
        connection: SkyLight.AnimationConnection? = nil
    ) {
        self.monitorId = monitorId
        self.targetWorkspaceId = targetWorkspaceId
        self.direction = direction
        self.proxies = proxies
        self.connection = connection
    }

    var swapPairs: [(windowId: UInt32, proxyId: UInt32)] {
        proxies.map { (windowId: $0.realWindowId, proxyId: $0.proxyWindowId) }
    }
}

@MainActor
extension LayoutRefreshController {
    /// Matches niri's own `workspace-switch` config shape so a future
    /// settings.toml entry can map onto it directly. Duration-based so the
    /// wall-clock feel is explicit rather than an emergent property of
    /// stiffness against a 0→1 progress domain.
    static let workspaceSwitchSpringConfig = SpringConfig(duration: 0.3, bounce: 0.0, epsilon: 0.001)

    /// Captures both virtual workspaces before membership visibility changes.
    /// Desktop-independent filters return complete images for windows that
    /// OmniWM has physically parked beyond the visible edge.
    func prepareWorkspaceSwitchTransition(
        monitor: Monitor,
        members: [WorkspaceSwitchTransition.Member]
    ) async -> WorkspaceSwitchPreparation? {
        guard controller?.motionPolicy.animationsEnabled != false else { return nil }
        guard !members.isEmpty else { return nil }
        guard SkyLight.shared.supportsProxyAnimation else { return nil }

        // Serialize transitions per display. A new request snaps the previous
        // proxy row to its authoritative endpoint before capturing the next one.
        if let existing = layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: monitor.displayId) {
            applyTransitionTransforms(existing, progress: 1)
            finalizeWorkspaceSwitchTransition(existing, displayId: monitor.displayId)
            stopDisplayLinkIfIdle(for: monitor.displayId)
        }

        guard let connection = SkyLight.shared.makeAnimationConnection() else { return nil }
        guard connection.disableUpdates() else {
            connection.close()
            return nil
        }

        let requests = members.compactMap { member -> WorkspaceSwitchCaptureRequest? in
            guard let realWid = UInt32(exactly: member.entry.token.windowId) else { return nil }
            return WorkspaceSwitchCaptureRequest(
                windowId: realWid,
                baseFrame: member.baseFrame,
                isIncoming: member.isIncoming
            )
        }
        guard requests.count == members.count else {
            connection.close()
            return nil
        }

        let results = await Self.captureImages(requests: requests)
        guard results.allSatisfy({ $0.image != nil }) else {
            connection.close()
            return nil
        }
        return WorkspaceSwitchPreparation(connection: connection, results: results)
    }

    private static func captureImages(
        requests: [WorkspaceSwitchCaptureRequest]
    ) async -> [WorkspaceSwitchCaptureResult] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let windowMap = Dictionary(
                uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
            )
            let items = requests.enumerated().compactMap { index, request -> WorkspaceSwitchCaptureItem? in
                guard let window = windowMap[CGWindowID(request.windowId)] else { return nil }
                return WorkspaceSwitchCaptureItem(index: index, request: request, window: window)
            }
            guard items.count == requests.count else { return [] }

            var indexedResults: [(Int, WorkspaceSwitchCaptureResult)] = []
            await withTaskGroup(of: (Int, WorkspaceSwitchCaptureResult).self) { group in
                var nextIndex = 0
                func addNextCapture() {
                    guard nextIndex < items.count else { return }
                    let item = items[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let image = await captureDesktopIndependentWindow(item)
                        return (
                            item.index,
                            WorkspaceSwitchCaptureResult(request: item.request, image: image)
                        )
                    }
                }

                for _ in 0 ..< min(4, items.count) {
                    addNextCapture()
                }
                while let result = await group.next() {
                    indexedResults.append(result)
                    addNextCapture()
                }
            }
            let results = indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
            return results
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "workspaceSwitchCaptureException")
            return []
        }
    }

    private nonisolated static func captureDesktopIndependentWindow(
        _ item: WorkspaceSwitchCaptureItem
    ) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: item.window)
        let scale = max(CGFloat(1), CGFloat(filter.pointPixelScale))
        let width = max(item.request.baseFrame.width, item.window.frame.width)
        let height = max(item.request.baseFrame.height, item.window.frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((width * scale).rounded()))
        config.height = max(1, Int((height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// Creates and swaps in every proxy while the source workspace is still
    /// active. The real source and target windows are now hidden before the
    /// normal virtual-workspace visibility mutation runs underneath them.
    func stageWorkspaceSwitchTransition(
        monitor: Monitor,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        direction: CGFloat,
        preparation: WorkspaceSwitchPreparation
    ) -> WorkspaceSwitchStagedTransition? {
        let connection = preparation.connection
        let results = preparation.results
        guard !results.isEmpty else {
            connection.close()
            return nil
        }

        var proxies: [WorkspaceSwitchTransition.Proxy] = []
        proxies.reserveCapacity(results.count)
        for result in results {
            let realWid = result.request.windowId
            guard let image = result.image,
                  let resource = makeProxyWindow(
                      connection: connection,
                      realWindowId: realWid,
                      baseFrame: result.request.baseFrame,
                      image: image
                  )
            else {
                releaseProxyWindows(proxies, connection: connection)
                connection.close()
                return nil
            }
            proxies.append(
                WorkspaceSwitchTransition.Proxy(
                    realWindowId: realWid,
                    proxyWindowId: resource.windowId,
                    baseFrame: result.request.baseFrame,
                    isIncoming: result.request.isIncoming,
                    resource: resource
                )
            )
        }

        let staged = WorkspaceSwitchStagedTransition(
            monitorId: monitor.id,
            targetWorkspaceId: targetWorkspaceId,
            direction: direction,
            proxies: proxies,
            connection: connection
        )

        // Outgoing proxies cover the still-visible source windows exactly.
        // Incoming proxies are explicitly outside the monitor; their current
        // horizontal park geometry is irrelevant and never becomes visible.
        for proxy in proxies {
            let frame: CGRect
            if proxy.isIncoming {
                let y = direction > 0
                    ? monitor.frame.minY - proxy.baseFrame.height - 40
                    : monitor.frame.maxY + 40
                frame = CGRect(
                    x: monitor.frame.minX,
                    y: y,
                    width: proxy.baseFrame.width,
                    height: proxy.baseFrame.height
                )
            } else {
                frame = proxy.baseFrame
            }
            let origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
            connection.setWindowTransform(proxy.proxyWindowId, presentingAt: origin)
        }

        // Proxy content can be published safely while the windows remain
        // ordered out. The SA then makes proxies visible and hides real windows
        // in one Dock transaction, avoiding a blank frame between connections.
        guard connection.reenableUpdates(), ScriptingAddition.swapProxiesIn(staged.swapPairs) else {
            _ = ScriptingAddition.swapProxiesOut(staged.swapPairs)
            releaseProxyWindows(proxies, connection: connection)
            connection.close()
            return nil
        }
        return staged
    }

    /// Starts one spring after the real visibility mutation has completed under
    /// the staged proxies. Only incoming origins are replaced: outgoing proxies
    /// retain their pre-switch physical frames.
    func startWorkspaceSwitchTransition(
        monitor: Monitor,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        staged: WorkspaceSwitchStagedTransition,
        incomingMembers: [WorkspaceSwitchTransition.Member]
    ) {
        guard let controller,
              let connection = staged.connection,
              staged.monitorId == monitor.id,
              staged.targetWorkspaceId == targetWorkspaceId,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == targetWorkspaceId,
              let displayLink = getOrCreateDisplayLink(for: monitor.displayId)
        else {
            cancelStagedWorkspaceSwitchTransition(staged)
            return
        }

        let incomingFrames = Dictionary(
            uniqueKeysWithValues: incomingMembers.compactMap { member -> (UInt32, CGRect)? in
                guard let wid = UInt32(exactly: member.entry.windowId) else { return nil }
                return (wid, member.baseFrame)
            }
        )
        guard staged.proxies.filter(\.isIncoming).allSatisfy({ incomingFrames[$0.realWindowId] != nil }) else {
            cancelStagedWorkspaceSwitchTransition(staged)
            return
        }

        let proxies = staged.proxies.map { proxy in
            guard proxy.isIncoming, let finalFrame = incomingFrames[proxy.realWindowId] else { return proxy }
            return WorkspaceSwitchTransition.Proxy(
                realWindowId: proxy.realWindowId,
                proxyWindowId: proxy.proxyWindowId,
                baseFrame: finalFrame,
                isIncoming: true,
                resource: proxy.resource
            )
        }
        let travel = -staged.direction * (monitor.frame.height + 40)
        let transition = WorkspaceSwitchTransition(
            monitorId: monitor.id,
            targetWorkspaceId: targetWorkspaceId,
            spring: SpringAnimation(
                from: 0,
                to: 1,
                startTime: CACurrentMediaTime(),
                config: Self.workspaceSwitchSpringConfig,
                displayRefreshRate: layoutState.refreshRateByDisplay[monitor.displayId] ?? 60
            ),
            travel: travel,
            proxies: proxies,
            connection: connection
        )

        applyTransitionTransforms(transition, progress: 0)
        layoutState.workspaceSwitchTransitionsByDisplay[monitor.displayId] = transition
        displayLink.add(to: .main, forMode: .common)
    }

    func cancelStagedWorkspaceSwitchTransition(_ staged: WorkspaceSwitchStagedTransition) {
        if let connection = staged.connection {
            _ = connection.disableUpdates()
            _ = ScriptingAddition.swapProxiesOut(staged.swapPairs)
            releaseProxyWindows(staged.proxies, connection: connection)
            _ = connection.reenableUpdates()
            connection.close()
        } else {
            _ = ScriptingAddition.swapProxiesOut(staged.swapPairs)
        }
    }

    var workspaceSwitchTransitionsByDisplay: [CGDirectDisplayID: WorkspaceSwitchTransition] {
        get { layoutState.workspaceSwitchTransitionsByDisplay }
        set { layoutState.workspaceSwitchTransitionsByDisplay = newValue }
    }

    func tickWorkspaceSwitchTransition(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let transition = layoutState.workspaceSwitchTransitionsByDisplay[displayId] else { return }
        guard let controller else {
            layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: displayId)
            finalizeWorkspaceSwitchTransition(transition, displayId: displayId)
            return
        }

        // If the active workspace moved on again mid-flight, a newer
        // authoritative path owns these windows — restore them immediately.
        guard controller.workspaceManager.activeWorkspaceOrFirst(on: transition.monitorId)?.id
            == transition.targetWorkspaceId
        else {
            layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: displayId)
            finalizeWorkspaceSwitchTransition(transition, displayId: displayId)
            stopDisplayLinkIfIdle(for: displayId)
            return
        }

        let progress = CGFloat(transition.spring.value(at: targetTime))
        if transition.spring.isComplete(at: targetTime) {
            applyTransitionTransforms(transition, progress: 1)
            layoutState.workspaceSwitchTransitionsByDisplay.removeValue(forKey: displayId)
            finalizeWorkspaceSwitchTransition(transition, displayId: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            applyTransitionTransforms(transition, progress: progress)
        }
    }

    /// Restores every real window (system alpha 1, proxy ungrouped) and
    /// destroys the proxies. Idempotent enough for the abort paths: a failed
    /// swap-out still destroys the proxies, and the real windows' alpha is
    /// Dock-side state the next successful send repairs.
    private func finalizeWorkspaceSwitchTransition(
        _ transition: WorkspaceSwitchTransition,
        displayId _: CGDirectDisplayID
    ) {
        guard let connection = transition.connection else {
            _ = ScriptingAddition.swapProxiesOut(transition.swapPairs)
            return
        }
        _ = connection.disableUpdates()
        _ = ScriptingAddition.swapProxiesOut(transition.swapPairs)
        releaseProxyWindows(transition.proxies, connection: connection)
        _ = connection.reenableUpdates()
        connection.close()
    }

    private func releaseProxyWindows(
        _ proxies: [WorkspaceSwitchTransition.Proxy],
        connection: SkyLight.AnimationConnection
    ) {
        for proxy in proxies {
            proxy.resource?.destroy(using: connection)
        }
    }

    private func applyTransitionTransforms(_ transition: WorkspaceSwitchTransition, progress: CGFloat) {
        guard let connection = transition.connection else { return }
        for proxy in transition.proxies {
            let appKitFrame = transition.frame(for: proxy, progress: progress)
            let origin = ScreenCoordinateSpace.toWindowServer(rect: appKitFrame).origin
            connection.setWindowTransform(proxy.proxyWindowId, presentingAt: origin)
        }
    }

    /// An OmniWM-owned window showing a static capture of the real window,
    /// created ordered-out — `swapProxiesIn` is what orders it in, grouped
    /// above its (hidden) real window.
    private func makeProxyWindow(
        connection: SkyLight.AnimationConnection,
        realWindowId: UInt32,
        baseFrame: CGRect,
        image: CGImage
    ) -> WorkspaceSwitchProxyResource? {
        let serverFrame = ScreenCoordinateSpace.toWindowServer(rect: baseFrame)
        let wid = connection.createImageProxyWindow(frame: serverFrame)
        guard wid != 0 else { return nil }
        _ = connection.configureWindow(wid, resolution: 2.0, opaque: false)
        _ = connection.disableWindowShadow(wid)
        _ = connection.setWindowAlpha(wid, alpha: 1)
        if let level = SkyLight.shared.windowLevel(realWindowId) {
            _ = connection.setWindowLevel(wid, level: level)
        }
        if let subLevel = SkyLight.shared.windowSubLevel(realWindowId) {
            _ = connection.setWindowSubLevel(wid, subLevel: subLevel)
        }
        guard let context = connection.createWindowContext(for: wid) else {
            connection.releaseWindow(wid)
            return nil
        }
        let bounds = CGRect(origin: .zero, size: serverFrame.size)
        context.interpolationQuality = .high
        context.clear(bounds)
        context.draw(image, in: bounds)
        context.flush()
        return WorkspaceSwitchProxyResource(windowId: wid, context: context, image: image)
    }
}
