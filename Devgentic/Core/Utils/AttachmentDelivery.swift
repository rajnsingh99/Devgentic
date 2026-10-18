// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentDelivery.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Persisted on `AttachedTextFile`; shown on the transcript chip and in exports.
enum AttachmentDelivery: Codable, Equatable, Sendable {
    /// The whole content was injected.
    case full
    /// Only the first `sentChars` of `totalChars` were injected, followed by a marker.
    case truncated(sentChars: Int, totalChars: Int)
    /// Nothing was injected: earlier files had used the total budget.
    case omitted(totalChars: Int)
    /// Stateless strategy: the model got the path and reads the file on demand.
    case pathOnly

    /// Chip / export wording. `nil` for `.full`, which needs no note.
    var note: String? {
        switch self {
        case .full:
            return nil
        case .truncated(let sent, let total):
            return String(localized: "Model received the first \(sent.formatted()) of \(total.formatted()) characters")
        case .omitted:
            return String(localized: "Not sent to the model: earlier attachments used the size budget")
        case .pathOnly:
            return String(localized: "Sent as a path; the agent reads it on demand")
        }
    }

    // MARK: Flat storage (SwiftData)
    // Stored as scalar columns rather than an enum blob; these two functions are the only codec and are round-trip
    // tested.

    var storage: (kind: String, sent: Int?, total: Int?) {
        switch self {
        case .full:                          return ("full", nil, nil)
        case .truncated(let sent, let total): return ("truncated", sent, total)
        case .omitted(let total):            return ("omitted", nil, total)
        case .pathOnly:                      return ("pathOnly", nil, nil)
        }
    }

    init?(kind: String?, sent: Int?, total: Int?) {
        switch kind {
        case "full":      self = .full
        case "truncated": guard let sent, let total else { return nil }; self = .truncated(sentChars: sent, totalChars: total)
        case "omitted":   guard let total else { return nil }; self = .omitted(totalChars: total)
        case "pathOnly":  self = .pathOnly
        default:          return nil
        }
    }
}

/// How a profile delivers attachments — resolved ONCE, from the profile, for all three sites.
enum AttachmentDeliveryMode: Equatable, Sendable {
    /// Stateless with `read_file`: a path manifest, no content.
    case pathManifest
    /// Content injected; `includeAbsolutePaths` widens each file's wrapper label.
    case inject(includeAbsolutePaths: Bool)

    /// Mirrors the orchestrator's Section 2 switch: stateless with `read_file` gets a manifest; stateless without it
    /// injects with paths; direct injection includes paths only on write-capable profiles (agent, code).
    @MainActor
    static func resolve(for profile: BackendProfileModel) -> AttachmentDeliveryMode {
        switch profile.resolvedFileContextStrategy {
        case .stateless:
            return profile.enabledToolNames.contains("read_file")
                ? .pathManifest
                : .inject(includeAbsolutePaths: true)
        case .contextualRAG, .directInjection:
            return .inject(includeAbsolutePaths: profile.profileType == .agent || profile.profileType == .code)
        }
    }

    /// Whether the model receives the files' content, and therefore whether conversation memory indexes them for later
    /// recall. Keyed on the delivery, not the configured strategy, so every injecting path counts.
    var deliversContent: Bool {
        if case .inject = self { return true }
        return false
    }
}

/// The injection arithmetic. Pure, so the transcript and the gauge can run the backend's
/// exact rule without the backend.
enum DirectInjectionPlan {

    /// Below this, a cut would hand the model a meaningless sliver — the file is omitted instead.
    static let minimumSlice = 1_000

    static func truncationMarker(sent: Int, total: Int) -> String {
        "\n[Truncated: only the first \(sent) of \(total) characters of this file were included.]"
    }

    static func wrapperLabel(name: String, path: String, includeAbsolutePaths: Bool) -> String {
        includeAbsolutePaths ? "\(name) (\(path))" : name
    }

    static func wrap(body: String, name: String, label: String) -> String {
        "\n\n--- Start of file: \(label) ---\n\(body)\n--- End of file: \(name) ---"
    }

    /// Width of the wrapper around a body — derived from `wrap` itself so it cannot drift.
    static func wrapperWidth(name: String, label: String) -> Int {
        wrap(body: "", name: name, label: label).count
    }

    /// Decides each file's delivery, in order, from its length and wrapper width. The running total counts everything
    /// `assemble` emits; a file is admitted while the total is under budget and gets at most `min(perFile, total -
    /// used)` characters of body.
    static func allocate(lengths: [Int], wrapperWidths: [Int]) -> [AttachmentDelivery] {
        precondition(lengths.count == wrapperWidths.count)
        var used = 0
        var deliveries: [AttachmentDelivery] = []
        for (length, wrapper) in zip(lengths, wrapperWidths) {
            let length = max(length, 0)
            guard used < DirectInjectionBudget.total else {
                deliveries.append(.omitted(totalChars: length))
                continue
            }
            let allowance = min(DirectInjectionBudget.perFile, DirectInjectionBudget.total - used)
            if length <= allowance {
                deliveries.append(.full)
                used += wrapper + length
            } else if allowance >= minimumSlice {
                deliveries.append(.truncated(sentChars: allowance, totalChars: length))
                used += wrapper + allowance + truncationMarker(sent: allowance, total: length).count
            } else {
                deliveries.append(.omitted(totalChars: length))
            }
        }
        return deliveries
    }

    struct File {
        let name: String
        let path: String
        let content: String
    }

    /// The two lanes that inject file content, each with its own wrapper; both are cut by the same allocation.
    enum Layout: Equatable, Sendable {
        /// Current-turn attachments: `--- Start of file: … ---` / `--- End of file: … ---`.
        case attachment(includeAbsolutePaths: Bool)
        /// A profile's knowledge sources (the `<knowledge_base>` layer): `--- Knowledge: … ---`.
        case knowledge
    }

    static func wrap(body: String, name: String, path: String, layout: Layout) -> String {
        switch layout {
        case .attachment(let includeAbsolutePaths):
            return wrap(body: body, name: name,
                        label: wrapperLabel(name: name, path: path, includeAbsolutePaths: includeAbsolutePaths))
        case .knowledge:
            return "\n\n--- Knowledge: \(name) ---\n\(body)"
        }
    }

    static func wrapperWidth(name: String, path: String, layout: Layout) -> Int {
        wrap(body: "", name: name, path: path, layout: layout).count
    }

    /// Builds the injected text and each file's delivery — the backend's assembler for both lanes.
    static func assemble(_ files: [File], layout: Layout) -> (text: String, deliveries: [AttachmentDelivery]) {
        let deliveries = allocate(
            lengths: files.map(\.content.count),
            wrapperWidths: files.map { wrapperWidth(name: $0.name, path: $0.path, layout: layout) }
        )
        var text = ""
        for (file, delivery) in zip(files, deliveries) {
            switch delivery {
            case .full:
                text += wrap(body: file.content, name: file.name, path: file.path, layout: layout)
            case .truncated(let sent, let total):
                text += wrap(body: String(file.content.prefix(sent)) + truncationMarker(sent: sent, total: total),
                             name: file.name, path: file.path, layout: layout)
            case .omitted, .pathOnly:
                continue
            }
        }
        return (text, deliveries)
    }

    /// Attachment-lane convenience.
    static func assemble(_ files: [File], includeAbsolutePaths: Bool) -> (text: String, deliveries: [AttachmentDelivery]) {
        assemble(files, layout: .attachment(includeAbsolutePaths: includeAbsolutePaths))
    }
}
