//
//  CreateScheduledTaskView.swift
//  Devgentic
//
//  Sheet for creating or editing a scheduled task.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CreateScheduledTaskView")

struct CreateScheduledTaskView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    /// If non-nil, we are editing an existing task.
    var existingTask: ScheduledTask?
    /// Pre-filled prompt (from ChatInputAreaView quick schedule).
    var prefillPrompt: String?

    // MARK: - Form State
    @State private var displayName: String = ""
    @State private var mode: TaskMode = .autonomous
    @State private var selectedProfileID: UUID?
    @State private var promptTemplate: String = ""
    @State private var scheduleType: ScheduleType = .recurring
    @State private var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State private var cronPreset: CronPreset = .daily9am
    @State private var customCronExpression: String = ""
    @State private var contextWindowMode: ContextWindowMode = .continuous
    @State private var linkedConversationID: UUID?

    @State private var validationError: String?

    enum ScheduleType: String, CaseIterable, Identifiable {
        case oneShot = "One-shot"
        case recurring = "Recurring"
        var id: String { rawValue }
    }

    enum CronPreset: String, CaseIterable, Identifiable {
        case daily9am = "Daily at 9 AM"
        case weekdays9am = "Weekdays at 9 AM"
        case weeklyMonday = "Weekly Monday 9 AM"
        case custom = "Custom"

        var id: String { rawValue }

        var expression: String? {
            switch self {
            case .daily9am: return "0 9 * * *"
            case .weekdays9am: return "0 9 * * 1-5"
            case .weeklyMonday: return "0 9 * * 1"
            case .custom: return nil
            }
        }
    }

    private var profiles: [BackendProfileModel] {
        (try? BackendProfileStore.shared.fetchProfiles()) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingTask != nil ? "Edit Scheduled Task" : "New Scheduled Task")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.title3)) // scales with Dynamic Type; ~18pt
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name
                    formSection("Name") {
                        TextField("e.g., Daily Standup", text: $displayName)
                            .textFieldStyle(.plain)
                            .font(theme.fontBody)
                            .padding(10)
                            .background(theme.surfaceOverlay)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Mode
                    formSection("Mode") {
                        Picker("", selection: $mode) {
                            ForEach(TaskMode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Backend Profile
                    formSection("Backend Profile") {
                        Picker("Select a profile", selection: $selectedProfileID) {
                            Text("None").tag(UUID?.none)
                            ForEach(profiles) { profile in
                                Text(profile.displayName).tag(Optional(profile.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Prompt Template
                    formSection("Prompt Template") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $promptTemplate)
                                .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced input
                                .frame(minHeight: 80, maxHeight: 150)
                                .padding(8)
                                .background(theme.surfaceOverlay)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .scrollContentBackground(.hidden)

                            // Variable chips
                            HStack(spacing: 6) {
                                ForEach(["{{date}}", "{{weekday}}", "{{runCount}}", "{{lastRunAt}}"], id: \.self) { variable in
                                    Button {
                                        promptTemplate += " \(variable)"
                                    } label: {
                                        Text(variable)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced (template chip)
                                            .foregroundColor(theme.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(theme.accentColor.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Schedule
                    formSection("Schedule") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $scheduleType) {
                                ForEach(ScheduleType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)

                            if scheduleType == .oneShot {
                                DatePicker("Fire at:", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.compact)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(CronPreset.allCases) { preset in
                                        HStack(spacing: 8) {
                                            Image(systemName: cronPreset == preset ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(cronPreset == preset ? theme.accentColor : theme.secondaryText.opacity(0.4))
                                                .font(theme.fontBody)
                                            Text(preset.rawValue)
                                                .font(theme.fontSubheadline)
                                                .foregroundColor(theme.primaryText)
                                            Spacer()
                                            if let expr = preset.expression {
                                                Text(expr)
                                                    .font(.system(size: 10, design: .monospaced)) // Fixed size: monospaced (cron expression)
                                                    .foregroundColor(theme.secondaryText.opacity(0.5))
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { cronPreset = preset }
                                    }

                                    if cronPreset == .custom {
                                        TextField("e.g., 30 8 * * 1", text: $customCronExpression)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced input
                                            .padding(8)
                                            .background(theme.surfaceOverlay)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }

                    // Context Mode (autonomous only)
                    if mode == .autonomous {
                        formSection("Context Window Mode") {
                            Picker("", selection: $contextWindowMode) {
                                ForEach(ContextWindowMode.allCases) { m in
                                    Text(m.displayName).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(contextWindowMode == .continuous
                                 ? "Appends to the same conversation thread. Full history is visible to the LLM."
                                 : "Creates a new conversation each run. No accumulated context.")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText.opacity(0.6))
                        }
                    }

                    // Validation error
                    if let error = validationError {
                        Text(error)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button(existingTask != nil ? "Save Changes" : "Create Task") {
                    createOrSave()
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 480, minHeight: 450)
        .background(theme.secondaryBackground)
        .onAppear {
            if let task = existingTask {
                loadFromTask(task)
            }
            if let prompt = prefillPrompt, promptTemplate.isEmpty {
                promptTemplate = prompt
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func formSection(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private func loadFromTask(_ task: ScheduledTask) {
        displayName = task.displayName
        mode = task.mode
        selectedProfileID = task.profileID
        promptTemplate = task.promptTemplate
        contextWindowMode = task.contextWindowMode
        linkedConversationID = task.linkedConversationID

        if let cron = task.cronExpression {
            scheduleType = .recurring
            if let preset = CronPreset.allCases.first(where: { $0.expression == cron }) {
                cronPreset = preset
            } else {
                cronPreset = .custom
                customCronExpression = cron
            }
        } else if let date = task.scheduledAt {
            scheduleType = .oneShot
            scheduledDate = date
        }
    }

    private func createOrSave() {
        // Validate
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = String(localized: "Name is required.")
            return
        }
        guard selectedProfileID != nil else {
            validationError = String(localized: "Please select a backend profile.")
            return
        }
        guard !promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = String(localized: "Prompt template is required.")
            return
        }

        let cronStr: String?
        let scheduledAtDate: Date?

        if scheduleType == .recurring {
            if cronPreset == .custom {
                guard !customCronExpression.isEmpty else {
                    validationError = String(localized: "Cron expression is required for custom schedule.")
                    return
                }
                // Validate cron
                do {
                    _ = try CronExpression(expression: customCronExpression)
                } catch {
                    validationError = error.localizedDescription
                    return
                }
                cronStr = customCronExpression
            } else {
                cronStr = cronPreset.expression
            }
            scheduledAtDate = nil
        } else {
            cronStr = nil
            scheduledAtDate = scheduledDate
        }

        var task = existingTask ?? ScheduledTask(
            id: UUID(),
            displayName: "",
            mode: .autonomous,
            promptTemplate: "",
            profileID: nil,
            attachedFileURLs: [],
            cronExpression: nil,
            scheduledAt: nil,
            isEnabled: true,
            isPaused: false,
            status: .pending,
            lastRunAt: nil,
            nextRunAt: nil,
            runCount: 0,
            lastRunSummary: nil,
            linkedConversationID: nil,
            contextWindowMode: .continuous,
            createdAt: Date()
        )

        task.displayName = displayName.trimmingCharacters(in: .whitespaces)
        task.mode = mode
        task.profileID = selectedProfileID
        task.promptTemplate = promptTemplate
        task.cronExpression = cronStr
        task.scheduledAt = scheduledAtDate
        task.contextWindowMode = contextWindowMode

        if existingTask != nil {
            SchedulerService.shared.updateTask(task)
        } else {
            SchedulerService.shared.createTask(task)
        }

        dismiss()
    }
}
