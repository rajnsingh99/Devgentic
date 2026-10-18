// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceActivity.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: not keyed by tool name: an allowlist misses `run_command` and folder ops, so every successful tool posts
/// A hint that something which can change files just finished; observers re-read and debounce.
/// Always posted on the main actor so SwiftUI `onReceive` observers update state on main.
enum WorkspaceActivity {
    static let didChange = Notification.Name("devgentic.workspaceActivity.didChange")
    /// `String` — why, for the observer's log.
    static let reasonKey = "reason"

    @MainActor
    static func post(reason: String) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [reasonKey: reason])
    }
}
