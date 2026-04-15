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

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    private var task: ScheduledTask? {
        SchedulerService.shared.scheduledTasks.first(where: { $0.id == taskID })
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar()

            if let task = task {
                ScrollView {
                    CreateScheduledTaskView(existingTask: task)
                        .padding(24)
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36)) // Fixed size: intentional (icon)
                        .foregroundColor(theme.secondaryText)
                    Text("Task not found")
                        .font(.title3)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
