// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics

/// Decides whether a newly arrived window is allowed to take focus, based on
/// the `focus` field resolved from app rules.
enum WindowFocusPolicyGate {
    /// How recently the user must have typed or clicked for an app activation
    /// to be treated as user driven.
    static let userInputWindow: TimeInterval = 2.0

    static func allowsFocus(
        policy: WindowRuleFocusPolicy?,
        windowPid: pid_t,
        frontmostPid: pid_t?,
        recentUserInput: @autoclosure () -> Bool
    ) -> Bool {
        switch policy ?? .always {
        case .always:
            true
        case .never:
            false
        case .userInitiated:
            // The window may only take focus if its app already owns the
            // foreground and the user did something to cause it. An app that
            // was launched in the background activates itself before its first
            // window appears, so the frontmost check alone is not enough.
            frontmostPid == windowPid && recentUserInput()
        }
    }

    /// True when the user typed, clicked, or scrolled within `seconds`.
    ///
    /// Uses the event source's idle timers rather than an event tap, so this
    /// costs nothing and needs no additional permission.
    static func hasRecentUserInput(within seconds: TimeInterval = userInputWindow) -> Bool {
        let types: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        return types.contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) <= seconds
        }
    }
}
