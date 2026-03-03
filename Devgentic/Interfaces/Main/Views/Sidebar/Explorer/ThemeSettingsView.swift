//
//  ThemeSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

struct ThemeSettingsView: View {
    // Access the shared ThemeManager from the environment.
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        Form {
            Section(header: Text("Appearance")
                .font(.headline)
                .foregroundColor(theme.primaryText)
            ) {
                // A Picker provides a native-looking dropdown for theme selection.
                // The selection binding is directly tied to the current theme's ID.
                Picker("Theme", selection: Binding(
                    get: { themeManager.currentTheme.id },
                    set: { newThemeID in
                        // Find the theme corresponding to the new ID and apply it.
                        if let newTheme = themeManager.availableThemes.first(where: { $0.id == newThemeID }) {
                            themeManager.applyTheme(newTheme)
                        }
                    }
                )) {
                    // Iterate over all available themes to create an option for each.
                    ForEach(themeManager.availableThemes, id: \.id) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }
                .pickerStyle(.menu) // Use a dropdown menu style.
                .foregroundColor(theme.primaryText)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 400)
        .padding()
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }
}

// MARK: - Preview Provider
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        // Provide a ThemeManager for the preview.
        ThemeSettingsView()
            .environmentObject(ThemeManager())
    }
}
