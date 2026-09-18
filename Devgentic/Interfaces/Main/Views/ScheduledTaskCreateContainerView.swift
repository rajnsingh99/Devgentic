// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScheduledTaskCreateContainerView.swift
//  Devgentic
//
//  In-window destination for creating a new scheduled task.
//  Thin wrapper around CreateScheduledTaskView, which owns its own
//  DynamicIslandBar + card-based layout (matches AgentConfigDetailView).
//

import SwiftUI

struct ScheduledTaskCreateContainerView: View {

    let prefillPrompt: String?
    let prefillConversationID: UUID?

    var body: some View {
        CreateScheduledTaskView(
            existingTask: nil,
            prefillPrompt: prefillPrompt,
            prefillConversationID: prefillConversationID
        )
    }
}
