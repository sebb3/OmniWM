// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import GhosttyKit

enum QuakeGhosttyHostAction: Equatable {
    struct SplitPlacement: Equatable {
        let direction: SplitDirection
        let newViewFirst: Bool
    }

    enum SplitTarget: Equatable {
        case previous
        case next
        case direction(NavigationDirection)
    }

    enum TabTarget: Equatable {
        case previous
        case next
        case last
        case index(Int)
    }

    case newTab
    case closeTab(ghostty_action_close_tab_mode_e)
    case newSplit(SplitPlacement)
    case gotoSplit(SplitTarget)
    case gotoTab(TabTarget)
    case moveTab(Int)
    case equalizeSplits
    case closeWindow
    case openConfig

    static func splitPlacement(_ direction: ghostty_action_split_direction_e) -> SplitPlacement {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            .init(direction: .horizontal, newViewFirst: true)
        case GHOSTTY_SPLIT_DIRECTION_UP:
            .init(direction: .vertical, newViewFirst: true)
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            .init(direction: .vertical, newViewFirst: false)
        default:
            .init(direction: .horizontal, newViewFirst: false)
        }
    }

    static func splitTarget(_ direction: ghostty_action_goto_split_e) -> SplitTarget {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: .next
        case GHOSTTY_GOTO_SPLIT_UP: .direction(.up)
        case GHOSTTY_GOTO_SPLIT_LEFT: .direction(.left)
        case GHOSTTY_GOTO_SPLIT_DOWN: .direction(.down)
        default: .direction(.right)
        }
    }

    static func tabTarget(_ target: ghostty_action_goto_tab_e) -> TabTarget? {
        switch target.rawValue {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: .previous
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: .next
        case GHOSTTY_GOTO_TAB_LAST.rawValue: .last
        case 0...: .index(Int(target.rawValue))
        default: nil
        }
    }
}
