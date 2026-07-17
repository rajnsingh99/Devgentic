//
//  CoreIntelligenceSettingsView.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import SwiftUI

/// Dedicated settings view for the Core Intelligence module.
/// Allows users to enable/disable the module, choose their own MLX model,
/// toggle individual features, and customize behavior with a prompt.
struct CoreIntelligenceSettingsView: View {

    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    // Model selection stored in UserDefaults
    @AppStorage(AppSettings.coreIntelligenceModelKey) private var selectedModel: String = ""

    // Feature toggles
    @AppStorage(AppSettings.ciFeatureRAGRewritingKey) private var ragRewritingEnabled: Bool = true
    @AppStorage(AppSettings.ciFeatureSuggestionKey) private var suggestionEnabled: Bool = false
    @AppStorage(AppSettings.ciFeatureMorningBriefKey) private var morningBriefEnabled: Bool = false
    @AppStorage(AppSettings.ciFeatureUserPersonalKey) private var userPersonalEnabled: Bool = false
    @AppStorage(AppSettings.ciFeatureResponseSynthesisKey) private var responseSynthesisEnabled: Bool = true
    @AppStorage(AppSettings.ciFeatureHistoryCompactionKey) private var historyCompactionEnabled: Bool = true

    // Custom prompt
    @AppStorage(AppSettings.ciCustomPromptKey) private var customPrompt: String = ""

    private var modelService = MLXModelService.shared
    @State private var currentFitAssessment: ModelFitAssessment?

