//
//  SettingsDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Wraps the SettingsCategory destination view for display
//  in the main content area.
//

import SwiftUI

struct SettingsDetailContainerView: View {

    let category: SettingsCategory

    @EnvironmentObject private var mainViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar()

            ScrollView {
                category.destination
                    .environmentObject(mainViewModel)
                    .padding()
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
