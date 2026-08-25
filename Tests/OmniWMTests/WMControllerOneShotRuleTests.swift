// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import OmniWMIPC
import XCTest

/// One-shot rules are in-memory only, matched exclusively on the live window
/// creation path — see the `oneShotRules` doc comment on `WMController`. These
/// tests cover the controller-level lifecycle (arm/cancel/match/reap);
/// `WindowRuleEngineTests` covers the per-field overlay itself.
@MainActor
final class WMControllerOneShotRuleTests: XCTestCase {
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMWMControllerOneShotRuleTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }

    private func facts(bundleId: String, appName: String = "Test App") -> WindowRuleFacts {
        WindowRuleFacts(
            appName: appName,
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: nil,
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: nil
        )
    }

    private func managedEvaluation(
        bundleId: String,
        token: WindowToken = WindowToken(pid: 4_242, windowId: 99)
    ) -> WMController.WindowDecisionEvaluation {
        WMController.WindowDecisionEvaluation(
            token: token,
            facts: facts(bundleId: bundleId),
            decision: WindowDecision(
                disposition: .managed,
                source: .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
    }

    func testAddOneShotRuleArmsItWithoutTouchingPersistentRules() {
        let controller = makeController()
        let rule = AppRule(bundleId: "com.apple.TextEdit", assignToWorkspace: "2")
        let persistentRulesBefore = controller.settings.appRules

        controller.addOneShotRule(rule)

        XCTAssertEqual(controller.oneShotRules, [rule])
        XCTAssertEqual(controller.settings.appRules, persistentRulesBefore, "must never write to settings.appRules")
    }

    func testRemoveOneShotRuleUnarmsAndReturnsTrue() {
        let controller = makeController()
        let rule = AppRule(bundleId: "com.apple.TextEdit", assignToWorkspace: "2")
        controller.addOneShotRule(rule)

        XCTAssertTrue(controller.removeOneShotRule(id: rule.id))

        XCTAssertTrue(controller.oneShotRules.isEmpty)
    }

    func testRemoveOneShotRuleReturnsFalseWhenNothingIsArmed() {
        let controller = makeController()

        XCTAssertFalse(controller.removeOneShotRule(id: UUID()))
    }

    func testApplyingOneShotRuleOverlaysAndReapsOnMatch() {
        let controller = makeController()
        let rule = AppRule(bundleId: "com.apple.TextEdit", assignToWorkspace: "2")
        controller.addOneShotRule(rule)

        let result = controller.applyingOneShotRule(
            to: managedEvaluation(bundleId: "com.apple.TextEdit")
        )

        XCTAssertEqual(result.decision.workspaceName, "2")
        XCTAssertEqual(result.decision.ruleEffects.matchedRuleId, rule.id)
        XCTAssertTrue(controller.oneShotRules.isEmpty, "a fired one-shot must be reaped")
    }

    /// The armed one-shot is for a different app; the evaluation for this
    /// window must pass through completely unchanged and the one-shot must
    /// stay armed for the window it was actually meant for.
    func testApplyingOneShotRuleLeavesNonMatchingEvaluationUntouched() {
        let controller = makeController()
        let rule = AppRule(bundleId: "com.apple.TextEdit", assignToWorkspace: "2")
        controller.addOneShotRule(rule)
        let evaluation = managedEvaluation(bundleId: "com.apple.Safari")

        let result = controller.applyingOneShotRule(to: evaluation)

        XCTAssertEqual(result.decision, evaluation.decision)
        XCTAssertEqual(controller.oneShotRules, [rule], "must stay armed for a real match later")
    }

    /// A help tag or other transient pre-window AX surface must not burn the
    /// one-shot before the app's real window arrives.
    func testApplyingOneShotRuleDoesNotReapWhenTheResultIsUnmanaged() {
        let controller = makeController()
        let rule = AppRule(bundleId: "com.apple.TextEdit", layout: .float, assignToWorkspace: "2")
        controller.addOneShotRule(rule)
        let unmanagedEvaluation = WMController.WindowDecisionEvaluation(
            token: WindowToken(pid: 4_242, windowId: 99),
            facts: facts(bundleId: "com.apple.TextEdit"),
            decision: WindowDecision(
                disposition: .unmanaged,
                source: .builtInRule("helpTagSurface"),
                layoutDecisionKind: .explicitLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )

        let result = controller.applyingOneShotRule(to: unmanagedEvaluation)

        XCTAssertEqual(result.decision, unmanagedEvaluation.decision)
        XCTAssertEqual(controller.oneShotRules, [rule], "must stay armed for the app's real window")
    }

    /// The common no-op path: no one-shots armed at all. Must not consult the
    /// (empty) one-shot engine or otherwise change the evaluation.
    func testApplyingOneShotRuleIsANoOpWhenNoneAreArmed() {
        let controller = makeController()
        let evaluation = managedEvaluation(bundleId: "com.apple.TextEdit")

        let result = controller.applyingOneShotRule(to: evaluation)

        XCTAssertEqual(result.decision, evaluation.decision)
    }

    /// Two one-shots can be armed for different apps at once; each fires only
    /// for its own match, exercising the same bestMatch specificity ordering
    /// `WindowRuleEngineTests` already covers for persistent rules, now wired
    /// through the one-shot engine.
    func testTwoArmedOneShotsEachFireIndependently() {
        let controller = makeController()
        let textEdit = AppRule(bundleId: "com.apple.TextEdit", assignToWorkspace: "2")
        let safari = AppRule(bundleId: "com.apple.Safari", assignToWorkspace: "3")
        controller.addOneShotRule(textEdit)
        controller.addOneShotRule(safari)

        let safariResult = controller.applyingOneShotRule(to: managedEvaluation(bundleId: "com.apple.Safari"))
        XCTAssertEqual(safariResult.decision.workspaceName, "3")
        XCTAssertEqual(controller.oneShotRules, [textEdit], "only the matched one is reaped")

        let textEditResult = controller.applyingOneShotRule(to: managedEvaluation(bundleId: "com.apple.TextEdit"))
        XCTAssertEqual(textEditResult.decision.workspaceName, "2")
        XCTAssertTrue(controller.oneShotRules.isEmpty)
    }
}
