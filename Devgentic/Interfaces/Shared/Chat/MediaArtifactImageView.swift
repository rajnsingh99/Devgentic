// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
import os

private let logger = DGLogger(category: "MediaArtifactImage")

/// ⚠️ [views/bm-1] OPEN, and this is the decision procedure — not a fix waiting to be written,
/// a measurement waiting to be taken.
///
/// The row says this view decodes and retains a FULL-RESOLUTION bitmap for a display bounded at
/// `ChatUIConstants.imageMaxWidth`. True, and deliberate: `loadedImage` is the SINGLE bitmap
/// serving the inline draw, the lightbox, Copy Image and Save, so downsampling it would degrade
/// three lossless consumers to pay for one bounded one. `AttachedImageCardView` can downsample
/// precisely because it keeps a SEPARATE full-size bitmap for those.
///
/// Whether the retention is worth closing turns on ONE unknown: how large the images actually
/// are. Verified in source — MLX derives every aspect ratio from a 1024 base and DALL·E 3 emits
/// at most 1792x1024, so against a ~1000px display cap both save around 5% of pixels, which is
/// nothing. Gemini is the exception: its request body carries no size at all and the model name
/// is user-configured, so its output resolution is whatever the model returns.
///
/// TO CLOSE THIS: generate one image per provider INCLUDING Gemini, then read the real dimensions
/// off the stored file (`sips -g pixelWidth -g pixelHeight` under
/// `~/Library/Application Support/Devgentic/MediaCache`). If Gemini's longest side is <= 1024 the
/// row is closed as overstated. If it is materially larger, the fix is a NEW
/// `ImageDownsampler.inline(from:maxDimension:)` wrapping through `NSBitmapImageRep` the way
/// `fullSize` does — NOT `thumbnail`, whose `NSImage(cgImage:size:)` reports scaled
/// `pixelsWide/High` and would break the lightbox's true-pixel caption — plus a deferred
/// full-size decode for the three lossless consumers.
///
/// Checked 2026-09-13: `MediaCache` does not exist on this machine, so no generated image has
/// ever been stored here and the measurement could not be taken.
struct MediaArtifactImageView: View {
    let artifact: MediaArtifact
    @Environment(\.appTheme) private var theme
    @State private var loadedImage: NSImage?
    @State private var loadedData: Data?
    @State private var isHovering = false
    @State private var loadError: String?
    /// [CF-26] Whether the current `loadError` could ever change on a retry.
    ///
    /// A `.remoteURL` that is not a file URL never resolves — `MediaReference.resolve()` refuses
    /// it unconditionally — so the Retry button beside the card was guaranteed to fail, forever.
    @State private var loadErrorIsRetriable = true
    /// ⚠️ [CF-40] Bumped by Retry so the error card's VoiceOver announcement carries a NEW
    /// identity per attempt. Without it a retry that fails the same way produced the identical
    /// sentence, which the announcer's repeat suppression swallowed for its whole window — so
    /// pressing Retry appeared to do nothing at all to a VoiceOver user.
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
        // Clear the DERIVED state first. `.task(id: artifact.id)` re-runs this when the view is
        // reused for a different artifact — which happens on every variant flip, since the
        // switch branch in `AgentBubbleContentView.contentView` is keyed only by the message
        // while `contentToDisplay` follows `currentAgentContent`. Without this reset the old
        // bitmap survived: `body` gives `loadedImage` precedence over `loadError`, so a new
        // artifact that fails to resolve kept showing the PREVIOUS picture with no error card
        // and no Retry — and `Save to Downloads` / `Copy Image` exported the previous
        // artifact's bytes, because `loadedData` was equally stale.
        // (`errorPlaceholder`'s Retry already does exactly this; the artifact-change path did not.)
        loadedImage = nil
        loadedData = nil
        loadError = nil
        loadErrorIsRetriable = true

        let reference = Self.resolvableReference(for: artifact.reference)

        // [CF-26] A genuinely remote reference is a dead end, not a failure: `resolve()` throws
        // for it every single time. Say so in the user's language and drop the Retry, rather
        // than showing "Convert to diskPath first" with a button that re-runs the same refusal.
        guard !Self.isUnresolvable(reference) else {
            loadError = String(localized: "This image is stored as a link to a remote address, and Devgentic never downloads images from the web.")
            loadErrorIsRetriable = false
            logger.info("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType)) is a non-file remote reference, which is never fetched — a download via MediaStore would have to convert it to a disk path first. CONSEQUENCE: an 'Image not available' card is shown in place of the picture, with NO Retry, because no retry can succeed.")
            return
        }

        do {
            let data = try await reference.resolve()
            // Decoding a full-size bitmap is expensive, so it goes off-main to keep a large
            // artifact from stalling the bubble it's rendering into. [CF-23] That needs
            // `ImageDownsampler.fullSize`, not `NSImage(data:)` — the latter only parses
            // headers here and materialises the pixels on FIRST DRAW, back on the main thread,
            // so this hop was moving nothing that cost anything.
            let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.fullSize(from: data) }.value
            guard !Task.isCancelled else { return }

