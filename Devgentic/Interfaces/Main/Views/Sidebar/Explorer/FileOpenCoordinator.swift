// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileOpenCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh on 20/09/26.
//

import Foundation
import AppKit

@MainActor
enum FileOpenCoordinator {
    private static let logger = DGLogger(category: "FileOpenCoordinator")

    /// Maximum file size (10 MB) permitted for in-app code editor to avoid memory pressure or UI lag.
    static let maxViewerFileSizeBytes: Int64 = 10 * 1024 * 1024
    
    /// Known binary and media extensions that cannot be meaningfully displayed in a text/code editor.
    static let binaryExtensions: Set<String> = [
        // Images (vector SVG is XML text, so excluded)
        "png", "jpg", "jpeg", "gif", "webp", "ico", "tiff", "bmp", "heic", "heif", "psd", "ai", "raw",
        // Audio
        "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma", "aiff",
        // Video
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv",
        // Archives & Packages
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "dmg", "pkg", "iso", "bin",
        // Executables & Libraries
        "exe", "dylib", "so", "a", "o", "class", "pyc", "dll",
        // Documents & Office
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote",
        // Fonts
        "ttf", "otf", "woff", "woff2", "eot",
        // Databases
        "db", "sqlite", "sqlite3", "realm"
    ]

    /// Determines whether a given URL is likely a binary or non-text file based on its extension.
    static func isLikelyBinary(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return binaryExtensions.contains(ext)
    }

    /// Opens the specified file item in the `CodeViewerPanelView` via `ChatHistoryViewModel`,
    /// or gracefully falls back to the system default application if it is binary, oversized, or unreadable.
    static func open(
        item: FileSystemItem,
        in chatHistoryViewModel: ChatHistoryViewModel,
        fallbackViewModel: ExplorerViewModel?
    ) {
        guard !item.isDirectory else {
            logger.info("Skipping open for directory: \(item.name)")
            return
        }

        let url = item.url

        // 1. Binary extension check: divert immediately to system default application.
        if isLikelyBinary(url: url) {
            logger.info("File '\(item.name)' is a binary asset (\(url.pathExtension)). Opening with system default app.")
            fallbackViewModel?.openWithSystemApp(item)
            return
        }

        // 2. Ensure security-scoped access if needed.
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 3. File size check: divert oversized files to avoid locking the UI.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > maxViewerFileSizeBytes {
            logger.warning("File '\(item.name)' is \(fileSize / (1024 * 1024))MB, exceeding the 10MB limit. Opening with system default app.")
            fallbackViewModel?.openWithSystemApp(item)
            return
        }

        // 4. Attempt to read as text (UTF-8, with fallback to Latin-1).
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
                content = latin1
            } else {
                logger.error("Failed to decode '\(item.name)' as text: \(error.localizedDescription). Falling back to system app.")
                fallbackViewModel?.openWithSystemApp(item)
                return
            }
        }

        // 5. Open in Code Viewer panel with inferred syntax highlighting language and tab persistence.
        let language = CodeSnippet.languageHint(forFileName: item.name)
        let snippet = CodeSnippet(language: language, code: content)

        logger.info("Opening '\(item.name)' (\(content.count) chars, language: \(language ?? "plain text")) in CodeViewerPanelView.")
        chatHistoryViewModel.openTab(
            for: snippet,
            fileName: item.name,
            filePath: item.url.path
        )
        chatHistoryViewModel.isCodeViewerVisible = true
    }
}
