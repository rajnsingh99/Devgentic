// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    // [Orb] Spoken into the Orb voice HUD. Same rationale as `.quickAccess`: voice
    // traffic was indistinguishable from typed main-window traffic everywhere downstream.
    // An unused enum case still compiles, so this does not break Orb's deletability contract.
    case orb
    /// [Phase 6 · F3] An UNATTENDED run fired by the scheduler, not typed by anyone.
    ///
    /// ⚠️ Added because `.localUI` could not tell "the user typed this and is waiting" apart from
    /// "a cron task fired while they were away". Orb's ambient announcements speak the former
    /// and must stay silent about the latter — announcing "the task you started just finished"
    /// for a task nobody started is the failure mode of that whole feature.
    case scheduled

    /// [Tier 3] An UNATTENDED run started because a BACKGROUND TASK finished, not typed by anyone.
    ///
    /// ⚠️⚠️ NOT `.localUI`, and the reason is grant isolation rather than logging.
    /// `SessionToolApprovals` keys a standing "allow for this chat" grant on the SURFACE precisely
    /// so one cannot cross a boundary — `WorkflowRunAttendance.origin` documents the incident that
    /// forced it, where a grant made by voice let a message from a paired phone run `execute_shell`
    /// with no prompt on any surface. A woken run stamped `.localUI` would inherit every grant the
    /// user made while typing, and then spend them with nobody watching.
    ///
    /// ⚠️ It is also not `.scheduled`. That case exists so Orb's ambient announcements can stay
    /// silent about runs nobody started; a finished build is a different question and deserves its
    /// own answer rather than inheriting the scheduler's.
    case backgroundTask
}
