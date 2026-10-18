// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatActionsSuppressedKey.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Environment flag that hides in-bubble actions routed through the main window's MessagingCoordinator (Redo, Resume).
/// The QuickAccess panel sets it; defaults to false.
private struct ChatActionsSuppressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var chatActionsSuppressed: Bool {
        get { self[ChatActionsSuppressedKey.self] }
        set { self[ChatActionsSuppressedKey.self] = newValue }
    }
}
