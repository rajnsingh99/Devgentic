//
//  FileAttachmentCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//

import SwiftUI

// MARK: - File Type Identity Colors
// Domain-specific colors for file type badges. Not themed — these are stable brand/identity colors
// that should be consistent regardless of light/dark mode or theme selection.
private enum FileTypeColor {
    static let swift  = Color(red: 237/255, green: 134/255, blue: 80/255) // Swift orange
    static let python = Color.blue
    static let jsTsx  = Color.yellow
    static let java   = Color.red
    static let html   = Color(red: 237/255, green: 134/255, blue: 80/255) // HTML orange
    static let css    = Color.blue
    static let docs   = Color.gray
    static let text   = Color.primary
}

/// A stylish, enhanced card for displaying a user-attached file, matching the new design.
/// It now includes a file-type specific icon, a description, and a colored border.
struct FileAttachmentCardView: View {
    let fileName: String
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    /// A private struct to hold display information based on the file type.
    private struct FileTypeInfo {
        let iconName: String
        let description: String
        let accentColor: Color
    }

    /// The file name without its extension.
    private var displayName: String {
        return (fileName as NSString).deletingPathExtension
    }

    /// Determines the icon, description, and color based on the file's extension.
    /// Uses domain-specific identity colors via FileTypeColor constants.
    private var fileTypeInfo: FileTypeInfo {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()

        switch fileExtension {
        case "swift":
            return FileTypeInfo(iconName: "swift", description: "Swift Source Code", accentColor: FileTypeColor.swift)
        case "py":
            return FileTypeInfo(iconName: "chevron.left.forwardslash.chevron.right", description: "Python Source Code", accentColor: FileTypeColor.python)
        case "js", "ts", "jsx", "tsx":
            return FileTypeInfo(iconName: "curlybraces", description: "JavaScript/TS Code", accentColor: FileTypeColor.jsTsx)
        case "java":
            return FileTypeInfo(iconName: "cup.and.saucer.fill", description: "Java Source Code", accentColor: FileTypeColor.java)
        case "html":
            return FileTypeInfo(iconName: "chevron.left.slash.chevron.right", description: "HTML Document", accentColor: FileTypeColor.html)
        case "css":
            return FileTypeInfo(iconName: "number", description: "CSS Stylesheet", accentColor: FileTypeColor.css)
        case "md", "markdown":
            return FileTypeInfo(iconName: "text.book.closed.fill", description: "Markdown Document", accentColor: FileTypeColor.docs)
        case "txt":
            return FileTypeInfo(iconName: "doc.text.fill", description: "Text File", accentColor: FileTypeColor.text)
        default:
            return FileTypeInfo(iconName: "doc.fill", description: "File Attachment", accentColor: FileTypeColor.docs)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.spacingSmall) {
                Image(systemName: fileTypeInfo.iconName)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(fileTypeInfo.accentColor) // Use accent color for the icon
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(theme.fontFootnote.weight(.bold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(fileTypeInfo.description)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(.horizontal, theme.spacingMedium)
            .padding(.vertical, theme.spacingSmall + 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fileTypeInfo.description): \(fileName)")
        .accessibilityHint("Double-tap to open file")
        .accessibilityAddTraits(.isButton)
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                .stroke(fileTypeInfo.accentColor, lineWidth: 1.5)
        )
        .shadow(color: theme.primaryText.opacity(0.05), radius: 2, y: 1)
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
        .environment(\.appTheme, AppThemes.DefaultTheme())
        .previewLayout(.sizeThatFits)
        .preferredColorScheme(.dark)
    }
}
