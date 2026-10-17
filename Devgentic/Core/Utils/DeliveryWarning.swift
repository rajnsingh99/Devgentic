// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeliveryWarning.swift
//  Devgentic
//
//  Tells the user BEFORE a send which files the model will receive only part of — or none of —
//  why, and what to do instead. Shown by the composer, QuickAccess and the profile editor's
//  knowledge-source rows.
//
//  ⚠️ The preview runs the backend's exact read-then-plan (`readFileContentOrThrow` at
//  `DirectInjectionBudget.readCap`, then `DirectInjectionPlan.allocate`), so a warning describes
//  what WILL happen, not an estimate. A stat'd-size guess would warn on a 2 MB PDF that extracts
//  to 30K characters and stay silent on multi-byte text.
//

import Foundation

struct DeliveryWarning: Identifiable, Equatable, Sendable {
    /// The file's path — stable across recomputes, so the view does not flicker.
    let id: String
    let fileName: String
    /// What happens: "The model will receive only the first 50,000 of 120,000 characters."
    let problem: String
    /// Why it happens.
    let reason: String
    /// What the user can do instead.
    let suggestion: String
}

enum DeliveryWarnings {

    /// Which injecting lane — decides wrapper widths and the wording.
    enum Lane: Equatable, Sendable {
        case attachment(includeAbsolutePaths: Bool)
        case knowledge

        var layout: DirectInjectionPlan.Layout {
            switch self {
            case .attachment(let paths): return .attachment(includeAbsolutePaths: paths)
            case .knowledge:             return .knowledge
            }
        }
    }

    /// The remedy that actually exists for this profile.
    enum Remedy: Equatable, Sendable {
        /// An agent can read files on demand (stateless strategy + `read_file`): no size limit.
        case readOnDemand
        /// Bots and workflows have no file tools — the content itself has to shrink.
        case split

        static func forProfileType(_ type: ProfileType?) -> Remedy {
            type == .agent ? .readOnDemand : .split
        }
    }

    /// A file as the preview sees it.
    struct Candidate: Sendable {
        let name: String
        let path: String
        let url: URL
    }

    enum Outcome: Equatable, Sendable {
        case planned(AttachmentDelivery)
        /// Over `readCap` — the reader refuses it before the plan runs.
        case tooLargeToRead
    }

    /// Reads and plans `candidates` exactly as the backend will, in order. A file the reader
    /// fails on for any OTHER reason (missing, binary, a folder) yields no outcome — the send
    /// path reports those with their own cause.
    static func outcomes(for candidates: [Candidate], lane: Lane,
                         reader: FileProcessorService) async -> [(Candidate, Outcome)] {
        var readable: [(Candidate, String)] = []
        var unreadable: [(Candidate, Outcome)] = []
        for candidate in candidates {
            if Task.isCancelled { return [] }
            do {
                let content = try await reader.readFileContentOrThrow(for: candidate.url, maxSize: DirectInjectionBudget.readCap)
                readable.append((candidate, content))
            } catch FileRetrievalError.tooLarge {
                unreadable.append((candidate, .tooLargeToRead))
            } catch {
                continue
            }
        }
        let deliveries = DirectInjectionPlan.allocate(
            lengths: readable.map(\.1.count),
            wrapperWidths: readable.map {
                DirectInjectionPlan.wrapperWidth(name: $0.0.name, path: $0.0.path, layout: lane.layout)
            })
        return zip(readable, deliveries).map { ($0.0, .planned($1)) } + unreadable
    }

    /// The user-facing warnings for the outcomes that lose content. `.full` and `.pathOnly`
    /// produce none.
    static func warnings(for outcomes: [(Candidate, Outcome)], lane: Lane, remedy: Remedy) -> [DeliveryWarning] {
        outcomes.compactMap { candidate, outcome in
            guard let (problem, reason) = describe(outcome, lane: lane) else { return nil }
            return DeliveryWarning(id: candidate.path, fileName: candidate.name,
                                   problem: problem, reason: reason,
                                   suggestion: suggestion(remedy: remedy, lane: lane))
        }
    }

    static func describe(_ outcome: Outcome, lane: Lane) -> (problem: String, reason: String)? {
        let perFile = DirectInjectionBudget.perFile.formatted()
        let total = DirectInjectionBudget.total.formatted()
        let scope = lane == .knowledge
            ? String(localized: "this profile's knowledge sources")
            : String(localized: "this message's attachments")
        switch outcome {
        case .planned(.full), .planned(.pathOnly):
            return nil
        case .planned(.truncated(let sent, let fileTotal)):
            let problem = String(localized: "The model will receive only the first \(sent.formatted()) of \(fileTotal.formatted()) characters.")
            let reason = sent >= DirectInjectionBudget.perFile
                ? String(localized: "Each file whose contents are sent to the model is limited to \(perFile) characters.")
                : String(localized: "Earlier files used most of the \(total)-character limit for \(scope), so this one gets what is left.")
            return (problem, reason)
        case .planned(.omitted):
            return (String(localized: "Not sent to the model."),
                    String(localized: "Earlier files used the \(total)-character limit for \(scope)."))
        case .tooLargeToRead:
            return (String(localized: "Not sent to the model."),
                    String(localized: "It is over \(DirectInjectionBudget.readCap.formatted()) characters, too large to read."))
        }
    }

    static func suggestion(remedy: Remedy, lane: Lane) -> String {
        switch (remedy, lane) {
        case (.readOnDemand, .attachment):
            return String(localized: "Enable read_file for this agent: it then reads the whole file on demand, with no size limit.")
        case (.readOnDemand, .knowledge):
            return String(localized: "Set this agent's file handling to on-demand reading with read_file enabled, or split the document into smaller files.")
        case (.split, .attachment):
            return String(localized: "Attach only the part you need, or split the file into smaller ones.")
        case (.split, .knowledge):
            return String(localized: "Split the document into smaller files, or keep only the sections this profile needs.")
        }
    }
}
