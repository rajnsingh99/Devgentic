//
//  AttachedFilePillView.swift
//  Devgentic
//
//  Created by Raj Singh on 14/05/25.
//

import SwiftUI
import UniformTypeIdentifiers // Already imported, but good to ensure

struct AttachedFilePillView: View {
    let fileItem: FileSystemItem
    var onRemove: () -> Void

    // Pill styling constants based on Screenshot 2
    private var pillBackgroundColor: Color {
        // Extracted from screenshot: A vibrant orange
        Color(red: 237/255, green: 134/255, blue: 80/255)
    }
    
    private var pillForegroundColor: Color {
        .white // Text and primary icon color
    }
    
    private var pillCornerRadius: CGFloat = 7.0 // Slightly rounded corners
    private var iconSize: CGFloat = 18 // Adjusted icon size

    // Determine the icon displayed in the pill
    private var displayIconName: String {
        // If it's source code, use a symbol that resembles "< / >"
        // "chevron.left.forwardslash.chevron.right" is an SF Symbol that looks somewhat like it.
        // "curlybraces" or "scroll" could also be alternatives for code.
        // For an exact match, a custom asset might be needed.
        if let type = UTType(filenameExtension: fileItem.url.pathExtension),
           type.conforms(to: .sourceCode) || type.conforms(to: .text) { // Broader check for text-based files for this icon
            return "chevron.left.forwardslash.chevron.right" // SF Symbol proxy for "< / >"
        }
        return fileItem.iconName // Fallback to FileSystemItem's default icon logic
    }
    
    private var displayIconFontWeight: Font.Weight {
        if let type = UTType(filenameExtension: fileItem.url.pathExtension),
           type.conforms(to: .sourceCode) || type.conforms(to: .text) {
            return .semibold // Make the code icon a bit bolder
        }
        return .regular
    }

    // MARK: - Initializer
    // Explicit public initializer to ensure accessibility, especially for Previews.
    // Swift's default memberwise initializer can sometimes have its access level
    // inferred in a way that makes it inaccessible if the struct contains private properties,
    // even if those private properties have default values or are computed.
    init(fileItem: FileSystemItem, onRemove: @escaping () -> Void) {
        self.fileItem = fileItem
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 6) { // Consistent spacing
            // File Icon
            Image(systemName: displayIconName)
                .font(.system(size: iconSize, weight: displayIconFontWeight))
                .foregroundColor(pillForegroundColor) // Icon color matches text
                .frame(width: iconSize + 4, alignment: .center) // Give icon a bit of breathing room

            // File Name and Type
            VStack(alignment: .leading, spacing: 1) { // Reduced spacing for tighter look
                Text(fileItem.name)
                    .font(.system(size: 12.5, weight: .medium)) // Slightly adjusted font
                    .foregroundColor(pillForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileItem.fileTypeDescription) // Using the enhanced description
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(pillForegroundColor.opacity(0.85)) // Slightly less prominent
                    .lineLimit(1)
            }

            Spacer(minLength: 6) // Ensure some space before the remove button

            // Remove Button
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold)) // Smaller, bolder xmark
                    .foregroundColor(pillForegroundColor.opacity(0.75)) // XMark color
                    .padding(4) // Slightly smaller padding for the circle
                    .background(pillForegroundColor.opacity(0.2)) // Subtle background for the 'x'
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(fileItem.name)")
        }
        .padding(.horizontal, 10) // Horizontal padding inside the pill
        .padding(.vertical, 7)   // Vertical padding inside the pill
        .background(pillBackgroundColor)
        .cornerRadius(pillCornerRadius)
        // Removed shadow as it's not prominent in the target screenshot for pills
        // .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Preview Provider
struct AttachedFilePillView_Previews: PreviewProvider {
    // Using the enhanced FileSystemItem from this phase for previews
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
            Text("Styled File Pills (Phase 4)")
                .font(.headline)
                .padding(.bottom, 5)

            AttachedFilePillView(
                fileItem: createDummyFile(name: "AIConnect", ext: "swift"),
                onRemove: { print("Remove AIConnect.swift") }
            )

            AttachedFilePillView(
                fileItem: createDummyFile(name: "DevgenticApp", ext: "swift"),
                onRemove: { print("Remove DevgenticApp.swift") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "MyDocument", ext: "pdf"),
                onRemove: { print("Remove MyDocument.pdf") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "ProjectRequirements", ext: "docx"),
                onRemove: { print("Remove ProjectRequirements.docx") }
            )

            AttachedFilePillView(
                fileItem: createDummyFile(name: "notes", ext: "txt"),
                onRemove: { print("Remove notes.txt") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "assets", ext: "", isDir: true),
                onRemove: { print("Remove assets folder") }
            )
            
            AttachedFilePillView(
                fileItem: createDummyFile(name: "archive", ext: "zip"),
                onRemove: { print("Remove archive.zip") }
            )
            
            Text("Example with longer names:")
                .font(.caption)
            AttachedFilePillView(
                fileItem: createDummyFile(name: "VeryLongFileNameThatDefinitelyNeedsTruncation", ext: "js"),
                onRemove: { print("Remove JS file") }
            )


        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3)) // Neutral background for preview
        .previewLayout(.sizeThatFits)
        .frame(width: 300) // Constrain width for better preview of pills
    }
}
