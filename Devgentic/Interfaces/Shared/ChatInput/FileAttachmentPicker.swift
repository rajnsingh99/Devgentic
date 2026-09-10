// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileAttachmentPicker.swift
//  Devgentic
//
//  [Q8] Shared file-attachment picking for the main composer (ChatInputAreaView) and the
//  QuickAccess panel. The accept policy — files + folders, multi-select, video/movie excluded,
//  FileSystemItem construction — lived in two near-identical copies; centralizing it means a
//  change to the rules (new excluded types, size limits, security scopes) applies to both.
//

import AppKit
import UniformTypeIdentifiers

enum FileAttachmentPicker {

    /// Not accepted as a chat attachment (video/movie).
    private static func isExcluded(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .video) || type.conforms(to: .movie)
        }
        return false
    }

    private static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }

    private static func fileByteSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// [M7] An image whose file exceeds the reject cap — refused (never modified) to keep the
    /// oversized file from ever being read into memory, persisted, or sent. Uses a fast size stat
    /// (no full read), so even a multi-GB file is rejected cheaply.
    static func isOversizedImage(_ url: URL) -> Bool {
        isImage(url) && fileByteSize(url) > ImageConstraints.maxAttachmentImageBytes
    }

    /// Builds an accepted FileSystemItem for `url`, or nil if excluded / oversized / non-existent.
    private static func item(for url: URL) -> FileSystemItem? {
        guard !isExcluded(url), !isOversizedImage(url) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: isDir.boolValue)
    }

    /// [M7] Tell the user which images were refused for exceeding the cap (they were dropped, not
    /// attached). Must run on the main thread (NSAlert).
    private static func warnOversized(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let mb = ImageConstraints.maxAttachmentImageBytes / (1024 * 1024)
        let names = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1 ? "Image too large" : "\(urls.count) images too large"
        alert.informativeText = "\(names) — over the \(mb) MB limit, so \(urls.count == 1 ? "it was" : "they were") not attached."
        alert.runModal()
    }

    /// Presents an NSOpenPanel (files + folders, multi-select) and delivers the accepted items
    /// on the main thread. `onItems` is not called when the user cancels or picks only excluded files.
    ///
    /// `attachedTo`: pass the hosting window to present the picker as a SHEET on it. Required for
    /// the QuickAccess panel — it floats at `.floating` level in a non-activating app, so a
    /// detached `begin()` panel opens at normal level BEHIND it and is barely reachable. A sheet
    /// is guaranteed above its parent and takes keyboard focus. nil = detached (main composer).
    @MainActor
    static func presentOpenPanel(prompt: String = "Attach",
                                 attachedTo window: NSWindow? = nil,
                                 onItems: @escaping ([FileSystemItem]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            warnOversized(panel.urls.filter { isOversizedImage($0) }) // [M7] feedback for refused images
            let items = panel.urls.compactMap { item(for: $0) }
            if !items.isEmpty { onItems(items) }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    /// Handles dropped `.fileURL` providers, delivering each accepted item on the main thread.
    /// Returns true (the drop is always "handled"), matching SwiftUI's onDrop contract.
    @discardableResult
    static func handleDrop(_ providers: [NSItemProvider], onItem: @escaping (FileSystemItem) -> Void) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    // [M7] Refuse an oversized image with feedback instead of attaching it.
                    if isOversizedImage(url) { warnOversized([url]); return }
                    if let fileItem = item(for: url) { onItem(fileItem) }
                }
            }
        }
        return true
    }
}
