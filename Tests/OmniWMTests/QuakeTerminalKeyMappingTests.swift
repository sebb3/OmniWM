// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
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

    func testEveryDigitKeyCodeSelectsItsTab() {
        let expectedTabIndexByKeyCode: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
        ]
        for (keyCode, expectedIndex) in expectedTabIndexByKeyCode {
            XCTAssertEqual(
                QuakeTerminalWindow.tabIndex(forDigitKeyCode: keyCode),
                expectedIndex,
                "keyCode \(keyCode) should select tab \(expectedIndex)"
            )
        }
    }

    func testMappingCoversExactlyNineDigits() {
        let mappedKeyCodes = (UInt16(0) ... 127).filter { QuakeTerminalWindow.tabIndex(forDigitKeyCode: $0) != nil }
        XCTAssertEqual(mappedKeyCodes.count, 9)

        let mappedIndexes = mappedKeyCodes.compactMap { QuakeTerminalWindow.tabIndex(forDigitKeyCode: $0) }
        XCTAssertEqual(mappedIndexes.sorted(), Array(0 ... 8))
    }

    func testEqualsKeyCodeSelectsNoTab() {
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 24))
    }

    func testUnmappedKeyCodesSelectNoTab() {
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 17))
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 29))
    }
}
