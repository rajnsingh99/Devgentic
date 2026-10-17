// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentIntake.swift
//  Devgentic
//
//  The ONE accept/refuse decision for a file a user is attaching, made at ATTACH time so a
//  file no send path can carry is refused while the user can still pick another.
//
//  Every interactive attach route funnels here:
//    • main composer (Chat + Code) — `ChatInputViewModel.addAttachedFiles`
//      (`@` picker, drag-and-drop, file panels)
//    • QuickAccess panel — `QuickAccessContentView.appendAttachments`
//  Scheduled tasks carry the composer's already-admitted files; Orb and ChatOps accept none.
//
//  ⚠️ Before this, the rules were split: `FileAttachmentPicker` refused oversized images and
//  silently dropped video, but only for the panel and drag-drop — the `@` picker bypassed
//  both — and nothing refused binaries, which failed at SEND as a read error the model never
//  saw (`January2026.class`, 2026-10-04).
//
//  ⚠️ Delivery is NOT decided here. Size budgets, strategy (direct vs stateless) and the
//  workflow document lane stay with their owners; this only refuses what the active profile's
//  lane cannot carry.
//
//  Folders (ATT-3) depend on that lane, so the caller passes the profile's
//  `AttachmentDeliveryMode`:
//    • `.pathManifest` — ACCEPTED: the agent gets the folder's path and can list it.
//    • `.inject`       — REFUSED: injection sends file CONTENTS and a folder has none. It used
//      to be accepted and fail at send as "Couldn't read 'X' — Try re-attaching", advice that
//      could never work.
//    • nil (profile unknown) — accepted; the send path reports `.isFolder` accurately if the
//      profile turns out to inject (e.g. the user switched profiles after attaching).
//

import Foundation

enum AttachmentIntake {

    struct Refusal: Equatable {
        let item: FileSystemItem
        let reason: String
    }

    enum Verdict: Equatable, Sendable {
        case accept(AttachmentKind)
        case refuse(String)
    }

    static func evaluate(_ item: FileSystemItem, deliveryMode: AttachmentDeliveryMode? = nil) -> Verdict {
        let kind = AttachmentClassifier.classify(item)
        switch kind {
        case .folder:
            if case .inject = deliveryMode {
                return .refuse(String(localized: "is a folder. This profile sends file contents to the model, and a folder has none. Attach the files inside it, or use an agent with read_file enabled."))
            }
            return .accept(kind)
        case .binary:
            return .refuse(String(localized: "is a binary file and can't be sent as text. Attach its source file instead."))
        case .video:
            return .refuse(String(localized: "is a video, which attachments can't carry."))
        case .image:
            let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard bytes <= ImageConstraints.maxAttachmentImageBytes else {
                let mb = ImageConstraints.maxAttachmentImageBytes / (1024 * 1024)
                return .refuse(String(localized: "is over the \(mb) MB image limit."))
            }
            return .accept(kind)
        case .document, .text:
            return .accept(kind)
        }
    }

    static func partition(_ items: [FileSystemItem], deliveryMode: AttachmentDeliveryMode? = nil) -> (accepted: [FileSystemItem], refused: [Refusal]) {
        var accepted: [FileSystemItem] = []
        var refused: [Refusal] = []
        for item in items {
            switch evaluate(item, deliveryMode: deliveryMode) {
            case .accept:              accepted.append(item)
            case .refuse(let reason):  refused.append(Refusal(item: item, reason: reason))
            }
        }
        return (accepted, refused)
    }

    /// One user-facing line per refused file, for a toast or alert.
    /// - Parameter removed: the files were ALREADY attached and have just been taken out by a
    ///   re-check (profile switch, restored draft) — worded so the user knows they went away.
    static func summary(_ refused: [Refusal], removed: Bool = false) -> String? {
        guard !refused.isEmpty else { return nil }
        let lines = refused.map { "'\($0.item.name)' \($0.reason)" }
        let lead = removed
            ? String(localized: "Removed from this message: ")
            : String(localized: "Not attached: ")
        return lead + lines.joined(separator: "\n")
    }
}
