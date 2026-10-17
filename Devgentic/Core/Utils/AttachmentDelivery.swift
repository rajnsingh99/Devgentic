// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentDelivery.swift
//  Devgentic
//
//  What the model actually received for each text/document attachment, and the ONE piece of
//  arithmetic that decides it. Three sites run that arithmetic and must agree to the character:
//    • `BackendOrchestrationService.assembleTextFileContent` — builds what the MODEL gets
//    • `MessageAttachmentBuilder`                          — records it on the TRANSCRIPT
//    • `PromptFitCheck.estimatedAttachmentChars`           — prices it for the context GAUGE
//  Each used to carry its own copy. The transcript stored up to 500K chars of a file the model
//  never saw a character of, and the gauge priced the stateless fallback without the path
//  wrapper the backend adds.
//
//  Policy (user decision, 2026-10-04): a text file over the per-file budget is CUT to what
//  fits, with a marker telling the model so — the same treatment documents already got. It
//  used to be dropped whole while a PDF of the same length was cut, so the model received
//  nothing for a 120K `.java` but the first 50K of a 120K `.pdf`.
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
    //
    // Stored as scalars rather than an enum blob: three optional columns are a lightweight
    // schema change, and a hand-written field-by-field codec is exactly where new fields get
    // dropped — so these two functions are the ONLY codec and are round-trip tested.

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

    /// ⚠️ Mirrors the orchestrator's Section 2 switch exactly:
    ///  • stateless + `read_file` → manifest
    ///  • stateless WITHOUT `read_file` → injection WITH paths (the fallback the orchestrator
    ///    takes so the manifest never points at a tool the profile can't call)
    ///  • direct injection → paths only on write-capable profiles (agent / code)
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

    /// Whether the model receives the files' CONTENT — and therefore whether conversation memory
    /// indexes them, so a later turn can recall what this one saw (RAG-18).
    ///
    /// ⚠️ Keyed on the DELIVERY, not the configured strategy. The orchestrator used to gate indexing
    /// on `strategy == .directInjection`, which missed both other injecting paths: the stateless
    /// fallback (no `read_file`) and the deprecated `.contextualRAG` strategy. The model saw those
    /// files; later turns could not recall them.
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

    /// Decides each file's delivery, in order, from its length and wrapper width. The running
    /// total counts everything `assemble` emits (wrapper + body + marker), as the backend
    /// always has: a file is admitted while the total is under budget, and gets at most
    /// `min(perFile, total − used)` characters of body.
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

    /// The two lanes that inject file content, each with its own wrapper. Both are cut by the
    /// SAME allocation — knowledge sources used to be dropped whole past the budget while
    /// attachments were cut (user decision 2026-10-05: one rule for both).
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
