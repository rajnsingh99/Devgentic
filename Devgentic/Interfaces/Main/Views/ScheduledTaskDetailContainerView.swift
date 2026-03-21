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

    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    private var task: ScheduledTask? {
        SchedulerService.shared.scheduledTasks.first(where: { $0.id == taskID })
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar()

            if let task = task {
                CreateScheduledTaskView(existingTask: task)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
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
