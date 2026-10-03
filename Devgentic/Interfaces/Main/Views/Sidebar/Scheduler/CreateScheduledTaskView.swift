// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CreateScheduledTaskView.swift
//  Devgentic
//
//  Full-window form for creating or editing a scheduled task.
//  Mirrors the AgentConfigDetailView card-based layout: DynamicIslandBar
//  on top with Cancel/Save trailing actions, identity header, then a
//  stack of SettingsCards for each configuration domain.
//
//  The form collapses the two underlying flags (`TaskMode` + `ContextWindowMode`)
//  into a single user-facing "Run Mode" with three concrete options:
//    • Continue an existing conversation  → conversationBound + linked conv
//    • Recurring thread                   → autonomous + continuous
//    • Fresh each time                    → autonomous + stateless
//

import SwiftUI
import SwiftData
import os

private let logger = DGLogger(category: "CreateScheduledTaskView")

struct CreateScheduledTaskView: View {

    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(BackendProfileService.self) private var profileService
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    // Floating prompt-editor managers — per-instance (not singletons), so
    // opening one of these editors here doesn't trample any open editor in
    // an Agent/Bot profile detail view.
    @State private var advancedPromptManager = AdvancedPromptWindowManager()
    @State private var simplePromptManager = SimplePromptWindowManager()

    /// If non-nil, we are editing an existing task.
    var existingTask: ScheduledTask?
    /// Pre-filled prompt (from ChatInputAreaView quick schedule).
    var prefillPrompt: String?
    /// Pre-selected conversation when invoked from inside an active chat —
    /// the form opens with run mode set to "Continue this conversation"
    /// and the picker pointing at this ID.
    var prefillConversationID: UUID?

    /// All conversations, newest first — drives the conversation picker shown
    /// when run mode is "Continue an existing conversation".
    @Query(sort: \ConversationSD.timestamp, order: .reverse)
    private var conversations: [ConversationSD]

    // MARK: - Form State
    @State private var displayName: String = ""
    @State private var selectedProfileID: UUID?
    @State private var promptTemplate: String = ""
    @State private var runStrategy: RunStrategy = .recurringThread
    @State private var linkedConversationID: UUID?
    @State private var scheduleType: ScheduleType = .recurring
    @State private var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State private var cronPreset: CronPreset = .daily9am
    @State private var customCronExpression: String = ""
    /// The task's own execution limit in seconds; nil = the profile's limit, else 30 min.
    @State private var runLimit: TimeInterval?

    /// Per-field validation errors. Captured up-front by `validate()` so the
    /// user sees every problem at once (rather than fix-save-fix-save) and
    /// each error renders next to the input that owns it.
    @State private var fieldErrors: [ValidationField: String] = [:]

    enum ValidationField: Hashable {
        case name
        case profile
        case prompt
        case conversation
        case cron
    }

    // MARK: - Local Enums

