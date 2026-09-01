// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class RuleDefaultSizeCLIContractTests: XCTestCase {
    func testRuleAddParsesDefaultFloatingSize() throws {
        let request = try CLIParser.parse(arguments: [
            "omniwmctl",
            "rule",
            "add",
            "--bundle-id",
            "com.apple.finder",
            "--layout",
            "float",
            "--default-width",
            "800",
            "--default-height",
            "600"
        ])

        guard case let .rule(.add(rule)) = request.request.payload else {
            return XCTFail("Expected rule add request")
        }
        XCTAssertEqual(rule.defaultWidth, 800)
        XCTAssertEqual(rule.defaultHeight, 600)
    }

    func testRuleAddParsesDefaultPositionAndAllWorkspaceVisibility() throws {
        let request = try CLIParser.parse(arguments: [
            "omniwmctl", "rule", "add",
            "--bundle-id", "com.apple.finder",
            "--layout", "float",
            "--default-position-x", "0.25",
            "--default-position-y", "0.75",
            "--display-on-all-workspaces", "on"
        ])

        guard case let .rule(.add(rule)) = request.request.payload else {
            return XCTFail("Expected rule add request")
        }
        XCTAssertEqual(rule.defaultPositionX, 0.25)
        XCTAssertEqual(rule.defaultPositionY, 0.75)
        XCTAssertEqual(rule.displayOnAllWorkspaces, true)
    }
}
