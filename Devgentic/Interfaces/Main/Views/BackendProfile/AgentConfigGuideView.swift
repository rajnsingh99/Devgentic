//
//  AgentConfigGuideView.swift
//  Devgentic
//
//  Comprehensive guide for agent configuration settings.
//  Helps users understand capabilities, execution limits, and error recovery.
//

import SwiftUI

struct AgentConfigGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Header
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "book.pages")
                            .font(.system(size: 20))
                            .foregroundColor(.accentColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Configuration Guide")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(theme.primaryText)
                    Text("Understand each setting and how to configure for optimal results.")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Close guide")
            }
            .padding(20)

            Divider().background(theme.dividerColor)

            // MARK: - Content
            ScrollView {
                VStack(spacing: 32) {

                    // 1. Overview
                    guideCard(title: "How Agents Work", icon: "brain.head.profile") {
                        guideParagraph("Every agent runs a **ReAct loop** — a cycle of Reasoning and Acting. The agent thinks about the task, decides which tool to use, observes the result, and repeats until the goal is achieved or the iteration budget is exhausted.")
                        guideParagraph("**Capabilities** layer additional behaviors on top of this core loop — planning ahead, self-correcting, or delegating to specialists. They compose independently: you can enable any combination.")
                        guideDiagram("Think  \u{2192}  Act  \u{2192}  Observe  \u{2192}  Think  \u{2192}  ...  \u{2192}  Answer")
                    }

                    // 2. Capabilities
                    guideCard(title: "Capabilities", icon: "brain.head.profile") {

                        // Planning
                        guideSubsection(
                            title: "Planning",
                            icon: "list.bullet.indent",
                            color: .blue
                        ) {
                            guideParagraph("When enabled, the agent **generates a plan** (a list of subtasks) before acting. Each subtask runs its own ReAct loop, then results are synthesised into a final response.")
                            guideSettingRow("Max Subtasks", "Maximum number of subtasks the planner can generate (2-10). Higher values suit complex, multi-faceted tasks.")
                            guideSettingRow("Parallel Subtasks", "When ON, independent subtasks run concurrently for faster execution. Turn OFF if subtask order matters.")
                            guideSettingRow("Tool Filtering", "When ON, each subtask receives only the tools relevant to it, reducing LLM confusion. Recommended for agents with many tools.")
                            guideTip("Enable Planning for tasks like \"research X, then write a report\" — anything with multiple distinct steps.")
                        }

                        Divider().background(theme.dividerColor).padding(.vertical, 4)

                        // Self-Reflection
                        guideSubsection(
                            title: "Self-Reflection",
                            icon: "arrow.trianglehead.2.counterclockwise",
                            color: .purple
                        ) {
                            guideParagraph("When enabled, the agent **evaluates its own output** after completing a task. If the result isn't good enough, it retries with self-critique — learning from what went wrong.")
                            guideSettingRow("Max Retries", "Number of reflection trials (1-5). Each retry uses the critique from the previous attempt to improve. More retries = better quality but higher cost.")
                            guideTip("Enable Self-Reflection for quality-critical tasks — code generation, writing, analysis where accuracy matters more than speed.")
                        }

                        Divider().background(theme.dividerColor).padding(.vertical, 4)

                        // Agent Delegation
                        guideSubsection(
                            title: "Agent Delegation",
                            icon: "person.2.fill",
                            color: .green
                        ) {
                            guideParagraph("When enabled, the agent can **delegate subtasks to specialist sub-agents** that you define. The LLM autonomously decides when and what to delegate based on the task requirements.")
                            guideParagraph("Sub-agents are lightweight specialists with their own model, instructions, and tools. They run independently and return results to the parent agent. Multiple delegations in one turn run in parallel.")
                            guideTip("Create sub-agents for distinct expertise areas — a \"SecurityReviewer\" for code audits, a \"DataAnalyst\" for number crunching, a \"Researcher\" for web lookups.")
                        }
                    }

                    // 3. Execution Limits
                    guideCard(title: "Execution Limits", icon: "gauge.with.dots.needle.33percent") {
                        guideSettingRow("Max Iterations", "The maximum number of think-act-observe cycles before the agent stops. Default: 15.\n\n\u{2022} Low (3-5): Quick lookups, simple Q&A\n\u{2022} Standard (10-15): Most tasks\n\u{2022} High (20-30): Complex research, multi-step problems")
                        Divider().background(theme.dividerColor)
                        guideSettingRow("Execution Timeout", "Wall-clock time limit in seconds. If the agent exceeds this, execution is forcefully cancelled. \"No limit\" means the agent runs until completion or iteration budget is exhausted.\n\nUseful as a safety net for tasks that might hang on slow API calls.")
                    }

                    // 4. Error Recovery
                    guideCard(title: "Error Recovery", icon: "arrow.clockwise") {
                        guideParagraph("These settings control how the agent handles failures during execution. They apply both when running standalone and as a workflow node.")

                        guideSettingRow("On Parse Failure", "When the LLM returns output the system can't parse (malformed JSON, missing fields).\n\n\u{2022} Retry 1-5x: Resend with a correction hint. Usually succeeds on retry.\n\u{2022} Higher retry counts are useful for smaller/local models that parse less reliably.")

                        Divider().background(theme.dividerColor)

                        guideSettingRow("Backoff Strategy", "Delay pattern between retries.\n\n\u{2022} Exponential: 1s, 2s, 4s, 8s... — best for rate-limited APIs\n\u{2022} Fixed: Constant 2s delay — simpler, predictable")

                        Divider().background(theme.dividerColor)

                        guideSettingRow("On Tool Failure", "When a tool execution fails repeatedly.\n\n\u{2022} Abort: Stop immediately and report the error\n\u{2022} Skip & Continue: Ignore the failed tool and keep reasoning\n\u{2022} Fallback Prompt: Ask the LLM to find an alternative approach")

                        Divider().background(theme.dividerColor)

                        guideSettingRow("On Budget Exhausted", "When the agent reaches max iterations without completing.\n\n\u{2022} Best-effort Response: Synthesise whatever partial results are available — usually preferred\n\u{2022} Fail Hard: Report failure with no output — use when partial results are worse than no results")
                    }

                    // 5. Quick Reference
                    guideCard(title: "Recommended Presets", icon: "sparkles") {
                        presetRow(
                            name: "Quick Lookup",
                            description: "Simple Q&A, single-tool tasks",
                            capabilities: "None",
                            iterations: "5"
                        )
                        Divider().background(theme.dividerColor)
                        presetRow(
                            name: "Standard",
                            description: "General-purpose agent tasks",
                            capabilities: "None",
                            iterations: "15"
                        )
                        Divider().background(theme.dividerColor)
                        presetRow(
                            name: "Complex Multi-Step",
                            description: "Research, reports, multi-faceted analysis",
                            capabilities: "Planning",
                            iterations: "15"
                        )
                        Divider().background(theme.dividerColor)
                        presetRow(
                            name: "Quality-Critical",
                            description: "Code generation, writing, accuracy-sensitive",
                            capabilities: "Self-Reflection",
                            iterations: "15"
                        )
                        Divider().background(theme.dividerColor)
                        presetRow(
                            name: "Team of Specialists",
                            description: "Diverse expertise needed, parallel work",
                            capabilities: "Delegation + Sub-Agents",
                            iterations: "15"
                        )
                        Divider().background(theme.dividerColor)
                        presetRow(
                            name: "Maximum Quality",
                            description: "Plan, delegate, then self-critique",
                            capabilities: "All three",
                            iterations: "20"
                        )
                    }
                }
                .padding(24)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(theme.primaryBackground)
        }
        .frame(width: 650, height: 700)
    }

    // MARK: - Guide Components

    @ViewBuilder
    private func guideCard(title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        SettingsCard(title: title, icon: icon, theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func guideSubsection(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
    }

    @ViewBuilder
    private func guideParagraph(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func guideSettingRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(description))
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func guideTip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.caption)
                .foregroundColor(.yellow)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func guideDiagram(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(theme.accentColor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.06))
            )
    }

    @ViewBuilder
    private func presetRow(name: String, description: String, capabilities: String, iterations: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Text(capabilities)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text("\(iterations) iters")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.vertical, 4)
    }
}