    // Debug test state
    @State private var testLog: [String] = []
    @State private var isTestRunning: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // 1. Master Enable + Model Selection
                SettingsCard(title: "Core Intelligence", icon: "cpu.fill", theme: theme) {
                    // Enable Toggle
                    SettingsRow(
                        title: "Enable Core Intelligence",
                        description: "A dedicated on-device MLX model that runs background intelligence tasks to improve your experience. Runs locally — no data leaves your machine.",
                        theme: theme
                    ) {
                        Toggle("", isOn: Bindable(viewModel).isIntelligenceCoreEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    if viewModel.isIntelligenceCoreEnabled {

                        // No-model-selected hint
                        if selectedModel.isEmpty {
                            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(theme.accentColor)
                                    .accessibilityHidden(true)
                                Text("Select a model below to activate Intelligence Core features.")
                                    .font(.system(.caption))
                                    .foregroundColor(theme.secondaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        // Model Selection
                        SettingsRow(
                            title: "Model",
                            description: "Choose which installed MLX model powers your Intelligence Core. Smaller models are faster; larger models are more capable.",
                            theme: theme
                        ) {
                            modelPicker
                        }

                        // Fit indicator
                        if let assessment = currentFitAssessment, assessment.estimatedRuntimeRAM > 0 {
                            HStack {
                                Spacer()
                                ModelFitInlineView(assessment: assessment)
                                    .padding(.trailing, 16)
                                    .padding(.bottom, 8)
                            }
                        }

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        // Manage Models button
                        HStack {
                            Spacer()
                            Button {
                                router.navigate(to: .mlxModelStore(profileID: UUID(), filterForTools: false))
                            } label: {
                                Label("Manage Models", systemImage: "square.grid.2x2")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }

                // 2. Feature Toggles (only shown when enabled and model selected)
                if viewModel.isIntelligenceCoreEnabled && !selectedModel.isEmpty {

                    SettingsCard(title: "Features", icon: "slider.horizontal.3", theme: theme) {
                        FeatureToggleRow(
                            title: "History Compaction",
                            description: "Automatically summarizes older conversation turns into checkpoints using Intelligence Core. Enables longer conversations without context overflow. Batch size adapts to your IC model's capacity.",
                            icon: "archivebox",
                            isOn: $historyCompactionEnabled,
                            theme: theme
                        )

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        FeatureToggleRow(
                            title: "Response Synthesis",
                            description: "Uses Intelligence Core to compose polished final responses from agent execution results. Particularly effective for local models.",
                            icon: "sparkles",
                            isOn: $responseSynthesisEnabled,
                            theme: theme
                        )

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        FeatureToggleRow(
                            title: "RAG — Contextual Query Rewriting",
                            description: "Rewrites ambiguous follow-up queries into self-contained searches for better knowledge retrieval. Active by default.",
                            icon: "magnifyingglass",
                            isOn: $ragRewritingEnabled,
                            theme: theme
                        )

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        FeatureToggleRow(
                            title: "Morning Brief",
                            description: "Generates a session recap card on launch summarizing what was accomplished, what's pending, and any uncommitted changes.",
                            icon: "sunrise.fill",
                            isOn: $morningBriefEnabled,
                            theme: theme
                        )

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        FeatureToggleRow(
                            title: "User Personal",
                            description: "Builds a personal profile over time to tailor responses to your workflow, preferences, and communication style. You can view and edit the profile at any time.",
                            icon: "person.text.rectangle.fill",
                            isOn: $userPersonalEnabled,
                            theme: theme
                        )

                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                        FeatureToggleRow(
                            title: "Context-Aware Suggestions",
                            description: "Proactively suggests next actions based on your conversation history and recent tool usage.",
                            icon: "lightbulb.fill",
                            isOn: $suggestionEnabled,
                            theme: theme,
                            comingSoon: true
                        )

                        // View Profile button (shown when User Personal is enabled)
                        if userPersonalEnabled {
                            HStack {
                                Spacer()
                                Button {
                                    router.navigateToUserPersonalProfile()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.text.rectangle")
                                        Text("View Profile")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let lastUpdated = UserPersonalService.shared.lastUpdated {
                                    Text("Updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(.caption2))
                                        .foregroundColor(theme.tertiaryText)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }

                    // 3. Debug: Test Morning Brief
                    #if DEBUG
                    SettingsCard(title: "Debug — Test Intelligence Core", icon: "ant.fill", theme: theme) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Simulate a Morning Brief generation to verify IC load/generate/unload lifecycle and memory tracking in Console logs.")
                               .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2)

                            HStack(spacing: 12) {
                                Button {
                                    runUserPersonalTest()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isTestRunning {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "person.text.rectangle.fill")
                                        }
                                        Text(isTestRunning ? "Running..." : "Run User Personal")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .controlSize(.small)
                                .disabled(isTestRunning || selectedModel.isEmpty)

                                Button {
                                    runMorningBriefTest()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isTestRunning {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "play.fill")
                                        }
                                        Text(isTestRunning ? "Running..." : "Run Morning Brief")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.accentColor)
                                .controlSize(.small)
                                .disabled(isTestRunning || selectedModel.isEmpty)

                                Button {
                                    runICLoadUnloadTest()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isTestRunning {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                        }
                                        Text(isTestRunning ? "Running..." : "Load → Unload Cycle")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isTestRunning || selectedModel.isEmpty)

                                Spacer()

                                if !testLog.isEmpty {
                                    Button("Clear Log") {
                                        testLog.removeAll()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(.caption))
                                    .foregroundColor(theme.accentColor)
                                }
                            }

                            if !testLog.isEmpty {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(testLog.enumerated()), id: \.offset) { _, line in
                                            Text(line)
                                                .font(.system(size: 11, design: .monospaced)) // Fixed size: monospaced tool output
                                                .foregroundColor(logColor(for: line))
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 200)
                                .padding(10)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.dividerColor, lineWidth: 1)
                                )
                            }
                        }
                        .padding(16)
                    }
                    #endif

                    // 4. Custom Prompt
                    SettingsCard(title: "Custom Behavior", icon: "text.quote", theme: theme) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom Prompt")
                                .font(theme.fontBody.weight(.medium))
                                .foregroundColor(theme.primaryText)

                            Text("Add a custom instruction that shapes how the Intelligence Core behaves across all features. For example: \"Be concise\" or \"Always respond in Spanish\".")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2)

                            TextEditor(text: $customPrompt)
                                .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced input
                                .frame(minHeight: 80, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.dividerColor, lineWidth: 1)
                                )
                        }
                        .padding(16)
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            modelService.refreshInstalledModels()
            updateFitAssessment()
        }
        .onChange(of: selectedModel) { _, _ in
            // Unload previous model when selection changes so next inference loads the new one
            Task { await IntelligenceCoreService.shared.unload() }
            updateFitAssessment()
        }
    }

    // MARK: - Model Picker

    @ViewBuilder
    private var modelPicker: some View {
        if modelService.installedModels.isEmpty {
            Text("No models installed")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
        } else {
            Picker("", selection: $selectedModel) {
                Text("Select a model…")
                    .tag("")

                ForEach(modelService.installedModels) { model in
                    Text(model.displayName)
                        .tag(model.displayName)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.primaryText)
            .fixedSize()
        }
    }

    // MARK: - Debug Test Actions

    #if DEBUG
    private func runUserPersonalTest() {
        guard !isTestRunning else { return }
        isTestRunning = true
        testLog.removeAll()
        appendLog("Starting User Personal analysis...")

        Task {
            let overallStart = CFAbsoluteTimeGetCurrent()

            // Temporarily enable for the test
            let wasEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey)
            UserDefaults.standard.set(true, forKey: AppSettings.ciFeatureUserPersonalKey)

            // Clear cooldown for test
            let savedDate = UserDefaults.standard.object(forKey: AppSettings.lastUserPersonalAnalysisDateKey)
            UserDefaults.standard.removeObject(forKey: AppSettings.lastUserPersonalAnalysisDateKey)

            let service = UserPersonalService.shared

            appendLog("Gate check: \(service.shouldAnalyze() ? "PASSED" : "FAILED")")
            appendLog("Analyzing recent conversations...")

            await service.analyzeRecentConversations()

            let profileLength = service.profileMarkdown.count
            appendLog("Profile now \(profileLength) chars")

            if let lastUpdated = service.lastUpdated {
                appendLog("Last updated: \(lastUpdated.formatted(date: .abbreviated, time: .standard))")
            }

            // Show first few lines of profile
            let previewLines = service.profileMarkdown.split(separator: "\n").prefix(10)
            for line in previewLines {
                appendLog("  \(line)")
            }

            // Restore state
            if let saved = savedDate {
                UserDefaults.standard.set(saved, forKey: AppSettings.lastUserPersonalAnalysisDateKey)
            }
            if !wasEnabled {
                UserDefaults.standard.set(false, forKey: AppSettings.ciFeatureUserPersonalKey)
            }

            let totalTime = CFAbsoluteTimeGetCurrent() - overallStart
            appendLog("DONE — Total: \(String(format: "%.2f", totalTime))s")
            isTestRunning = false
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        testLog.append("[\(timestamp)] \(text)")
    }

    private func runICLoadUnloadTest() {
        guard !isTestRunning else { return }
        isTestRunning = true
        testLog.removeAll()
        appendLog("Starting IC Load → Unload cycle...")

        Task {
            do {
                let preProfile = SystemHardwareProfiler.shared.profile
                appendLog("Pre-load RAM available: \(preProfile.formattedAvailableRAM)")

                let loadStart = CFAbsoluteTimeGetCurrent()
                appendLog("Loading model: \(selectedModel)...")
                try await IntelligenceCoreService.shared.load(caller: .unknown)
                let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
                appendLog("Model loaded in \(String(format: "%.2f", loadTime))s")

                let midProfile = SystemHardwareProfiler.shared.profile
                appendLog("Post-load RAM available: \(midProfile.formattedAvailableRAM)")

                appendLog("Unloading model...")
                await IntelligenceCoreService.shared.unload(caller: .unknown)

                let postProfile = SystemHardwareProfiler.shared.profile
                appendLog("Post-unload RAM available: \(postProfile.formattedAvailableRAM)")
                appendLog("DONE — Load/Unload cycle complete.")
            } catch {
                appendLog("ERROR: \(error.localizedDescription)")
            }
            isTestRunning = false
        }
    }

    private func runMorningBriefTest() {
        guard !isTestRunning else { return }
        isTestRunning = true
        testLog.removeAll()
        appendLog("Starting Morning Brief simulation...")

        Task {
            let overallStart = CFAbsoluteTimeGetCurrent()

            // Override the cooldown by temporarily clearing the last-shown date
            let savedDate = UserDefaults.standard.object(forKey: AppSettings.lastMorningBriefDateKey)
            UserDefaults.standard.removeObject(forKey: AppSettings.lastMorningBriefDateKey)

            // Ensure toggles are set for the test
            let wasEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureMorningBriefKey)
            UserDefaults.standard.set(true, forKey: AppSettings.ciFeatureMorningBriefKey)

            let briefService = MorningBriefService.shared
            let shouldShow = briefService.shouldShowBrief()
            appendLog("Gate check: \(shouldShow ? "PASSED" : "FAILED")")

            if shouldShow {
                appendLog("Generating brief (gather context → IC insights)...")
                let brief = await briefService.generateBrief()

                if let brief {
                    appendLog("Brief generated — \(brief.insights.count) insights")
                    for insight in brief.insights {
                        appendLog("  ● \(insight.title) (\(insight.timeAgo))")
                        appendLog("    Summary: \(String(insight.summary.prefix(100)))")
                        if let suggestion = insight.suggestion {
                            appendLog("    Suggestion: \(String(suggestion.prefix(100)))")
                        }
                    }
                    if let status = brief.systemStatus {
                        appendLog("  System: \(status)")
                    }
                } else {
                    appendLog("Brief returned nil — no data or IC failed.")
                }
            }

            // Restore original state
            if let saved = savedDate {
                UserDefaults.standard.set(saved, forKey: AppSettings.lastMorningBriefDateKey)
            }
            if !wasEnabled {
                UserDefaults.standard.set(false, forKey: AppSettings.ciFeatureMorningBriefKey)
            }

            let totalTime = CFAbsoluteTimeGetCurrent() - overallStart
            appendLog("DONE — Total: \(String(format: "%.2f", totalTime))s")
            isTestRunning = false
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("ERROR") { return theme.errorColor }
        if line.contains("DONE") { return theme.successColor }
        if line.contains("PASSED") { return theme.successColor }
        if line.contains("FAILED") { return theme.warningColor }
        if line.contains("AI Summary") && line.contains("chars") { return theme.accentColor }
        return theme.primaryText
    }
    #endif

    // MARK: - Helpers

    private func updateFitAssessment() {
        guard !selectedModel.isEmpty,
              let model = modelService.installedModels.first(where: { $0.displayName == selectedModel }) else {
            currentFitAssessment = nil
            return
        }
        let profile = modelService.cachedCognitiveProfile(for: model)
        currentFitAssessment = ModelFitAdvisor.assess(metadata: profile.metadata)
    }
}

// MARK: - Feature Toggle Row

/// A specialized settings row for Intelligence Core feature toggles.
private struct FeatureToggleRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let icon: String
    @Binding var isOn: Bool
    let theme: any Theme
    var comingSoon: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isOn && !comingSoon ? theme.accentColor : theme.secondaryText)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if comingSoon {
                        Text("Coming Soon")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryText.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(theme.accentColor)
                .disabled(comingSoon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isHovered ? theme.accentColor.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if !comingSoon {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
        .opacity(comingSoon ? 0.6 : 1.0)
    }
}