            if let image {
                self.loadedImage = image
                self.loadedData = data      // keep the ORIGINAL bytes for a lossless save
                self.loadError = nil
            } else {
                self.loadError = String(localized: "Could not decode image data")
                // ⚠️ [bm-4] Retry is pointless for `.ephemeralData`: the bytes are already in
                // memory and a retry re-reads the SAME ones, so the decode must fail again.
                // Offering the button invited an endless loop on a card that can never recover.
                // Deliberately NOT done by widening `isUnresolvable` to cover `.ephemeralData` —
                // that would skip the decode ATTEMPT entirely and show "stored image is missing"
                // copy for bytes that are present but undecodable (and it is pinned false by
                // `MediaArtifactReferenceRepairTests`). A disk/store-backed reference keeps its
                // retry: for those the bytes are re-read, so a transient failure can recover.
                if case .ephemeralData = reference { self.loadErrorIsRetriable = false }
                logger.error("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType), \(data.count) bytes) resolved but did NOT decode. CONSEQUENCE: the picture is missing from the transcript and the error card is shown in its place.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.loadError = error.localizedDescription
            // A `.diskPath` reference that no longer resolves is exactly the durability
            // failure the logging standard exists for: without this line, "my generated
            // images disappeared" leaves no trace beyond an error card the user scrolls past.
            logger.error("[MEDIA] Artifact \(self.artifact.id.uuidString.prefix(8)) (\(Self.referenceKind(reference)), \(self.artifact.mimeType)) FAILED to resolve: \(error.localizedDescription). CONSEQUENCE: the picture is missing from the transcript and the error card is shown in its place (retry offered).")
        }
    }

    /// [CF-26] The reference `loadImage` actually reads from, which is not always the one the
    /// artifact carries.
    ///
    /// The legacy `"image"` decode shim (`ChatMessage.swift`) maps EVERY url-only message to
    /// `.remoteURL` — including the `file://` URLs older image-gen runs wrote to disk — and
    /// `MediaReference.resolve()` refuses `.remoteURL` unconditionally. So readable pictures
    /// still sitting on disk rendered a developer-facing "Convert to diskPath first" card next
    /// to a Retry that re-ran the same refusal. A `file://` URL is a disk path however it got
    /// labelled; read it as one.
    ///
    /// The repair lives here rather than in `MediaReference` because that type is Core and
    /// serves the whole pipeline (where "remote is never auto-fetched" is a deliberate rule);
    /// this is the one renderer that has to cope with the legacy shape.
    nonisolated static func resolvableReference(for reference: MediaReference) -> MediaReference {
        if case .remoteURL(let url) = reference, url.isFileURL {
            return .diskPath(url)
        }
        return reference
    }

    /// [CF-26] Whether this reference can never produce bytes, so the card must not offer a
    /// Retry. Only a non-file `.remoteURL` qualifies — everything else can succeed on a later
    /// read (a file can come back). Expects a reference already passed through
    /// `resolvableReference(for:)`.
    nonisolated static func isUnresolvable(_ reference: MediaReference) -> Bool {
        if case .remoteURL(let url) = reference { return !url.isFileURL }
        return false
    }

    /// Reference kind for logs — the URL itself is deliberately not logged (user paths).
    private static func referenceKind(_ reference: MediaReference) -> String {
        switch reference {
        case .diskPath:      return "diskPath"
        case .remoteURL:     return "remoteURL"
        case .ephemeralData: return "ephemeralData"
        }
    }

    // MARK: - Subviews

    /// Sized off the shared constants, not a bespoke 256×256 square.
    ///
    /// `ChatUIConstants.imagePlaceholderMinHeight` exists so "the bubble doesn't jump when the
    /// picture arrives", but the app's primary image renderer ignored it and reserved a fixed
    /// square instead — so the bubble jumped anyway, and tuning the constant had no effect
    /// where it mattered most. `maxWidth` matches the loaded image's own frame (:34), so the
    /// placeholder and the picture occupy the same width.
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

    /// The shared error card, not a bespoke one. The old placeholder was a fixed
    /// 256×128 tile that truncated the reason to TWO lines with no expand, no copy, and
    /// no way to retry — a dead end that also announced nothing. ErrorMessageView brings
    /// copy + the VoiceOver announcement for free.
    ///
    /// [CF-26] Retry is offered only where a retry can work. A resolve against disk is
    /// genuinely retriable (a file can be back on the next read); a non-file `.remoteURL` is
    /// refused by `MediaReference.resolve()` every time, so that card says the image is
    /// unavailable and carries no button.
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
                    loadAttempt += 1  // [CF-40] a new attempt is a new announcement identity
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
            // A plain cancel is not a failure and stays quiet; `.OK` with no URL is, and
            // used to exit through the same silent return.
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

