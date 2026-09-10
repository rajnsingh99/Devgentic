// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileAttachmentCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//

import SwiftUI

// MARK: - Refined File Type Identity Colors
private enum FileTypeColor {
    static let swift  = Color(red: 249/255, green: 115/255, blue: 22/255)  // Warm Coral Orange (#F97316)
    static let python = Color(red: 56/255,  green: 189/255, blue: 248/255) // Sleek Azure (#38BDF8)
    static let jsTsx  = Color(red: 245/255, green: 158/255, blue: 11/255)  // Soft Gold Amber (#F59E0B)
    static let java   = Color(red: 244/255, green: 63/255,  blue: 94/255)  // Rose Crimson (#F43F5E)
    static let html   = Color(red: 249/255, green: 115/255, blue: 22/255)  // Warm Coral Orange (#F97316)
    static let css    = Color(red: 99/255,  green: 102/255, blue: 241/255) // Indigo Modern (#6366F1)
    static let docs   = Color(red: 168/255, green: 162/255, blue: 158/255) // Slate Muted (#A8A29E)
    static let text   = Color.secondary
}

/// A stylish, premium glass card for displaying user-attached files in user prompts.
struct FileAttachmentCardView: View {
    let fileName: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    private struct FileTypeInfo {
        let iconName: String
        let description: String
        let badgeTag: String
        let accentColor: Color
    }

    private var displayName: String {
        return (fileName as NSString).deletingPathExtension
    }

    private var fileTypeInfo: FileTypeInfo {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()

        switch fileExtension {
        case "swift":
            return FileTypeInfo(iconName: "swift", description: "Swift Source Code", badgeTag: "SWIFT", accentColor: FileTypeColor.swift)
        case "py":
            return FileTypeInfo(iconName: "chevron.left.forwardslash.chevron.right", description: "Python Source Code", badgeTag: "PY", accentColor: FileTypeColor.python)
        case "js", "ts", "jsx", "tsx":
            return FileTypeInfo(iconName: "curlybraces", description: "JavaScript/TS Code", badgeTag: fileExtension.uppercased(), accentColor: FileTypeColor.jsTsx)
        case "java":
            return FileTypeInfo(iconName: "cup.and.saucer.fill", description: "Java Source Code", badgeTag: "JAVA", accentColor: FileTypeColor.java)
        case "html":
            return FileTypeInfo(iconName: "chevron.left.slash.chevron.right", description: "HTML Document", badgeTag: "HTML", accentColor: FileTypeColor.html)
        case "css":
            return FileTypeInfo(iconName: "number", description: "CSS Stylesheet", badgeTag: "CSS", accentColor: FileTypeColor.css)
        case "md", "markdown":
            return FileTypeInfo(iconName: "text.book.closed.fill", description: "Markdown Document", badgeTag: "MD", accentColor: FileTypeColor.docs)
        case "txt":
            return FileTypeInfo(iconName: "doc.text.fill", description: "Text File", badgeTag: "TXT", accentColor: FileTypeColor.text)
        default:
            return FileTypeInfo(iconName: "doc.fill", description: "File Attachment", badgeTag: fileExtension.isEmpty ? "FILE" : fileExtension.uppercased(), accentColor: FileTypeColor.docs)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Icon Tile Container
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fileTypeInfo.accentColor.opacity(0.14))
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(fileTypeInfo.accentColor.opacity(0.28), lineWidth: 0.5)
                        )

                    Image(systemName: fileTypeInfo.iconName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(fileTypeInfo.accentColor)
                }

                // File Details
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(fileTypeInfo.description)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }

                // Language Badge
                Text(fileTypeInfo.badgeTag)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(fileTypeInfo.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(fileTypeInfo.accentColor.opacity(0.12)))
                    .overlay(Capsule().stroke(fileTypeInfo.accentColor.opacity(0.25), lineWidth: 0.5))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceOverlay.opacity(isHovering ? 0.75 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? fileTypeInfo.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 0.5)
            )
            .scaleEffect(isHovering ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fileTypeInfo.description): \(fileName)")
        .accessibilityHint("Double-tap to open file")
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview Provider
struct FileAttachmentCardView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FileAttachmentCardView(fileName: "MainApplicationViewModel.swift") {}
                FileAttachmentCardView(fileName: "requirements.txt") {}
                FileAttachmentCardView(fileName: "README.md") {}
                FileAttachmentCardView(fileName: "A_Very_Long_File_Name_That_Should_Be_Truncated.js") {}
            }
            .padding()
        }
        .frame(height: 100)
        .environment(\.appTheme, AppThemes.MaterialTheme())
        .previewLayout(.sizeThatFits)
        .preferredColorScheme(.dark)
    }
}
