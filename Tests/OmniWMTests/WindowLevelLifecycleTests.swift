// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class WindowLevelLifecycleTests: XCTestCase {
    func testExitResetDeduplicatesManagedWindowsAndRestoresNormalLevel() {
        var resets: [(windowId: UInt32, level: ScriptingAddition.LevelKey)] = []

        LayoutRefreshController.resetWindowLevels(
            windowIds: [23, 19, 23, -1, Int(UInt32.max) + 1]
        ) { windowId, level in
            resets.append((windowId, level))
            return true
        }

        XCTAssertEqual(resets.map(\.windowId), [19, 23])
        XCTAssertEqual(resets.map(\.level), [.normal, .normal])
    }
}
