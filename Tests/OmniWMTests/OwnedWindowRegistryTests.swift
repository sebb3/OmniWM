import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeOwnedWindowTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.owned-window.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeOwnedWindowTestController() -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    return WMController(
        settings: SettingsStore(defaults: makeOwnedWindowTestDefaults()),
        windowFocusOperations: operations
    )
}

@MainActor
private func closeOwnedUtilityWindowsForTests() async {
    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    SponsorsWindowController.shared.windowForTests?.close()
    await Task.yield()
}

@Suite(.serialized) struct OwnedWindowRegistryTests {
    @Test @MainActor func utilityWindowControllersRegisterAndUnregisterWindows() async {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        await closeOwnedUtilityWindowsForTests()
        defer {
            registry.resetForTests()
        }

        let controller = makeOwnedWindowTestController()
        let settings = controller.settings

        SettingsWindowController.shared.show(settings: settings, controller: controller)
        AppRulesWindowController.shared.show(settings: settings, controller: controller)
        SponsorsWindowController.shared.show()

        guard let settingsWindow = SettingsWindowController.shared.windowForTests,
              let appRulesWindow = AppRulesWindowController.shared.windowForTests,
              let sponsorsWindow = SponsorsWindowController.shared.windowForTests
        else {
            Issue.record("Expected owned utility windows to be created")
            return
        }

        #expect(registry.contains(window: settingsWindow))
        #expect(registry.contains(window: appRulesWindow))
        #expect(registry.contains(window: sponsorsWindow))
        #expect(registry.contains(windowNumber: settingsWindow.windowNumber))
        #expect(registry.contains(windowNumber: appRulesWindow.windowNumber))
        #expect(registry.contains(windowNumber: sponsorsWindow.windowNumber))

        settingsWindow.close()
        appRulesWindow.close()
        sponsorsWindow.close()
        await Task.yield()

        #expect(registry.contains(window: settingsWindow) == false)
        #expect(registry.contains(window: appRulesWindow) == false)
        #expect(registry.contains(window: sponsorsWindow) == false)
        #expect(registry.contains(windowNumber: settingsWindow.windowNumber) == false)
        #expect(registry.contains(windowNumber: appRulesWindow.windowNumber) == false)
        #expect(registry.contains(windowNumber: sponsorsWindow.windowNumber) == false)
    }
}
