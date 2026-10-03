// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentConfigGuideView.swift
//  Devgentic
//
//  Comprehensive guide for agent configuration settings.
//  Helps users understand capabilities, execution limits, and error recovery.
//

import SwiftUI
import AppKit

// MARK: - Navigation Hierarchy

enum AgentGuideSection: String, CaseIterable, Identifiable {
    case all = "all"
    case howAgentsWork = "how_agents_work"
    case planning = "planning"
    case selfReflection = "self_reflection"
    case executionLimits = "execution_limits"
    case errorRecovery = "error_recovery"
    case presets = "presets"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Documentation"
        case .howAgentsWork: return "How Agents Work"
        case .planning: return "Planning Capability"
        case .selfReflection: return "Self-Reflection Capability"
        case .executionLimits: return "Execution Limits"
        case .errorRecovery: return "Error Recovery"
        case .presets: return "Recommended Presets"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "All Topics"
        case .howAgentsWork: return "How Agents Work"
        case .planning: return "Planning"
        case .selfReflection: return "Self-Reflection"
        case .executionLimits: return "Execution Limits"
        case .errorRecovery: return "Error Recovery"
        case .presets: return "Presets"
        }
    }

    var icon: String {
        switch self {
        case .all: return "books.vertical.fill"
        case .howAgentsWork: return "brain.head.profile"
        case .planning: return "list.bullet.indent"
        case .selfReflection: return "arrow.trianglehead.2.counterclockwise"
        case .executionLimits: return "gauge.with.dots.needle.33percent"
        case .errorRecovery: return "arrow.clockwise"
        case .presets: return "sparkles"
        }
    }

    var group: AgentGuideGroup {
        switch self {
        case .all, .howAgentsWork: return .overview
        case .planning, .selfReflection: return .capabilities
        case .executionLimits, .errorRecovery: return .limitsAndControl
        case .presets: return .reference
        }
    }

    var badgeText: String? {
        switch self {
        case .howAgentsWork: return "ReAct"
        case .planning: return "Planner"
        case .selfReflection: return "Critique"
        case .executionLimits: return "Budgets"
        case .errorRecovery: return "Policies"
        case .presets: return "6 Archetypes"
        case .all: return nil
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return "Complete reference of agent ReAct execution, composable capabilities, limits, and resilience."
        case .howAgentsWork:
            return "Reasoning and Acting loop architecture, tool observations, and independent capability layers."
        case .planning:
            return "Multi-step subtask generation, planner budgets, and contextual tool filtering."
        case .selfReflection:
            return "Autonomous output evaluation, iterative self-critique, and retry limits."
        case .executionLimits:
            return "Iteration ceilings, wall-clock execution timeouts, and API safety nets."
        case .errorRecovery:
            return "Parse failure resends, tool failure tolerances, fallback prompts, and budget exhaustion."
        case .presets:
            return "Pre-configured archetypes optimized for Q&A, research, code generation, and quality."
        }
    }
}

enum AgentGuideGroup: String, CaseIterable, Identifiable {
    case overview = "OVERVIEW"
    case capabilities = "CAPABILITIES"
    case limitsAndControl = "LIMITS & CONTROL"
    case reference = "PRESETS & REFERENCE"

    var id: String { rawValue }
}

// MARK: - Main Guide View

