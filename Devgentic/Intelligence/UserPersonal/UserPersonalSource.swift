// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserPersonalSource.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - User Personal Source Protocol

/// Any data source that can contribute profile observations.
///
/// To add a new source:
/// 1. Create a class conforming to `UserPersonalSource`.
/// 2. Register it in `UserPersonalService.sourceRegistry`.
///
/// Sources receive pre-fetched conversation data from the service
/// (a single SwiftData query, distributed to all sources).
/// Keep `gather(from:)` fast — pure computation, no I/O.
protocol UserPersonalSource: Identifiable, Sendable where ID == String {
    /// Unique identifier for this source (e.g. "conversation_patterns").
    var id: String { get }

    /// Human-readable name shown in diagnostics.
    var displayName: String { get }

    /// Whether this source is currently enabled.
    var isEnabled: Bool { get }

    /// Analyzes conversation data and returns profile observations.
    /// Called on a background task — safe to do async work.
    func gather(from conversations: [UserPersonalConversationData]) async -> [ProfileFragment]
}
