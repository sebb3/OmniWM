import AppKit
import Foundation

@MainActor
final class AXEventHandler: CGSEventDelegate {
    struct DebugCounters {
        var geometryRelayoutRequests = 0
        var geometryRelayoutsSuppressedDuringGesture = 0
    }

    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var windowTypeProvider: ((AXWindowRef, pid_t) -> AXWindowType)?
    var frameProvider: ((AXWindowRef) -> CGRect?)?
    private(set) var debugCounters = DebugCounters()

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, _):
            handleCGSWindowCreated(windowId: windowId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid)

        case .titleChanged:
            controller.updateWorkspaceBar()
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        guard let controller else { return }

        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }

        guard let token = resolveWindowToken(windowId) else {
            return
        }

        if controller.workspaceManager.entry(for: token) != nil {
            return
        }

        let pid = token.pid
        subscribeToWindows([windowId])

        if let axRef = resolveAXWindowRef(windowId: windowId, pid: pid) {
            handleCreated(ref: axRef, pid: pid, winId: Int(windowId))
        }
    }

    func resetDebugStateForTests() {
        debugCounters = .init()
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard let token = resolveTrackedToken(windowId) else { return }

        updateFocusedBorderForFrameChange(token: token)

        guard isWindowDisplayable(token: token) else {
            return
        }

        if controller.isInteractiveGestureActive {
            debugCounters.geometryRelayoutsSuppressedDuringGesture += 1
            return
        }

        debugCounters.geometryRelayoutRequests += 1
        controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
    }

    private func updateFocusedBorderForFrameChange(token: WindowToken) {
        guard let controller else { return }
        guard controller.workspaceManager.focusedToken == token,
              let entry = controller.workspaceManager.entry(for: token)
        else { return }

        if let frame = frameProvider?(entry.axRef) ?? (try? AXWindowService.frame(entry.axRef)) {
            controller.borderCoordinator.updateBorderIfAllowed(token: token, frame: frame, windowId: entry.windowId)
        }
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        guard let controller else { return }
        removeDeferredCreatedWindow(windowId)
        guard let token = resolveTrackedToken(windowId),
              controller.workspaceManager.entry(for: token) != nil else {
            return
        }

        handleRemoved(token: token)
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows() async {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            guard let token = resolveWindowToken(windowId) else {
                continue
            }
            if controller.workspaceManager.entry(for: token) != nil {
                continue
            }
            let pid = token.pid
            guard let axRef = resolveAXWindowRef(windowId: windowId, pid: pid) else {
                continue
            }
            handleCreated(ref: axRef, pid: pid, winId: Int(windowId))
        }
    }

    private func handleCreated(ref: AXWindowRef, pid: pid_t, winId: Int) {
        guard let controller else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appPolicy = app?.activationPolicy
        let windowType = windowTypeProvider?(ref, pid)
            ?? AXWindowService.windowType(ref, appPolicy: appPolicy, bundleId: bundleId)
        guard windowType == .tiling else { return }

        if let bundleId, controller.appRulesByBundleId[bundleId]?.alwaysFloat == true {
            return
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            axRef: ref,
            pid: pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        if workspaceId != controller.activeWorkspace()?.id {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId),
               controller.workspaceManager.workspaces(on: monitor.id)
               .contains(where: { $0.id == workspaceId })
            {
                _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
            }
        }

        _ = controller.workspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)
        subscribeToWindows([UInt32(winId)])
        controller.updateWorkspaceBar()

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        handleRemoved(token: .init(pid: pid, windowId: winId))
    }

    func handleRemoved(token: WindowToken) {
        guard let controller else { return }
        let entry = controller.workspaceManager.entry(for: token)
        let affectedWorkspaceId = entry?.workspaceId
        let removedHandle = entry?.handle
        let shouldRecoverFocus = token == controller.workspaceManager.focusedToken
        let layoutType = affectedWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout

        if let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId,
           layoutType != .dwindle
        {
           let shouldAnimate = if let engine = controller.niriEngine,
                                    let windowNode = engine.findNode(for: token)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        if let removed = removedHandle {
            controller.focusCoordinator.discardPendingFocus(removed.id)
        }

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            removedNodeId = engine.findNode(for: token)?.id
        }

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus
            )
        }
    }

    func handleAppActivation(pid: pid_t) {
        guard let controller else { return }
        guard controller.hasStartedServices else { return }
        let focusedWindow = resolveFocusedWindowValue(pid: pid)

        guard let windowElement = focusedWindow else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }

        guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }

        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        guard let axRef = try? AXWindowRef(element: axElement) else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }
        let winId = axRef.windowId

        let appFullscreen = AXWindowService.isFullscreen(axRef)

        if let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId) {
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen
            )
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
        controller.borderManager.hideBorder()
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool
    ) {
        guard let controller else { return }
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow

        _ = controller.workspaceManager.confirmManagedFocus(
            entry.token,
            in: wsId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: shouldActivateWorkspace
        )

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            var state = controller.workspaceManager.niriViewportState(for: wsId)
            controller.niriLayoutHandler.activateNode(
                node, in: wsId, state: &state,
                options: .init(layoutRefresh: isWorkspaceActive, axFocus: false)
            )
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil
                )
            )

            if let frame = node.frame {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        } else if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
        }
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if shouldActivateWorkspace {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.token)
            }
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    private func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    private func resolveTrackedToken(_ windowId: UInt32) -> WindowToken? {
        if let token = resolveWindowToken(windowId) {
            return token
        }
        guard let controller else { return nil }
        let matches = controller.workspaceManager.allEntries().filter { $0.windowId == Int(windowId) }
        guard matches.count == 1 else { return nil }
        return matches[0].token
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        if let focusedWindowValueProvider {
            return focusedWindowValueProvider(pid)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }
}
