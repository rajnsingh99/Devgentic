//
//  SettingsSection.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import Foundation

// MARK: - Settings Section Definition
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case agents = "Agents"
    case license = "License & Access"

    var id: String { self.rawValue }

    // SF Symbols for icons
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "person.3.sequence"
        case .license: return "key"
        }
    }
}
