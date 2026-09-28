// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteCommandAge.swift
//  Devgentic
//
//  A remote command that arrives long after it was sent is NOT run (Timeout inventory D-23, owner
//  decision 2026-09-27 — the same rule as a missed scheduled run: skip it and say so).
//
//  ⚠️ Why: Telegram keeps undelivered updates for 24 h, and Discord/Slack replay recent events on
//  reconnect. A Mac that slept through the evening woke up and ran "deploy it" sent eight hours
//  earlier — work the operator had long stopped expecting, with nobody watching.
//
//  ⚠️ Only commands that START or CHANGE work are gated. Answers to a question that is still open
//  (approve/deny, gate choice, clarification) are accepted at any age: the question is live, and
//  the contract never puts a human on a timer. Read-only commands (/status, /conversations …)
//  answer with the CURRENT state, so their age does not matter.
//

import Foundation

enum RemoteCommandAge {

    /// Older than this, a work-starting command is skipped.
    static let maxAge: TimeInterval = 10 * 60

    /// Whether `command`'s age decides if it runs.
    static func isAgeGated(_ command: ChatOpsCommand) -> Bool {
        switch command {
        case .freeText, .newConversation, .cancel, .switchConversation, .selectProfile, .useProfile:
            return true
        case .conversations, .status, .help, .conversationPage, .profiles, .searchConversations,
             .conversationHistory, .answerClarification, .approveHITL, .denyHITL, .gateChoiceHITL,
             .clarificationResponse, .pairingAttempt, .unknown:
            return false
        }
    }

    /// The command's age when it is too old to run, else nil. An unknown send time is never stale:
    /// refusing on missing data would make the bot deaf to an event shape this build doesn't model.
    static func staleAge(sentAt: Date?, now: Date = Date()) -> TimeInterval? {
        guard let sentAt else { return nil }
        let age = now.timeIntervalSince(sentAt)
        return age > maxAge ? age : nil
    }

    /// What the operator is told instead.
    static func notice(age: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = age >= 3600 ? [.day, .hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        let ago = formatter.string(from: age) ?? "\(Int(age / 60))m"
        return "⏸ This arrived while your Mac was asleep or Devgentic was closed (sent \(ago) ago), so it was not run. Send it again to run it."
    }

    // MARK: - Send times, per platform

    /// Telegram `message.date`: Unix seconds.
    static func telegramSentAt(_ unixSeconds: Int?) -> Date? {
        unixSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Discord `message.timestamp`: ISO 8601, usually with fractional seconds.
    static func discordSentAt(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// Slack `ts`: "<unix seconds>.<sequence>".
    static func slackSentAt(_ ts: String?) -> Date? {
        guard let ts, let seconds = Double(ts), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
