import Foundation

enum WindowRuleManageAction: String, Codable, CaseIterable, Identifiable {
    case auto
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .off: "Ignore"
        }
    }
}

enum WindowRuleLayoutAction: String, Codable, CaseIterable, Identifiable {
    case auto
    case tile
    case float

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .tile: "Tile"
        case .float: "Float"
        }
    }
}

struct AppRule: Codable, Identifiable, Equatable {
    let id: UUID
    var bundleId: String
    var appNameSubstring: String?
    var titleSubstring: String?
    var titleRegex: String?
    var axRole: String?
    var axSubrole: String?
    var alwaysFloat: Bool?
    var manage: WindowRuleManageAction?
    var layout: WindowRuleLayoutAction?
    var assignToWorkspace: String?
    var minWidth: Double?
    var minHeight: Double?

    init(
        id: UUID = UUID(),
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        alwaysFloat: Bool? = nil,
        manage: WindowRuleManageAction? = nil,
        layout: WindowRuleLayoutAction? = nil,
        assignToWorkspace: String? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil
    ) {
        self.id = id
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.alwaysFloat = alwaysFloat
        self.manage = manage
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    var effectiveManageAction: WindowRuleManageAction {
        manage ?? .auto
    }

    var effectiveLayoutAction: WindowRuleLayoutAction {
        if let layout {
            return layout
        }
        if alwaysFloat == true {
            return .float
        }
        return .auto
    }

    var hasAdvancedMatchers: Bool {
        appNameSubstring?.isEmpty == false ||
            titleSubstring?.isEmpty == false ||
            titleRegex?.isEmpty == false ||
            axRole?.isEmpty == false ||
            axSubrole?.isEmpty == false
    }

    var specificity: Int {
        var score = 1
        if appNameSubstring?.isEmpty == false { score += 1 }
        if titleSubstring?.isEmpty == false { score += 1 }
        if titleRegex?.isEmpty == false { score += 1 }
        if axRole?.isEmpty == false { score += 1 }
        if axSubrole?.isEmpty == false { score += 1 }
        return score
    }

    var hasAnyRule: Bool {
        effectiveManageAction != .auto || effectiveLayoutAction != .auto ||
            assignToWorkspace != nil ||
            minWidth != nil || minHeight != nil ||
            hasAdvancedMatchers
    }
}
