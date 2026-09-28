// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageLightbox.swift
//  Devgentic
//
//  Full-size image viewer. Chat caps images at `ChatUIConstants.imageMaxWidth`, which for
//  a 1024² generated image means the user had only ever seen it at half size with no way
//  to look closer — the whole point of generating it.
//
//  Presented from both image renderers via `.imageLightbox(...)`.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isHoveringCanvas = false
    @State private var didCopy = false
    @State private var toastMessage: String?
    @State private var toastIcon: String?
    @State private var toastIsError = false
    @State private var toastTask: Task<Void, Never>?

    private static let minZoom: CGFloat = 0.2
    private static let maxZoom: CGFloat = 6.0

    private var pixelSize: CGSize {
        // `image.size` is in points; the bitmap rep carries the real pixel dimensions.
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private var displayTitle: String {
        if let fileBaseName, !fileBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileBaseName
        }
        if let altText, !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return altText
        }
        return "Image Preview"
    }

    private var fullTitle: String {
        if let altText, !altText.isEmpty { return altText }
        if let fileBaseName, !fileBaseName.isEmpty { return fileBaseName }
        return "Image"
    }

    private var formatBadgeText: String? {
        if let data {
            return ImageExport.fileExtension(for: data, declaredMimeType: mimeType).uppercased()
        }
        if let mimeType {
            let parts = mimeType.split(separator: "/")
            if parts.count == 2 {
                return String(parts[1]).uppercased()
            }
        }
        return nil
    }

    private var fileSizeText: String? {
        guard let data, data.count > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 1)

            imageSurface
        }
        .frame(
            minWidth: 880,
            idealWidth: 1120,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 800,
            maxHeight: .infinity
        )
        .background(LightboxWindowSizer())
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
        )
        .onDisappear {
            NSCursor.arrow.set()
        }
        .background {
            // Invisible keyboard shortcut receivers
            Group {
                Button("") { step(0.25) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("") { step(0.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { step(-0.25) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") { resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("") { copy() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            // Leading: Icon Badge + Titles & Metadata
            HStack(spacing: 10) {
                // Image glyph icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(theme.accentColor.opacity(0.3), lineWidth: 0.5)
                        )

                    Image(systemName: "photo.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fullTitle)

                    HStack(spacing: 6) {
                        // Pixel dimensions chip (never wraps)
                        HStack(spacing: 3.5) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 8.5))
                            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(theme.surfaceOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        // Format chip (e.g. PNG / JPG)
                        if let formatBadgeText {
                            Text(formatBadgeText)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(theme.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        // File size chip (e.g. 1.2 MB)
                        if let fileSizeText {
                            Text(fileSizeText)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundColor(theme.secondaryText.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(theme.surfaceOverlay)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 16)

            // Trailing: Controls
            HStack(spacing: 8) {
                // Zoom Control Island (Height: 28pt)
                zoomIsland

                // Divider line
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 2)

                // Copy Button (Height: 28pt)
                TactileIconButton(
                    icon: didCopy ? "checkmark" : "doc.on.doc",
                    tooltip: "Copy image (⌘C)",
                    accessibilityLabel: "Copy image",
                    variant: didCopy ? .primary : .secondary,
                    size: 28
                ) {
                    copy()
                }

                // Save to Downloads Button (Height: 28pt)
                TactileIconButton(
                    icon: "arrow.down.to.line",
                    tooltip: "Save to Downloads (⌘S)",
                    accessibilityLabel: "Save image to Downloads",
                    variant: .secondary,
                    size: 28,
                    isEnabled: data != nil
                ) {
                    save()
                }

                // Close Button (Height: 28pt)
                TactileIconButton(
                    icon: "xmark",
                    tooltip: "Close (Esc)",
                    accessibilityLabel: "Close",
                    variant: .subtle,
                    size: 28
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.95))
    }

    // MARK: - Zoom Control Island

    private var zoomIsland: some View {
        HStack(spacing: 0) {
            // Zoom Out
            Button {
                step(-0.25)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(zoom > Self.minZoom ? theme.secondaryText : theme.secondaryText.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom <= Self.minZoom)
            .help("Zoom out (⌘-)")

            // Percentage Label / Preset cycler
            Button {
                cycleZoomPreset()
            } label: {
                Text("\(Int(round(zoom * 100)))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(abs(zoom - 1.0) < 0.05 ? theme.secondaryText : theme.accentColor)
                    .frame(minWidth: 44)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom level: \(Int(round(zoom * 100)))%. Click to cycle 100% / 200% / Fit.")

            // Zoom In
            Button {
                step(0.25)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(zoom < Self.maxZoom ? theme.secondaryText : theme.secondaryText.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom >= Self.maxZoom)
            .help("Zoom in (⌘+)")

            // Divider inside island
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)

            // Fit to Window Reset
            Button {
                resetZoom()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(abs(zoom - 1.0) < 0.05 ? theme.accentColor : theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to window (⌘0)")
        }
        .padding(1)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Surface

    private var imageSurface: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let aspect: CGFloat = {
                if pixelSize.width > 0 && pixelSize.height > 0 {
                    return pixelSize.width / pixelSize.height
                }
                if image.size.width > 0 && image.size.height > 0 {
                    return image.size.width / image.size.height
                }
                return 1.0
            }()

            let margin: CGFloat = zoom <= 1.02 ? 24 : 0
            let availW = max(viewport.width - margin * 2, 1)
            let availH = max(viewport.height - margin * 2, 1)

            let isHeightConstrained = (availW / availH) > aspect
            let baseW = isHeightConstrained ? (availH * aspect) : availW
            let baseH = isHeightConstrained ? availH : (availW / aspect)

            let renderedW = max(baseW * zoom, 1)
            let renderedH = max(baseH * zoom, 1)

            ZStack {
                // Dark tactile canvas background
                theme.primaryBackground
                    .ignoresSafeArea()

                // Centered Image with Drag and Zoom
                Image(nsImage: image)
                    .resizable()
                    .interpolation(zoom > 2 ? .none : .high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: renderedW, height: renderedH)
                    .clipShape(RoundedRectangle(cornerRadius: zoom <= 1.02 ? 6 : 0, style: .continuous))
                    .shadow(
                        color: zoom <= 1.02 ? Color.black.opacity(0.45) : Color.clear,
                        radius: 18, x: 0, y: 6
                    )
                    .offset(offset)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits(.isImage)

                // Floating Toast Banner (Top Center)
                if let toastMessage, let toastIcon {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: toastIcon)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(toastIsError ? theme.errorColor : theme.successColor)

                            Text(toastMessage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            theme.secondaryBackground.opacity(0.95)
                                .clipShape(Capsule())
                        )
                        .overlay(
                            Capsule().stroke(toastIsError ? theme.errorColor.opacity(0.4) : theme.successColor.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
                        .padding(.top, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)

                        Spacer()
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .clipped()
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringCanvas = hovering
                updateCursor()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard zoom > 1.01 else { return }
                        isDragging = true
                        updateCursor()
                        let raw = CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height
                        )
                        offset = clampOffset(raw, renderedWidth: renderedW, renderedHeight: renderedH, viewport: viewport)
                    }
                    .onEnded { _ in
                        isDragging = false
                        committedOffset = offset
                        updateCursor()
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let targetZoom = clamp(committedZoom * value.magnification)
                        zoom = targetZoom
                        if zoom <= 1.02 {
                            offset = .zero
                            committedOffset = .zero
                        } else {
                            let rw = baseW * zoom
                            let rh = baseH * zoom
                            offset = clampOffset(offset, renderedWidth: rw, renderedHeight: rh, viewport: viewport)
                            committedOffset = offset
                        }
                    }
                    .onEnded { _ in
                        committedZoom = zoom
                        committedOffset = offset
                        updateCursor()
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    if zoom > 1.02 {
                        zoom = 1.0
                        committedZoom = 1.0
                        offset = .zero
                        committedOffset = .zero
                    } else {
                        zoom = 2.0
                        committedZoom = 2.0
                    }
                    updateCursor()
                }
            }
            .background(
                ScrollZoomMonitorView(isHovering: isHoveringCanvas) { delta in
                    handleScrollZoom(delta: delta, baseW: baseW, baseH: baseH, viewport: viewport)
                }
            )
        }
    }

    // MARK: - Actions

    private var accessibilityLabel: String {
        if let altText, !altText.isEmpty { return altText }
        return String(localized: "Image, \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels")
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minZoom), Self.maxZoom)
    }

    private func clampOffset(_ raw: CGSize, renderedWidth: CGFloat, renderedHeight: CGFloat, viewport: CGSize) -> CGSize {
        var clampedX: CGFloat = 0
        if renderedWidth > viewport.width {
            let maxPanX = (renderedWidth - viewport.width) / 2 + 32
            clampedX = min(max(raw.width, -maxPanX), maxPanX)
        } else {
            clampedX = 0
        }

        var clampedY: CGFloat = 0
        if renderedHeight > viewport.height {
            let maxPanY = (renderedHeight - viewport.height) / 2 + 32
            clampedY = min(max(raw.height, -maxPanY), maxPanY)
        } else {
            clampedY = 0
        }

        return CGSize(width: clampedX, height: clampedY)
    }

    private func updateCursor() {
        guard isHoveringCanvas else {
            NSCursor.arrow.set()
            return
        }
        if isDragging {
            NSCursor.closedHand.set()
        } else if zoom > 1.02 {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func handleScrollZoom(delta: CGFloat, baseW: CGFloat, baseH: CGFloat, viewport: CGSize) {
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.85)) {
            let newZoom = clamp(zoom + delta)
            zoom = newZoom
            committedZoom = newZoom
            if zoom <= 1.02 {
                offset = .zero
                committedOffset = .zero
            } else {
                let rw = baseW * zoom
                let rh = baseH * zoom
                offset = clampOffset(offset, renderedWidth: rw, renderedHeight: rh, viewport: viewport)
                committedOffset = offset
            }
            updateCursor()
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            zoom = 1.0
            committedZoom = 1.0
            offset = .zero
            committedOffset = .zero
            updateCursor()
        }
    }

    private func step(_ delta: CGFloat) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            zoom = clamp(zoom + delta)
            committedZoom = zoom
            if zoom <= 1.02 {
                offset = .zero
                committedOffset = .zero
            }
            updateCursor()
        }
    }

    private func cycleZoomPreset() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if abs(zoom - 1.0) < 0.05 {
                zoom = 2.0
            } else if abs(zoom - 2.0) < 0.05 {
                zoom = 0.5
            } else {
                zoom = 1.0
            }
            committedZoom = zoom
            if zoom <= 1.02 {
                offset = .zero
                committedOffset = .zero
            }
            updateCursor()
        }
    }

    private func copy() {
        ImageExport.copyToPasteboard(image)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            didCopy = true
        }
        showToast(message: "Copied image to clipboard", icon: "checkmark.circle.fill", isError: false)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                didCopy = false
            }
        }
    }

    private func save() {
        guard let data else { return }
        do {
            let url = try ImageExport.saveToDownloads(
                data: data,
                declaredMimeType: mimeType,
                baseName: suggestedBaseName
            )
            showToast(message: "Saved to Downloads (\(url.lastPathComponent))", icon: "checkmark.circle.fill", isError: false)
        } catch {
            showToast(message: error.localizedDescription, icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    private func showToast(message: String, icon: String, isError: Bool) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            toastMessage = message
            toastIcon = icon
            toastIsError = isError
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                toastMessage = nil
                toastIcon = nil
            }
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

// MARK: - Window Sizer

private struct LightboxWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let screenRect = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let targetWidth = min(1120, max(880, screenRect.width - 60))
            let targetHeight = min(800, max(620, screenRect.height - 60))
            if window.frame.width < targetWidth || window.frame.height < targetHeight {
                window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
                if window.sheetParent == nil {
                    let newOrigin = NSPoint(
                        x: screenRect.midX - targetWidth / 2,
                        y: screenRect.midY - targetHeight / 2
                    )
                    window.setFrameOrigin(newOrigin)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Scroll to Zoom Monitor

private struct ScrollZoomMonitorView: NSViewRepresentable {
    var isHovering: Bool
    var onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorNSView {
        let view = MonitorNSView()
        view.isHovering = isHovering
        view.onZoom = onZoom
        view.installMonitor()
        return view
    }

    func updateNSView(_ nsView: MonitorNSView, context: Context) {
        nsView.isHovering = isHovering
        nsView.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: MonitorNSView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

private final class MonitorNSView: NSView {
    var isHovering: Bool = false
    var onZoom: ((CGFloat) -> Void)?
    private var monitor: Any?

    func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isHovering else { return event }

            let rawDelta: CGFloat
            if event.hasPreciseScrollingDeltas {
                rawDelta = event.scrollingDeltaY * 0.006
            } else {
                rawDelta = event.scrollingDeltaY > 0 ? 0.15 : -0.15
            }

            guard abs(rawDelta) > 0.0001 else { return event }

            DispatchQueue.main.async {
                self.onZoom?(rawDelta)
            }
            return nil
        }
    }

    func removeMonitor() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        removeMonitor()
    }
}


