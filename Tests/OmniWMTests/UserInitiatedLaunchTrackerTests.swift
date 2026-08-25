// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class UserInitiatedLaunchTrackerTests: XCTestCase {
    /// Drives the tracker's clock so cold starts can be simulated without
    /// waiting for them.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private func makeTracker() -> (UserInitiatedLaunchTracker, Clock) {
        let clock = Clock()
        return (UserInitiatedLaunchTracker(now: { clock.now }), clock)
    }

    func testSlowColdStartStillCountsAsUserLaunched() {
        let (tracker, clock) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: true)

        // Eight seconds of loading, user sitting still the whole time.
        clock.advance(8)
        XCTAssertTrue(tracker.isAwaitingLaunchedApp(pid: 42, secondsSinceUserInput: 8))
    }

    func testUserActingElsewhereRevokesTheLaunchClaim() {
        let (tracker, clock) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: true)

        // Launched 8s ago, but the user typed 1s ago — they have moved on and
        // a late window must not interrupt them.
        clock.advance(8)
        XCTAssertFalse(tracker.isAwaitingLaunchedApp(pid: 42, secondsSinceUserInput: 1))
    }

    func testLaunchingInputDoesNotDisqualifyItself() {
        let (tracker, clock) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: true)

        // The keypress that caused the launch lands fractionally before the
        // launch notification, so it reads as marginally "after" it.
        clock.advance(0.2)
        XCTAssertTrue(tracker.isAwaitingLaunchedApp(pid: 42, secondsSinceUserInput: 0.1))
    }

    func testSelfLaunchedAppIsNeverVouchedFor() {
        let (tracker, _) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: false)

        XCTAssertFalse(tracker.wasUserLaunched(pid: 42))
        XCTAssertFalse(tracker.isAwaitingLaunchedApp(pid: 42, secondsSinceUserInput: 0))
    }

    func testClaimExpiresAfterTheGracePeriod() {
        let (tracker, clock) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: true)

        clock.advance(UserInitiatedLaunchTracker.launchGrace + 1)
        XCTAssertFalse(tracker.wasUserLaunched(pid: 42))
        XCTAssertFalse(tracker.isAwaitingLaunchedApp(pid: 42, secondsSinceUserInput: 999))
    }

    /// pids are recycled. A background launch reusing the pid of an earlier
    /// user launch must not inherit its claim.
    func testRecycledPidDoesNotInheritAnEarlierClaim() {
        let (tracker, clock) = makeTracker()
        tracker.recordLaunch(pid: 42, userInitiated: true)

        clock.advance(2)
        tracker.recordLaunch(pid: 42, userInitiated: false)
        XCTAssertFalse(tracker.wasUserLaunched(pid: 42))
    }
}
