import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite struct LayoutRefreshControllerTests {
    @Test @MainActor func hiddenEdgeRevealUsesOnePointZeroForNonZoomApps() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: false) == 1.0)
    }

    @Test @MainActor func hiddenEdgeRevealUsesZeroForZoom() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: true) == 0)
    }

    @Test @MainActor func executeLayoutPlanAppliesFrameDiffAndFocusedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 101)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 120, y: 80, width: 900, height: 640)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)
        diff.borderMode = .direct

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                rememberedFocusToken: token
            ),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(lastAppliedFramesForLayoutPlanTests(on: controller)[101] == frame)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 101)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == token)
    }

    @Test @MainActor func executeLayoutPlanPreservesHiddenStateOnHideAndClearsItOnShow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout visibility test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 202)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.4, y: 0.3),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        var hideDiff = WorkspaceLayoutDiff()
        hideDiff.visibilityChanges = [.hide(token, side: .right, targetY: 120)]
        hideDiff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)

        var showDiff = WorkspaceLayoutDiff()
        showDiff.visibilityChanges = [.show(token)]
        showDiff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: showDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
    }

    @Test @MainActor func executeLayoutPlanRestoresInactiveWindowFromFrameDiffWithoutShow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for frame-only restore test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 250)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)

        let frame = CGRect(x: 160, y: 110, width: 820, height: 540)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: LayoutHiddenStateSnapshot(
                    WindowModel.HiddenState(
                        proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                        referenceMonitorId: monitor.id,
                        workspaceInactive: true
                    )
                )
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(lastAppliedFramesForLayoutPlanTests(on: controller)[250] == frame)
    }

    @Test @MainActor func executeLayoutPlanHidesBorderWhenFocusedFrameIsMissing() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for border executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 303)
        controller.setBordersEnabled(true)

        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.visibilityChanges = [.show(token)]
        primingDiff.focusedFrame = LayoutFocusedFrame(
            token: token,
            frame: CGRect(x: 20, y: 20, width: 400, height: 300)
        )
        primingDiff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 303)

        var hideBorderDiff = WorkspaceLayoutDiff()
        hideBorderDiff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideBorderDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
    }

    @Test @MainActor func executeLayoutPlanDoesNotRestoreInactiveWorkspaceForNonActivePlan() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let activeWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for inactive restore regression test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: inactiveWorkspaceId, windowId: 404)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        _ = controller.workspaceManager.setActiveWorkspace(activeWorkspaceId, on: monitor.id)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [
            LayoutFrameChange(
                token: token,
                frame: CGRect(x: 220, y: 120, width: 760, height: 520),
                forceApply: false
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: inactiveWorkspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: inactiveWorkspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}
