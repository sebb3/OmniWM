// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class DockPayloadInjectorTests: XCTestCase {
    func testUnavailableWithoutBundledPayload() {
        let environment = DockPayloadInjectionEnvironment(
            payloadURL: nil,
            clientURL: nil,
            dockPID: 42,
            run: { _, _ in XCTFail("Unexpected command"); return 1 }
        )

        XCTAssertEqual(DockPayloadInjector.inject(environment: environment), .unavailable)
    }

    func testExistingPayloadSkipsLLDB() throws {
        let fixture = try makeFixture()
        var commands: [(URL, [String])] = []
        let environment = DockPayloadInjectionEnvironment(
            payloadURL: fixture.payload,
            clientURL: fixture.client,
            dockPID: 42,
            run: { executable, arguments in
                commands.append((executable, arguments))
                return 0
            }
        )

        XCTAssertEqual(DockPayloadInjector.inject(environment: environment), .alreadyLoaded)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.1, ["status"])
    }

    func testInjectsWithLLDBThenVerifiesPayload() throws {
        let fixture = try makeFixture()
        var commands: [(URL, [String])] = []
        let environment = DockPayloadInjectionEnvironment(
            payloadURL: fixture.payload,
            clientURL: fixture.client,
            dockPID: 42,
            run: { executable, arguments in
                commands.append((executable, arguments))
                if executable == fixture.client { return commands.count == 1 ? 3 : 0 }
                return 0
            },
            waitForPayload: {}
        )

        XCTAssertEqual(DockPayloadInjector.inject(environment: environment), .injected)
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[1].0.path, "/usr/bin/xcrun")
        XCTAssertEqual(
            commands[1].1,
            [
                "lldb", "--batch", "-p", "42",
                "-o", "process load \"\(fixture.payload.path)\"",
                "-o", "process detach"
            ]
        )
        XCTAssertEqual(commands[2].1, ["status"])
    }

    private func makeFixture() throws -> (payload: URL, client: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("payload.dylib")
        let client = directory.appendingPathComponent("status")
        XCTAssertTrue(FileManager.default.createFile(atPath: payload.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: client.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: client.path
        )
        return (payload, client)
    }
}
