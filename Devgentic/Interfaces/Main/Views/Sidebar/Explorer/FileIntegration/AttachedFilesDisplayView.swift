// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachedFilesDisplayView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct AttachedFilesDisplayView: View {
    let attachedFiles: [FileSystemItem]
    var onRemoveFile: (FileSystemItem) -> Void // Action to pass to each pill

    var body: some View {
        // Only show the scroll view if there are files to display
        if !attachedFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachedFiles) { fileItem in
                        AttachedFilePillView(
                            fileItem: fileItem,
                            onRemove: {
                                onRemoveFile(fileItem)
                            }
                        )
                        // Add a unique ID for ForEach if FileSystemItem's id isn't always unique
                        // or if you encounter issues with updates. Here, fileItem.id is assumed to be unique.
                    }
                }
                .padding(.horizontal, 10) // Add some horizontal padding to the HStack
                .padding(.vertical, 5)    // Add a little vertical padding if needed
            }
            .frame(height: 50) // Constrain the height of the scrollable area; adjust as needed
            // .background(Color.gray.opacity(0.1)) // Optional: for debugging layout
        } else {
            EmptyView() // Don't take up space if there are no files
        }
    }
}

// MARK: - Preview Provider
struct AttachedFilesDisplayView_Previews: PreviewProvider {
    static func createPreviewItem(name: String, ext: String) -> FileSystemItem {
        let tempDir = FileManager.default.temporaryDirectory
        let dummyURL = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
         if !FileManager.default.fileExists(atPath: dummyURL.path) {
            try? "dummy content".write(to: dummyURL, atomically: true, encoding: .utf8)
        }
        return FileSystemItem(id: dummyURL, name: "\(name).\(ext)", url: dummyURL, isDirectory: false)
    }

    @State static var previewFiles: [FileSystemItem] = [
        createPreviewItem(name: "AIConnect", ext: "swift"),
        createPreviewItem(name: "DevgenticApp", ext: "swift"),
        createPreviewItem(name: "ProjectPlan", ext: "pdf"),
        createPreviewItem(name: "UserFlow", ext: "png"),
        createPreviewItem(name: "Notes", ext: "txt")
    ]
    
    @State static var fewFiles: [FileSystemItem] = [
        createPreviewItem(name: "Readme", ext: "md")
    ]
    
    @State static var noFiles: [FileSystemItem] = []


    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Display with Multiple Files:")
                .font(.headline)
            AttachedFilesDisplayView(
                attachedFiles: previewFiles,
                onRemoveFile: { fileItem in
                    print("Preview: Remove \(fileItem.name)")
                    previewFiles.removeAll(where: { $0.id == fileItem.id })
                }
            )

            Text("Display with Few Files:")
                .font(.headline)
            AttachedFilesDisplayView(
                attachedFiles: fewFiles,
                onRemoveFile: { fileItem in
                    print("Preview: Remove \(fileItem.name)")
                    fewFiles.removeAll(where: { $0.id == fileItem.id })
                }
            )
            
            Text("Display with No Files:")
               .font(.headline)
            AttachedFilesDisplayView(
                attachedFiles: noFiles,
                onRemoveFile: { _ in }
            )

            Spacer()
        }
        .padding()
        .previewLayout(.sizeThatFits)
        .frame(width: 400) // Simulate a typical width for this component
    }
}
