// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageLightbox.swift
//  Devgentic
//
//  Full-size image viewer. Chat caps images at `ChatUIConstants.imageMaxWidth`, which for
//  a 1024²generated image means the user had only ever seen it at half size with no way
//  to look closer — the whole point of generating it.
//
//  Presented from both image renderers via `.imageLightbox(...)`.
//

import SwiftUI
import AppKit

struct ImageLightbox: View {
    let image: NSImage
    /// The image's own description — alt text, or an artifact label. Drives the title and
    /// the VoiceOver label, so the viewer says what the picture IS rather than "image".
    let altText: String?
    /// [bm-8] The saved file's base name when the caller knows one (an attachment's own
    /// filename, extension already removed). Nil means "derive it from `altText`", which is
    /// right for a generated image whose label is prose.
    var fileBaseName: String? = nil
    /// Original bytes. Saved verbatim so nothing is re-encoded on the way out.
    let data: Data?
    let mimeType: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var saveError: String?
    @State private var savedURL: URL?

    private static let minZoom: CGFloat = 0.1
    private static let maxZoom: CGFloat = 8

    private var pixelSize: CGSize {
        // `image.size` is in points; the bitmap rep carries the real pixel dimensions.
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            imageSurface
            if let saveError {
                banner(text: saveError, icon: "exclamationmark.triangle.fill", tint: theme.errorColor)
            } else if let savedURL {
                banner(text: "Saved to \(savedURL.lastPathComponent)", icon: "checkmark.circle.fill", tint: theme.successColor)
            }
        }
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 700)
        .background(theme.primaryBackground)
    }

    // MARK: - Surface

    private var imageSurface: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(zoom > 2 ? .none : .high)   // show real pixels when inspecting closely
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: max(geo.size.width * zoom, 1),
                        height: max(geo.size.height * zoom, 1)
                    )
                    .frame(
                        minWidth: geo.size.width,
                        minHeight: geo.size.height
                    )   // keep it centred while it still fits
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits(.isImage)
            }
            .scrollDisabled(zoom <= 1)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = clamp(committedZoom * value.magnification)
                    }
                    .onEnded { _ in committedZoom = zoom }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    zoom = zoom > 1 ? 1 : 2
                    committedZoom = zoom
                }
            }
        }
        .background(theme.secondaryBackground)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: theme.spacingSmall) {
            VStack(alignment: .leading, spacing: 1) {
                Text(altText?.isEmpty == false ? altText! : "Image")
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button { step(-0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")

            Text("\(Int(zoom * 100))%")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .frame(width: 48)
                .accessibilityLabel("Zoom \(Int(zoom * 100)) percent")

            Button { step(0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { zoom = 1; committedZoom = 1 }
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("Fit to window")
            .accessibilityLabel("Fit to window")

            Divider().frame(height: 16)

            Button { ImageExport.copyToPasteboard(image) } label: { Image(systemName: "doc.on.doc") }
                .help("Copy image")
                .accessibilityLabel("Copy image")

            Button(action: save) { Image(systemName: "arrow.down.circle") }
                .help("Save to Downloads")
                .accessibilityLabel("Save image to Downloads")
                .disabled(data == nil)

            Button { dismiss() } label: { Image(systemName: "xmark") }
                .help("Close")
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, theme.spacingMedium)
        .padding(.vertical, theme.spacingSmall)
    }

    private func banner(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: theme.spacingXSmall) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundColor(tint)
        .padding(.horizontal, theme.spacingMedium)
        .padding(.vertical, theme.spacingSmall)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var accessibilityLabel: String {
        if let altText, !altText.isEmpty { return altText }
        return String(localized: "Image, \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels")
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minZoom), Self.maxZoom)
    }

    private func step(_ delta: CGFloat) {
        withAnimation(.easeInOut(duration: 0.12)) {
            zoom = clamp(zoom + delta)
            committedZoom = zoom
        }
    }

    private func save() {
        guard let data else { return }
        saveError = nil
        savedURL = nil
        do {
            savedURL = try ImageExport.saveToDownloads(   // [bm-8] base name, not the label
                data: data,
                declaredMimeType: mimeType,
                baseName: suggestedBaseName
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var suggestedBaseName: String {
        Self.suggestedBaseName(altText: altText, fileBaseName: fileBaseName)
    }

    /// Name the file after what it depicts when we know, so Downloads doesn't fill up with
    /// interchangeable "devgentic-image-a1b2c3" files.
    ///
    /// [bm-8] `fileBaseName` wins when the caller has a real filename, and is used VERBATIM:
    /// slugifying "Screenshot 2026-09-11.png" gave "screenshot-2026-09-11-png", and
    /// `saveToDownloads` then appended the sniffed extension, so saving from the lightbox
    /// produced "screenshot-2026-09-11-png.png" while the same image saved from the card's
    /// context menu produced "Screenshot 2026-09-11.png".
    ///
    /// ⚠️ The extension is stripped by the CALLER, not here. A blanket `deletingPathExtension`
    /// inside this function would maul prose: "diagram.of.the.system" → "diagram.of.the"
    /// (probed). A generated image's label is prose and must keep going through the slug path
    /// below untouched, which is why this takes a separate parameter instead of a flag.
    ///
    /// `nonisolated static` so the naming rule is testable without presenting a sheet.
    nonisolated static func suggestedBaseName(altText: String?, fileBaseName: String?) -> String {
        if let fileBaseName {
            let trimmed = fileBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty/whitespace name is no name: fall through rather than hand
            // `saveToDownloads` a base it cannot make unique.
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        guard let altText, !altText.isEmpty else {
            return "devgentic-image-\(UUID().uuidString.prefix(6))"
        }
        let slug = altText
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "devgentic-image" : String(slug.prefix(60))
    }
}

// MARK: - Presentation

extension View {
    /// Opens `ImageLightbox` in a sheet when `isPresented`. Both image renderers attach
    /// this so zoom behaves identically wherever an image appears.
    ///
    /// [CF-25] `onDismiss` is how a caller that decoded the full-size bitmap ONLY for this
    /// sheet gets to drop it again. Without it there was no dismissal hook at all, so
    /// `AttachedImageCardView` held every opened photo's pixels in row state for as long as the
    /// conversation stayed on screen. Callers whose image is the one the bubble itself renders
    /// (`MediaArtifactImageView`) leave it nil — that bitmap is not the sheet's to release.
    /// [bm-8] `fileBaseName` names the SAVED FILE only — the title and the VoiceOver label
    /// keep using `altText`. A caller whose `altText` is a filename passes the extension-less
    /// form here rather than changing `altText`, which would have changed all three.
    func imageLightbox(
        isPresented: Binding<Bool>,
        image: NSImage?,
        altText: String?,
        data: Data?,
        mimeType: String? = nil,
        fileBaseName: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            if let image {
                ImageLightbox(image: image, altText: altText, fileBaseName: fileBaseName, data: data, mimeType: mimeType)
            }
        }
    }
}
