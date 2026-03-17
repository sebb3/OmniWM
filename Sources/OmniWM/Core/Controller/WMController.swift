import AppKit
import Foundation

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void

    static let live = WindowFocusOperations(
        activateApp: { pid in
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: [])
            }
        },
        focusSpecificWindow: { pid, windowId, element in
            OmniWM.focusWindow(pid: pid, windowId: windowId, windowRef: element)
        },
        raiseWindow: { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    )
}

@MainActor @Observable
final class WMController {
    struct WorkspaceBarRefreshDebugState {
        var requestCount: Int = 0
        var scheduledCount: Int = 0
        var executionCount: Int = 0
        var isQueued: Bool = false
    }

    struct WindowDecisionEvaluation {
        let token: WindowToken
        let facts: WindowRuleFacts
        let decision: WindowDecision
        let appFullscreen: Bool
        let manualOverride: ManualWindowOverride?
    }

    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false
    let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    let focusCoordinator: FocusOperationCoordinator
    let windowRuleEngine = WindowRuleEngine()

    var niriEngine: NiriLayoutEngine?
    var dwindleEngine: DwindleLayoutEngine?

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()
    @ObservationIgnored
    private var workspaceBarRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var pendingWorkspaceBarRefreshGeneration: UInt64?
    @ObservationIgnored
    private let hiddenBarController: HiddenBarController
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(settings: settings)

    var isTransferringWindow: Bool = false
    var hiddenAppPIDs: Set<pid_t> = []

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var commandHandler = CommandHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var layoutRefreshController = LayoutRefreshController(controller: self)
    var niriLayoutHandler: NiriLayoutHandler { layoutRefreshController.niriHandler }
    var dwindleLayoutHandler: DwindleLayoutHandler { layoutRefreshController.dwindleHandler }
    @ObservationIgnored
    private(set) lazy var serviceLifecycleManager = ServiceLifecycleManager(controller: self)
    @ObservationIgnored
    private(set) lazy var windowActionHandler = WindowActionHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var focusNotificationDispatcher = FocusNotificationDispatcher(controller: self)
    @ObservationIgnored
    private(set) lazy var borderCoordinator = BorderCoordinator(controller: self)
    var hasStartedServices = false
    @ObservationIgnored
    private(set) var isMouseWarpPolicyEnabled = false
    @ObservationIgnored
    private let ownedWindowRegistry = OwnedWindowRegistry.shared
    @ObservationIgnored
    private(set) var workspaceBarRefreshDebugState = WorkspaceBarRefreshDebugState()
    @ObservationIgnored
    var workspaceBarRefreshExecutionHookForTests: (() -> Void)?

    let animationClock = AnimationClock()
    private let windowFocusOperations: WindowFocusOperations

    init(
        settings: SettingsStore,
        hiddenBarController: HiddenBarController? = nil,
        windowFocusOperations: WindowFocusOperations = .live
    ) {
        self.settings = settings
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.windowFocusOperations = windowFocusOperations
        workspaceManager = WorkspaceManager(settings: settings)
        focusCoordinator = FocusOperationCoordinator()
        workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler.handleCommand(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, index in
            self?.layoutRefreshController.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
        }
        workspaceManager.onSessionStateChanged = { [weak self] in
            self?.focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore) {
        settings.appearanceMode.apply()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gapSize)
        setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )

