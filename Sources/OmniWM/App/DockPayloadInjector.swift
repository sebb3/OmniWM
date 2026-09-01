// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum DockPayloadInjectionOutcome: Equatable {
    case unavailable
    case alreadyLoaded
    case injected
    case failed
}

struct DockPayloadInjectionEnvironment: @unchecked Sendable {
    var payloadURL: URL?
    var clientURL: URL?
    var dockPID: pid_t?
    var run: (URL, [String]) -> Int32
    var waitForPayload: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
}

enum DockPayloadInjector {
    static func injectOnStartup() {
        let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("DockPayload")
        let environment = DockPayloadInjectionEnvironment(
            payloadURL: resourceDirectory?.appendingPathComponent("libOmniWMDockPayload.dylib"),
            clientURL: resourceDirectory?.appendingPathComponent("omniwm-dock-payload-status"),
            dockPID: NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first?.processIdentifier,
            run: run
        )
        DispatchQueue.global(qos: .utility).async {
            switch inject(environment: environment) {
            case .alreadyLoaded:
                Log.layout.info("Dock payload already loaded")
            case .injected:
                Log.layout.notice("Dock payload injected")
            case .failed:
                Log.layout.error("Dock payload injection failed")
            case .unavailable:
                break
            }
        }
    }

    static func inject(environment: DockPayloadInjectionEnvironment) -> DockPayloadInjectionOutcome {
        guard let payloadURL = environment.payloadURL,
              let clientURL = environment.clientURL,
              let dockPID = environment.dockPID,
              FileManager.default.isExecutableFile(atPath: clientURL.path),
              FileManager.default.fileExists(atPath: payloadURL.path)
        else {
            return .unavailable
        }
        if environment.run(clientURL, ["status"]) == 0 {
            return .alreadyLoaded
        }

        let escapedPayloadPath = payloadURL.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let arguments = [
            "lldb",
            "--batch",
            "-p", String(dockPID),
            "-o", "process load \"\(escapedPayloadPath)\"",
            "-o", "process detach"
        ]
        guard environment.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments) == 0 else {
            return .failed
        }

        for _ in 0 ..< 20 {
            if environment.run(clientURL, ["status"]) == 0 {
                return .injected
            }
            environment.waitForPayload()
        }
        return .failed
    }

    private static func run(_ executableURL: URL, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
