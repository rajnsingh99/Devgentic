// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
//  opens the lightbox, and released again when it closes (CF-25). Copy decodes into
//  a local and keeps nothing.
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
                       mimeType: "image/\(ImageExport.fileExtension(for: file.binaryData))",
                       // [bm-8] The SAVE name only — the same value this card's own
                       // context-menu Save has always used, so the two routes agree. `altText`
                       // keeps the full filename for the title and the spoken label.
                       fileBaseName: (file.name as NSString).deletingPathExtension,
                       // [CF-25] The full-size bitmap belongs to the open sheet and nothing
                       // else — the chip renders from `thumbnail`. Holding it past dismissal
                       // retained ~45 MB per opened 12 MP photo in a row the user had scrolled
                       // away from, on top of `binaryData` already resident for the message.
                       onDismiss: { fullImage = nil })
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
    /// scrolling.
    ///
    /// [CF-25] The decoded bitmap lives only as long as the lightbox does: `fullImage` is
    /// cleared when the sheet dismisses, so a transcript row that has been opened once no
    /// longer carries ~45 MB of pixels for the life of the conversation view. Re-opening pays
    /// the decode again, which is a few hundred milliseconds off-main, once, on a click.
    private func openLightbox() {
        if fullImage != nil {
            showLightbox = true
            return
        }
        let data = file.binaryData
        Task {
            // [CF-23] `ImageDownsampler.fullSize`, not `NSImage(data:)`: the latter only reads
            // headers here and decodes on first DRAW, which is the main thread — so this hop
            // was moving the cheap 0.2 ms and leaving the 60 ms where it hurt.
            let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.fullSize(from: data) }.value
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
            // [CF-23] Same eager decode as `openLightbox` — the pasteboard write reads the
            // pixels, so a lazily-decoded NSImage would have paid for them on the main thread
            // the moment this returned.
            let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.fullSize(from: data) }.value
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
            ImageExport.copyToPasteboard(image)
            // [CF-25] Deliberately NOT stored in `fullImage`. A copy needs the bitmap for the
            // length of the pasteboard write (which takes its own copy of the bytes), not for
            // the life of the row — and this row sits in a `LazyVStack` that keeps the state of
            // every instantiated row while the conversation is on screen. Storing it here is
            // what made "copy ten photos" cost half a gigabyte of pixels nobody was looking at.
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
