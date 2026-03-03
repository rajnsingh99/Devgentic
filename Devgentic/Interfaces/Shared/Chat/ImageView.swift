//
//  ImageView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/08/25.
//
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ImageView")

struct ImageView: View {
    let imageData: Data

    @State private var isHovering = false
    @State private var didCopy = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Attempt to create an NSImage from the provided raw data.
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(theme.cornerRadiusMedium)
                    .overlay(
                        // Add a subtle border to frame the image nicely.
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .stroke(theme.dividerColor, lineWidth: 1)
                    )
            } else {
                // Error State: Display a placeholder if image data is invalid.
                VStack(spacing: theme.spacingXSmall) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundColor(theme.secondaryText)
                    Text("Failed to load image data")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: 500, minHeight: 150, alignment: .center)
                .background(theme.controlBackground)
                .cornerRadius(theme.cornerRadiusMedium)
                .onAppear {
                    logger.error("❌ Failed to create NSImage from the provided data.")
                }
            }

            // Action button overlay that appears on hover.
            if isHovering {
                // --- CHANGE: Added Copy and Generate Variations buttons ---
                HStack(spacing: theme.spacingSmall) {
                    ActionButton(action: copyImageToClipboard) {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(didCopy ? theme.successColor : .white)
                    .help("Copy Image to Clipboard")

                    ActionButton(action: {
                        // TODO: Implement variation generation logic
                    }) {
                        Label("Variations", systemImage: "wand.and.rays")
                    }
                    .foregroundColor(.white)
                    .help("Generate Variations (not implemented)")

                    ActionButton(action: saveImage) {
                        Image(systemName: "arrow.down.circle")
                    }
                    .foregroundColor(.white)
                    .help("Save Image")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, theme.spacingXSmall)
                .padding(.horizontal, theme.spacingSmall)
                .background(Color.black.opacity(0.6))
                .cornerRadius(theme.cornerRadiusLarge)
                .padding(theme.spacingSmall)
                .transition(.opacity.animation(.easeInOut))
            }
        }
        .onHover { hovering in
            withAnimation {
                isHovering = hovering
            }
        }
    }

    /// Copies the generated image to the system clipboard.
    private func copyImageToClipboard() {
        guard let nsImage = NSImage(data: imageData) else {
            logger.error("❌ Failed to create NSImage for clipboard.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])

        logger.info("✅ Image copied to clipboard.")

        // Provide visual feedback to the user.
        withAnimation(.easeInOut) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut) { didCopy = false }
        }
    }

    /// Opens an NSSavePanel to allow the user to save the image to disk.
    private func saveImage() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "generated-image-\(UUID().uuidString.prefix(6)).png"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try imageData.write(to: url)
                    logger.info("✅ Image saved successfully to \(url.path)")
                } catch {
                    logger.error("❌ Failed to save image: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Reusable Action Button View
fileprivate struct ActionButton<LabelContent: View>: View {
    let action: () -> Void
    @ViewBuilder let label: LabelContent

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering ? theme.secondaryText.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}
