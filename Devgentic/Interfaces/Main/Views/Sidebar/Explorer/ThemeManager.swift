//
//  ThemeManager.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI
import Combine

/// A class that manages the application's themes.
///
/// This `ObservableObject` is responsible for:
/// - Holding the list of all available themes.
/// - Keeping track of the currently active theme.
/// - Persisting the user's theme choice to `UserDefaults`.
/// - Applying a new theme and ensuring the UI updates reactively.
final class ThemeManager: ObservableObject {

    /// The key used to store the selected theme's ID in UserDefaults.
    private static let selectedThemeKey = "selectedThemeID"

    /// The array of all themes available in the application.
    let availableThemes: [any Theme] = [
        AppThemes.DefaultTheme(),
        AppThemes.DraculaTheme(),
        AppThemes.OneLightTheme()
    ]

    /// The currently active theme. Published to allow SwiftUI views to automatically
    /// update when the theme changes.
    @Published private(set) var currentTheme: any Theme

    init() {
        // On initialization, load the saved theme ID from UserDefaults.
        let savedThemeID = UserDefaults.standard.string(forKey: Self.selectedThemeKey)
        
        // Find the theme that matches the saved ID.
        // If no theme is found (e.g., first app launch or corrupted data),
        // fall back to the first available theme (DefaultTheme).
        self.currentTheme = availableThemes.first { $0.id == savedThemeID } ?? availableThemes[0]
    }

    /// Applies a new theme to the application.
    ///
    /// - Parameter theme: The theme to be applied.
    func applyTheme(_ theme: any Theme) {
        // Update the current theme. This will trigger UI updates in all observing views.
        self.currentTheme = theme
        
        // Save the new theme's ID to UserDefaults to persist the choice across app launches.
        UserDefaults.standard.set(theme.id, forKey: Self.selectedThemeKey)
    }
}
