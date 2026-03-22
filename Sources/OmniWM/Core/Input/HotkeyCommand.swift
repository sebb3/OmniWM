import Foundation

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case toggleFullscreen
    case toggleNativeFullscreen
    case moveColumn(Direction)
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case cycleColumnWidthForward
    case cycleColumnWidthBackward
    case toggleColumnFullWidth

    case swapWorkspaceWithMonitor(Direction)

    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resizeInDirection(Direction, Bool)
    case preselect(Direction)
    case preselectClear

    case workspaceBackAndForth
    case focusWorkspaceAnywhere(Int)
    case moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction)

    case openCommandPalette

    case raiseAllFloatingWindows
    case toggleFocusedWindowFloating
    case assignFocusedWindowToScratchpad
    case toggleScratchpadWindow

    case openMenuAnywhere

    case toggleWorkspaceBarVisibility
    case toggleHiddenBar
    case toggleQuakeTerminal
    case toggleWorkspaceLayout
    case toggleOverview

    var displayName: String {
        switch self {
        case let .focus(dir): "Focus \(dir.displayName)"
        case .focusPrevious: "Focus Previous Window"
        case let .move(dir): "Move \(dir.displayName)"
        case let .moveToWorkspace(idx): "Move to Workspace \(idx + 1)"
        case .moveWindowToWorkspaceUp: "Move Window to Workspace Up"
        case .moveWindowToWorkspaceDown: "Move Window to Workspace Down"
        case let .moveColumnToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveColumnToWorkspaceUp: "Move Column to Workspace Up"
        case .moveColumnToWorkspaceDown: "Move Column to Workspace Down"
        case let .switchWorkspace(idx): "Switch to Workspace \(idx + 1)"
        case .switchWorkspaceNext: "Switch to Next Workspace"
        case .switchWorkspacePrevious: "Switch to Previous Workspace"
        case .focusMonitorPrevious: "Focus Previous Monitor"
        case .focusMonitorNext: "Focus Next Monitor"
        case .focusMonitorLast: "Focus Last Monitor"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .toggleNativeFullscreen: "Toggle Native Fullscreen"
        case let .moveColumn(dir): "Move Column \(dir.displayName)"
        case .toggleColumnTabbed: "Toggle Column Tabbed"
        case .focusDownOrLeft: "Traverse Backward"
        case .focusUpOrRight: "Traverse Forward"
        case .focusColumnFirst: "Focus First Column"
        case .focusColumnLast: "Focus Last Column"
        case let .focusColumn(idx): "Focus Column \(idx + 1)"
        case .cycleColumnWidthForward: "Cycle Column Width Forward"
        case .cycleColumnWidthBackward: "Cycle Column Width Backward"
        case .toggleColumnFullWidth: "Toggle Column Full Width"
        case let .swapWorkspaceWithMonitor(dir): "Swap Workspace with \(dir.displayName) Monitor"
        case .balanceSizes: "Balance Sizes"
        case .moveToRoot: "Move to Root"
        case .toggleSplit: "Toggle Split"
        case .swapSplit: "Swap Split"
        case let .resizeInDirection(dir, grow): "\(grow ? "Grow" : "Shrink") \(dir.displayName)"
        case let .preselect(dir): "Preselect \(dir.displayName)"
        case .preselectClear: "Clear Preselection"
        case .workspaceBackAndForth: "Switch to Previous Workspace"
        case let .focusWorkspaceAnywhere(idx): "Focus Workspace \(idx + 1) Anywhere"
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir): "Move Window to Workspace \(wsIdx + 1) on \(monDir.displayName) Monitor"
        case .openCommandPalette: "Toggle Command Palette"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .toggleFocusedWindowFloating: "Toggle Focused Window Floating"
        case .assignFocusedWindowToScratchpad: "Assign Focused Window to Scratchpad"
        case .toggleScratchpadWindow: "Toggle Scratchpad Window"
        case .openMenuAnywhere: "Open Menu Anywhere"
        case .toggleWorkspaceBarVisibility: "Toggle Workspace Bar"
        case .toggleHiddenBar: "Toggle Hidden Bar"
        case .toggleQuakeTerminal: "Toggle Quake Terminal"
        case .toggleWorkspaceLayout: "Toggle Workspace Layout"
        case .toggleOverview: "Toggle Overview"
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .moveToRoot, .toggleSplit, .swapSplit, .preselect, .preselectClear, .resizeInDirection:
            .dwindle

        case .moveColumn, .moveColumnToWorkspace, .moveColumnToWorkspaceUp, .moveColumnToWorkspaceDown,
             .toggleColumnFullWidth, .toggleColumnTabbed,
             .focusPrevious, .focusDownOrLeft, .focusUpOrRight,
             .focusColumnFirst, .focusColumnLast, .focusColumn:
            .niri

        case .focus, .toggleFullscreen, .cycleColumnWidthForward, .cycleColumnWidthBackward,
             .balanceSizes,
             .move,
             .moveToWorkspace, .moveWindowToWorkspaceUp, .moveWindowToWorkspaceDown,
             .switchWorkspace, .switchWorkspaceNext, .switchWorkspacePrevious,
             .focusMonitorPrevious, .focusMonitorNext, .focusMonitorLast,
             .toggleNativeFullscreen,
             .swapWorkspaceWithMonitor,
             .workspaceBackAndForth, .focusWorkspaceAnywhere,
             .moveWindowToWorkspaceOnMonitor,
             .openCommandPalette, .raiseAllFloatingWindows, .toggleFocusedWindowFloating,
             .assignFocusedWindowToScratchpad, .toggleScratchpadWindow,
             .openMenuAnywhere,
             .toggleWorkspaceBarVisibility, .toggleHiddenBar, .toggleQuakeTerminal,
             .toggleWorkspaceLayout, .toggleOverview:
            .shared
        }
    }
}
