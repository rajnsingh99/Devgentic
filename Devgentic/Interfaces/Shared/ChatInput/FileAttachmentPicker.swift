// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileAttachmentPicker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import UniformTypeIdentifiers

/// Shared file-attachment picking for the main composer and the QuickAccess panel: panel presentation, drop
/// handling and `FileSystemItem` construction. The accept/refuse policy is `AttachmentIntake`, applied where items land.
enum FileAttachmentPicker {

    /// Builds the FileSystemItem for `url`, or nil if nothing exists there.
    /// Applies no accept/refuse policy: that is `AttachmentIntake`, applied by the destination
    /// (`ChatInputViewModel.addAttachedFiles`, QuickAccess `appendAttachments`).
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

    /// Presents an NSOpenPanel (files + folders, multi-select) and delivers accepted items on the main thread; `onItems`
    /// is not called on cancel. `attachedTo` is the hosting window to present a sheet on, required for the QuickAccess
    /// panel, which floats above a detached panel. nil presents it detached (main composer).
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
