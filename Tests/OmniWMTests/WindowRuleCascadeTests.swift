// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WindowRuleCascadeTests: XCTestCase {
    private func facts(bundleId: String?, appName: String? = nil, title: String? = nil) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: appName,
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: title,
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

    func testWildcardRuleMatchesEveryBundle() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [AppRule(bundleId: AppRule.wildcardBundleId, windowLevel: .below)])

        for bundleId in ["com.apple.finder", "com.spotify.client", nil] {
            let decision = engine.decision(for: facts(bundleId: bundleId), token: nil, appFullscreen: false)
            XCTAssertEqual(decision.ruleEffects.windowLevel, .below, "bundle \(bundleId ?? "nil")")
        }
    }

    func testWildcardScoresBelowEveryNarrowerRule() {
        XCTAssertEqual(AppRule(bundleId: AppRule.wildcardBundleId).specificity, 0)
        XCTAssertGreaterThan(AppRule(bundleId: "com.apple.finder").specificity, 0)
    }

    func testNarrowRuleOverridesWildcardPerField() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [
            AppRule(bundleId: AppRule.wildcardBundleId, focus: .never, windowLevel: .normal),
            AppRule(bundleId: "com.spotify.client", focus: .always),
        ])

        let spotify = engine.decision(for: facts(bundleId: "com.spotify.client"), token: nil, appFullscreen: false)
        XCTAssertEqual(spotify.ruleEffects.focus, .always)
        // Not stated by the narrow rule, so it still falls through to the default.
        XCTAssertEqual(spotify.ruleEffects.windowLevel, .normal)

        let other = engine.decision(for: facts(bundleId: "com.apple.finder"), token: nil, appFullscreen: false)
        XCTAssertEqual(other.ruleEffects.focus, .never)
    }

    func testPositionAndAllWorkspaceVisibilityCascadePerField() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [
            AppRule(
                bundleId: AppRule.wildcardBundleId,
                defaultPositionX: 0.1,
                defaultPositionY: 0.9,
                displayOnAllWorkspaces: true
            ),
            AppRule(
                bundleId: "com.spotify.client",
                defaultPositionX: 0.25,
                displayOnAllWorkspaces: false
            ),
        ])

        let decision = engine.decision(
            for: facts(bundleId: "com.spotify.client"),
            token: nil,
            appFullscreen: false
        )
        XCTAssertEqual(decision.admissionHints.defaultPositionX, 0.25)
        XCTAssertEqual(decision.admissionHints.defaultPositionY, 0.9)
        XCTAssertEqual(decision.ruleEffects.displayOnAllWorkspaces, false)
    }

    func testNarrowRuleWithUnrelatedEffectDoesNotShadowDefault() {
        // The winner-takes-all path would drop the wildcard's level here, since
        // the float rule is more specific and says nothing about the level.
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [
            AppRule(bundleId: AppRule.wildcardBundleId, windowLevel: .floating),
            AppRule(bundleId: "com.spotify.client", layout: .float),
        ])

        let decision = engine.decision(for: facts(bundleId: "com.spotify.client"), token: nil, appFullscreen: false)
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.ruleEffects.windowLevel, .floating)
    }

    func testDeclarationOrderBreaksSpecificityTies() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [
            AppRule(bundleId: "com.spotify.client", windowLevel: .floating),
            AppRule(bundleId: "com.spotify.client", windowLevel: .below),
        ])

        let decision = engine.decision(for: facts(bundleId: "com.spotify.client"), token: nil, appFullscreen: false)
        XCTAssertEqual(decision.ruleEffects.windowLevel, .floating)
    }

    func testFocusGateTruthTable() {
        let pid: pid_t = 42

        XCTAssertTrue(WindowFocusPolicyGate.allowsFocus(
            policy: nil, windowPid: pid, frontmostPid: 99, recentUserInput: false
        ), "no rule keeps today's always-focus behaviour")

        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .never, windowPid: pid, frontmostPid: pid, recentUserInput: true
        ))

        XCTAssertTrue(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated, windowPid: pid, frontmostPid: pid, recentUserInput: true
        ))

        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated, windowPid: pid, frontmostPid: pid, recentUserInput: false
        ), "app is frontmost but nothing the user did caused it")

        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated, windowPid: pid, frontmostPid: 99, recentUserInput: true
        ), "user is busy in another app")
    }

    func testUserLaunchExcusesStaleInputButNotTheForeground() {
        let pid: pid_t = 42

        // Cold start from Raycast or the Dock: the launching keypress expired
        // while the app loaded, but the app owns the foreground once ready.
        XCTAssertTrue(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated,
            windowPid: pid,
            frontmostPid: pid,
            recentUserInput: false,
            userLaunched: true
        ))

        // Regression: a window opened behind the user's back, while they happen
        // to be clicking in another app. The click vouches for the launch, so
        // only the foreground check stands between it and stolen focus.
        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated,
            windowPid: pid,
            frontmostPid: 99,
            recentUserInput: true,
            userLaunched: true
        ))

        // An app that launched itself never gets vouched for either.
        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .userInitiated,
            windowPid: pid,
            frontmostPid: 99,
            recentUserInput: false,
            userLaunched: false
        ))

        // `never` still wins outright.
        XCTAssertFalse(WindowFocusPolicyGate.allowsFocus(
            policy: .never,
            windowPid: pid,
            frontmostPid: pid,
            recentUserInput: true,
            userLaunched: true
        ))
    }

    func testAutoLevelSinksTiledWindows() {
        // Tiled windows are pushed under the normal band rather than floats
        // being lifted above it, so unmanaged windows — alerts, sheets, other
        // apps' dialogs — sit above the tiles without any rule naming them.
        XCTAssertEqual(ScriptingAddition.resolveLevel(rule: .auto, isFloating: false), .below)
        XCTAssertEqual(ScriptingAddition.resolveLevel(rule: .auto, isFloating: true), .normal)
        XCTAssertEqual(ScriptingAddition.resolveLevel(rule: nil, isFloating: false), .below)

        // Explicit levels ignore disposition.
        XCTAssertEqual(ScriptingAddition.resolveLevel(rule: .floating, isFloating: false), .floating)
        XCTAssertEqual(ScriptingAddition.resolveLevel(rule: .normal, isFloating: true), .normal)

        XCTAssertLessThan(
            ScriptingAddition.LevelKey.below.windowLevel,
            ScriptingAddition.LevelKey.normal.windowLevel,
            "tiled must rank under ordinary windows or the feature is pointless"
        )
        XCTAssertGreaterThan(
            ScriptingAddition.LevelKey.floating.windowLevel,
            ScriptingAddition.LevelKey.normal.windowLevel
        )
    }

    func testRoundTripsThroughCodable() throws {
        let rule = AppRule(
            bundleId: AppRule.wildcardBundleId,
            focus: .userInitiated,
            windowLevel: .floating
        )
        let decoded = try JSONDecoder().decode(AppRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded.focus, .userInitiated)
        XCTAssertEqual(decoded.windowLevel, .floating)
    }
}
