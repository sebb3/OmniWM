// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

/// Remembers which apps the user started, as opposed to apps that started
/// themselves.
///
/// The click that launches an app is only observable *at launch time*. A cold
/// start can take many seconds, and the user sits still while it loads, so by
/// the time the first window arrives the input has long expired. Sampling
/// input recency when the process appears and remembering the verdict lets a
/// slow app still focus its first window, while an updater that launches
/// itself — necessarily while the user is idle — still cannot.
@MainActor
final class UserInitiatedLaunchTracker {
    /// How long after a user-driven launch its arriving windows still count as
    /// user initiated. Generous enough for a cold start of a large app.
    static let launchGrace: TimeInterval = 30

    private var launchedAtByPid: [pid_t: Date] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Records a launch. `userInitiated` must be evaluated by the caller at the
    /// moment the launch is observed — that is the whole point of this type.
    func recordLaunch(pid: pid_t, userInitiated: Bool) {
        prune()
        guard userInitiated else {
            // A previous launch of a recycled pid must not vouch for this one.
            launchedAtByPid.removeValue(forKey: pid)
            return
        }
        launchedAtByPid[pid] = now()
    }

    func wasUserLaunched(pid: pid_t) -> Bool {
        guard let launchedAt = launchedAtByPid[pid] else { return false }
        return now().timeIntervalSince(launchedAt) <= Self.launchGrace
    }

    /// True when the user launched this app and has not done anything since —
    /// they are still waiting for it.
    ///
    /// A launched app is not reliably frontmost when its first window arrives:
    /// a launcher like Raycast dismisses itself on Enter, handing the
    /// foreground back to the previous app while the new one is still starting.
    /// Waiting is what licenses focus here. Once the user has typed or clicked
    /// somewhere else they have moved on, and a late window must not interrupt
    /// them.
    func isAwaitingLaunchedApp(pid: pid_t, secondsSinceUserInput: TimeInterval) -> Bool {
        guard let launchedAt = launchedAtByPid[pid] else { return false }
        let sinceLaunch = now().timeIntervalSince(launchedAt)
        guard sinceLaunch <= Self.launchGrace else { return false }
        // The input that caused the launch is not "since" the launch. Allow a
        // small margin so that click or keypress does not disqualify itself.
        return secondsSinceUserInput >= sinceLaunch - Self.launchInputMargin
    }

    /// Slack between the user's launching input and the launch notification.
    private static let launchInputMargin: TimeInterval = 0.75

    func forget(pid: pid_t) {
        launchedAtByPid.removeValue(forKey: pid)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.launchGrace)
        launchedAtByPid = launchedAtByPid.filter { $0.value > cutoff }
    }
}