struct AgentConfigGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var selectedSection: AgentGuideSection = .all
    @State private var searchText: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 250)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(width: 0.5)

            detailContentView
        }
        .frame(minWidth: 840, idealWidth: 940, minHeight: 620, idealHeight: 750)
        .background(theme.primaryBackground)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Branding
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent Guide")
                        .font(theme.fontFootnote.weight(.bold))
                        .foregroundColor(theme.primaryText)
                    Text("Configuration & Mechanics")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text("Search settings & presets...").foregroundColor(theme.placeholderText)
                )
                .textFieldStyle(.plain)
                .font(theme.fontCaption)
                .foregroundColor(theme.primaryText)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // Navigation Sections
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AgentGuideGroup.allCases) { group in
                        let sections = AgentGuideSection.allCases.filter { $0.group == group }
                        let matching = sections.filter { matchesSearch($0) }

                        if !matching.isEmpty {
                            sidebarGroupHeader(group.rawValue)
                            ForEach(matching) { section in
                                sidebarItemRow(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            // Footer Verification Placard
            sidebarFooterPlacard
        }
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private func sidebarGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundColor(theme.secondaryText.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func sidebarItemRow(_ section: AgentGuideSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 18)

                Text(section.shortTitle)
                    .font(theme.fontCaption.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge = section.badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(isSelected ? theme.accentColor.opacity(0.18) : theme.surfaceOverlay)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var sidebarFooterPlacard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                Text("ReAct Architecture")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
            }
            Text("Verified against ReAct agent loop invariants and capability runtime contracts.")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(1.8)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlay.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
        )
        .padding(12)
    }

    // MARK: - Detail Content

    private var detailContentView: some View {
        VStack(spacing: 0) {
            // Header Bar
            detailHeaderBar
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Scrollable Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedSection == .all && searchText.isEmpty {
                        heroArchitectureCallout
                    }

                    if !searchText.isEmpty {
                        searchHeaderCallout
                    }

                    renderSectionContent()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .padding(.trailing, 8) // Trailing clearance for seamless overlay scroller
            }
        }
    }

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: selectedSection.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(selectedSection.title)
                        .font(theme.fontTitle3.weight(.bold))
                        .foregroundColor(theme.primaryText)

                    if let badge = selectedSection.badgeText {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(theme.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(selectedSection.subtitle)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            TactileIconButton(
                icon: "xmark.circle.fill",
                tooltip: "Close Guide (Esc)",
                accessibilityLabel: "Close Guide",
                variant: .subtle,
                size: 26
            ) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var heroArchitectureCallout: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)
                    Text("Autonomous ReAct Agent Engine")
                        .font(theme.fontSubheadline.weight(.bold))
                        .foregroundColor(theme.primaryText)
                }

                Text("Devgentic agents run a cycle of Reasoning, Acting via tool invocations, and Observation. Composable capabilities layer structured subtask planning, autonomous self-reflection, and fault-tolerant error policies on top.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                statPill(title: "Cycle", count: "ReAct", color: theme.accentColor)
                statPill(title: "Capabilities", count: "Composable", color: .purple)
                statPill(title: "Presets", count: "6 Profiles", color: .green)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func statPill(title: String, count: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(count)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var searchHeaderCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(theme.accentColor)
            Text("Filtered results for: ")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
            Text("\"\(searchText)\"")
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Button("Clear Filter") {
                searchText = ""
            }
            .buttonStyle(.plain)
            .font(theme.fontCaption)
            .foregroundColor(theme.accentColor)
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
    }

    // MARK: - Section Routing

    @ViewBuilder
    private func renderSectionContent() -> some View {
        switch selectedSection {
        case .all:
            VStack(alignment: .leading, spacing: 20) {
                if shouldShow(.howAgentsWork) { howAgentsWorkContent }
                if shouldShow(.planning) || shouldShow(.selfReflection) {
                    capabilitiesSectionContent
                }
                if shouldShow(.executionLimits) { executionLimitsContent }
                if shouldShow(.errorRecovery) { errorRecoveryContent }
                if shouldShow(.presets) { presetsContent }
            }
        case .howAgentsWork: howAgentsWorkContent
        case .planning: planningContent
        case .selfReflection: selfReflectionContent
        case .executionLimits: executionLimitsContent
        case .errorRecovery: errorRecoveryContent
        case .presets: presetsContent
        }
    }

    private func shouldShow(_ section: AgentGuideSection) -> Bool {
        if searchText.isEmpty { return true }
        return matchesSearch(section)
    }

    private func matchesSearch(_ section: AgentGuideSection) -> Bool {
        if searchText.isEmpty { return true }
        let query = searchText.lowercased()
        if section.title.lowercased().contains(query) { return true }
        if section.shortTitle.lowercased().contains(query) { return true }
        if section.subtitle.lowercased().contains(query) { return true }

        switch section {
        case .howAgentsWork:
            return "react loop think act observe reasoning capability".contains(query)
        case .planning:
            return "planning subtasks tool filtering max subtasks planner".contains(query)
        case .selfReflection:
            return "self-reflection critique retries trial evaluation quality".contains(query)
        case .executionLimits:
            return "execution limits max iterations timeout wall-clock budget".contains(query)
        case .errorRecovery:
            return "error recovery parse failure tool tolerance abort skip fallback budget exhausted".contains(query)
        case .presets:
            return "presets lookup standard multi-step quality specialists team".contains(query)
        case .all:
            return true
        }
    }

    // MARK: - Section 1: How Agents Work

    private var howAgentsWorkContent: some View {
        guideCard(
            title: "How Agents Work",
            icon: "brain.head.profile",
            tag: "Core Loop",
            tagColor: theme.accentColor
        ) {
            guideParagraph("Every agent runs a **ReAct loop** — a cycle of Reasoning and Acting. The agent thinks about the task, decides which tool to use, observes the result, and repeats until the goal is achieved or the iteration budget is exhausted.")
            guideParagraph("**Capabilities** layer additional behaviors on top of this core loop — planning ahead, self-correcting, or delegating to specialists. They compose independently: you can enable any combination.")

            visualReActFlow

            guideDiagram("Think  →  Act  →  Observe  →  Think  →  ...  →  Answer")
        }
    }

    private var visualReActFlow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                reactStepPill(number: "1", title: "Think", subtitle: "Reasoning", icon: "brain", color: .blue)
                flowArrow
                reactStepPill(number: "2", title: "Act", subtitle: "Tool Call", icon: "hammer.fill", color: .orange)
                flowArrow
                reactStepPill(number: "3", title: "Observe", subtitle: "Execution Result", icon: "eye.fill", color: .purple)
                flowArrow
                HStack(spacing: 4) {
                    Image(systemName: "arrow.trianglehead.2.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.accentColor)
                    Text("Loop / Adapt")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.accentColor.opacity(0.12))
                .clipShape(Capsule())
                flowArrow
                reactStepPill(number: "✓", title: "Answer", subtitle: "Final Synthesis", icon: "flag.checkered", color: .green)
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.controlBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func reactStepPill(number: String, title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 18, height: 18)
                Text(number)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.primaryText)
                }
                Text(subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.surfaceOverlayStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.secondaryText.opacity(0.65))
    }

    // MARK: - Section 2: Capabilities (Combined / Discrete)

    private var capabilitiesSectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            modernSectionHeader(title: "Capabilities", icon: "brain.head.profile", count: "2 Modules")
            if shouldShow(.planning) { planningContent }
            if shouldShow(.selfReflection) { selfReflectionContent }
        }
    }

    private var planningContent: some View {
        guideCard(
            title: "Planning",
            icon: "list.bullet.indent",
            tag: "Multi-Step Decomposition",
            tagColor: .blue
        ) {
            guideParagraph("When enabled, the agent **generates a plan** (a list of subtasks) before acting. Each subtask runs its own ReAct loop, then results are synthesised into a final response.")

            VStack(spacing: 10) {
                guideSettingCard(
                    title: "Max Subtasks",
                    badge: "2 – 10 Subtasks",
                    description: "Maximum number of subtasks the planner can generate (2-10). Higher values suit complex, multi-faceted tasks."
                )

                // ⚠️ Register A74: a "Parallel Subtasks" row sat here describing a
                // toggle the user cannot find — the control was removed from
                // `AgentCapabilitiesSection` and this guide was not updated with it, so
                // the only remaining mention of the setting was an instruction to go and
                // change something that isn't there.
                //
                // ⚠️ Removed rather than reworded: this list documents CONTROLS, and
                // there is no control. The stored `parallelSubtasks` field is still read
                // by `PlanningCapability` for profiles that persisted `true` — that is
                // register A67 and is NOT fixed by this. If A67 restores the toggle,
                // restore this row with it.
                guideSettingCard(
                    title: "Tool Filtering",
                    badge: "Context Optimizer",
                    description: "When ON, each subtask receives only the tools relevant to it, reducing LLM confusion. Recommended for agents with many tools."
                )
            }

            guideTip("Enable Planning for tasks like \"research X, then write a report\" — anything with multiple distinct steps.")
        }
    }

    private var selfReflectionContent: some View {
        guideCard(
            title: "Self-Reflection",
            icon: "arrow.trianglehead.2.counterclockwise",
            tag: "Autonomous Evaluator",
            tagColor: .purple
        ) {
            guideParagraph("When enabled, the agent **evaluates its own output** after completing a task. If the result isn't good enough, it retries with self-critique — learning from what went wrong.")

            guideSettingCard(
                title: "Max Retries",
                badge: "1 – 5 Trials",
                description: "Number of reflection trials (1-5). Each retry uses the critique from the previous attempt to improve. More retries = better quality but higher cost."
            )

            guideTip("Enable Self-Reflection for quality-critical tasks — code generation, writing, analysis where accuracy matters more than speed.")

            // ⚠️ register B15 — the "Agent Delegation" subsection was REMOVED, not
            // reworded. It documented sub-agents "that you define" running "in
            // parallel": there has been no UI to define them since the toggle was
            // withdrawn, the parallel claim contradicted A66's own note that sub-agents
            // share one model and therefore queue, and as of B15 the runtime does not
            // inject `call_agent` at all (`AgentConnect.agentDelegationSupported`).
            // A74 removed the sibling "Parallel Subtasks" row for the same reason: this
            // list documents CONTROLS, and there is no control here to document.
            // Restore this section if `agentDelegationSupported` is ever flipped back.
        }
    }

    // MARK: - Section 3: Execution Limits

    private var executionLimitsContent: some View {
        guideCard(
            title: "Execution Limits",
            icon: "gauge.with.dots.needle.33percent",
            tag: "Compute Guardrails",
            tagColor: theme.accentColor
        ) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Iterations")
                            .font(theme.fontFootnote.weight(.bold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("Default: 15")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text("The maximum number of think-act-observe cycles before the agent stops.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 8) {
                        limitRangePill(range: "Low (3-5)", label: "Quick lookups, simple Q&A", color: .cyan)
                        limitRangePill(range: "Standard (10-15)", label: "Most general tasks", color: .green)
                        limitRangePill(range: "High (20-30)", label: "Complex research & problems", color: .orange)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
                )

                guideSettingCard(
                    title: "Execution Timeout",
                    badge: "Wall-Clock Cap",
                    description: "Wall-clock time limit in seconds. If the agent exceeds this, execution is forcefully cancelled. \"No limit\" means the agent runs until completion or iteration budget is exhausted.\n\nUseful as a safety net for tasks that might hang on slow API calls."
                )
            }
        }
    }

    private func limitRangePill(range: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(range)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 8.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Section 4: Error Recovery

    private var errorRecoveryContent: some View {
        guideCard(
            title: "Error Recovery",
            icon: "arrow.clockwise",
            tag: "Resilience Policies",
            tagColor: .orange
        ) {
            guideParagraph("These settings control how the agent handles failures during execution. They apply both when running standalone and as a workflow node.")

            VStack(spacing: 10) {
                guideSettingCard(
                    title: "On Parse Failure",
                    badge: "Auto (3 Retries)",
                    description: "How many times to resend with a correction hint when the LLM returns output the system can't parse (malformed JSON, missing fields). This affects ONLY parse failures.\n\n• Auto: a sensible default (3).\n• Higher counts help smaller/local models that parse less reliably.\n\nNetwork issues (timeouts, rate limits, server errors) are handled automatically based on your provider and are not configured here."
                )

                guideSettingCard(
                    title: "Tool Failure Tolerance",
                    badge: "Auto (3 Failures)",
                    description: "How many consecutive tool failures the agent tolerates before it gives up. Separate from the parse-failure setting above and from the policy below — this is the count; the policy decides what happens once the count is reached.\n\n• Auto: a sensible default (3)."
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("On Tool Failure")
                            .font(theme.fontFootnote.weight(.bold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("Policy Options")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }

                    Text("When a tool execution fails repeatedly:")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 8) {
                        policyPill(name: "Abort", desc: "Stop immediately & report", color: .red)
                        policyPill(name: "Skip & Continue", desc: "Ignore failure & reason", color: .orange)
                        policyPill(name: "Fallback Prompt", desc: "Ask LLM for alternative", color: .blue)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("On Budget Exhausted")
                            .font(theme.fontFootnote.weight(.bold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("Policy Options")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.purple)
                    }

                    Text("When the agent reaches max iterations without completing:")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 8) {
                        policyPill(name: "Best-effort Response", desc: "Synthesise partial results (preferred)", color: .green)
                        policyPill(name: "Fail Hard", desc: "Report failure with no output", color: .red)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
                )
            }
        }
    }

    private func policyPill(name: String, desc: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
            Text(desc)
                .font(.system(size: 8.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Section 5: Presets

    private var presetsContent: some View {
        guideCard(
            title: "Recommended Presets",
            icon: "sparkles",
            tag: "6 Archetypes",
            tagColor: .green
        ) {
            guideParagraph("Quickly match your task to a verified configuration pattern:")

            VStack(spacing: 8) {
                presetCard(
                    name: "Quick Lookup",
                    description: "Simple Q&A, single-tool tasks",
                    capabilities: "None",
                    capabilitiesColor: theme.secondaryText,
                    iterations: "5"
                )

                presetCard(
                    name: "Standard",
                    description: "General-purpose agent tasks",
                    capabilities: "None",
                    capabilitiesColor: theme.secondaryText,
                    iterations: "15"
                )

                presetCard(
                    name: "Complex Multi-Step",
                    description: "Research, reports, multi-faceted analysis",
                    capabilities: "Planning",
                    capabilitiesColor: .blue,
                    iterations: "15"
                )

                presetCard(
                    name: "Quality-Critical",
                    description: "Code generation, writing, accuracy-sensitive",
                    capabilities: "Self-Reflection",
                    capabilitiesColor: .purple,
                    iterations: "15"
                )

                presetCard(
                    name: "Team of Specialists",
                    description: "Diverse expertise needed, parallel work",
                    capabilities: "Delegation + Sub-Agents",
                    capabilitiesColor: .orange,
                    iterations: "15"
                )

                presetCard(
                    name: "Maximum Quality",
                    description: "Plan, delegate, then self-critique",
                    capabilities: "All three",
                    capabilitiesColor: .green,
                    iterations: "20"
                )
            }
        }
    }

    private func presetCard(
        name: LocalizedStringKey,
        description: LocalizedStringKey,
        capabilities: LocalizedStringKey,
        capabilitiesColor: Color,
        iterations: String
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(theme.fontFootnote.weight(.bold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text(capabilities)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(capabilitiesColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(capabilitiesColor.opacity(0.12))
                    .clipShape(Capsule())

                // ⚠️ `iterations` stays a plain String — it is a numeral, not prose.
                Text("\(iterations) iters")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.surfaceOverlay)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    // MARK: - Reusable Modern Components

    private func modernSectionHeader(title: LocalizedStringKey, icon: String, count: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(theme.accentColor)

            Text(title)
                .font(theme.fontSubheadline.weight(.bold))
                .foregroundColor(theme.primaryText)

            if let count = count {
                Text(count)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    private func guideCard<Content: View>(
        title: LocalizedStringKey,
        icon: String,
        tag: String? = nil,
        tagColor: Color = .blue,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tagColor)

                Text(title)
                    .font(theme.fontFootnote.weight(.bold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if let tag = tag {
                    Text(tag)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(tagColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tagColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func guideSettingCard(title: LocalizedStringKey, badge: String? = nil, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                if let badge = badge {
                    Spacer()
                    Text(badge)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.surfaceOverlay)
                        .clipShape(Capsule())
                }
            }
            Text(description)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2.2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    // ⚠️ Register A62. Every helper below takes a `LocalizedStringKey` so literals at call sites
    // remain extractable keys in the String Catalog.
    private func guideParagraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(theme.fontCaption2)
            .foregroundColor(theme.secondaryText)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func guideTip(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)
                .padding(.top, 1)
            Text(text)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .italic()
                .lineSpacing(2.2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.2), lineWidth: 0.8)
        )
    }

    // ⚠️ Also a `LocalizedStringKey`: its only content is "Think → Act → Observe → … → Answer",
    // which is four translatable words, not ASCII art.
    private func guideDiagram(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(theme.fontCodeCaption)
            .foregroundColor(theme.accentColor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
            )
    }
}
