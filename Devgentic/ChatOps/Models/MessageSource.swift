// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessageSource.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Identifies where a message originated from.
/// Used to determine whether stream events should be mirrored to a remote transport.
enum MessageSource: String, Codable, Sendable {
    case localUI
    case telegram
    case discord
    case slack
    /// [Q2] Messages originated from the QuickAccess floating panel — distinguishes panel
    /// traffic from main-window (.localUI) in ChatOps mirroring / analytics / audit.
    case quickAccess
    // Spoken into the Orb voice HUD; distinguishes voice traffic from typed main-window traffic downstream.
    // An unused enum case still compiles, so this does not break Orb's deletability.
    case orb
    /// An unattended run fired by the scheduler, not typed by anyone.
    /// Distinct from `.localUI` so Orb's ambient announcements stay silent about runs nobody started.
    case scheduled

    /// An unattended run started because a background task finished, not typed by anyone.
    /// Not `.localUI`, whose "allow for this chat" grants it would inherit; not `.scheduled`, which Orb treats differently.
    case backgroundTask
}
