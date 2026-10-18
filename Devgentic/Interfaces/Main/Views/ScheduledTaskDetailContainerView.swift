// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScheduledTaskDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// In-window destination for editing an existing scheduled task. Looks the task up by ID, shows a "not found"
/// placeholder if it is gone, and otherwise hands off to `CreateScheduledTaskView`.
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
