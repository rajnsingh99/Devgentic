//
//  FileAttachmentCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//

import SwiftUI

/// A stylish, enhanced card for displaying a user-attached file, matching the new design.
/// It now includes a file-type specific icon, a description, and a colored border.
struct FileAttachmentCardView: View {
    let fileName: String
    let action: () -> Void

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
    private var fileTypeInfo: FileTypeInfo {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let orangeAccent = Color(red: 237/255, green: 134/255, blue: 80/255)

        switch fileExtension {
        case "swift":
            return FileTypeInfo(iconName: "swift", description: "Swift Source Code", accentColor: orangeAccent)
        case "py":
            return FileTypeInfo(iconName: "chevron.left.forwardslash.chevron.right", description: "Python Source Code", accentColor: .blue)
        case "js", "ts", "jsx", "tsx":
            return FileTypeInfo(iconName: "curlybraces", description: "JavaScript/TS Code", accentColor: .yellow)
        case "java":
            return FileTypeInfo(iconName: "cup.and.saucer.fill", description: "Java Source Code", accentColor: .red)
        case "html":
            return FileTypeInfo(iconName: "chevron.left.slash.chevron.right", description: "HTML Document", accentColor: orangeAccent)
        case "css":
            return FileTypeInfo(iconName: "number", description: "CSS Stylesheet", accentColor: .blue)
        case "md", "markdown":
            return FileTypeInfo(iconName: "text.book.closed.fill", description: "Markdown Document", accentColor: .gray)
        case "txt":
            return FileTypeInfo(iconName: "doc.text.fill", description: "Text File", accentColor: .primary)
        default:
            return FileTypeInfo(iconName: "doc.fill", description: "File Attachment", accentColor: .gray)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: UITheme.Spacing.small) {
                Image(systemName: fileTypeInfo.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(fileTypeInfo.accentColor) // Use accent color for the icon
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    // Use the new `displayName` computed property
                    Text(displayName)
                        .font(UITheme.Fonts.footnote.weight(.bold))
                        .foregroundColor(UITheme.Colors.primaryText)
                        .lineLimit(1)

                    Text(fileTypeInfo.description)
                        .font(UITheme.Fonts.caption2)
                        .foregroundColor(UITheme.Colors.secondaryText)
                }
            }
            .padding(.horizontal, UITheme.Spacing.medium)
            .padding(.vertical, UITheme.Spacing.small + 2)
        }
        .buttonStyle(.plain)
        // Set the background to match other control elements
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(UITheme.CornerRadius.medium)
        // Add an overlay for the border using the accent color
        .overlay(
            RoundedRectangle(cornerRadius: UITheme.CornerRadius.medium)
                .stroke(fileTypeInfo.accentColor, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }
}

// MARK: - Preview Provider
struct FileAttachmentCardView_Previews: PreviewProvider {
    static var previews: some View {
        // Wrap in a ScrollView to demonstrate horizontal layout
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
        .background(Color(NSColor.windowBackgroundColor))
        .previewLayout(.sizeThatFits)
        .preferredColorScheme(.dark)
    }
}
