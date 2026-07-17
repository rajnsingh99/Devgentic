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
    @State private var loadedData: Data?
    @State private var isHovering = false
    @State private var loadError: String?
    @State private var showLightbox = false
    @State private var saveError: String?
    @State private var savedURL: URL?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Image Display
            ZStack {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: ChatUIConstants.imageMaxWidth,
                               maxHeight: ChatUIConstants.imageMaxWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { showLightbox = true }
                        .accessibilityLabel(imageAccessibilityLabel)
                        .accessibilityAddTraits([.isImage, .isButton])
                        .accessibilityHint("Opens the image at full size")
                        // `.onTapGesture` isn't bridged to an accessibility action — without
                        // this the hint promises an action VO-Space can't perform.
                        .accessibilityAction { showLightbox = true }
                        .shadow(color: theme.shadowColor, radius: 8, x: 0, y: 4)
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
                        // Hover toolbar, ported from the retired legacy renderer: the
                        // context menu is complete but undiscoverable, and mouse users
                        // shouldn't need to know to right-click. Mouse-only sugar — the
                        // context menu and accessibility actions remain the reachable
                        // routes (a hover-gated control must never be the ONLY route).
                        .overlay(alignment: .topTrailing) {
                            if isHovering {
                                hoverToolbar
                                    .transition(.opacity)
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

            // A save used to leave no trace whether it worked or not. Failures raise an
            // alert; successes say where the file went, then get out of the way.
            if let savedURL {
                Label("Saved to \(savedURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(theme.successColor)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                    .task(id: savedURL) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        withAnimation { self.savedURL = nil }
                    }
            }
        }
        // Keyed to the artifact: a bare `.task` runs once per view identity, so when SwiftUI
        // reused this view for a DIFFERENT artifact (same position in a rebuilt list) it kept
        // showing the previous picture forever. ImageView already hit and fixed this.
        .task(id: artifact.id) {
            await loadImage()
        }
        .imageLightbox(isPresented: $showLightbox, image: loadedImage,
                       altText: artifact.label, data: loadedData, mimeType: artifact.mimeType)
        .alert("Couldn't save image", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var imageAccessibilityLabel: String {
        var spoken = String(localized: "Generated image")
        if let label = artifact.label, !label.isEmpty { spoken = String(localized: "Image: \(label)") }
        // The model/provider overlay only exists while the mouse hovers, so this was the
        // one thing about a generated image a non-mouse user could never learn. It's
        // appended rather than given its own element: it's provenance, not a control.
        if !generationProvenance.isEmpty {
            spoken += ". \(generationProvenance)"
        }
        return spoken
    }

    /// The same model/provider shown in the hover overlay, in spoken form.
    private var generationProvenance: String {
        [artifact.metadata["model"]?.stringValue, artifact.metadata["provider"]?.stringValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Image Loading

    private func loadImage() async {
        do {
            let data = try await artifact.reference.resolve()
            // Decoding a full-size bitmap is expensive and was happening on whatever
            // context resolve() returned on — off-main keeps a large artifact from
            // stalling the bubble it's rendering into.
            let image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard !Task.isCancelled else { return }

            if let image {
                self.loadedImage = image
                self.loadedData = data      // keep the ORIGINAL bytes for a lossless save
                self.loadError = nil
            } else {
                self.loadError = String(localized: "Could not decode image data")
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.loadError = error.localizedDescription
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

    /// The shared error card, not a bespoke one. The old placeholder was a fixed
    /// 256×128 tile that truncated the reason to TWO lines with no expand, no copy, and
    /// no way to retry — a dead end that also announced nothing. ErrorMessageView brings
    /// copy + the VoiceOver announcement for free, and the reference resolve is genuinely
    /// retriable (a file on disk can be back on the next read).
    private func errorPlaceholder(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorMessageView(
                title: String(localized: "Failed to load image"),
                details: error,
                category: .imageResolutionFailed
            )
            RetryMessageButton {
                loadError = nil   // back to the loading placeholder while we re-resolve
                loadedImage = nil
                Task { await loadImage() }
            }
        }
        .frame(maxWidth: ChatUIConstants.imageMaxWidth, alignment: .leading)
    }

    private var metadataOverlay: some View {
        HStack(spacing: 8) {
            if let model = artifact.metadata["model"]?.stringValue {
                Text(model)
                    .font(.system(.caption2, weight: .medium))
            }
            if let provider = artifact.metadata["provider"]?.stringValue {
                Text(provider)
                    .font(.system(.caption2))
            }
        }
        .foregroundColor(.white)
        // Hidden because `imageAccessibilityLabel` already speaks this — leaving it visible
        // to VoiceOver would read the model and provider twice.
        .accessibilityHidden(true)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // MARK: Liquid Glass
        .glassEffect(.regular, in: .rect(cornerRadius: 6))
        // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
        // .background(.ultraThinMaterial)
        // .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            showLightbox = true
        } label: {
            Label("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .disabled(loadedImage == nil)

        Button {
            saveToDownloads()
        } label: {
            Label("Save to Downloads", systemImage: "arrow.down.to.line")
        }
        .disabled(loadedData == nil)

        // Both save flavours, from the two renderers this view unifies: one-click to
        // Downloads (with the confirmation banner) and pick-a-destination.
        Button {
            saveAs()
        } label: {
            Label("Save As…", systemImage: "square.and.arrow.down")
        }
        .disabled(loadedData == nil)

        Button {
            copyImage()
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
        .disabled(loadedImage == nil)
    }

    /// Hover affordance for mouse users; every action here is also in the context menu.
    private var hoverToolbar: some View {
        HStack(spacing: theme.spacingSmall) {
            ImageHoverActionButton(action: { showLightbox = true }) {
                Label("Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("View at full size")

            ImageHoverActionButton(action: copyImage) {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .foregroundColor(didCopy ? theme.successColor : .white)
            .help("Copy Image to Clipboard")

            ImageHoverActionButton(action: saveToDownloads) {
                Image(systemName: "arrow.down.circle")
            }
            .help("Save to Downloads")
        }
        .font(.system(.caption, weight: .medium))
        .foregroundColor(.white)
        .padding(.vertical, theme.spacingXSmall)
        .padding(.horizontal, theme.spacingSmall)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
        .padding(theme.spacingSmall)
        // The context menu + accessibility actions are the reachable routes; exposing a
        // hover-gated duplicate to VoiceOver would only add unreachable noise.
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// Saves the original bytes to Downloads.
    ///
    /// Previously force-unwrapped the Downloads directory (a crash, to save a picture),
    /// re-encoded every artifact to PNG regardless of `mimeType` (recompressing a JPEG and
    /// misnaming the result), and dropped write failures with `try?` — so a save that never
    /// happened looked exactly like one that did.
    private func saveToDownloads() {
        guard let data = loadedData else { return }
        saveError = nil
        savedURL = nil
        do {
            savedURL = try ImageExport.saveToDownloads(
                data: data,
                declaredMimeType: artifact.mimeType,
                baseName: baseName
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var baseName: String {
        guard let label = artifact.label, !label.isEmpty else {
            return "devgentic-image-\(artifact.id.uuidString.prefix(8))"
        }
        let slug = label
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "devgentic-image-\(artifact.id.uuidString.prefix(8))" : String(slug.prefix(60))
    }

    /// Save panel variant — the user picks the destination. The extension still follows
    /// the actual bytes via ImageExport.
    private func saveAs() {
        guard let data = loadedData else { return }
        let panel = ImageExport.savePanel(baseName: baseName, data: data, declaredMimeType: artifact.mimeType)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                savedURL = url
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func copyImage() {
        guard let image = loadedImage else { return }
        ImageExport.copyToPasteboard(image)
        withAnimation(.easeInOut) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut) { didCopy = false }
        }
    }
}

// MARK: - Hover Action Button
/// Ported with the hover toolbar from the retired legacy ImageView.
fileprivate struct ImageHoverActionButton<LabelContent: View>: View {
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

