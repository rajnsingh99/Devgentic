// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MediaArtifactImageView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "MediaArtifactImage")

// Why: downsampling `loadedImage` would degrade three lossless consumers to save memory for one bounded
// display.
/// Renders a generated image artifact, decoding one full-resolution bitmap that serves the inline draw,
/// the lightbox, Copy Image and Save.
struct MediaArtifactImageView: View {
    let artifact: MediaArtifact
    @Environment(\.appTheme) private var theme
    @State private var loadedImage: NSImage?
    @State private var loadedData: Data?
    @State private var isHovering = false
    @State private var loadError: String?
    /// Whether the current `loadError` could change on a retry.
    /// A non-file `.remoteURL` never resolves, so Retry would fail forever.
    @State private var loadErrorIsRetriable = true
    /// Bumped by Retry so the error card's VoiceOver announcement has a new identity per attempt, defeating
    /// repeat suppression.
    @State private var loadAttempt = 0
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
                        // Hover toolbar: mouse-only sugar over the context menu; the context menu and accessibility actions
                        // remain the reachable routes.
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

            // Failures raise an alert; successes say where the file went, then get out of the way.
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
        // Keyed to the artifact: a bare `.task` runs once per view identity and would keep showing the
        // previous picture when SwiftUI reuses the view.
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
        // Appended to the spoken label: the model/provider overlay shows only on hover, so non-mouse users
        // would never learn it.
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
        // Clears the derived state first: `body` gives `loadedImage` precedence over `loadError`, so a stale
        // bitmap or bytes would survive an artifact change, showing and exporting the previous image.
        loadedImage = nil
        loadedData = nil
        loadError = nil
        loadErrorIsRetriable = true

        let reference = Self.resolvableReference(for: artifact.reference)

        // A genuinely remote reference is a dead end, not a failure: `resolve()` throws for it every time, so
        // the card says so and drops Retry.
        guard !Self.isUnresolvable(reference) else {
            loadError = String(localized: "This image is stored as a link to a remote address, and Devgentic never downloads images from the web.")
            loadErrorIsRetriable = false
            logger.info("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType)) is a non-file remote reference, which is never fetched — a download via MediaStore would have to convert it to a disk path first. CONSEQUENCE: an 'Image not available' card is shown in place of the picture, with NO Retry, because no retry can succeed.")
            return
        }

        do {
            let data = try await reference.resolve()
            // Decodes off-main with `ImageDownsampler.fullSize`; `NSImage(data:)` only parses headers and
            // materialises pixels on first draw.
            let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.fullSize(from: data) }.value
            guard !Task.isCancelled else { return }

            if let image {
                self.loadedImage = image
                self.loadedData = data      // keep the ORIGINAL bytes for a lossless save
                self.loadError = nil
            } else {
                self.loadError = String(localized: "Could not decode image data")
                // Retry is pointless for `.ephemeralData`: the bytes are in memory and a retry re-reads the same ones.
                // `isUnresolvable` is not widened for this, since that would skip the decode attempt entirely.
                if case .ephemeralData = reference { self.loadErrorIsRetriable = false }
                logger.error("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType), \(data.count) bytes) resolved but did NOT decode. CONSEQUENCE: the picture is missing from the transcript and the error card is shown in its place.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.loadError = error.localizedDescription
            // A `.diskPath` reference that fails to resolve is a durability failure, so it is logged.
            logger.error("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType)) FAILED to resolve: \(error.localizedDescription). CONSEQUENCE: the picture is missing from the transcript and the error card is shown in its place (retry offered).")
        }
    }

    /// The reference `loadImage` actually reads from, which is not always the one the artifact carries.
    /// A `file://` URL labelled remote is read as a disk path; the repair lives here because
    /// `MediaReference` never auto-fetches remote.
    nonisolated static func resolvableReference(for reference: MediaReference) -> MediaReference {
        if case .remoteURL(let url) = reference, url.isFileURL {
            return .diskPath(url)
        }
        return reference
    }

    /// Whether this reference can never produce bytes, so the card must not offer Retry: only a non-file
    /// `.remoteURL`. Expects a reference already passed through `resolvableReference(for:)`.
    nonisolated static func isUnresolvable(_ reference: MediaReference) -> Bool {
        if case .remoteURL(let url) = reference { return !url.isFileURL }
        return false
    }

    /// Reference kind for logs; the URL itself is not logged, since it carries user paths.
    private static func referenceKind(_ reference: MediaReference) -> String {
        switch reference {
        case .diskPath:      return "diskPath"
        case .remoteURL:     return "remoteURL"
        case .ephemeralData: return "ephemeralData"
        }
    }

    // MARK: - Subviews

    /// Sized off the shared constants so the bubble does not jump when the picture arrives.
    /// `maxWidth` matches the loaded image's own frame.
    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.secondaryBackground)
            .frame(maxWidth: ChatUIConstants.imageMaxWidth,
                   minHeight: ChatUIConstants.imagePlaceholderMinHeight)
            .overlay(
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading image...")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            )
    }

    /// The shared error card (`ErrorMessageView`), which provides copy and a VoiceOver announcement.
    /// Retry is offered only where it can work: a disk resolve is retriable, a non-file `.remoteURL` is
    /// refused every time.
    private func errorPlaceholder(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorMessageView(
                title: loadErrorIsRetriable
                    ? String(localized: "Failed to load image")
                    : String(localized: "Image not available"),
                details: error,
                category: .imageResolutionFailed,
                announcementKey: "media-artifact-\(artifact.id.uuidString)#\(loadAttempt)"
            )
            if loadErrorIsRetriable {
                RetryMessageButton {
                    loadAttempt += 1  // a new attempt is a new announcement identity
                    loadError = nil   // back to the loading placeholder while we re-resolve
                    loadedImage = nil
                    Task { await loadImage() }
                }
            }
        }
        .frame(maxWidth: ChatUIConstants.imageMaxWidth,
               minHeight: ChatUIConstants.imagePlaceholderMinHeight, alignment: .leading)
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

    /// Saves the original bytes to Downloads, keeping the artifact's `mimeType` and surfacing write
    /// failures.
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
            // A plain cancel is not a failure and stays quiet; `.OK` with no URL is a failure.
            guard response == .OK else { return }
            guard let url = panel.url else {
                logger.error("[MEDIA] Save-As for artifact \(self.artifact.id.uuidString.prefix(8)) was CONFIRMED but the panel returned no URL. CONSEQUENCE: nothing was written and the user saw no error.")
                saveError = String(localized: "Couldn't determine where to save the image.")
                return
            }
            do {
                try data.write(to: url)
                savedURL = url
            } catch {
                saveError = error.localizedDescription
                logger.error("[MEDIA] Save-As for artifact \(self.artifact.id.uuidString.prefix(8)) FAILED writing \(data.count) bytes: \(error.localizedDescription). CONSEQUENCE: nothing was written; the alert tells the user.")
            }
        }
    }

    private func copyImage() {
        guard let image = loadedImage else { return }
        // The checkmark is the only feedback this affordance gives, so it must follow the
        // pasteboard's answer rather than the fact that we asked.
        guard ImageExport.copyToPasteboard(image) else {
            saveError = String(localized: "Couldn't copy the image. The clipboard is now empty.")
            return
        }
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

