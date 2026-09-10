// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MorningBriefSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

// MARK: - Morning Brief Source Protocol

/// Any data source that can contribute fragments to the Morning Brief.
///
/// To add a new source:
/// 1. Create a class conforming to `MorningBriefSource`.
/// 2. Register it in `MorningBriefService.sourceRegistry`.
///
/// Sources are collected in parallel — keep `gather()` fast (<2 seconds).
protocol MorningBriefSource: Identifiable where ID == String {
    /// Unique identifier for this source (e.g. "recent_conversations").
    var id: String { get }

    /// Human-readable name shown as the section header.
    var displayName: String { get }

    /// SF Symbol name for the section icon.
    var icon: String { get }

    /// Whether this source is currently enabled by the user.
    var isEnabled: Bool { get }

    /// Gathers context fragments from this source.
    /// Called on a background task — safe to do async work.
    func gather() async -> [BriefFragment]
}
