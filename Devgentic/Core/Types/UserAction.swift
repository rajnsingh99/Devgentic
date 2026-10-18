// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserAction.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Declares that the current call is triggered by explicit user interaction.
/// Required by service methods that bypass caching or cooldowns.
struct UserAction: Sendable, CustomStringConvertible {

    let description: String

    /// Intentionally private so other files cannot fabricate actions ad-hoc.
    /// All allowed actions live in the static registry below.
    private init(description: String) {
        self.description = description
    }

    // MARK: - Action Registry
    //
    // Add new actions here as new "force" APIs appear. Keep descriptions
    // hierarchical (`<domain>.<surface>.<control>`) for easy log grepping.

    /// User tapped the refresh button (or pressed ⌘R) in the Ollama model
    /// store, explicitly asking the server to be re-probed.
    static let ollamaRefreshButton = UserAction(description: "ollama.refresh.button")

    /// User pressed Download (or Retry) on the Setup Assistant's model step with Ollama selected.
    /// A stale "disconnected" from before they started Ollama must not fail the download.
    static let onboardingDownloadButton = UserAction(description: "onboarding.model.download")
}
