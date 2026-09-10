// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MessageSource.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
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
    // [Jarvis] Spoken into the Jarvis voice HUD. Same rationale as `.quickAccess`: voice
    // traffic was indistinguishable from typed main-window traffic everywhere downstream.
    // An unused enum case still compiles, so this does not break Jarvis's deletability contract.
    case jarvis
    /// [Phase 6 · F3] An UNATTENDED run fired by the scheduler, not typed by anyone.
    ///
    /// ⚠️ Added because `.localUI` could not tell "the user typed this and is waiting" apart from
    /// "a cron task fired while they were away". Jarvis's ambient announcements speak the former
    /// and must stay silent about the latter — announcing "the task you started just finished"
    /// for a task nobody started is the failure mode of that whole feature.
    case scheduled
}
