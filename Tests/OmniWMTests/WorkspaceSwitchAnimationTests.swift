// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwitchAnimationTests: XCTestCase {
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMWorkspaceSwitchAnimationTests-\(UUID().uuidString)",
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

    // MARK: - interpolatedFrame

    func testInterpolatedFrameAtZeroProgressIsExactlyTheStartFrame() {
        let controller = makeController()
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 0, y: 1200, width: 800, height: 600)

        let frame = controller.layoutRefreshController.interpolatedFrame(from: from, to: to, progress: 0)

        XCTAssertEqual(frame, from, "progress 0 must be exactly the prior frame, not an approximation")
    }

    func testInterpolatedFrameAtFullProgressIsExactlyTheEndFrame() {
        let controller = makeController()
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 0, y: 1200, width: 800, height: 600)

        let frame = controller.layoutRefreshController.interpolatedFrame(from: from, to: to, progress: 1)

        XCTAssertEqual(frame, to, "progress 1 must be exactly the target frame, not an approximation")
    }

    func testInterpolatedFrameAtHalfProgressIsTheMidpoint() {
        let controller = makeController()
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 0, y: 1200, width: 800, height: 600)

        let frame = controller.layoutRefreshController.interpolatedFrame(from: from, to: to, progress: 0.5)

        XCTAssertEqual(frame.origin.y, 600, accuracy: 0.001)
    }

    /// Size is interpolated too, not just origin — a window whose target size
    /// differs (e.g. a different workspace's tiling arrangement) should not
    /// pop to its final size mid-slide.
    func testInterpolatedFrameBlendsSizeAsWellAsOrigin() {
        let controller = makeController()
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let to = CGRect(x: 0, y: 0, width: 800, height: 600)

        let frame = controller.layoutRefreshController.interpolatedFrame(from: from, to: to, progress: 0.5)

        XCTAssertEqual(frame.width, 600, accuracy: 0.001)
        XCTAssertEqual(frame.height, 450, accuracy: 0.001)
    }

    // MARK: - WorkspaceSwitchAnimationCapture

    func testIncomingPriorFrameLookupFallsBackWhenTokenWasNotCaptured() {
        let entry = makeWindowState(pid: 42, windowId: 7)
        let capture = WorkspaceNavigationHandler.WorkspaceSwitchAnimationCapture(
            outgoingPriorFrames: [],
            incomingPriorFrames: [(entry: entry, priorFrame: CGRect(x: 1, y: 2, width: 3, height: 4))]
        )

        XCTAssertEqual(capture.incomingPriorFrame(for: entry.token), CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(
            capture.incomingPriorFrame(for: WindowToken(pid: 99, windowId: 1)),
            "a window that was not part of the captured incoming set must not silently match another one"
        )
    }

    private func makeWindowState(pid: pid_t, windowId: Int) -> WindowState {
        WindowState(
            token: WindowToken(pid: pid, windowId: windowId),
            axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            workspaceId: WorkspaceDescriptor.ID(),
            mode: .tiling,
            managedReplacementMetadata: nil,
            ruleEffects: .none,
            admissionHints: .none
        )
    }
}
