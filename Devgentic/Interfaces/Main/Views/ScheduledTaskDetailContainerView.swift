// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScheduledTaskDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  In-window destination for editing an existing scheduled task.
//  Looks up the task by ID; if missing (deleted out from under us),
//  shows a "not found" placeholder. Otherwise hands off to
//  CreateScheduledTaskView, which owns its own DynamicIslandBar
//  + card-based layout (matches AgentConfigDetailView).
//

import SwiftUI

struct ScheduledTaskDetailContainerView: View {

    let taskID: UUID

    private var task: ScheduledTask? {
        SchedulerService.shared.scheduledTasks.first(where: { $0.id == taskID })
    }

    var body: some View {
        if let task = task {
            CreateScheduledTaskView(
                existingTask: task,
                prefillPrompt: nil
            )
        } else {
            VStack(spacing: 0) {
                DynamicIslandBar(title: "Edit Task", icon: "clock.badge")

                ContentNotFoundView(
                    icon: "clock.badge.exclamationmark",
                    title: "Task Not Found",
                    subtitle: "This scheduled task may have been deleted. Use the back button to return."
                )
            }
        }
    }
}
