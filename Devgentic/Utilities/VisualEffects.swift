//
//  VisualEffects.swift
//  Devgentic
//
//  Created by Raj Singh on 18/08/25.
//

import SwiftUI

struct ChatGPTBackgroundView: View {
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                theme.primaryBackground,
                theme.controlBackground
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            theme.primaryText.opacity(0.04)
                .blendMode(.multiply)
        )
        .edgesIgnoringSafeArea(.all)
    }
}

struct ChatHistoryVisualEffectBlur: View {
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        ZStack {
            CHVisualEffectBlur(material: .underWindowBackground)
            theme.primaryBackground.opacity(0.4)
        }
    }
}

// Helper for the custom blur view
private struct CHVisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
