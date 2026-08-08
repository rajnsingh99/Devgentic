//
//  ProfileType+Display.swift
//  Devgentic
//
//  Single source for the profile-type identity color. Previously duplicated as
//  private switches in five views (ChatInputAreaView, AddBackendProfileView,
//  BackendProfilePanelView, WorkflowCanvasState, WorkflowNodeView), which had
//  already drifted (.teal vs .cyan for code).
//

import SwiftUI

extension ProfileType {
    /// Identity color used for profile-type dots, node accents, and pickers.
    var displayColor: Color {
        switch self {
        case .bot:      return .blue
        case .agent:    return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        case .code:     return .cyan
        }
    }
}

// MARK: - ProfileType Localization
//
// Moved here from BackendProfilePanelView.swift on 06/08/26 (register G93) when that dead
// view was deleted. It belongs here anyway: this file is the single source for ProfileType
// presentation, and `ProfileType` itself is declared in BackendProfile.swift, a
// Foundation-only model file whose values are Codable and reach SwiftData/JSON — it must not
// import SwiftUI, so presentation-only properties live in the SwiftUI layer instead.
extension ProfileType {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .bot:      return "Bot"
        case .agent:    return "Agent"
        case .workflow: return "Workflow"
        case .imageGen: return "Image Generator"
        case .code:     return "Code"
        }
    }
}

