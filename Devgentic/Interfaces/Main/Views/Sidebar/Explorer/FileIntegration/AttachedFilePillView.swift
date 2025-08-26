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

    // Pill styling constants
    private var pillBackgroundColor: Color {
        Color(red: 237/255, green: 134/255, blue: 80/255)
    }
    
    private var pillForegroundColor: Color {
        .white
    }
    
    private var pillCornerRadius: CGFloat = 7.0
    private var iconSize: CGFloat = 18

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

    init(fileItem: FileSystemItem, onRemove: @escaping () -> Void) {
        self.fileItem = fileItem
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 6) {
            // File Icon
            Image(systemName: displayIconName)
                .font(.system(size: iconSize, weight: displayIconFontWeight))
                .foregroundColor(pillForegroundColor)
                .frame(width: iconSize + 4, alignment: .center)

            // File Name and Type
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName) // Use the name without the extension
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(pillForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileItem.fileTypeDescription)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(pillForegroundColor.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Remove Button
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(pillForegroundColor.opacity(0.75))
                    .padding(4)
                    .background(pillForegroundColor.opacity(0.2))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(fileItem.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(pillBackgroundColor)
        .cornerRadius(pillCornerRadius)
        .frame(maxWidth: 250) // Constrain the maximum width of the pill
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
        } else if isDir {
            // For directories, ensure the name doesn't have an extension unless intended
        }
        return FileSystemItem(id: dummyURL, name: actualName, url: dummyURL, isDirectory: isDir)
    }

    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Styled File Pills (No Extensions)")
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
            
            Text("Example with longer names:")
                .font(.caption)
            AttachedFilePillView(
                fileItem: createDummyFile(name: "VeryLongFileNameThatDefinitelyNeedsTruncationAndShouldBeHandledGracefully", ext: "js"),
                onRemove: { print("Remove JS file") }
            )
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .previewLayout(.sizeThatFits)
        .frame(width: 300)
    }
}