        if niriEngine == nil {
            enableNiriLayout(
                maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
            maxVisibleColumns: settings.niriMaxVisibleColumns,
            infiniteLoop: settings.niriInfiniteLoop,
            centerFocusedColumn: settings.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: settings.niriSingleWindowAspectRatio,
            columnWidthPresets: settings.niriColumnWidthPresets,
            defaultColumnWidth: settings.niriDefaultColumnWidth
        )

        if dwindleEngine == nil {
            enableDwindleLayout()
        }
        updateDwindleConfig(
            smartSplit: settings.dwindleSmartSplit,
            defaultSplitRatio: settings.dwindleDefaultSplitRatio,
            splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
            singleWindowAspectRatio: settings.dwindleSingleWindowAspectRatio.size
        )

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateMonitorDwindleSettings()
        updateAppRules()

        setBordersEnabled(settings.bordersEnabled)
        updateBorderConfig(BorderConfig.from(settings: settings))

        setFocusFollowsMouse(settings.focusFollowsMouse)
        setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        setPreventSleepEnabled(settings.preventSleepEnabled)
        setQuakeTerminalEnabled(settings.quakeTerminalEnabled)

        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            serviceLifecycleManager.start()
        } else {
            serviceLifecycleManager.stop()
        }
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        enabled ? hotkeys.start() : hotkeys.stop()
    }

    func setGapSize(_ size: Double) {
        workspaceManager.setGaps(to: size)
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
    }

    func setBordersEnabled(_ enabled: Bool) {
        borderManager.setEnabled(enabled)
    }

    func updateBorderConfig(_ config: BorderConfig) {
        borderManager.updateConfig(config)
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.setup(controller: self, settings: settings)
    }

    func cleanupUIOnStop() {
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.cleanup()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func toggleHiddenBar() {
        hiddenBarController.toggle()
    }

    func setQuakeTerminalEnabled(_ enabled: Bool) {
        if enabled {
            quakeTerminalController.setup()
        } else {
            quakeTerminalController.cleanup()
        }
    }

    func toggleQuakeTerminal() {
        guard settings.quakeTerminalEnabled else { return }
        quakeTerminalController.toggle()
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func requestWorkspaceBarRefresh() {
        workspaceBarRefreshDebugState.requestCount += 1

        guard workspaceBarRefreshIsEnabled else { return }
        guard pendingWorkspaceBarRefreshGeneration == nil else { return }

        let generation = workspaceBarRefreshGeneration
        pendingWorkspaceBarRefreshGeneration = generation
        workspaceBarRefreshDebugState.scheduledCount += 1
        workspaceBarRefreshDebugState.isQueued = true

        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushRequestedWorkspaceBarRefresh(expectedGeneration: generation)
            }
        }
    }

    func isManagedWindowDisplayable(_ handle: WindowHandle) -> Bool {
        guard workspaceManager.entry(for: handle) != nil else { return false }
        if hiddenAppPIDs.contains(handle.pid) {
            return false
        }
        if workspaceManager.layoutReason(for: handle.id) != .standard {
            return false
        }
        return !workspaceManager.isHiddenInCorner(handle.id)
    }

    func isManagedWindowSuspendedForNativeFullscreen(_ token: WindowToken) -> Bool {
        workspaceManager.isNativeFullscreenSuspended(token)
    }

    func updateWorkspaceBarSettings() {
        workspaceBarManager.updateSettings()
    }

    func updateMonitorOrientations() {
        let monitors = workspaceManager.monitors
        for monitor in monitors {
            let orientation = settings.effectiveOrientation(for: monitor)
            niriEngine?.monitors[monitor.id]?.updateOrientation(orientation)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        guard let engine = niriEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedNiriSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorDwindleSettings() {
        guard let engine = dwindleEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedDwindleSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func workspaceBarItems(for monitor: Monitor, deduplicate: Bool, hideEmpty: Bool) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: deduplicate,
            hideEmpty: hideEmpty,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: workspaceManager.focusedToken,
            settings: settings
        )
    }

    func focusWorkspaceFromBar(named name: String) {
        windowActionHandler.focusWorkspaceFromBar(named: name)
    }

    func focusWindowFromBar(token: WindowToken) {
        windowActionHandler.focusWindowFromBar(token: token)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    @discardableResult
    func syncMouseWarpPolicy(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        let shouldEnable = shouldUseMouseWarp(for: effectiveMonitors)

        if shouldEnable {
            _ = settings.persistEffectiveMouseWarpMonitorOrder(for: effectiveMonitors)
        }

        guard shouldEnable != isMouseWarpPolicyEnabled else {
            return shouldEnable
        }

        if shouldEnable {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
        }

        isMouseWarpPolicyEnabled = shouldEnable
        return shouldEnable
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        return insetWorkingFrame(from: monitor.visibleFrame, scale: scale)
    }

    func insetWorkingFrame(from frame: CGRect, scale: CGFloat = 2.0) -> CGRect {
        let outer = workspaceManager.outerGaps
        let struts = Struts(
            left: outer.left,
            right: outer.right,
            top: outer.top,
            bottom: outer.bottom
        )
        return computeWorkingArea(
            parentArea: frame,
            scale: scale,
            struts: struts
        )
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding]) {
        hotkeys.updateBindings(bindings)
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestFullRescan(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController.requestFullRescan(reason: .appRulesChanged)
    }

    var hotkeyRegistrationFailures: Set<HotkeyCommand> {
        hotkeys.registrationFailures
    }

    private var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBarEnabled || settings.monitorBarSettings.contains(where: { $0.enabled == true })
    }

    private func flushRequestedWorkspaceBarRefresh(expectedGeneration: UInt64) {
        guard pendingWorkspaceBarRefreshGeneration == expectedGeneration,
              workspaceBarRefreshGeneration == expectedGeneration
        else {
            return
        }

        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshDebugState.isQueued = false

        guard workspaceBarRefreshIsEnabled else { return }

        workspaceBarRefreshDebugState.executionCount += 1
        workspaceBarRefreshExecutionHookForTests?()
        workspaceBarManager.update()
    }

    private func cancelPendingWorkspaceBarRefresh() {
        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshGeneration &+= 1
        workspaceBarRefreshDebugState.isQueued = false
    }

    func waitForWorkspaceBarRefreshForTests() async {
        for _ in 0..<100 {
            await Task.yield()
            if !workspaceBarRefreshDebugState.isQueued {
                break
            }
        }
        await Task.yield()
    }

    func resetWorkspaceBarRefreshDebugStateForTests() {
        cancelPendingWorkspaceBarRefresh()
        workspaceBarRefreshDebugState = .init()
        workspaceBarRefreshExecutionHookForTests = nil
    }

    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        niriLayoutHandler.enableNiriLayout(
            maxWindowsPerColumn: maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }

    func syncMonitorsToNiriEngine() {
        niriLayoutHandler.syncMonitorsToNiriEngine()
    }

    func updateNiriConfig(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            columnWidthPresets: columnWidthPresets,
            defaultColumnWidth: defaultColumnWidth
        )
    }

    func enableDwindleLayout() {
        dwindleLayoutHandler.enableDwindleLayout()
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowAspectRatio: CGSize? = nil,
        innerGap: CGFloat? = nil,
        outerGapTop: CGFloat? = nil,
        outerGapBottom: CGFloat? = nil,
        outerGapLeft: CGFloat? = nil,
        outerGapRight: CGFloat? = nil
    ) {
        dwindleLayoutHandler.updateDwindleConfig(
            smartSplit: smartSplit,
            defaultSplitRatio: defaultSplitRatio,
            splitWidthMultiplier: splitWidthMultiplier,
            singleWindowAspectRatio: singleWindowAspectRatio,
            innerGap: innerGap,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight
        )
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.focusedToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func resolveWorkspaceForNewWindow(
        workspaceName: String? = nil,
        axRef: AXWindowRef,
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        if let wsName = workspaceName,
           let wsId = workspaceManager.workspaceId(for: wsName, createIfMissing: false)
        {
            return wsId
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return workspace.id
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            let center = frame.center
            if let monitor = center.monitorApproximation(in: workspaceManager.monitors),
               let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            {
                return workspace.id
            }
        }
        if let fallbackWorkspaceId {
            return fallbackWorkspaceId
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return workspaceId
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return createdWorkspaceId
        }
        fatalError("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func resolvedAppInfo(for pid: pid_t) -> AppInfoCache.AppInfo? {
        appInfoCache.info(for: pid) ?? NSRunningApplication(processIdentifier: pid).map {
            AppInfoCache.AppInfo(
                name: $0.localizedName,
                bundleId: $0.bundleIdentifier,
                icon: $0.icon,
                activationPolicy: $0.activationPolicy
            )
        }
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil
    ) -> WindowDecisionEvaluation {
        let appInfo = resolvedAppInfo(for: pid)
        let facts = axEventHandler.windowFactsProvider?(axRef, pid) ?? WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(for: appInfo?.bundleId)
            )
        )
        let fullscreen = appFullscreen ?? (axEventHandler.isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef))
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        let decision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: fullscreen
        )
        return WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: fullscreen,
            manualOverride: windowRuleEngine.manualOverride(for: token)
        )
    }

    func decideWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil
    ) -> WindowDecision {
        evaluateWindowDisposition(
            axRef: axRef,
            pid: pid,
            appFullscreen: appFullscreen
        ).decision
    }

    func makeWindowDecisionDebugSnapshot(
        from evaluation: WindowDecisionEvaluation
    ) -> WindowDecisionDebugSnapshot {
        WindowDecisionDebugSnapshot(
            token: evaluation.token,
            appName: evaluation.facts.appName,
            bundleId: evaluation.facts.ax.bundleId,
            title: evaluation.facts.ax.title,
            axRole: evaluation.facts.ax.role,
            axSubrole: evaluation.facts.ax.subrole,
            appFullscreen: evaluation.appFullscreen,
            manualOverride: evaluation.manualOverride,
            disposition: evaluation.decision.disposition,
            source: evaluation.decision.source,
            workspaceName: evaluation.decision.workspaceName,
            minWidth: evaluation.decision.ruleEffects.minWidth,
            minHeight: evaluation.decision.ruleEffects.minHeight,
            matchedRuleId: evaluation.decision.ruleEffects.matchedRuleId,
            heuristicReasons: evaluation.decision.heuristicReasons,
            attributeFetchSucceeded: evaluation.facts.ax.attributeFetchSucceeded
        )
    }

    func windowDecisionDebugSnapshot(for token: WindowToken) -> WindowDecisionDebugSnapshot? {
        let axRef = workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        guard let axRef else { return nil }
        let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        return makeWindowDecisionDebugSnapshot(from: evaluation)
    }

    func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
        let managedToken = workspaceManager.focusedToken
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let token = managedToken ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        guard let token else { return nil }
        return windowDecisionDebugSnapshot(for: token)
    }

    func copyDebugDump(_ snapshot: WindowDecisionDebugSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.formattedDump(), forType: .string)
    }

    func clearManualWindowOverride(for token: WindowToken) {
        windowRuleEngine.clearManualOverride(for: token)
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>
    ) async -> Bool {
        guard !targets.isEmpty else { return false }

        var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
        var tokensToReevaluate: Set<WindowToken> = []
        var pidTargets: Set<pid_t> = []

        for target in targets {
            switch target {
            case let .window(token):
                tokensToReevaluate.insert(token)
                if let axRef = resolveAXWindowRef(for: token) {
                    liveWindowsByToken[token] = axRef
                }
            case let .pid(pid):
                pidTargets.insert(pid)
            }
        }

        for pid in pidTargets {
            if let app = NSRunningApplication(processIdentifier: pid) {
                let windows = await axManager.windowsForApp(app)
                for (axRef, _, windowId) in windows {
                    let token = WindowToken(pid: pid, windowId: windowId)
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                }
            }

            for entry in workspaceManager.entries(forPid: pid) {
                tokensToReevaluate.insert(entry.token)
            }
        }

        var relayoutNeeded = false

        for token in tokensToReevaluate.sorted(by: {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }) {
            let existingEntry = workspaceManager.entry(for: token)
            let axRef = liveWindowsByToken[token] ?? existingEntry?.axRef
            guard let axRef else { continue }

            let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)

            if let existingEntry, !evaluation.decision.isResolved {
                _ = workspaceManager.addWindow(
                    axRef,
                    pid: token.pid,
                    windowId: token.windowId,
                    to: existingEntry.workspaceId,
                    ruleEffects: existingEntry.ruleEffects
                )
                continue
            }

            if evaluation.decision.managesWindow {
                let oldEffects = existingEntry?.ruleEffects ?? .none
                let workspaceId = existingEntry?.workspaceId ?? resolveWorkspaceForNewWindow(
                    workspaceName: evaluation.decision.workspaceName,
                    axRef: axRef,
                    pid: token.pid,
                    fallbackWorkspaceId: activeWorkspace()?.id
                )

                _ = workspaceManager.addWindow(
                    axRef,
                    pid: token.pid,
                    windowId: token.windowId,
                    to: workspaceId,
                    ruleEffects: evaluation.decision.ruleEffects
                )

                if existingEntry == nil || oldEffects != evaluation.decision.ruleEffects {
                    relayoutNeeded = true
                }
                continue
            }

            if existingEntry != nil {
                _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
                relayoutNeeded = true
            }
        }

        if relayoutNeeded {
            layoutRefreshController.requestRelayout(reason: .windowRuleReevaluation)
        }

        return relayoutNeeded
    }

    func toggleFocusedWindowFloating() {
        let managedToken = workspaceManager.focusedToken
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let token = managedToken ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        guard let token else { return }

        if windowRuleEngine.manualOverride(for: token) != nil {
            windowRuleEngine.setManualOverride(nil, for: token)
        } else if let axRef = resolveAXWindowRef(for: token) {
            let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)
            let nextOverride: ManualWindowOverride = evaluation.decision.managesWindow ? .forceFloat : .forceTile
            windowRuleEngine.setManualOverride(nextOverride, for: token)
        } else if workspaceManager.entry(for: token) != nil {
            windowRuleEngine.setManualOverride(.forceFloat, for: token)
        } else {
            return
        }

        Task { @MainActor [weak self] in
            _ = await self?.reevaluateWindowRules(for: [.window(token)])
        }
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId
    }

    func openCommandPalette() { CommandPaletteController.shared.show(wmController: self) }
    func openMenuAnywhere() { windowActionHandler.openMenuAnywhere() }
    func navigateToCommandPaletteWindow(_ handle: WindowHandle) { windowActionHandler.navigateToWindow(handle: handle) }
    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }
    func toggleOverview() { windowActionHandler.toggleOverview() }
    func raiseAllFloatingWindows() { windowActionHandler.raiseAllFloatingWindows() }
    func isOverviewOpen() -> Bool { windowActionHandler.isOverviewOpen() }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(for workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        )
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        if let engine = niriEngine,
           let preferredNodeId,
           let node = engine.findNode(by: preferredNodeId) as? NiriWindow
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitorId
            )
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    func ensureFocusedTokenValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition else { return }

        if let focusedToken = workspaceManager.focusedToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId
        {
            if let engine = niriEngine,
               let node = engine.findNode(for: focusedToken)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: focusedToken,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
            } else {
                _ = workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: focusedToken
                    )
                )
            }
            return
        }

        guard let nextFocusToken = workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        ) else {
            return
        }

        if let engine = niriEngine,
           let node = engine.findNode(for: nextFocusToken)
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: nextFocusToken,
                in: workspaceId
            )
        }
        focusWindow(nextFocusToken)
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        moveMouseToWindow(handle.id)
    }

    func moveMouseToWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return }

        CGWarpMouseCursorPosition(center)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }
}

