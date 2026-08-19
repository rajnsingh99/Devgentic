//
//  AttachedImageCardView.swift
//  Devgentic
//
//  Thumbnail card for a user-ATTACHED image in the user bubble — the sibling of
//  `FileAttachmentCardView` for pictures.
//
//  ATT-2 (chat hardening round 3): attached images were persisted at full fidelity
//  (`AttachedImageFile.binaryData`) but had ZERO render sites — every image a user
//  sent was invisible in the transcript, live and after reload, while the model saw
//  it. This card renders from the persisted bytes, NOT the file URL: the URL goes
//  stale the moment the source file moves or is deleted (and sandbox scope may not
//  survive relaunch), whereas the stored bytes are the transcript's durable copy.
//
//  Cost posture: the row shows a bounded `ImageDownsampler` thumbnail (decoded
//  off-main, keyed by file identity); the FULL image is decoded only when the user
//  opens the lightbox.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "AttachedImage")

struct AttachedImageCardView: View {
    let file: AttachedImageFile
    @Environment(\.appTheme) private var theme

    @State private var thumbnail: NSImage?
    @State private var decodeFailed = false
    @State private var showLightbox = false
    @State private var fullImage: NSImage?
    /// Failure of any context-menu action, surfaced as one alert. Was `saveError: String?`,
    /// which only Save ever set.
    @State private var actionError: ActionError?

    struct ActionError {
        let title: String
        let message: String
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: ChatUIConstants.attachmentThumbnailPointSize,
                           maxHeight: ChatUIConstants.attachmentThumbnailPointSize)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .stroke(theme.dividerColor, lineWidth: 1)
                    )
                    .onTapGesture { openLightbox() }
                    .accessibilityLabel("Attached image: \(file.name)")
                    .accessibilityAddTraits([.isImage, .isButton])
                    .accessibilityHint("Opens the image at full size")
                    // `.onTapGesture` isn't bridged to an accessibility action (same
                    // fix as MediaArtifactImageView) — without this the hint promises
                    // an action VO-Space can't perform.
                    .accessibilityAction { openLightbox() }
                    .contextMenu { contextMenuItems }
            } else if decodeFailed {
                // Chip-scale fallback: the bytes wouldn't decode, but the transcript
                // must still show that an image was sent (the whole point of ATT-2).
                Label(file.name, systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, theme.spacingSmall)
                    .padding(.vertical, theme.spacingXSmall)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .fill(theme.secondaryBackground)
                    )
                    .accessibilityLabel("Attached image failed to load: \(file.name)")
            } else {
                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                    .fill(theme.secondaryBackground)
                    .frame(width: ChatUIConstants.attachmentThumbnailPointSize,
                           height: ChatUIConstants.attachmentThumbnailPointSize * 0.75)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Loading attached image: \(file.name)")
            }
        }
        // Keyed to the file: SwiftUI reuses this view for a DIFFERENT attachment at the
        // same list position; a bare `.task` would keep showing the previous picture
        // (the exact bug MediaArtifactImageView documents).
        .task(id: file.id) {
            let data = file.binaryData
            // Request 2× the point size so the chip is sharp on Retina displays.
            let thumb = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.thumbnail(from: data, maxDimension: ChatUIConstants.attachmentThumbnailPointSize * 2)
            }.value
            guard !Task.isCancelled else { return }
            if let thumb { thumbnail = thumb } else { decodeFailed = true }
        }
        .imageLightbox(isPresented: $showLightbox,
                       image: fullImage,
                       altText: file.name,
                       data: file.binaryData,
                       mimeType: "image/\(ImageExport.fileExtension(for: file.binaryData))")
        // One alert for all three context-menu actions. It used to cover Save only, so
        // "View Full Size" and "Copy Image" failed with no feedback whatsoever — see
        // `openLightbox` / `copyImage`.
        .alert(actionError?.title ?? "", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError?.message ?? "")
        }
    }

    /// Full-size decode is deferred to here — thumbnails are the only cost while
    /// scrolling. Decoded once, then reused for repeat opens and for Copy.
    private func openLightbox() {
        if fullImage != nil {
            showLightbox = true
            return
        }
        let data = file.binaryData
        Task {
            let image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard let image else {
                // Was a bare `return`. The user CLICKED this — nothing opening, with no alert
                // and no log, reads as the app being unresponsive rather than a failed decode.
                logger.warning("[MEDIA] Full-size decode of attached image '\(self.file.name)' (\(data.count) bytes) FAILED after the thumbnail succeeded. CONSEQUENCE: 'View Full Size' opened nothing; the chip keeps its thumbnail and the user is told.")
                actionError = ActionError(
                    title: String(localized: "Couldn't open this image"),
                    message: String(localized: "\(self.file.name) can't be decoded at full size. The preview thumbnail is still available.")
                )
                return
            }
            fullImage = image
            showLightbox = true
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            openLightbox()
        } label: {
            Label("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right")
        }

        Button {
            copyImage()
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }

        // Failures alert; success relies on the Dock's Downloads bounce — a chip has
        // no room for the confirmation banner MediaArtifactImageView shows.
        Button {
            saveToDownloads()
        } label: {
            Label("Save to Downloads", systemImage: "arrow.down.to.line")
        }
    }

    private func copyImage() {
        if let fullImage {
            ImageExport.copyToPasteboard(fullImage)
            return
        }
        let data = file.binaryData
        Task {
            let image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard let image else {
                // The clipboard is NOT cleared on failure, so a silent return here left the
                // user pasting stale contents believing the copy had worked.
                logger.warning("[MEDIA] Full-size decode of attached image '\(self.file.name)' (\(data.count) bytes) FAILED. CONSEQUENCE: nothing was copied and the CLIPBOARD STILL HOLDS ITS PREVIOUS CONTENTS; the user is told so they don't paste the wrong thing.")
                actionError = ActionError(
                    title: String(localized: "Couldn't copy this image"),
                    message: String(localized: "\(self.file.name) can't be decoded at full size, so nothing was copied. Your clipboard is unchanged.")
                )
                return
            }
            fullImage = image
            ImageExport.copyToPasteboard(image)
        }
    }

    private func saveToDownloads() {
        do {
            _ = try ImageExport.saveToDownloads(
                data: file.binaryData,
                declaredMimeType: "image/\(ImageExport.fileExtension(for: file.binaryData))",
                baseName: (file.name as NSString).deletingPathExtension
            )
        } catch {
            logger.error("[MEDIA] Save to Downloads FAILED for attached image '\(self.file.name)' (\(self.file.binaryData.count) bytes): \(error.localizedDescription). CONSEQUENCE: nothing was written; the alert tells the user.")
            actionError = ActionError(
                title: String(localized: "Couldn't save image"),
                message: error.localizedDescription
            )
        }
    }
}
