// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LeftoverDownloadNotice.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Shows a once-per-launch toast that unfinished MLX downloads are taking up disk space.
/// `MLXModelService.scanPartialDownloadsAtLaunch` decides whether there is anything to report; this renders its verdict.
struct LeftoverDownloadNoticeModifier: ViewModifier {
    /// Passed in, not read from the environment: this is applied at the app root, OUTSIDE the
    /// `.environment(toastManager)` that the views below it read.
    let toastManager: ToastManager

    func body(content: Content) -> some View {
        content.onChange(of: MLXModelService.shared.pendingLeftoverNotice, initial: true) { _, notice in
            guard let notice else { return }
            MLXModelService.shared.pendingLeftoverNotice = nil
            toastManager.show(Self.message(for: notice), style: .warning, duration: 10)
        }
    }

    static func message(for notice: MLXModelService.LeftoverNotice) -> String {
        let size = ByteCountFormatter.string(fromByteCount: notice.bytes, countStyle: .file)
        if notice.count == 1 {
            return String(localized: "1 unfinished download is using \(size). Open Downloads to resume or delete it.")
        }
        return String(localized: "\(notice.count) unfinished downloads are using \(size). Open Downloads to resume or delete them.")
    }
}
