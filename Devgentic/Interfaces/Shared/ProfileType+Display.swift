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
