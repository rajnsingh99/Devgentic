// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileAttachmentPicker.swift
//  Devgentic
//
//  [Q8] Shared file-attachment picking for the main composer (ChatInputAreaView) and the
//  QuickAccess panel: panel presentation, drop handling and FileSystemItem construction.
//  The accept/refuse POLICY is `AttachmentIntake`, applied where the items land.
//

import AppKit
import UniformTypeIdentifiers

enum FileAttachmentPicker {

    /// Builds the FileSystemItem for `url`, or nil if nothing exists there.
    ///
    /// ⚠️ No accept/refuse policy here — that is `AttachmentIntake`, applied by the
    /// destination (`ChatInputViewModel.addAttachedFiles`, QuickAccess `appendAttachments`).
    /// This file used to refuse oversized images and silently drop video itself, which the
    /// composer's `@` picker never passed through.
    private static func item(for url: URL) -> FileSystemItem? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: isDir.boolValue)
    }

    /// Shows `AttachmentIntake` refusals as an alert — for surfaces with no toast host (the
    /// QuickAccess panel). `attachedTo`: present as a sheet on that window; a floating
    /// non-activating panel would otherwise hide a detached alert behind itself.
    @MainActor
    static func presentRefusals(_ refused: [AttachmentIntake.Refusal], removed: Bool = false, attachedTo window: NSWindow?) {
        guard let message = AttachmentIntake.summary(refused, removed: removed) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = removed
            ? (refused.count == 1 ? String(localized: "Attachment removed") : String(localized: "\(refused.count) attachments removed"))
            : (refused.count == 1 ? String(localized: "File not attached") : String(localized: "\(refused.count) files not attached"))
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Presents an NSOpenPanel (files + folders, multi-select) and delivers the accepted items
    /// on the main thread. `onItems` is not called when the user cancels.
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
                    if let fileItem = item(for: url) { onItem(fileItem) }
                }
            }
        }
        return true
    }
}
