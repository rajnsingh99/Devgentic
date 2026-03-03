//
//  ModernSection.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
//

import SwiftUI


struct ModernSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    @Environment(\.appTheme) private var theme
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 4)
            
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding()
            .background(theme.controlBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .shadow(color: theme.primaryText.opacity(0.03), radius: 2, x: 0, y: 1)
        }
    }
}
