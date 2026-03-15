//
//  MediaArtifactImageView.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Rich image rendering component for MediaArtifact images in chat.
//  Displays generated images with metadata overlay and context menu.
//

import SwiftUI
import AppKit

struct MediaArtifactImageView: View {
    let artifact: MediaArtifact
    @Environment(\.appTheme) private var theme
    @State private var loadedImage: NSImage?
    @State private var isHovering = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Image Display
            ZStack {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 512, maxHeight: 512)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if isHovering {
                                metadataOverlay
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                } else if let error = loadError {
                    errorPlaceholder(error)
                } else {
                    loadingPlaceholder
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
            .contextMenu {
                contextMenuItems
            }

            // Label
            if let label = artifact.label, !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .task {
            await loadImage()
        }
    }

    // MARK: - Image Loading

    private func loadImage() async {
        do {
            let data = try await artifact.reference.resolve()
            if let image = NSImage(data: data) {
                await MainActor.run {
                    self.loadedImage = image
                }
            } else {
                await MainActor.run {
                    self.loadError = "Could not decode image data"
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Subviews

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.secondaryBackground)
            .frame(width: 256, height: 256)
            .overlay(
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading image...")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            )
    }

    private func errorPlaceholder(_ error: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.secondaryBackground)
            .frame(width: 256, height: 128)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("Failed to load image")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .lineLimit(2)
                }
                .padding()
            )
    }

    private var metadataOverlay: some View {
        HStack(spacing: 8) {
            if let model = artifact.metadata["model"]?.stringValue {
                Text(model)
                    .font(.system(size: 10, weight: .medium))
            }
            if let provider = artifact.metadata["provider"]?.stringValue {
                Text(provider)
                    .font(.system(size: 10))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
        .padding(8)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            saveToDownloads()
        } label: {
            Label("Save to Downloads", systemImage: "arrow.down.to.line")
        }

        Button {
            copyImage()
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Actions

    private func saveToDownloads() {
        guard let image = loadedImage else { return }
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fileName = "devgentic-image-\(artifact.id.uuidString.prefix(8)).png"
        let fileURL = downloadsURL.appendingPathComponent(fileName)

        if let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }
    }

    private func copyImage() {
        guard let image = loadedImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

