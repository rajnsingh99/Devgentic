// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXModelsLocation.swift
//  Devgentic
//
//  Created 2026-08-03 for G14.
//
//  `modelsDirectory` was a private computed property with no override: 76 GB of models pinned
//  to the boot volume on a machine that may have a fast external SSD, with no supported way to
//  relocate them. LM Studio, Ollama (`OLLAMA_MODELS`), Jan and GPT4All all support this.
//
//  It also contained `urls(for:).first!` — an unlogged force-unwrap in a directory-resolution
//  path that a user-configurable location makes genuinely fallible.
//

import Foundation
import os

private let logger = DGLogger(category: "MLXModelsLocation")

/// Resolves where MLX models live, honouring a user override.
///
/// ⚠️ Resolution must never trap and never silently succeed with the wrong directory. A wrong
/// answer here re-downloads gigabytes or, worse, points the partial-download cleanup at
/// somewhere it shouldn't be. Every fallback logs why it was taken.
enum MLXModelsLocation {

    /// Bookmark to the user's chosen directory.
    ///
    /// A bookmark rather than a plain path for two reasons: it survives the user moving or
    /// renaming the folder, and it keeps working if the app is ever sandboxed (it is not
    /// today — the entitlements carry only microphone access).
    private static let bookmarkKey = "mlx.models.directory.bookmark"
    /// Human-readable path, purely so settings can show the location without resolving the
    /// bookmark (which can prompt) on every render.
    private static let displayPathKey = "mlx.models.directory.displayPath"

    // MARK: - Resolution

    /// The default location, inside Application Support.
    ///
    /// Returns nil only if Application Support itself cannot be resolved — previously a `!`
    /// force-unwrap on the same lookup.
    static var defaultDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            logger.error("[MLXSTORE] Could not resolve Application Support. CONSEQUENCE: no default models directory exists; MLX downloads and the installed scan cannot function until a custom location is set.")
            return nil
        }
        return appSupport.appendingPathComponent("huggingface/models")
    }

    /// The directory in effect: the user's override when it resolves and is usable, otherwise
    /// the default.
    static func effectiveDirectory() -> URL? {
        if let custom = resolvedCustomDirectory() {
            return custom
        }
        return defaultDirectory
    }

    /// Whether a custom location is configured (regardless of whether it currently resolves).
    static var hasCustomDirectory: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// The stored path, for display in settings.
    static var displayPath: String? {
        UserDefaults.standard.string(forKey: displayPathKey)
    }

    /// Resolves the stored bookmark, or nil when none is set or it no longer works.
    private static func resolvedCustomDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            logger.error("[MLXSTORE] The custom models directory bookmark could not be resolved — the folder was probably deleted or is on an unmounted volume. CONSEQUENCE: falling back to the default location in Application Support; models in the custom folder will not be listed until it is available again or re-selected.")
            return nil
        }

        if isStale {
            // Refresh it so the next launch doesn't re-resolve a stale bookmark.
            logger.info("[MLXSTORE] Custom models directory bookmark was stale (the folder moved); refreshing it.")
            _ = setCustomDirectory(url)
        }

        guard isUsable(url) else {
            logger.error("[MLXSTORE] The custom models directory at \(url.path) is not readable/writable. CONSEQUENCE: falling back to the default location. If it is under Desktop, Documents or Downloads, macOS may be withholding access until the app is granted permission in System Settings › Privacy & Security › Files and Folders.")
            return nil
        }
        return url
    }

    /// True when the app can actually read and write there.
    ///
    /// ⚠️ Worth checking explicitly: a folder under Desktop/Documents/Downloads is subject to
    /// TCC, so the picker can hand back a URL the app then cannot use. Failing loudly here
    /// beats a mysteriously empty model list.
    static func isUsable(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fm.isReadableFile(atPath: url.path) && fm.isWritableFile(atPath: url.path)
    }

    // MARK: - Mutation

    /// Points the store at `url`. Returns false when it can't be used, leaving the previous
    /// setting untouched.
    @discardableResult
    static func setCustomDirectory(_ url: URL) -> Bool {
        guard isUsable(url) else {
            logger.error("[MLXSTORE] Refusing to use \(url.path) as the models directory — it is not a readable, writable folder. CONSEQUENCE: the previous location is kept.")
            return false
        }

        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            logger.error("[MLXSTORE] Could not create a bookmark for \(url.path). CONSEQUENCE: the custom models directory was not saved; the previous location is kept.")
            return false
        }

        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: displayPathKey)
        logger.notice("[MLXSTORE] Models directory set to \(url.path). Existing models in the previous location are NOT moved — they simply stop being listed until the old location is selected again.")
        return true
    }

    /// Returns to the default location. Does not move or delete anything.
    static func clearCustomDirectory() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: displayPathKey)
        logger.notice("[MLXSTORE] Models directory reset to the default in Application Support. Models in the custom folder are left where they are.")
    }
}
