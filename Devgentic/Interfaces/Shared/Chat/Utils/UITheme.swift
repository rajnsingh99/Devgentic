//
//  UITheme.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//

import SwiftUI

struct UITheme {

    // MARK: - Color Palette
    struct Colors {
        static let primaryText = Color(NSColor.labelColor)
        static let secondaryText = Color(NSColor.secondaryLabelColor)
        static let tertiaryText = Color(NSColor.tertiaryLabelColor)
        
        static let background = Color(NSColor.windowBackgroundColor)
        static let controlBackground = Color(NSColor.controlBackgroundColor)
        static let textBackground = Color(NSColor.textBackgroundColor)

        // UPDATED: Changed to a muted teal for a modern, tech-focused feel.
        static let accent = Color(hex: "#388E8E")
        static let userBubbleBackground = Color(hex: "#388E8E")
        static let attachmentBackground = Color(NSColor.controlBackgroundColor).opacity(0.7)
        
        // EDIT: Changed to a solid dark background and added a new text color.
        static let inlineCodeBackground = Color(red: 0.2, green: 0.2, blue: 0.22)
        static let inlineCodeText = Color(red: 0.9, green: 0.9, blue: 0.9)
        
        static let accentMuted = Color(hex: "#388E8E").opacity(0.7)
        
        static let success = Color.green
        static let error = Color.red
    }

    // MARK: - Font Styles
    struct Fonts {
        static let largeTitle = Font.system(size: 32, weight: .bold)
        static let title1 = Font.system(size: 26, weight: .bold)
        static let title2 = Font.system(size: 20, weight: .semibold)
        static let title3 = Font.system(size: 18, weight: .semibold)
        
        static let headline = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular) // Changed from 14 to 15
        static let callout = Font.system(size: 14, weight: .regular)
        static let subheadline = Font.system(size: 14, weight: .regular)
        
        static let footnote = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 12, weight: .regular)
        static let caption2 = Font.system(size: 11, weight: .regular)
        
        static let code = Font.system(size: 13, weight: .regular, design: .monospaced) // Changed from 12 to 13
        static let codeCaption = Font.system(size: 10, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing
    /// Standardized spacing values for layout consistency.
    struct Spacing {
        /// 2 points
        static let xxsmall: CGFloat = 2
        /// 4 points
        static let xsmall: CGFloat = 4
        /// 8 points
        static let small: CGFloat = 8
        /// 12 points
        static let medium: CGFloat = 10
        /// 16 points
        static let large: CGFloat = 14
        /// 24 points
        static let xlarge: CGFloat = 20
        /// 32 points
        static let xxlarge: CGFloat = 28
    }
    
    // MARK: - Corner Radius
    struct CornerRadius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 16
    }
}

// REMOVED: The duplicate Color extension that was causing the build errors.
// The project likely already has a similar helper defined elsewhere.
