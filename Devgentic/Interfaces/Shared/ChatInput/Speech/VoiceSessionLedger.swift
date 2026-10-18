// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VoiceSessionLedger.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Which surface owns a voice session. Typed so logs and busy-errors can name the
/// holder ("Voice input is already active in the Quick Access panel").
enum VoiceSurface: String, Sendable, Codable, CaseIterable {
    case mainComposer = "main-composer"
    case quickAccess = "quickaccess"
    case orb = "orb"

    /// User-facing name for busy messages.
    var displayName: String {
        switch self {
        case .mainComposer: return String(localized: "the main composer")
        case .quickAccess: return String(localized: "the Quick Access panel")
        case .orb: return String(localized: "the Orb overlay")
        }
    }
}

struct VoiceSessionLedger: Equatable, Sendable {

    struct Session: Equatable, Sendable {
        let id: UUID
        let owner: VoiceSurface

        /// Short id for log correlation across start/state/stop lines.
        var shortID: String { String(id.uuidString.prefix(8)) }
    }

    enum EndDisposition: Equatable, Sendable {
        /// This call ended the active session — the caller performs the real teardown.
        case finalized
        /// The session was already ended (double-stop race, superseded) — do nothing.
        case stale
    }

    private(set) var active: Session?
    private(set) var pendingStopID: UUID?

    var isBusy: Bool { active != nil }

    /// V2: claim the single slot. Returns `nil` when another session holds it —
    /// the caller must reject the start (NOT overwrite the live session).
    mutating func begin(owner: VoiceSurface) -> Session? {
        guard active == nil else { return nil }
        let session = Session(id: UUID(), owner: owner)
        active = session
        pendingStopID = nil
        return session
    }

    /// V1: record that a stop was REQUESTED, before any await — so when the blocking
    /// stream call returns, a requested end is distinguishable from WhisperKit's
    /// swallowed-error break. Returns the session being stopped, or `nil` if idle.
    mutating func markStopRequested() -> Session? {
        guard let session = active else { return nil }
        pendingStopID = session.id
        return session
    }

    /// V6: end bookkeeping for `id`. Only the CURRENT session may finalize; a stop
    /// that lost a race reports `.stale` and must skip its teardown.
    mutating func end(_ id: UUID) -> EndDisposition {
        guard active?.id == id else { return .stale }
        active = nil
        pendingStopID = nil
        return .finalized
    }

    /// V1: the blocking stream call returned for `id` — true when NOTHING requested
    /// this end, i.e. WhisperKit broke its loop on a swallowed error with the audio
    /// engine still running.
    func isUnrequestedEnd(_ id: UUID) -> Bool {
        active?.id == id && pendingStopID != id
    }
}

// MARK: - Dead-Mic Detection

/// Detects sessions where the engine opened but never delivered audio, as a pure, testable core.
/// A session is dead only when it lasted at least `minimumSessionDuration` and no energy sample ever arrived.
struct DeadMicDetector: Equatable, Sendable {

    /// Below this, a silent session is presumed to be a quick manual stop.
    static let minimumSessionDuration: TimeInterval = 1.0

    private(set) var consecutiveDeadSessions = 0
    private(set) var sessionSawAudio = false

    mutating func beginSession() {
        sessionSawAudio = false
    }

    /// Call on every state callback that carries energy samples.
    mutating func recordAudioArrived() {
        sessionSawAudio = true
        // A live session proves the engine recovered — the streak is over.
        consecutiveDeadSessions = 0
    }

    /// Assess a session that ENDED (stop or auto-stop — not user cancel).
    /// Returns `true` when the session was dead; increments the streak.
    mutating func assessSessionEnd(duration: TimeInterval) -> Bool {
        guard !sessionSawAudio, duration >= Self.minimumSessionDuration else {
            return false
        }
        consecutiveDeadSessions += 1
        return true
    }
}
