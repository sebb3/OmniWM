import AppKit
import Foundation
import Testing

@testable import OmniWM

@Suite struct WorkspaceBarDataSourceTests {
    @Test @MainActor func floatingOnlyWorkspaceIsHidden() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 6001, name: "Terminal", bundleId: "com.example.terminal")
        controller.appInfoCache.storeInfoForTests(pid: 6002, name: "Console", bundleId: "com.example.console")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 901),
            pid: 6001,
            windowId: 901,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 902),
            pid: 6002,
            windowId: 902,
            to: workspace2,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: false,
            hideEmpty: true,
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.focusedToken,
            settings: controller.settings
        )

        #expect(items.map(\.id).contains(workspace1))
        #expect(items.map(\.id).contains(workspace2) == false)
    }

    @Test @MainActor func mixedWorkspaceRendersOnlyTiledIcons() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing workspace bar fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 7001, name: "Tiled App", bundleId: "com.example.tiled")
        controller.appInfoCache.storeInfoForTests(pid: 7002, name: "Console App", bundleId: "com.example.console")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1001),
            pid: 7001,
            windowId: 1001,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1002),
            pid: 7002,
            windowId: 1002,
            to: workspace1,
            mode: .floating
        )

        let items = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: false,
            hideEmpty: false,
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: nil,
            focusedToken: controller.workspaceManager.focusedToken,
            settings: controller.settings
        )

        let workspaceItem = try #require(items.first(where: { $0.id == workspace1 }))
        #expect(workspaceItem.windows.count == 1)
        #expect(workspaceItem.windows.map(\.appName) == ["Tiled App"])
        #expect(workspaceItem.windows.map(\.windowId) == [1001])
    }
}
