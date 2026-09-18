// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserAction.swift
//  Devgentic
//
//  A proof-of-intent token for service methods that bypass caching, cooldowns,
//  or debouncing. Services that expose such a "force" path accept a `UserAction`
//  parameter to declare that this invocation MUST originate from explicit user
//  interaction (a button tap, keyboard shortcut, context-menu selection).
//
//  Enforcement is social, not cryptographic — Swift doesn't have module
//  boundaries inside a single target. The value lives in three places:
//
//    1. Signature: `forceCheckServerStatus(triggeredBy: UserAction)` screams
//       "this is a bypass; don't call me from init or on-change" more loudly
//       than any doc comment.
//
//    2. Registry: Each allowed action is defined once as a static member
//       below. Adding a new one requires touching this file, which focuses
//       code review.
//
//    3. Telemetry: The `description` string is logged by callee services, so
//       bad callers surface in production logs — e.g. if a VM init somehow
//       acquires `.ollamaRefreshButton` and calls the force path, the log
//       will read "force triggered by ollama.refresh.button" from a context
//       that clearly isn't a button tap.
//
//  History: This type was added because `OllamaService.forceCheckServerStatus()`
//  was silently misused by `OllamaModelStoreViewModel.init()`, causing the
//  Ollama server to be hammered whenever SwiftUI recreated the view. The
//  signature didn't communicate its intent; the caller couldn't be blamed
//  for not reading the doc comment.
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
}
