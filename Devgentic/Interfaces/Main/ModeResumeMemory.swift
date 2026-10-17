// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModeResumeMemory.swift
//  Devgentic
//
//  Where the user was in each interface mode, so switching modes RESUMES instead of dropping to
//  Home. A mode switch used to clear the selection and the profile every time: leaving Code for
//  a moment lost the open session and its project, and leaving Chat lost the conversation.
//
//  Only the SELECTION is remembered. Everything else follows from re-selecting it, exactly as a
//  sidebar click does — messages, the conversation's profile, and in Code its project folder
//  (`restoreCodeProjectForSelectedConversation`). The composer draft is NOT carried: it is keyed
//  per mode (`ComposerDraftStore.Key`) and swapped by the composer.
//
//  Session-scoped: a relaunch starts each mode at Home.
//

import Foundation

struct ModeResumeMemory {

    /// What a mode was showing when it was left.
    struct Spot: Equatable {
        /// The selected conversation, or nil for Home.
        var conversationID: UUID?
        /// The profile picked on Home. Not used when a conversation is resumed — the
        /// conversation brings its own.
        var profileID: UUID?
    }

    private var spots: [MainApplicationViewModel.InterfaceMode: Spot] = [:]

    mutating func leave(_ mode: MainApplicationViewModel.InterfaceMode, at spot: Spot) {
        spots[mode] = spot
    }

    /// Where to land on entering `mode`. A remembered conversation that no longer exists (deleted
    /// while away) resumes as that mode's Home rather than selecting a ghost.
    func resume(_ mode: MainApplicationViewModel.InterfaceMode, conversationExists: (UUID) -> Bool) -> Spot {
        guard let spot = spots[mode] else { return Spot() }
        if let id = spot.conversationID {
            return conversationExists(id) ? Spot(conversationID: id, profileID: nil) : Spot()
        }
        return spot
    }
}
