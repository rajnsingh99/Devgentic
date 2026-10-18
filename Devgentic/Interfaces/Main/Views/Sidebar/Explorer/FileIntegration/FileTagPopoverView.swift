// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileTagPopoverView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit // For NSPasteboard

struct FileTagPopoverView: View {
    let fileItem: FileSystemItem
    var dismissAction: () -> Void // Action to dismiss the popover

    @State private var fullPathCopied: Bool = false
    @State private var contentPreview: String? = nil
    @State private var isLoadingPreview: Bool = false
    @State private var previewError: String? = nil

    private func loadContentPreview() {
        isLoadingPreview = true
        previewError = nil
        
        Task {
            let didStartAccess = fileItem.url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { fileItem.url.stopAccessingSecurityScopedResource() }
            }

            if didStartAccess {
                do {
                    let data = try Data(contentsOf: fileItem.url)
                    if let stringContent = String(data: data, encoding: .utf8) {
                        await MainActor.run {
                            self.contentPreview = String(stringContent.prefix(1000))
                            if stringContent.count > 1000 {
                                self.contentPreview! += "\n\n--- (Preview truncated) ---"
                            }
                        }
                    } else {
                        await MainActor.run {
                            self.contentPreview = "--- (Binary content or unsupported encoding) ---"
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.previewError = "Error reading file: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    self.previewError = "Could not access file for preview."
                }
            }
            await MainActor.run {
                isLoadingPreview = false
            }
        }
    }

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: fileItem.iconName)
                    .foregroundColor(theme.secondaryText)
                    .accessibilityHidden(true)
                Text(fileItem.name)
                    .font(theme.fontHeadline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                TactileIconButton(icon: "xmark", tooltip: "Close", size: .compact) {
                    dismissAction()
                }
            }

            Text("Path: \(fileItem.url.path)")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            
            HStack(spacing: 8) {
                TactileButton(
                    title: fullPathCopied ? "Path Copied!" : "Copy Path",
                    icon: fullPathCopied ? "checkmark.circle.fill" : "doc.on.doc",
                    variant: fullPathCopied ? .primary : .secondary,
                    size: .compact
                ) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(fileItem.url.path, forType: .string)
                    fullPathCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        fullPathCopied = false
                    }
                }
                
                TactileButton(
                    title: "Open in Finder",
                    icon: "folder",
                    variant: .subtle,
                    size: .compact
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileItem.url])
                    dismissAction()
                }
            }
            
            Divider()
                .overlay(theme.dividerColor)

            if let preview = contentPreview {
                Text("Content Preview:")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                ScrollView {
                    Text(preview)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(theme.surfaceOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxHeight: 150)
            } else if isLoadingPreview {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview...")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
            } else if let error = previewError {
                 Text("Preview Error:")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.errorColor)
                 Text(error)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.errorColor)
            } else {
                TactileButton(
                    title: "Show Content Preview",
                    icon: "eye",
                    variant: .secondary,
                    size: .compact
                ) {
                    loadContentPreview()
                }
            }
        }
        .padding()
        .background(theme.secondaryBackground)
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 450)
        .onAppear(perform: loadContentPreview)
    }
}

struct FileTagPopoverView_Previews: PreviewProvider {
    // Corrected: Call createDummyFile() as part of sampleFile initialization
    static let sampleFile: FileSystemItem = {
        createDummyFile() // Ensure dummy file is created before sampleFile is fully initialized
        return FileSystemItem(
            id: URL(fileURLWithPath: "/tmp/sample.txt"),
            name: "sample_document_for_preview.txt",
            url: URL(fileURLWithPath: "/tmp/sample.txt"),
            isDirectory: false
        )
    }()
    
    static func createDummyFile() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.txt")
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            try? "This is a sample text file for SwiftUI preview purposes.\nIt contains multiple lines.\nHello, World!".write(to: dummyURL, atomically: true, encoding: .utf8)
        }
    }

    static var previews: some View {
        // Now the previews body only contains the View, and sampleFile is already set up.
        FileTagPopoverView(fileItem: sampleFile, dismissAction: { print("Preview dismiss") })
            .previewLayout(.sizeThatFits)
            .padding()
    }
}
