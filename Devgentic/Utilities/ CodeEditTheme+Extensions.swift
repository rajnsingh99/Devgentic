//
//  CodeEditTheme+Extensions.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import CodeEditSourceEditor

/// This extension provides a centralized, reusable definition for the default dark theme
/// used across different code editor instances in the app.
extension CodeEditSourceEditor.EditorTheme {
    public static let defaultDark: Self = .init(
        text: .init(color: .white),
        insertionPoint: .white,
        invisibles: .init(color: .systemGray.withAlphaComponent(0.5)),
        background: NSColor(hex: "#282a36"),
        lineHighlight: NSColor(hex: "#44475a").withAlphaComponent(0.5),
        selection: NSColor(hex: "#44475a"),
        keywords: .init(color: NSColor(hex: "#ff79c6")),
        commands: .init(color: NSColor(hex: "#8be9fd")),
        types: .init(color: NSColor(hex: "#8be9fd")),
        attributes: .init(color: NSColor(hex: "#50fa7b")),
        variables: .init(color: .white),
        values: .init(color: NSColor(hex: "#f1fa8c")),
        numbers: .init(color: NSColor(hex: "#bd93f9")),
        strings: .init(color: NSColor(hex: "#f1fa8c")),
        characters: .init(color: NSColor(hex: "#f1fa8c")),
        comments: .init(color: NSColor(hex: "#6272a4"))
    )
}

/// This extension provides a shared helper for creating NSColor instances from hex strings.
extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
