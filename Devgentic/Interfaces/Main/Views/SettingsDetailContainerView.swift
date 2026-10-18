// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Wraps the `SettingsCategory` destination view for display in the main content area.
struct SettingsDetailContainerView: View {

    let category: SettingsCategory

    @Environment(MainApplicationViewModel.self) private var mainViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        if category == .mlxModelStore {
            category.destination
                .environment(mainViewModel)
        } else {
            VStack(spacing: 0) {
                DynamicIslandBar(title: category.localizedTitle, icon: category.iconName)

                ScrollView {
                    category.destination
                        .environment(mainViewModel)
                        .padding(24)
                        .frame(maxWidth: ViewLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
