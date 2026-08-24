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
    private static let opcodeWindowSwapProxyIn: UInt8 = 0x0E
    private static let opcodeWindowSwapProxyOut: UInt8 = 0x0F

    private static var socketPath: String {
        "/tmp/yabai-sa_\(NSUserName()).socket"
    }

    /// The addition is optional: it needs SIP relaxed and an explicit install,
    /// so every caller has to tolerate it being absent.
    ///
    /// Deliberately no `isAvailable` check against the socket file. The
    /// addition only unlinks the socket while loading, so a stale one outlives
    /// a Dock crash and would report a dead addition as healthy. Attempting the
    /// send is the only honest test, and it fails at once when nothing listens.

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

    /// Hides each real window behind its proxy in one transaction: the addition
    /// orders the proxy above the window (grouped with it, so it tracks the
    /// window's own level/sub-level) and sets the *real* window's system alpha
    /// to 0. Both are foreign-window mutations, so — same as `setSubLevel` —
    /// they only take effect issued from Dock's privileged connection; a plain
    /// `SLSTransactionSetWindowSystemAlpha` from OmniWM's own connection would
    /// report success and do nothing an independent observer can see.
    @discardableResult
    static func swapProxiesIn(_ pairs: [(windowId: UInt32, proxyId: UInt32)]) -> Bool {
        swapProxy(pairs, opcode: opcodeWindowSwapProxyIn)
    }

    /// Reverses `swapProxiesIn`: restores the real window's alpha to 1 and
    /// un-groups the proxy, so the caller should already have written the real
    /// window's final AX frame and destroyed the proxy before calling this.
    @discardableResult
    static func swapProxiesOut(_ pairs: [(windowId: UInt32, proxyId: UInt32)]) -> Bool {
        swapProxy(pairs, opcode: opcodeWindowSwapProxyOut)
    }

    private static func swapProxy(_ pairs: [(windowId: UInt32, proxyId: UInt32)], opcode: UInt8) -> Bool {
        guard !pairs.isEmpty else { return true }

        var payload: [UInt8] = [opcode]
        withUnsafeBytes(of: Int32(pairs.count).littleEndian) { payload.append(contentsOf: $0) }
        for pair in pairs {
            withUnsafeBytes(of: pair.windowId.littleEndian) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: pair.proxyId.littleEndian) { payload.append(contentsOf: $0) }
        }

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
