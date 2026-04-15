//
//  AttachedFilePillView.swift
//  Devgentic
//
//  Created by Raj Singh on 14/05/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct AttachedFilePillView: View {
    let fileItem: FileSystemItem
    var onRemove: () -> Void

    // Explicit initializer to resolve 'inaccessible due to private protection level' error
    init(fileItem: FileSystemItem, onRemove: @escaping () -> Void) {
        self.fileItem = fileItem
        self.onRemove = onRemove
    }

    // MARK: - State
    @State private var isHovering: Bool = false
    @State private var isRemoveButtonHovering: Bool = false
    @Environment(\.appTheme) private var theme

    // MARK: - Modern Styling Constants
    private var pillBackgroundColor: Color {
        // Adapts to light/dark mode automatically
        isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05)
    }
    
    private var pillBorderColor: Color {
        isHovering ? Color.primary.opacity(0.15) : Color.primary.opacity(0.08)
    }

    private var pillCornerRadius: CGFloat = 10.0
    private var iconSize: CGFloat = 16

    // Determine the icon displayed in the pill
    private var displayIconName: String {
        if let type = UTType(filenameExtension: fileItem.url.pathExtension),
           type.conforms(to: .sourceCode) || type.conforms(to: .text) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return fileItem.iconName
    }
    
    private var displayIconFontWeight: Font.Weight {
        if let type = UTType(filenameExtension: fileItem.url.pathExtension),
           type.conforms(to: .sourceCode) || type.conforms(to: .text) {
            return .semibold
        }
        return .regular
    }

    private var displayName: String {
        if fileItem.isDirectory {
            return fileItem.name
        } else {
            return (fileItem.name as NSString).deletingPathExtension
        }
    }

    // MARK: - Body
    var body: some View {
        HStack(spacing: 10) {
            // File Icon
            // Modern twist: Use accent color for the icon instead of the background
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 28, height: 28)

                Image(systemName: displayIconName)
                    .font(.system(.caption, weight: displayIconFontWeight))
                    .foregroundColor(theme.accentColor)
            }

            // File Name and Type
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileItem.fileTypeDescription.uppercased())
                    .font(.system(size: 9, weight: .semibold)) // Fixed size: intentional (badge/chip text)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Remove Button
            // Hidden by default, becomes prominent on pill hover, red on button hover
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold)) // Fixed size: intentional (small remove icon)
                    .foregroundColor(isRemoveButtonHovering ? .white : theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isRemoveButtonHovering ? theme.errorColor.opacity(0.9) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle()) // Increases hit area
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.15)) { isRemoveButtonHovering = hover }
            }
            .accessibilityLabel("Remove \(fileItem.name)")
        }
        .padding(.leading, 6) // Less padding left because icon container has its own spacing
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(pillBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: pillCornerRadius)
                .stroke(pillBorderColor, lineWidth: 1)
        )
        // Subtle scale effect on hover for "tactile" feel
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .onHover { hover in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hover }
        }
        .frame(maxWidth: 260)
    }
}

// MARK: - Preview Provider
struct AttachedFilePillView_Previews: PreviewProvider {
    static func createDummyFile(name: String, ext: String, isDir: Bool = false) -> FileSystemItem {
        let tempDir = FileManager.default.temporaryDirectory
        var actualName = name
        if !ext.isEmpty {
            actualName = "\(name).\(ext)"
        }
        let dummyURL = tempDir.appendingPathComponent(actualName)
        
        if !isDir && !FileManager.default.fileExists(atPath: dummyURL.path) {
            try? "dummy content for \(actualName)".write(to: dummyURL, atomically: true, encoding: .utf8)
        }
        return FileSystemItem(id: dummyURL, name: actualName, url: dummyURL, isDirectory: isDir)
    }

    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Modern File Pills")
                .font(.headline)
                .padding(.bottom, 5)

            AttachedFilePillView(
                fileItem: createDummyFile(name: "AIConnect", ext: "swift"),
                onRemove: { print("Remove AIConnect.swift") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "MyDocument", ext: "pdf"),
                onRemove: { print("Remove MyDocument.pdf") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "archive", ext: "zip"),
                onRemove: { print("Remove archive.zip") }
            )
            
            Text("Long Filename Handling:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "VeryLongFileNameThatDefinitelyNeedsTruncationAndShouldBeHandledGracefully", ext: "js"),
                onRemove: { print("Remove JS file") }
            )
        }
        .padding(30)
        .background(AppThemes.DefaultTheme().primaryBackground) // Preview-only
        .previewLayout(.sizeThatFits)
        .frame(width: 350)
    }
}
