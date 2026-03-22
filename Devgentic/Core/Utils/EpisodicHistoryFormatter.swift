//
//  EpisodicHistoryFormatter.swift
//  Devgentic
//
//  Created for Memory Architecture Migration.
//  Updated: Phase 3 — XML Episodic Memory with executable tool recipes.
//

import Foundation

/// Adapts the visual UI chat history into the cognitive SessionGraph state
/// and produces XML-based episodic memory for LLM prompt injection.
struct EpisodicHistoryFormatter {

    // MARK: - XML Escape Helper

    /// Escapes special characters for safe use in XML attribute values and text content.
    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Truncates a string to a maximum length, appending "..." if truncated.
    private static func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength - 3)) + "..."
    }

    // MARK: - Params Parsing

    /// Parses a serialized JSON params string into a flat [String: String] dictionary.
    /// Nested values are serialized back to compact JSON strings.
    private static func parseParams(_ jsonString: String) -> [String: String] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in obj {
            switch value {
            case let str as String:
                result[key] = truncate(str, maxLength: 200)
            case let num as NSNumber:
                result[key] = "\(num)"
            case is NSNull:
                continue
            default:
                // Arrays/objects: serialize to compact JSON
                if let nested = try? JSONSerialization.data(withJSONObject: value),
                   let str = String(data: nested, encoding: .utf8) {
                    result[key] = truncate(str, maxLength: 200)
                }
            }
        }
        return result
    }

    // MARK: - Build Graph (with enriched actions)

    /// Builds the ephemeral SessionGraph dynamically from the chat history.
    /// Now populates `MemoryAction` with tool params and error reasons for XML episodic memory.
    ///
    /// - Parameters:
    ///   - history: The sanitized array of previous ChatMessages (excluding the current pending query).
    ///   - sessionID: The current conversation UUID string.
    /// - Returns: A fully assembled, ephemeral SessionGraph.
    static func buildGraph(from history: [ChatMessage], sessionID: String) -> SessionGraph {
        var episodes: [MemoryEpisode] = []
        var negativeConstraints: Set<String> = []

        var pendingUserText: String? = nil

        for message in history {
            let text = message.content.textContent ?? ""

            if message.sender == .user {
                pendingUserText = text

            } else if message.sender == .agent {

                var actions: [MemoryAction] = []
                var usedTools: [String] = []
                var userCorrection: String? = nil

                // Extract tool executions from timeline events
                for event in message.timelineEvents {
                    if case .toolExecution(let id, let name, let params, let output, let isSuccess, let isExecuting) = event,
                       !isExecuting {

                        usedTools.append(name)
                        let success = isSuccess ?? false

                        // Ghost Protocol: track failed tools
                        if !success {
                            negativeConstraints.insert(name)
                        }

                        // Determine status and error reason
                        let status: String
                        var errorReason: String? = nil

                        if success {
                            status = "SUCCESS"
                        } else if let out = output, out.contains("denied") || out.contains("User explicitly") {
                            status = "DENIED"
                            errorReason = truncate(out, maxLength: 150)
                            userCorrection = "User denied: \(name)"
                        } else {
                            status = "FAILED"
                            errorReason = output.map { truncate($0, maxLength: 150) }
                        }

                        let action = MemoryAction(
                            id: id,
                            toolName: name,
                            intent: name,
                            status: status,
                            params: parseParams(params),
                            errorReason: errorReason
                        )
                        actions.append(action)
                    }
                }

                // Build episode from user-agent pair
                if let userText = pendingUserText {
                    let truncatedUser = userText.count > 50 ? String(userText.prefix(47)) + "..." : userText
                    let summary: String

                    if usedTools.isEmpty {
                        summary = "User query: '\(truncatedUser)' -> Agent provided a direct response."
                    } else {
                        let uniqueTools = Array(Set(usedTools)).joined(separator: ", ")
                        summary = "User query: '\(truncatedUser)' -> Agent executed tools: [\(uniqueTools)]."
                    }

                    let episode = MemoryEpisode(
                        id: message.id,
                        primaryGoal: userText,
                        status: "COMPLETED",
                        finalOutcome: text.isEmpty ? "(Agent returned visual output/tool result)" : text,
                        summary: summary,
                        actions: actions,
                        userCorrection: userCorrection
                    )

                    episodes.append(episode)
                    pendingUserText = nil
                }
            }
        }

        return SessionGraph(
            sessionID: sessionID,
            episodes: episodes,
            negativeConstraints: Array(negativeConstraints),
            workingMemory: [:]
        )
    }

    // MARK: - XML Episodic Memory Builder

    /// Builds an XML string representation of recent history for LLM prompt injection.
    /// Produces executable tool recipes with recency, failure context, and user correction signals.
    ///
    /// - Parameters:
    ///   - history: The array of previous ChatMessages.
    ///   - limit: The maximum number of recent turn-pairs to include (default 4).
    /// - Returns: An XML-formatted episodic memory block.
    static func buildRecentHistoryString(from history: [ChatMessage], limit: Int = 4) -> String {
        // Pair user-agent messages into logical turns
        let turns = pairTurns(from: history)

        if turns.isEmpty {
            return "<episodic_memory><recent/></episodic_memory>"
        }

        let recentTurns = turns.suffix(limit)
        let totalTurns = turns.count

        var xml = "<episodic_memory>\n  <recent>\n"

        for (index, turn) in recentTurns.enumerated() {
            let absoluteIndex = totalTurns - recentTurns.count + index
            let turnsAgo = totalTurns - absoluteIndex
            let recencyLabel = turnsAgo == 1 ? "1 turn ago" : "\(turnsAgo) turns ago"

            let goal = xmlEscape(truncate(turn.userQuery, maxLength: 80))
            let turnStatus = turn.actions.contains(where: { $0.status != "SUCCESS" }) ? "failed" : "completed"

            xml += "    <turn status=\"\(turnStatus)\" goal=\"\(goal)\" recency=\"\(recencyLabel)\">\n"

            for action in turn.actions {
                let actionStatus: String
                switch action.status {
                case "SUCCESS": actionStatus = "success"
                case "DENIED": actionStatus = "denied"
                default: actionStatus = "failed"
                }

                xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(actionStatus)\">\n"

                // Params as XML attributes
                if !action.params.isEmpty {
                    let paramAttrs = action.params
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\"\(xmlEscape($0.value))\"" }
                        .joined(separator: " ")
                    xml += "        <params \(paramAttrs)/>\n"
                }

                // Error reason for failed/denied actions
                if let error = action.errorReason {
                    xml += "        <error>\(xmlEscape(error))</error>\n"
                }

                xml += "      </action>\n"
            }

            // User correction signal
            if let correction = turn.userCorrection {
                xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
            }

            xml += "    </turn>\n"
        }

        xml += "  </recent>\n</episodic_memory>"
        return xml
    }

    // MARK: - Turn Pairing

    /// A paired user-agent turn for XML generation.
    struct TurnPair {
        let userQuery: String
        let actions: [MemoryAction]
        let userCorrection: String?
    }

    /// Pairs consecutive user-agent messages into logical turns.
    private static func pairTurns(from history: [ChatMessage]) -> [TurnPair] {
        var turns: [TurnPair] = []
        var pendingUserText: String? = nil

        for message in history {
            if message.sender == .user {
                pendingUserText = message.content.textContent ?? ""

            } else if message.sender == .agent, let userText = pendingUserText {
                var actions: [MemoryAction] = []
                var userCorrection: String? = nil

                for event in message.timelineEvents {
                    if case .toolExecution(let id, let name, let params, let output, let isSuccess, let isExecuting) = event,
                       !isExecuting {

                        let success = isSuccess ?? false
                        let status: String
                        var errorReason: String? = nil

                        if success {
                            status = "SUCCESS"
                        } else if let out = output, out.contains("denied") || out.contains("User explicitly") {
                            status = "DENIED"
                            errorReason = truncate(out, maxLength: 150)
                            userCorrection = "User denied: \(name)"
                        } else {
                            status = "FAILED"
                            errorReason = output.map { truncate($0, maxLength: 150) }
                        }

                        actions.append(MemoryAction(
                            id: id,
                            toolName: name,
                            intent: name,
                            status: status,
                            params: parseParams(params),
                            errorReason: errorReason
                        ))
                    }
                }

                turns.append(TurnPair(
                    userQuery: userText,
                    actions: actions,
                    userCorrection: userCorrection
                ))
                pendingUserText = nil
            }
        }

        return turns
    }
}
