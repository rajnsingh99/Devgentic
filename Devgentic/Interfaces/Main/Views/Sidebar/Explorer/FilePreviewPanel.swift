//
//  FilePreviewPanel.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import SwiftUI

struct FilePreviewPanel: View {
    let file: FileSystemItem
    @State private var previewText: String?
    @State private var isLoading = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: file.iconName)
                    .foregroundColor(file.iconColor(for: theme))
                Text(file.name)
                    .font(.headline)
                Spacer()
            }
            .foregroundColor(theme.primaryText)

            Divider()

            // Content
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Extracting...")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let text = previewText {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            } else {
                Text("No preview available for this file type.")
                    .foregroundColor(theme.secondaryText)
                    .font(.caption)
            }
        }
        .padding()
        .frame(width: 420)
        .task {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        isLoading = true
        defer { isLoading = false }

        let registry = DocumentExtractionRegistry.shared
        guard registry.canExtract(from: file.url) else { return }

        // Security-scoped access for sandboxed files
        let didStartAccess = file.url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { file.url.stopAccessingSecurityScopedResource() }
        }

        do {
            let result = try await registry.extract(from: file.url, maxSize: 2_000)
            previewText = result.text
        } catch {
            previewText = "Extraction error: \(error.localizedDescription)"
        }
    }
}
