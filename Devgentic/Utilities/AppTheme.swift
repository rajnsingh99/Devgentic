//
//  AppTheme.swift
//  Devgentic
//
//  Created by Raj Singh on 18/08/25.
//

import SwiftUI

struct AppTheme {
    struct Colors {
        static let premiumDarkGrey = Color(red: 0.1, green: 0.1, blue: 0.1)
    }
}

struct ChatGPTBackgroundView: View {
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 0.15, green: 0.15, blue: 0.16),
                Color(red: 0.1, green: 0.1, blue: 0.11)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            Color.black.opacity(0.04)
                .blendMode(.multiply)
        )
        .edgesIgnoringSafeArea(.all)
    }
}

struct ChatHistoryVisualEffectBlur: View {
    var body: some View {
        ZStack {
            CHVisualEffectBlur(material: .underWindowBackground)
            Color.black.opacity(0.4)
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