    /// Single user-facing axis that replaces the (TaskMode, ContextWindowMode) pair.
    /// Mapped back to those underlying values at save time.
    enum RunStrategy: String, CaseIterable, Identifiable {
        case continueConversation
        case recurringThread
        case freshEachTime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .continueConversation: return "Continue an existing conversation"
            case .recurringThread:      return "Recurring thread"
            case .freshEachTime:        return "Fresh each time"
            }
        }

        var caption: String {
            switch self {
            case .continueConversation:
                return "Append each run to a conversation you pick. Useful for follow-ups on a thread."
            case .recurringThread:
                return "Auto-create one thread and append every run to it. Memory accumulates over time."
            case .freshEachTime:
                return "Start a new conversation on every run. No accumulated context."
            }
        }

        var icon: String {
            switch self {
            case .continueConversation: return "bubble.left.and.bubble.right.fill"
            case .recurringThread:      return "arrow.triangle.2.circlepath"
            case .freshEachTime:        return "sparkles"
            }
        }
    }

    enum ScheduleType: String, CaseIterable, Identifiable {
        case oneShot = "One-shot"
        case recurring = "Recurring"
        var id: String { rawValue }

        /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
        /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
        /// invisible to the String Catalog extractor and would have shipped untranslated inside
        /// otherwise-translated chrome. `rawValue` stays for `id`/`tag` identity only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .oneShot:   return "One-shot"
            case .recurring: return "Recurring"
            }
        }
    }

    enum CronPreset: String, CaseIterable, Identifiable {
        case daily9am = "Daily at 9 AM"
        case weekdays9am = "Weekdays at 9 AM"
        case weeklyMonday = "Weekly Monday 9 AM"
        case custom = "Custom"

        var id: String { rawValue }

        /// User-facing name. ⚠️ Separate from `rawValue` on purpose — see `ScheduleType.localizedTitle`.
        /// `rawValue` stays for `id`/`tag` identity and for `loadFromTask`'s preset matching.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .daily9am:     return "Daily at 9 AM"
            case .weekdays9am:  return "Weekdays at 9 AM"
            case .weeklyMonday: return "Weekly Monday 9 AM"
            case .custom:       return "Custom"
            }
        }

        var expression: String? {
            switch self {
            case .daily9am: return "0 9 * * *"
            case .weekdays9am: return "0 9 * * 1-5"
            case .weeklyMonday: return "0 9 * * 1"
            case .custom: return nil
            }
        }
    }

    /// Schedulable profile types. Code profiles are ephemeral (folder/file
    /// context isn't persisted) and image-gen profiles produce images, not
    /// the text feedback the scheduler reports back. Both make scheduling
    /// either broken (code) or pointless (imageGen).
    private static let schedulableTypes: Set<ProfileType> = [.bot, .agent, .workflow]

    /// Backed by the @Observable `BackendProfileService.sharedProfiles` list so the
    /// picker auto-refreshes when a profile is added or deleted in another
    /// part of the app while this form is open.
    ///
    /// ⚠️ `sharedProfiles`, so a workflow node's owned configuration row is never schedulable —
    /// it is not a profile the user has anywhere else, and a scheduled run of one would execute a
    /// single node outside the workflow that gives it its input.
    private var profiles: [BackendProfileModel] {
        profileService.sharedProfiles.filter { Self.schedulableTypes.contains($0.profileType) }
    }

    private var isEditing: Bool { existingTask != nil }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(
                title: isEditing ? "Edit Task" : "New Scheduled Task",
                icon: "clock.badge",
                onBack: { router.goBack() }
            ) {
                actionButtons
            }

            ScrollView {
                VStack(spacing: 32) {

                    identityHeader

                    SettingsCard(title: "Backend Profile", icon: "cpu", theme: theme) {
                        backendProfileSection
                    }

                    SettingsCard(title: "Run Mode", icon: "play.circle", theme: theme) {
                        runModeSection
                    }

                    SettingsCard(title: "Prompt Template", icon: "text.quote", theme: theme) {
                        promptTemplateSection
                    }

                    SettingsCard(title: "Schedule", icon: "calendar", theme: theme) {
                        scheduleSection
                    }

                    SettingsCard(title: "Time Limit", icon: "clock", theme: theme) {
                        runLimitSection
                    }
                }
                .padding(ViewLayout.containerPadding)
                .padding(.bottom, ViewLayout.containerPadding)
                .frame(maxWidth: ViewLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if let task = existingTask {
                loadFromTask(task)
            } else {
                applyPrefills()
            }
        }
        .onDisappear {
            // Close any detached prompt editor windows so they don't outlive
            // the form (mirrors AgentConfigDetailView's cleanup).
            // Same navigation teardown as the profile editors — commit before closing.
            advancedPromptManager.closeWindowCommittingChanges()
            simplePromptManager.closeWindow()
        }
    }

    // MARK: - Header

    private var identityHeader: some View {
        let nameInvalid = fieldErrors[.name] != nil
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: isEditing ? "calendar.badge.clock" : "calendar.badge.plus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .foregroundColor(theme.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                TextField("e.g. Daily Standup Reminder", text: $displayName)
                    .font(theme.fontTitle2)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.primaryText)
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) {
                        // Red underline when name validation fails — minimal
                        // chrome that draws the eye without crowding the header
                        // with an error caption.
                        Rectangle()
                            .fill(theme.errorColor)
                            .frame(height: nameInvalid ? 2 : 0)
                            .animation(.easeInOut(duration: 0.15), value: nameInvalid)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Task name")
                    .accessibilityValue(nameInvalid ? "Required, missing" : displayName)
                    .onChange(of: displayName) { _, newValue in
                        fieldErrors[.name] = nil
                        // Keep any open detached editor's window title in sync
                        // with the live name. Both managers no-op when their
                        // window isn't visible, so we don't need to know which
                        // (if any) is open.
                        let liveName = editorTitleName(for: newValue)
                        advancedPromptManager.updateTitle(agentName: liveName)
                        simplePromptManager.updateTitle(botName: liveName)
                    }

                Text(isEditing
                     ? "Edit when this task runs and what it does."
                     : "Configure when this task runs and what it does.")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }

    // MARK: - Card: Backend Profile

    private var backendProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inference Engine")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Backend profile used to run the prompt.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }

                Spacer(minLength: 16)

                Picker("", selection: $selectedProfileID) {
                    Label("None", systemImage: "minus.circle").tag(UUID?.none)
                    ForEach(profiles) { profile in
                        Label(profile.displayName, systemImage: profile.profileType.iconName)
                            .tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: selectedProfileID) { _, _ in
                    fieldErrors[.profile] = nil
                }
            }

            inlineError(fieldErrors[.profile])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Card: Run Mode (3-way selector)

    private var runModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 8) {
                ForEach(RunStrategy.allCases) { strategy in
                    runStrategyRow(strategy)
                }
            }

            // Conversation picker — only when "Continue an existing conversation"
            if runStrategy == .continueConversation {
                conversationPicker
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func runStrategyRow(_ strategy: RunStrategy) -> some View {
        let isSelected = runStrategy == strategy
        Button {
            runStrategy = strategy
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: strategy.icon)
                    .font(theme.fontBody)
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(strategy.title)
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    Text(strategy.caption)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? theme.accentColor : theme.surfaceOverlayStrong)
                    .font(theme.fontTitle3)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(strategy.title). \(strategy.caption)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var conversationPicker: some View {
        if conversations.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(theme.secondaryText)
                Text("No conversations yet. Start one in chat first, then choose it here.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversation")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Each run will be appended to this thread.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }

                    Spacer(minLength: 16)

                    Picker("", selection: $linkedConversationID) {
                        Text("Select a conversation").tag(UUID?.none)
                        ForEach(conversations) { conv in
                            Text(conversationDisplayName(conv)).tag(Optional(conv.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: linkedConversationID) { _, _ in
                        fieldErrors[.conversation] = nil
                    }
                }

                inlineError(fieldErrors[.conversation])
            }
        }
    }

    private func conversationDisplayName(_ conv: ConversationSD) -> String {
        if let title = conv.userDefinedTitle, !title.isEmpty {
            return title
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(String(localized: "Untitled")) · \(formatter.string(from: conv.timestamp))"
    }

    // MARK: - Card: Prompt Template

    private var promptTemplateSection: some View {
        let promptInvalid = fieldErrors[.prompt] != nil
        return VStack(alignment: .leading, spacing: 12) {
            // Header with title, hint, and expand action
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt Template")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Instructions executed on each run. Dynamic context is injected at runtime.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }

                Spacer(minLength: 16)

                Button {
                    openExpandedEditor()
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .font(theme.fontCaption2.weight(.medium))
                .buttonStyle(.link)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $promptTemplate)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(theme.textBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(promptInvalid ? theme.errorColor : theme.dividerColor,
                                    lineWidth: promptInvalid ? 1.5 : 1)
                    )
                    .accessibilityLabel("Prompt template")
                    .accessibilityValue(promptInvalid ? "Required, missing" : promptTemplate)
                    .onChange(of: promptTemplate) { _, _ in
                        fieldErrors[.prompt] = nil
                    }

                if promptTemplate.isEmpty {
                    Text("Describe what the task should do.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }

            inlineError(fieldErrors[.prompt])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Expand Editor

    /// Opens the appropriate detached prompt editor based on the selected
    /// profile type. Agent profiles get the advanced editor (with tool
    /// autocomplete via the profile's configured tools); everything else
    /// gets the simple editor with token estimation.
    private func openExpandedEditor() {
        let titleName = editorTitleName(for: displayName)

        let profile = selectedProfileID.flatMap { id in
            profiles.first(where: { $0.id == id })
        }

        if let profile, case .agent(let config) = profile.details {
            // Tools binding is read-only here — schedules reference existing
            // tools but shouldn't mutate the underlying profile.
            advancedPromptManager.showEditor(
                text: $promptTemplate,
                // ⚠️ `.constant` deliberately, mirroring the simple editor below (register B18):
                // `titleName` is DERIVED per call from the task name with an "unnamed task"
                // fallback, so there is no binding into the draft to hand over. This view keeps
                // driving `updateTitle` explicitly on `.onChange(of: displayName)` — which is why
                // the agent PROFILE editor was the only place the stale title ever showed.
                agentName: .constant(titleName),
                configuredTools: .constant(config.tools),
                themeManager: themeManager
            )
        } else {
            simplePromptManager.showEditor(
                text: $promptTemplate,
                // ⚠️ `.constant` deliberately: `titleName` is derived per call from the task name,
                // and a scheduled task has no single model, so there is no context window to
                // report either. Both are honest "not applicable" here rather than oversights.
                botName: .constant(titleName),
                themeManager: themeManager
            )
        }
    }

    /// Detached-editor window title — falls back to a generic placeholder
    /// when the user hasn't named the task yet so the OS window chrome
    /// never reads "System Instructions: ".
    private func editorTitleName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Scheduled Task" : trimmed
    }

    // MARK: - Card: Schedule

    /// Presets offered for a task's own limit (HITL Waiting Contract §5). A stored value outside
    /// them is still shown, so editing a task never silently changes its limit.
    private static let runLimitPresets: [TimeInterval] = [5, 15, 30, 60, 120].map { $0 * 60 }

    private var runLimitSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stop After")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("A run that works longer than this is stopped and marked Timed out. Time spent waiting for approval is not counted. Default uses the profile's execution timeout, or \(ToolExecutionMediator.describe(SchedulerCoordinator.defaultScheduledRunLimit)) if it has none.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
            }

            Spacer(minLength: 16)

            Picker("", selection: $runLimit) {
                Text("Default").tag(TimeInterval?.none)
                ForEach(Self.runLimitPresets + (runLimit.map { Self.runLimitPresets.contains($0) ? [] : [$0] } ?? []), id: \.self) { seconds in
                    Text(ToolExecutionMediator.describe(seconds)).tag(TimeInterval?.some(seconds))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $scheduleType) {
                ForEach(ScheduleType.allCases) { type in
                    Text(type.localizedTitle).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            if scheduleType == .oneShot {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fire At")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Task runs once at this date and time.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }

                    Spacer(minLength: 16)

                    DatePicker("", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recurring Pattern")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    VStack(spacing: 8) {
                        ForEach(CronPreset.allCases) { preset in
                            cronPresetRow(preset)
                        }
                    }

                    if cronPreset == .custom {
                        customCronEditor
                    }
                }
            }

            if let nextFire = nextFireDatePreview {
                Divider()
                nextRunPreview(nextFire)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live preview of when the task will next fire — derived from the cron
    /// expression (recurring) or the picker date (one-shot). nil when the
    /// schedule is incomplete or invalid (e.g., custom cron with parse error).
    private var nextFireDatePreview: Date? {
        if scheduleType == .oneShot {
            return scheduledDate > Date() ? scheduledDate : nil
        }
        let expression: String?
        if cronPreset == .custom {
            expression = customCronExpression.isEmpty ? nil : customCronExpression
        } else {
            expression = cronPreset.expression
        }
        guard let expr = expression,
              let cron = try? CronExpression(expression: expr) else { return nil }
        return cron.nextFireDate(after: Date())
    }

    private func nextRunPreview(_ date: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(theme.fontCaption2.weight(.medium))
                .foregroundColor(theme.secondaryText)
                .accessibilityHidden(true)
            Text("Next run:")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
            Text(formatter.string(from: date))
                .font(theme.fontCaption2.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .monospacedDigit()
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// Custom cron field with live parsing — error surfaces immediately while
    /// typing (instead of waiting for Save), and a green humanReadable
    /// preview ("Daily at 9:30 AM") confirms the expression matches intent.
    private var customCronEditor: some View {
        let cronInvalid = fieldErrors[.cron] != nil
        let parsedCron = (try? CronExpression(expression: customCronExpression))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Custom Cron Expression")
                .font(theme.fontCaption2.weight(.semibold))
                .foregroundColor(theme.secondaryText)
            TextField("e.g., 30 8 * * 1", text: $customCronExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .background(theme.textBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(cronInvalid ? theme.errorColor : theme.dividerColor,
                                lineWidth: cronInvalid ? 1.5 : 1)
                )
                .onChange(of: customCronExpression) { _, newValue in
                    validateCron(newValue)
                }

            if let parsed = parsedCron, fieldErrors[.cron] == nil, !customCronExpression.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(parsed.humanReadable)
                        .font(theme.fontCaption2)
                }
                .foregroundColor(.green)
            }

            inlineError(fieldErrors[.cron])
        }
        .padding(.top, 4)
    }

    /// Live cron validation — empty input is OK (no error until Save), but
    /// any non-empty text gets parsed immediately so the user sees feedback
    /// while typing.
    private func validateCron(_ expression: String) {
        guard !expression.isEmpty else {
            fieldErrors[.cron] = nil
            return
        }
        do {
            _ = try CronExpression(expression: expression)
            fieldErrors[.cron] = nil
        } catch {
            fieldErrors[.cron] = error.localizedDescription
        }
    }

    @ViewBuilder
    private func cronPresetRow(_ preset: CronPreset) -> some View {
        let isSelected = cronPreset == preset
        Button {
            cronPreset = preset
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(preset.localizedTitle)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                Spacer(minLength: 8)

                if let expr = preset.expression {
                    Text(expr)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.surfaceOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        // Cron syntax is visual reassurance; the preset name
                        // is the accessible label so VoiceOver doesn't read
                        // out "0 9 * * *".
                        .accessibilityHidden(true)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? theme.accentColor : theme.surfaceOverlayStrong)
                    .font(theme.fontTitle3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // `Text` overload, not the `String` one — `accessibilityLabel(_: String)`
        // does not localize, so VoiceOver would read the untranslated rawValue.
        .accessibilityLabel(Text(preset.localizedTitle))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Inline Error

    /// Compact red caption rendered directly under the input that failed
    /// validation. Returns EmptyView when there's no error so callers can
    /// drop it inline without conditionals.
    @ViewBuilder
    private func inlineError(_ message: String?) -> some View {
        if let message {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(message)
                    .font(theme.fontCaption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(theme.errorColor)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            IslandPillButton(
                title: isEditing ? "Save Changes" : "Create Task",
                icon: isEditing ? "checkmark" : "plus",
                style: .primary,
                accessibilityLabel: isEditing ? "Save task changes" : "Create scheduled task",
                keyboardShortcut: .defaultAction
            ) {
                createOrSave()
            }
        }
    }

    // MARK: - Prefill / Load

    private func applyPrefills() {
        if let prompt = prefillPrompt, promptTemplate.isEmpty {
            promptTemplate = prompt
        }
        if let convID = prefillConversationID {
            runStrategy = .continueConversation
            linkedConversationID = convID
        }
    }

    private func loadFromTask(_ task: ScheduledTask) {
        displayName = task.displayName
        selectedProfileID = task.profileID
        promptTemplate = task.promptTemplate
        linkedConversationID = task.linkedConversationID
        runLimit = task.runLimit
        runStrategy = strategy(from: task.mode, contextWindowMode: task.contextWindowMode)

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

    /// Map underlying (TaskMode, ContextWindowMode) → user-facing RunStrategy.
    private func strategy(from mode: TaskMode, contextWindowMode: ContextWindowMode) -> RunStrategy {
        switch mode {
        case .conversationBound:
            return .continueConversation
        case .autonomous:
            return contextWindowMode == .continuous ? .recurringThread : .freshEachTime
        }
    }

    // MARK: - Validation

    /// Collect every field error in one pass so the user sees all problems
    /// at once and each error renders next to the input that owns it.
    /// Returns `nil` when valid; otherwise a tuple of `(cron, scheduledAt)`
    /// derived once during validation so `createOrSave` doesn't recompute.
    private func validate() -> (cron: String?, scheduledAt: Date?)? {
        var errors: [ValidationField: String] = [:]

        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors[.name] = String(localized: "Name is required.")
        }
        if selectedProfileID == nil {
            errors[.profile] = String(localized: "Please select a backend profile.")
        }
        if promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            errors[.prompt] = String(localized: "Prompt template is required.")
        }
        if runStrategy == .continueConversation && linkedConversationID == nil {
            errors[.conversation] = String(localized: "Pick a conversation to continue, or choose a different run mode.")
        }

        // Schedule fields — derived on the success path; cron is the only
        // sub-field with its own error surface.
        var resolvedCron: String? = nil
        var resolvedDate: Date? = nil
        if scheduleType == .recurring {
            if cronPreset == .custom {
                if customCronExpression.isEmpty {
                    errors[.cron] = String(localized: "Cron expression is required.")
                } else {
                    do {
                        _ = try CronExpression(expression: customCronExpression)
                        resolvedCron = customCronExpression
                    } catch {
                        errors[.cron] = error.localizedDescription
                    }
                }
            } else {
                resolvedCron = cronPreset.expression
            }
        } else {
            resolvedDate = scheduledDate
        }

        fieldErrors = errors
        return errors.isEmpty ? (resolvedCron, resolvedDate) : nil
    }

    // MARK: - Save

    private func createOrSave() {
        guard let resolved = validate() else {
            logger.debug("Save blocked by validation: \(fieldErrors.keys.map { "\($0)" }.joined(separator: ","))")
            return
        }

        // Map RunStrategy → underlying flags
        let resolvedMode: TaskMode
        let resolvedContextMode: ContextWindowMode
        let resolvedLink: UUID?
        switch runStrategy {
        case .continueConversation:
            resolvedMode = .conversationBound
            resolvedContextMode = .continuous
            resolvedLink = linkedConversationID
        case .recurringThread:
            resolvedMode = .autonomous
            resolvedContextMode = .continuous
            resolvedLink = nil
        case .freshEachTime:
            resolvedMode = .autonomous
            resolvedContextMode = .stateless
            resolvedLink = nil
        }

        let cronStr = resolved.cron
        let scheduledAtDate = resolved.scheduledAt

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
        task.mode = resolvedMode
        task.profileID = selectedProfileID
        task.promptTemplate = promptTemplate
        task.cronExpression = cronStr
        task.scheduledAt = scheduledAtDate
        task.contextWindowMode = resolvedContextMode
        task.linkedConversationID = resolvedLink
        task.runLimit = runLimit

        if isEditing {
            SchedulerService.shared.updateTask(task)
            logger.info("Updated scheduled task \(task.id) — mode=\(resolvedMode.rawValue) cron=\(cronStr ?? "nil") oneShot=\(scheduledAtDate?.description ?? "nil")")
            toastManager.show(String(localized: "Task updated"), style: .success)
        } else {
            SchedulerService.shared.createTask(task)
            logger.info("Created scheduled task \(task.id) — mode=\(resolvedMode.rawValue) cron=\(cronStr ?? "nil") oneShot=\(scheduledAtDate?.description ?? "nil")")
            toastManager.show(String(localized: "Task created"), style: .success)
        }

        router.goBack()
    }
}
