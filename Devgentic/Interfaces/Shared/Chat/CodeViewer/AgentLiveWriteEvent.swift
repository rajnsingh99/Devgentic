// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AgentLiveWriteEvent.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import os

private let logger = DGLogger(category: "AgentLiveWriteEvent")

/// Live-agent-tab plumbing: `ActiveStreamManager` posts these as file-writing tool calls
/// start and finish, and `ChatHistoryViewModel` turns them into live Code Viewer tabs.
///
/// BADGE-ONLY policy (user decision 2026-07-25): live tabs update in place when the panel
/// is open and make the minimized pill pulse otherwise — the panel is NEVER auto-opened
/// and the active tab is never switched unless the user's follow toggle is on.
///
/// The payload factories are pure and unit-tested; the notification layer just carries
/// them. Loose coupling via NotificationCenter mirrors `SpeechService.speechOpenCodeViewer`
/// — ActiveStreamManager (Core) must not depend on the chat view model (Interfaces).
enum AgentLiveWriteEvent {

    static let began = Notification.Name("AgentLiveWriteBegan")
    static let completed = Notification.Name("AgentLiveWriteCompleted")
    static let payloadKey = "payload"

    /// Live tabs cover the FULL-CONTENT writers only. Append writes carry just the
    /// fragment (post-state unknowable before the pre-read lands) and edit tools carry
    /// find/replace strings — both stay on the completion-chip path.
    ///
    /// ⚠️ [CR52/CR59] This is the FOURTH member of a four-way contract, and it is the one that
    /// drifted. `create_file` was in `ToolExecutionLoop.preSnapshotToolNames`, in
    /// `TimelineFileViewerAction.chipEligibleTools` and in `primaryLabel`'s write case, but never
    /// here — it was missing from the day this set was introduced, not removed later. Since
    /// `create_file` is `.libraryExceptCode` it is the AGENT and WORKFLOW profiles' ordinary
    /// creation tool, so those profiles got no live tab, no pulsing pill and no "agent is writing"
    /// banner for a file creation, while `write_file` — the same visibility class — did. The nil
    /// was SILENT: the guards below return before `skip` is even declared.
    ///
    /// ⚠️ The membership rule is DERIVED, not a list to curate by hand: this set is exactly the
    /// pre-snapshotted tools whose params already carry the full post-state, i.e.
    /// `preSnapshot − postSnapshot`. That is what "full-content writer" means above, and
    /// `SnapshotToolContractDriftTests` now binds both directions of it so a fifth member cannot
    /// drift in or out silently. Do not add a name here without adding it to the executor's
    /// snapshot sets — the test will say so.
    static let liveWriteToolNames: Set<String> = [
        "write_file", "overwrite_file", "create_new_file", "create_file"
    ]

    /// Same cap as the executor's snapshots — a live tab isn't worth more memory than
    /// a persisted diff is.
    static let liveContentByteLimit = 512_000

    struct Began: Sendable {
        let conversationID: UUID
        let path: String
        let fileName: String
        let proposedContent: String
    }

    struct Completed: Sendable {
        let conversationID: UUID
        /// Absolute path — the live tab's identity (a basename collides across directories).
        let path: String
        let fileName: String
        let isSuccess: Bool
        let preWriteContent: String?
    }

    /// Payload for a STARTING file write, or nil when the call shouldn't produce a live
    /// tab (non-file tool, append mode, unparseable/empty args, over the cap).
    ///
    /// Non-candidates return nil SILENTLY — every shell command would otherwise log. Once
    /// the tool is a live-write candidate, each nil says why no tab appeared, since that is
    /// the question a missing live tab raises on-device.
    static func began(toolName: String, params: String, conversationID: UUID) -> Began? {
        guard liveWriteToolNames.contains(toolName) else { return nil }

        func skip(_ reason: String) -> Began? {
            logger.info("[CodeViewer] No live tab for '\(toolName)' in \(conversationID.uuidString.prefix(8)) — \(reason). The completion chip on the timeline row is unaffected.")
            return nil
        }

        guard let arguments = parsedParams(params) else {
            return skip("tool params are not decodable JSON")
        }
        guard let path = filePath(in: arguments) else {
            return skip("no 'path'/'file_path' argument")
        }
        guard !(toolName == "write_file" && isAppendMode(arguments)) else {
            // Expected by design — the fragment alone can't be shown as a file.
            return nil
        }
        guard let content = arguments["content"] as? String, !content.isEmpty else {
            return skip("write to '\((path as NSString).lastPathComponent)' carried no 'content'")
        }
        guard content.utf8.count <= liveContentByteLimit else {
            return skip("proposed content for '\((path as NSString).lastPathComponent)' is \(content.utf8.count) bytes, over the \(liveContentByteLimit)-byte live-tab cap")
        }
        return Began(
            conversationID: conversationID,
            path: FilePathResolver.resolve(path),
            fileName: (path as NSString).lastPathComponent,
            proposedContent: content
        )
    }

    /// Payload for a FINISHED file write (success or failure), or nil for calls that
    /// never produced a live tab.
    static func completed(toolName: String, params: String, isSuccess: Bool, preWriteContent: String?, conversationID: UUID) -> Completed? {
        guard liveWriteToolNames.contains(toolName),
              let arguments = parsedParams(params),
              let path = filePath(in: arguments),
              !(toolName == "write_file" && isAppendMode(arguments)) else { return nil }
        return Completed(
            conversationID: conversationID,
            path: FilePathResolver.resolve(path),
            fileName: (path as NSString).lastPathComponent,
            isSuccess: isSuccess,
            preWriteContent: preWriteContent
        )
    }

    // MARK: - Param parsing (mirrors TimelineFileViewerAction / WriteFileTool decoding)

    private static func parsedParams(_ params: String) -> [String: Any]? {
        guard let data = params.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func filePath(in arguments: [String: Any]) -> String? {
        guard let path = (arguments["path"] as? String) ?? (arguments["file_path"] as? String),
              !path.isEmpty else { return nil }
        return path
    }

    private static func isAppendMode(_ arguments: [String: Any]) -> Bool {
        for key in ["append", "isAppend", "shouldAppend", "appending"] {
            if let flag = arguments[key] as? Bool { return flag }
            if let string = arguments[key] as? String, let flag = Bool(string.lowercased()) { return flag }
        }
        return false
    }
}
