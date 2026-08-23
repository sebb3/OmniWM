// SPDX-License-Identifier: GPL-2.0-only

import Darwin
import CoreGraphics
import Foundation

/// Client for the scripting addition's socket protocol.
///
/// The addition runs inside Dock, whose window-server connection is privileged,
/// so it can set a sub-level on a window OmniWM does not own. No out-of-process
/// SkyLight call can do that: `SLSSetWindowLevel` from our own connection
/// reports success and is readable back through that same connection, yet an
/// independent observer still sees the original level.
///
/// A sub-level is a standing property rather than a one-shot reorder, so a
/// window stays above its peers without OmniWM re-asserting anything each pass,
/// and without the activation that fronting a window would force.
enum ScriptingAddition {
    /// `CGWindowLevelKey` values. The addition feeds these through
    /// `CGWindowLevelForKey` before calling `SLSSetWindowSubLevel`, so it wants
    /// the key rather than a resolved level. These match yabai's `LAYER_*`
    /// macros (`src/misc/macros.h:42`).
    enum LevelKey: Int32 {
        /// `kCGBackstopMenuLevelKey` — below normal windows, still above the
        /// desktop.
        case below = 3
        /// `kCGNormalWindowLevelKey`
        case normal = 4
        /// `kCGFloatingWindowLevelKey`
        case floating = 5

        /// The resolved window level for this key.
        ///
        /// The addition applies `CGWindowLevelForKey` itself before calling
        /// `SLSSetWindowSubLevel`, so anything setting a sub-level directly has
        /// to perform the same conversion to land in the same band.
        var windowLevel: CGWindowLevel {
            switch self {
            case .below: CGWindowLevelForKey(.backstopMenu)
            case .normal: CGWindowLevelForKey(.normalWindow)
            case .floating: CGWindowLevelForKey(.floatingWindow)
            }
        }
    }

    /// Resolve the sub-level a window should sit at.
    ///
    /// Shared so that anything drawn to accompany a window — a focus border,
    /// say — can be placed in the same band as the window it belongs to.
    static func resolveLevel(
        rule: WindowRuleWindowLevel?,
        isFloating: Bool
    ) -> LevelKey {
        switch rule ?? .auto {
        case .auto:
            // Sink the tiled substrate rather than lifting the floats, which is
            // what yabai does (`window_manager.c:833`). Everything unmanaged —
            // alerts, sheets, pickers, other apps' dialogs — defaults to normal,
            // so it lands above the tiles for free. Lifting floats instead would
            // also push them above system-level windows.
            isFloating ? .normal : .below
        case .below:
            .below
        case .normal:
            .normal
        case .floating:
            .floating
        }
    }

    private static let opcodeWindowLayer: UInt8 = 0x09

    private static var socketPath: String {
        "/tmp/yabai-sa_\(NSUserName()).socket"
    }

    /// Touched to ask a privileged helper to reload the addition. Updating a
    /// file's modification time needs no privilege, while loading the addition
    /// into Dock needs root, so this is the whole interface between the two.
    ///
    /// Nothing here depends on a helper existing: without one the file is just
    /// an unread timestamp and stacking stays at system behaviour.
    private static var reloadTriggerPath: String {
        NSHomeDirectory() + "/.local/state/omniwm/reload-scripting-addition"
    }

    /// Dock restarting takes the addition down with it. A burst of failures is
    /// one event, not many, so requests are collapsed rather than sent per
    /// window; a reload takes far less than this to become visible.
    private static let reloadRequestInterval: TimeInterval = 5
    @MainActor private static var lastReloadRequest: Date = .distantPast

    /// Note that the socket file is deliberately not consulted to decide
    /// whether the addition is alive. It is only unlinked when the addition
    /// loads, so a stale one outlives a Dock crash and would report a dead
    /// addition as healthy. A failed send is the only honest signal.
    @MainActor
    static func requestReload() {
        let now = Date()
        guard now.timeIntervalSince(lastReloadRequest) >= reloadRequestInterval else { return }
        lastReloadRequest = now

        let manager = FileManager.default
        let path = reloadTriggerPath
        let directory = (path as NSString).deletingLastPathComponent
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if manager.fileExists(atPath: path) {
            try? manager.setAttributes([.modificationDate: now], ofItemAtPath: path)
        } else {
            manager.createFile(atPath: path, contents: nil)
        }
    }

    @discardableResult
    static func setSubLevel(windowId: UInt32, level: LevelKey) -> Bool {
        var payload: [UInt8] = [opcodeWindowLayer]
        withUnsafeBytes(of: windowId.littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: level.rawValue.littleEndian) { payload.append(contentsOf: $0) }

        // Framing is a little-endian Int16 payload length followed by the
        // payload; the length deliberately excludes its own two bytes.
        var message: [UInt8] = []
        withUnsafeBytes(of: Int16(payload.count).littleEndian) { message.append(contentsOf: $0) }
        message.append(contentsOf: payload)

        return transmit(message)
    }

    private static func transmit(_ message: [UInt8]) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let path = socketPath
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }

        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, addressSize)
            }
        }
        guard connected == 0 else { return false }

        let written = message.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard written == message.count else { return false }

        // The addition acknowledges with a single byte once it has handled the
        // message; waiting for it keeps callers ordered against Dock.
        var acknowledgement: UInt8 = 0
        _ = recv(descriptor, &acknowledgement, 1, 0)
        return true
    }
}
