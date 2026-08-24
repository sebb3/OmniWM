// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

/// The workspace-switch slide animates OmniWM-owned proxy windows along
/// imposed vertical geometry — see
/// `LayoutRefreshController+WorkspaceSwitchAnimation.swift`. These tests cover
/// that geometry; capture, swap, and transform application are
/// integration-only and verified live.
@MainActor
final class WorkspaceSwitchAnimationTests: XCTestCase {
    private func makeTransition(travel: CGFloat, proxies: [WorkspaceSwitchTransition.Proxy]) -> WorkspaceSwitchTransition {
        WorkspaceSwitchTransition(
            monitorId: Monitor.ID(displayId: 1),
            targetWorkspaceId: WorkspaceDescriptor.ID(),
            spring: SpringAnimation(from: 0, to: 1, startTime: 0),
            travel: travel,
            proxies: proxies
        )
    }

    private func makeProxy(isIncoming: Bool, baseFrame: CGRect) -> WorkspaceSwitchTransition.Proxy {
        WorkspaceSwitchTransition.Proxy(
            realWindowId: 19,
            proxyWindowId: 900,
            baseFrame: baseFrame,
            isIncoming: isIncoming
        )
    }

    // MARK: - Slide geometry (AppKit Y-up coordinates)

    /// Switching "next" (down the stack) uses negative travel in AppKit
    /// coordinates: the incoming proxy starts one screen *below* its
    /// authoritative frame and converges exactly onto it.
    func testIncomingProxyEntersFromBelowOnNextAndLandsExactly() {
        let base = CGRect(x: 100, y: 54, width: 800, height: 600)
        let proxy = makeProxy(isIncoming: true, baseFrame: base)
        let transition = makeTransition(travel: -1480, proxies: [proxy])

        XCTAssertEqual(transition.frame(for: proxy, progress: 0), base.offsetBy(dx: 0, dy: -1480))
        XCTAssertEqual(transition.frame(for: proxy, progress: 0.5), base.offsetBy(dx: 0, dy: -740))
        XCTAssertEqual(
            transition.frame(for: proxy, progress: 1),
            base,
            "progress 1 must land exactly on the authoritative frame, no residual offset"
        )
    }

    /// An outgoing proxy starts at its pre-switch frame and exits one screen
    /// the other way while the incoming row enters on the same spring.
    func testOutgoingProxyExitsUpwardOnNext() {
        let base = CGRect(x: 100, y: 54, width: 800, height: 600)
        let proxy = makeProxy(isIncoming: false, baseFrame: base)
        let transition = makeTransition(travel: -1480, proxies: [proxy])

        XCTAssertEqual(transition.frame(for: proxy, progress: 0), base)
        XCTAssertEqual(transition.frame(for: proxy, progress: 0.5), base.offsetBy(dx: 0, dy: 740))
        XCTAssertEqual(transition.frame(for: proxy, progress: 1), base.offsetBy(dx: 0, dy: 1480))
    }

    /// Switching "previous" (positive travel) mirrors both directions.
    func testPreviousDirectionMirrorsBothSides() {
        let base = CGRect(x: 100, y: 54, width: 800, height: 600)
        let incoming = makeProxy(isIncoming: true, baseFrame: base)
        let outgoing = makeProxy(isIncoming: false, baseFrame: base)
        let transition = makeTransition(travel: 1480, proxies: [incoming, outgoing])

        XCTAssertEqual(transition.frame(for: incoming, progress: 0), base.offsetBy(dx: 0, dy: 1480), "enters from above")
        XCTAssertEqual(transition.frame(for: incoming, progress: 1), base)
        XCTAssertEqual(transition.frame(for: outgoing, progress: 0), base)
        XCTAssertEqual(transition.frame(for: outgoing, progress: 1), base.offsetBy(dx: 0, dy: -1480), "exits below")
    }

    /// X, width, and height are never touched — the slide is purely vertical.
    func testSlideOnlyMovesY() {
        let base = CGRect(x: 123, y: 54, width: 810, height: 620)
        let proxy = makeProxy(isIncoming: true, baseFrame: base)
        let transition = makeTransition(travel: -1480, proxies: [proxy])

        for progress in stride(from: CGFloat(0), through: 1, by: 0.25) {
            let frame = transition.frame(for: proxy, progress: progress)
            XCTAssertEqual(frame.origin.x, base.origin.x)
            XCTAssertEqual(frame.width, base.width)
            XCTAssertEqual(frame.height, base.height)
        }
    }

    /// The swap pairs preserve real↔proxy association order for the scripting
    /// addition's wire format.
    func testSwapPairsMatchProxies() {
        let a = WorkspaceSwitchTransition.Proxy(realWindowId: 19, proxyWindowId: 901, baseFrame: .zero, isIncoming: true)
        let b = WorkspaceSwitchTransition.Proxy(realWindowId: 23, proxyWindowId: 902, baseFrame: .zero, isIncoming: true)
        let transition = makeTransition(travel: -1480, proxies: [a, b])

        XCTAssertEqual(transition.swapPairs.map(\.windowId), [19, 23])
        XCTAssertEqual(transition.swapPairs.map(\.proxyId), [901, 902])
    }

    // MARK: - Capture

    func testStagedTransitionStoresDirection() {
        let targetWorkspaceId = WorkspaceDescriptor.ID()
        let previous = WorkspaceSwitchStagedTransition(
            monitorId: Monitor.ID(displayId: 1),
            targetWorkspaceId: targetWorkspaceId,
            direction: -1,
            proxies: []
        )
        let next = WorkspaceSwitchStagedTransition(
            monitorId: Monitor.ID(displayId: 1),
            targetWorkspaceId: targetWorkspaceId,
            direction: 1,
            proxies: []
        )

        XCTAssertEqual(previous.direction, -1)
        XCTAssertEqual(next.direction, 1)
    }
}
