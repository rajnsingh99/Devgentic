//
//  ScheduledTaskDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Wraps CreateScheduledTaskView for display in the main content area.
//  Looks up the task by ID from SchedulerService and provides it
//  for editing, with DynamicIslandBar for back navigation.
//

import SwiftUI

struct ScheduledTaskDetailContainerView: View {

    let taskID: UUID

    private var task: ScheduledTask? {
        SchedulerService.shared.scheduledTasks.first(where: { $0.id == taskID })
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(
                title: task?.displayName ?? "Edit Task",
                icon: "clock.badge"
            )

            if let task = task {
                ScrollView {
                    CreateScheduledTaskView(existingTask: task)
                        .padding(24)
                        .frame(maxWidth: ViewLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ContentNotFoundView(
                    icon: "clock.badge.exclamationmark",
                    title: "Task Not Found",
                    subtitle: "This scheduled task may have been deleted. Use the back button to return."
                )
            }
        }
    }
}
