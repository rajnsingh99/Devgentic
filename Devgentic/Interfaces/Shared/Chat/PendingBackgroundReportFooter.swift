// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PendingBackgroundReportFooter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The single predicate behind both the footer and the sidebar badge. A static function over an injected array so a
/// test exercises the real condition rather than a transcription of it.
enum PendingBackgroundReports {

    /// Tasks that will speak into the conversation on their own: opted in and not yet finished. Both conditions are
    /// needed: a finished task has already reported, and a running task that did not opt in ends silently.
    static func count(in snapshots: [BackgroundProcessRegistry.Snapshot]) -> Int {
        snapshots.filter { $0.notifyOnCompletion && !$0.status.isTerminal }.count
    }

    /// Live count for one conversation. `nil` conversation → 0, never a crash.
    @MainActor
    static func count(forConversation conversationID: UUID?) -> Int {
        guard let conversationID else { return 0 }
        return count(in: BackgroundProcessRegistry.shared.snapshots(conversationID: conversationID))
    }
}

struct PendingBackgroundReportFooter: View {

    let conversationID: UUID?

    @Environment(\.appTheme) private var theme

    @State private var pending: Int = 0

    var body: some View {
        Group {
            if pending > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))   // Fixed size: inline marker
                    Text(pending == 1
                         ? String(localized: "1 background task will report here when it finishes")
                         : String(localized: "\(pending) background tasks will report here when they finish"))
                }
                .font(theme.fontCaption)
                .foregroundColor(theme.tertiaryText)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .help(String(localized: "These tasks were started with notify_on_completion, so each one adds a turn to this conversation when it ends — you don't need to ask."))
            } else {
                EmptyView()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: conversationID) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { note in
            // Only this conversation's tasks — a task finishing elsewhere must not redraw this.
            guard note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID == conversationID
            else { return }
            reload()
        }
    }

    private func reload() {
        pending = PendingBackgroundReports.count(forConversation: conversationID)
    }
}
