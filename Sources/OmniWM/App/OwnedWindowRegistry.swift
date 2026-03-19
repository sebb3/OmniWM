import AppKit
import Foundation

@MainActor
final class OwnedWindowRegistry {
    static let shared = OwnedWindowRegistry()

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var registeredWindowNumbers: Set<Int> = []

    func register(_ window: NSWindow) {
        windows.add(window)
        if window.windowNumber > 0 {
            registeredWindowNumbers.insert(window.windowNumber)
        }
    }

    func unregister(_ window: NSWindow) {
        windows.remove(window)
        if window.windowNumber > 0 {
            registeredWindowNumbers.remove(window.windowNumber)
        }
    }

    func contains(point: CGPoint) -> Bool {
        visibleWindows.contains { $0.frame.contains(point) }
    }

    func contains(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return visibleWindows.contains { $0 === window }
    }

    func contains(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        return registeredWindowNumbers.contains(windowNumber)
    }

    var hasFrontmostWindow: Bool {
        guard let app = NSApp else { return false }
        return contains(window: app.keyWindow) || contains(window: app.mainWindow)
    }

    var hasVisibleWindow: Bool {
        !visibleWindows.isEmpty
    }

    func resetForTests() {
        windows.removeAllObjects()
        registeredWindowNumbers.removeAll()
    }

    private var registeredWindows: [NSWindow] {
        windows.allObjects
    }

    private var visibleWindows: [NSWindow] {
        registeredWindows.filter(\.isVisible)
    }
}