extension WMController {
    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

    func isPointInQuakeTerminal(_ point: CGPoint) -> Bool {
        guard settings.quakeTerminalEnabled,
              quakeTerminalController.visible,
              let window = quakeTerminalController.window else {
            return false
        }
        return window.frame.contains(point)
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        if isPointInQuakeTerminal(point) { return true }
        if windowActionHandler.isPointInOverview(point) { return true }
        return ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        workspaceManager.isNonManagedFocusActive && hasFrontmostOwnedWindow
    }

    func focusWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(token) else { return }

        _ = workspaceManager.beginManagedFocusRequest(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )

        let axRef = entry.axRef
        let pid = entry.pid
        let windowId = entry.windowId
        let moveMouseEnabled = moveMouseToFocusedWindowEnabled

        focusCoordinator.focusWindow(
            token,
            performFocus: {
                // 1. Activate app first (brings process to front, may pick wrong key window)
                self.windowFocusOperations.activateApp(pid)

                // 2. Private API sets the SPECIFIC window as key (overrides activate's choice)
                self.windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)

                // 3. AX raise ensures the window is visually on top and receives keyboard focus
                self.windowFocusOperations.raiseWindow(axRef.element)

                if moveMouseEnabled {
                    self.moveMouseToWindow(token)
                }

                if let entry = self.workspaceManager.entry(for: token) {
                    if let engine = self.niriEngine,
                       let node = engine.findNode(for: token),
                       let frame = node.renderedFrame ?? node.frame
                    {
                        self.borderCoordinator.updateBorderIfAllowed(token: token, frame: frame, windowId: entry.windowId)
                    } else if let frame = self.axManager.lastAppliedFrame(for: entry.windowId) {
                        self.borderCoordinator.updateBorderIfAllowed(token: token, frame: frame, windowId: entry.windowId)
                    } else if let frame = try? AXWindowService.frame(entry.axRef) {
                        self.borderCoordinator.updateBorderIfAllowed(token: token, frame: frame, windowId: entry.windowId)
                    }
                }
            },
            onDeferredFocus: { [weak self] deferred in
                guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
                self.focusWindow(deferred)
            }
        )
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
