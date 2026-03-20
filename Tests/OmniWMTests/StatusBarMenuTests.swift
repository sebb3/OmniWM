import AppKit
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct StatusBarMenuTests {
    @Test func buildMenuUsesCurrentAppAppearanceForMenuAndViews() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        application.appearance = NSAppearance(named: .aqua)
        let lightMenu = builder.buildMenu()

        #expect(lightMenu.appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.first?.view).appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.dropFirst(3).first?.view).appearance?.name == .aqua)

        application.appearance = NSAppearance(named: .darkAqua)
        let darkMenu = builder.buildMenu()

        #expect(darkMenu.appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.first?.view).appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.dropFirst(3).first?.view).appearance?.name == .darkAqua)
    }
}
