// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatActionsSuppressedKey.swift
//  Devgentic
//
//  [QA revival P1c] Environment flag: when true, in-bubble actions that route through the
//  MAIN window's MessagingCoordinator (Redo/regenerate, Resume interrupted run) are hidden.
//  The QuickAccess panel sets this because those actions guard on membership in the main
//  window's currentChatMessages and would benignly no-op on a panel-only message — showing a
//  dead button. Defaults to false, so the main window is unaffected.
//

import SwiftUI

private struct ChatActionsSuppressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var chatActionsSuppressed: Bool {
        get { self[ChatActionsSuppressedKey.self] }
        set { self[ChatActionsSuppressedKey.self] = newValue }
    }
}
