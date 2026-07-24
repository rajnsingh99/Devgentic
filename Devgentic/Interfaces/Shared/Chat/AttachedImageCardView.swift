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

struct AttachedImageCardView: View {
    let file: AttachedImageFile
    @Environment(\.appTheme) private var theme

    @State private var thumbnail: NSImage?
    @State private var decodeFailed = false
    @State private var showLightbox = false
    @State private var fullImage: NSImage?
    @State private var saveError: String?

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
        .alert("Couldn't save image", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
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
            guard let image else { return }   // undecodable at full size: keep the thumbnail, no empty lightbox
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
            guard let image else { return }
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
            saveError = error.localizedDescription
        }
    }
}
