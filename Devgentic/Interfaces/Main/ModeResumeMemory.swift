// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModeResumeMemory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Remembers the selection in each interface mode so switching modes resumes instead of dropping to Home.
/// Only the selection is kept (the composer draft is keyed per mode), and it is session-scoped.
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

    /// Where to land on entering `mode`. A remembered conversation that was deleted while away resumes as that mode's Home
    /// rather than selecting a ghost.
    func resume(_ mode: MainApplicationViewModel.InterfaceMode, conversationExists: (UUID) -> Bool) -> Spot {
        guard let spot = spots[mode] else { return Spot() }
        if let id = spot.conversationID {
            return conversationExists(id) ? Spot(conversationID: id, profileID: nil) : Spot()
        }
        return spot
    }
}
