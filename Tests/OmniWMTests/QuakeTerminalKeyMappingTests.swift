// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import GhosttyKit
import XCTest

@MainActor
final class QuakeTerminalKeyMappingTests: XCTestCase {
    func testQuakeHotkeySummonsHiddenTerminal() {
        XCTAssertEqual(
            QuakeTerminalController.hotkeyAction(isVisible: false, isFocused: false),
            .summon
        )
    }

    func testQuakeHotkeyFocusesVisibleUnfocusedTerminal() {
        XCTAssertEqual(
            QuakeTerminalController.hotkeyAction(isVisible: true, isFocused: false),
            .focus
        )
    }

    func testQuakeHotkeyHidesVisibleFocusedTerminal() {
        XCTAssertEqual(
            QuakeTerminalController.hotkeyAction(isVisible: true, isFocused: true),
            .hide
        )
    }

    func testLeftQuakeTerminalReservesItsConfiguredWidth() {
        XCTAssertEqual(
            QuakeTerminalController.reservedEdge(
                position: .left,
                customFrame: nil,
                displayId: 7,
                configuredWidth: 640,
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            QuakeTerminalReservedEdge(displayId: 7, width: 640)
        )
    }

    func testOnlyStandardLeftQuakeTerminalReservesAnEdge() {
        for position in QuakeTerminalPosition.allCases where position != .left {
            XCTAssertNil(QuakeTerminalController.reservedEdge(
                position: position,
                customFrame: nil,
                displayId: 7,
                configuredWidth: 640,
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ))
        }
        XCTAssertNil(QuakeTerminalController.reservedEdge(
            position: .left,
            customFrame: CGRect(x: 100, y: 100, width: 640, height: 700),
            displayId: 7,
            configuredWidth: 640,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ))
    }

    func testLeftAnchoredCustomTerminalReservesItsActualWidth() {
        XCTAssertEqual(
            QuakeTerminalController.reservedEdge(
                position: .left,
                customFrame: CGRect(x: 10, y: 100, width: 700, height: 700),
                displayId: 7,
                configuredWidth: 640,
                visibleFrame: CGRect(x: 10, y: 0, width: 1440, height: 900)
            ),
            QuakeTerminalReservedEdge(displayId: 7, width: 700)
        )
    }

    func testCustomTerminalSlidesOnlyWhenAnchoredToTheLeftEdge() {
        let visibleFrame = CGRect(x: 10, y: 0, width: 1440, height: 900)
        XCTAssertTrue(QuakeTerminalController.isLeftAnchored(
            CGRect(x: 10, y: 100, width: 700, height: 700),
            in: visibleFrame
        ))
        XCTAssertFalse(QuakeTerminalController.isLeftAnchored(
            CGRect(x: 100, y: 100, width: 700, height: 700),
            in: visibleFrame
        ))
    }

    func testQuakeFocusBorderFramesOutsideTerminalContent() {
        XCTAssertEqual(
            QuakeTerminalFocusBorderWindow.frame(around: CGRect(x: 100, y: 200, width: 600, height: 400)),
            CGRect(x: 97, y: 197, width: 606, height: 406)
        )
    }

    func testGhosttyDirectionsMapToQuakeLayoutOperations() {
        XCTAssertEqual(
            QuakeGhosttyHostAction.splitPlacement(GHOSTTY_SPLIT_DIRECTION_RIGHT),
            .init(direction: .horizontal, newViewFirst: false)
        )
        XCTAssertEqual(
            QuakeGhosttyHostAction.splitPlacement(GHOSTTY_SPLIT_DIRECTION_UP),
            .init(direction: .vertical, newViewFirst: true)
        )
        XCTAssertEqual(
            QuakeGhosttyHostAction.splitTarget(GHOSTTY_GOTO_SPLIT_PREVIOUS),
            .previous
        )
        XCTAssertEqual(
            QuakeGhosttyHostAction.splitTarget(GHOSTTY_GOTO_SPLIT_DOWN),
            .direction(.down)
        )
    }

    func testGhosttyTabTargetsRetainConfiguredMeaning() {
        XCTAssertEqual(QuakeGhosttyHostAction.tabTarget(GHOSTTY_GOTO_TAB_PREVIOUS), .previous)
        XCTAssertEqual(QuakeGhosttyHostAction.tabTarget(GHOSTTY_GOTO_TAB_NEXT), .next)
        XCTAssertEqual(QuakeGhosttyHostAction.tabTarget(GHOSTTY_GOTO_TAB_LAST), .last)
    }
}
