//
//  Theme.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

// MARK: - Theme Protocol
/// A protocol that defines the blueprint for any theme in the application.
/// It ensures that every theme provides a consistent set of colors and metadata.
protocol Theme {
    /// A unique identifier for the theme, used for saving to UserDefaults.
    var id: String { get }
    
    /// The user-facing name of the theme, displayed in settings.
    var displayName: String { get }

    // --- Core Colors ---
    var primaryBackground: Color { get }
    var secondaryBackground: Color { get }
    var tertiaryBackground: Color { get }

    // --- Text Colors ---
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var tertiaryText: Color { get }
    
    // --- Control & Accent Colors ---
    var accentColor: Color { get }
    var dividerColor: Color { get }
    var selectionColor: Color { get }
    
    // --- Semantic Colors ---
    var errorColor: Color { get }
    var successColor: Color { get }
    var warningColor: Color { get }
}


// MARK: - AppThemes
/// A namespace to contain all the concrete theme implementations.
enum AppThemes {}

// MARK: - Default Theme
extension AppThemes {
    /// The Default Theme automatically adapts to the system's Light and Dark modes.
    struct DefaultTheme: Theme {
        let id = "default"
        let displayName = "Default (System)"

        // Uses SwiftUI's semantic colors which adapt automatically.
        let primaryBackground: Color = Color(nsColor: .windowBackgroundColor)
        let secondaryBackground: Color = Color(nsColor: .controlBackgroundColor)
        let tertiaryBackground: Color = Color(nsColor: .underPageBackgroundColor)

        let primaryText: Color = .primary
        let secondaryText: Color = .secondary
        let tertiaryText: Color = Color(nsColor: .tertiaryLabelColor)
        
        let accentColor: Color = .accentColor
        let dividerColor: Color = Color(nsColor: .separatorColor)
        let selectionColor: Color = Color(nsColor: .selectedContentBackgroundColor)
        
        let errorColor: Color = .red
        let successColor: Color = .green
        let warningColor: Color = .orange
    }
}

// MARK: - Dracula Theme
extension AppThemes {
    /// A popular dark theme for developers.
    struct DraculaTheme: Theme {
        let id = "dracula"
        let displayName = "Dracula"

        let primaryBackground: Color = Color(hex: "#282a36")
        let secondaryBackground: Color = Color(hex: "#383A59") // A slightly lighter variant for sidebars
        let tertiaryBackground: Color = Color(hex: "#44475a")

        let primaryText: Color = Color(hex: "#f8f8f2")
        let secondaryText: Color = Color(hex: "#6272a4")
        let tertiaryText: Color = Color(hex: "#44475a")

        let accentColor: Color = Color(hex: "#bd93f9") // Purple
        let dividerColor: Color = Color(hex: "#44475a")
        let selectionColor: Color = Color(hex: "#44475a")

        let errorColor: Color = Color(hex: "#ff5555") // Red
        let successColor: Color = Color(hex: "#50fa7b") // Green
        let warningColor: Color = Color(hex: "#f1fa8c") // Yellow
    }
}


// MARK: - Color Hex Initializer
/// An extension to allow creating SwiftUI Colors from a hex string.
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
