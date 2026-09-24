// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskDividerView.swift
//  Devgentic
//
//  How a turn nobody typed appears in the transcript.
//
//  ⚠️ THE ALTERNATIVE WAS TO RENDER NOTHING, AND IT WAS REJECTED. A woken background-task run
//  persists a short stub as its user message so the exchange PAIRS — without it the agent's report
//  is an orphan and both history walks drop it (see `ChatMessage.isSyntheticPrompt`). That stub
//  has to be SOMETHING on screen, and there were three candidates:
//
//    1. A user bubble. Wrong outright: it puts words in the user's mouth. Nobody typed this.
//    2. Nothing at all. The store would then hold a message the screen denies — and the model
//       carries it in every later prompt, so "why does it remember saying that?" becomes
//       unanswerable from the transcript. A divergence between what is stored and what is shown
//       is the kind of thing that costs an hour six months later.
//    3. This: a centered divider that says a task ended, in the place where it ended.
//
//  ⚠️ The text is the STUB, rendered verbatim — it was built from the registry snapshot at wake
//  time (`BackgroundTaskWakeCoordinator.stub(for:)`), so it carries the task's real id and exit
//  status. It is deliberately NOT re-derived from the model's report, which is prose a small local
//  model can get wrong, and deliberately NOT re-read from the registry, which has no memory of a
//  task once its conversation is reloaded. The divider is the authoritative record; the report
//  next to it is the readable one.
//

import SwiftUI

struct BackgroundTaskDividerView: View {

    let message: ChatMessage

    @Environment(\.appTheme) private var theme

    /// The stub text, or a neutral fallback if the row's content is unreadable.
    ///
    /// ⚠️ Falls back rather than rendering empty. A synthetic row whose content failed to decode
    /// still marks a real boundary in the conversation — the agent message beside it is a report
    /// about SOMETHING — and a divider with no words at least keeps the turn structure legible.
    private var label: String {
        guard let text = message.content.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return String(localized: "A background task finished.")
        }
        return text
    }

    private var timestamp: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: theme.spacingSmall) {
            rule
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))   // Fixed size: inline marker
                Text(label)
                Text("·")
                Text(timestamp)
            }
            .font(theme.fontCaption)
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            rule
        }
        .padding(.horizontal, theme.spacingMedium)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // One element to VoiceOver, not five fragments — `label` already reads as a sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) At \(timestamp).")
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}
