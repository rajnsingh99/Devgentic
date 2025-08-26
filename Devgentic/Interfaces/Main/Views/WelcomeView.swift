//
//  WelcomeView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//

import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .foregroundColor(Color.secondary.opacity(0.4))

            VStack(alignment: .leading, spacing: 16) {
                ShortcutView(keys: ["⌘", "B"], description: "Open/Close Sidebar")
                ShortcutView(keys: ["⌘", "O"], description: "Add Context")
                ShortcutView(keys: ["⇧", "⌘", "C"], description: "Open Conversation")
                ShortcutView(keys: ["⇧", "⌘", "A"], description: "Open Configuration")
            }
            .frame(width: 400)
        }
    }
}

struct ShortcutView: View {
    let keys: [String]
    let description: String

    var body: some View {
        HStack {
            Text(description)
                .font(.system(size: 16))
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .frame(minWidth: 24, alignment: .center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                }
            }
        }
    }
}

#Preview {
    WelcomeView()
        .frame(width: 700, height: 700)
        .background(Color(NSColor.windowBackgroundColor))
}
