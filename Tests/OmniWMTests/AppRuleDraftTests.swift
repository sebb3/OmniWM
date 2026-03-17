import Testing

@testable import OmniWM

private func makeDecisionSnapshot(
    bundleId: String? = "com.example.app",
    title: String? = nil,
    axRole: String? = nil,
    axSubrole: String? = nil
) -> WindowDecisionDebugSnapshot {
    WindowDecisionDebugSnapshot(
        token: nil,
        appName: "Example App",
        bundleId: bundleId,
        title: title,
        axRole: axRole,
        axSubrole: axSubrole,
        appFullscreen: false,
        manualOverride: nil,
        disposition: .managed,
        source: .heuristic,
        workspaceName: nil,
        minWidth: nil,
        minHeight: nil,
        matchedRuleId: nil,
        heuristicReasons: [],
        attributeFetchSucceeded: true
    )
}

@Suite struct AppRuleDraftTests {
    @Test func guidedSeedEnablesTitleRoleAndSubroleMatchersFromSnapshot() {
        let snapshot = makeDecisionSnapshot(
            bundleId: "com.example.viewer",
            title: "Picture in Picture",
            axRole: "AXWindow",
            axSubrole: "AXFloatingWindow"
        )

        let draft = AppRuleDraft.guided(from: snapshot)

        #expect(draft?.bundleId == "com.example.viewer")
        #expect(draft?.titleMatcherMode == .substring)
        #expect(draft?.titleSubstring == "Picture in Picture")
        #expect(draft?.axRoleEnabled == true)
        #expect(draft?.axRole == "AXWindow")
        #expect(draft?.axSubroleEnabled == true)
        #expect(draft?.axSubrole == "AXFloatingWindow")
        #expect(draft?.appNameMatcherEnabled == false)
        #expect(draft?.assignToWorkspaceEnabled == false)
        #expect(draft?.minWidthEnabled == false)
        #expect(draft?.minHeightEnabled == false)
    }

    @Test func guidedSeedOnlyEnablesMatchersForAvailableSnapshotFields() {
        let snapshot = makeDecisionSnapshot(bundleId: "com.example.browser")

        let draft = AppRuleDraft.guided(from: snapshot)

        #expect(draft?.bundleId == "com.example.browser")
        #expect(draft?.titleMatcherMode == TitleMatcherMode.none)
        #expect(draft?.axRoleEnabled == false)
        #expect(draft?.axSubroleEnabled == false)
        #expect(draft?.hasActiveAdvancedMatchers == false)
    }
}
