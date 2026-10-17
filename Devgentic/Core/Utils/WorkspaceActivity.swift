// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceActivity.swift
//  Devgentic
//
//  "Files on disk may have changed" — posted by the run loop and the save path, observed by
//  anything that caches disk state (today: the Git Changes panel).
//

import Foundation

/// A HINT, not a report: posters do not know whether anything changed, only that something which
/// CAN change files just finished. Observers re-read; a spurious hint costs one cheap refresh.
///
/// ⚠️ Deliberately NOT keyed by tool name. A file-mutating-tool allowlist was wrong on day one
/// (`write_file` had been removed) and missed the tools most likely to change the tree —
/// `run_command` (`sed -i`, `npm install`, `git checkout`), background tasks, folder ops. Every
/// successful tool posts; observers debounce.
///
/// Always posted on the MAIN actor, so SwiftUI `onReceive` observers update state on main.
enum WorkspaceActivity {
    static let didChange = Notification.Name("devgentic.workspaceActivity.didChange")
    /// `String` — why, for the observer's log.
    static let reasonKey = "reason"

    @MainActor
    static func post(reason: String) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [reasonKey: reason])
    }
}
