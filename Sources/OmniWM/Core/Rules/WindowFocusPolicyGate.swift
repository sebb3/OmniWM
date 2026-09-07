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
        recentUserInput: @autoclosure () -> Bool,
        userLaunched: @autoclosure () -> Bool = false
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
            //
            // `userLaunched` covers the cold start: the user's click happened
            // when the app launched, which can be many seconds before its first
            // window exists, so input recency alone would deny focus to an app
            // the user explicitly opened.
            //
            // It does NOT excuse the frontmost check. Input recency at launch is
            // only a proxy for "the user started this app", and a weak one — the
            // user is usually clicking on something unrelated. A window opened
            // behind the user's back therefore gets vouched for by whatever they
            // happened to be doing. Requiring the app to own the foreground is
            // what actually distinguishes a launch the user asked for from one
            // they did not.
            frontmostPid == windowPid && (recentUserInput() || userLaunched())
        }
    }

    /// True when the user typed, clicked, or scrolled within `seconds`.
    ///
    /// Uses the event source's idle timers rather than an event tap, so this
    /// costs nothing and needs no additional permission.
    static func hasRecentUserInput(within seconds: TimeInterval = userInputWindow) -> Bool {
        secondsSinceLastUserInput() <= seconds
    }

    /// Seconds since the user last typed, clicked, or scrolled.
    static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }
}
