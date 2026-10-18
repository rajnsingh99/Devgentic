// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentLiveWriteEvent.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "AgentLiveWriteEvent")

/// Live-agent-tab plumbing: `ActiveStreamManager` posts these as file-writing tool calls start and finish,
/// and `ChatHistoryViewModel` turns them into live Code Viewer tabs.
/// Tabs update in place or pulse the minimized pill; the panel is never auto-opened unless follow is on.
enum AgentLiveWriteEvent {

    static let began = Notification.Name("AgentLiveWriteBegan")
    static let completed = Notification.Name("AgentLiveWriteCompleted")
    static let payloadKey = "payload"

    // Why: derived from the executor's snapshot sets; add a name to those sets, not here, or the drift test fails.
    /// Tools whose params carry the full post-state, so a live tab can show the write: `preSnapshot - postSnapshot`.
    /// Append and edit tools stay on the completion-chip path.
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

    /// Payload for a starting file write, or nil when the call should not produce a live tab.
    /// Non-file tools return nil silently; live-write candidates log why no tab appeared.
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
