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
            Divider()
                .foregroundColor(theme.dividerColor)

            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.vertical, 4)
        }
    }
}
