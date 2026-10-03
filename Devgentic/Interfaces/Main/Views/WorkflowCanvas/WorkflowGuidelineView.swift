// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowGuidelineView.swift
//  Devgentic
//
//  The in-app workflow manual, opened from the canvas's "Guide" button. One place that explains
//  every node kind and the execution model — including the behaviours a user cannot infer from the
//  canvas: unattended (scheduled / chat-bridge) differences, failure routing, timeouts, and what
//  becomes the final output.
//
//  ⚠️ EVERY CLAIM IN HERE MUST MATCH THE ENGINE. This file is user-facing documentation of
//  `WorkflowExecutor` behaviour, and the register has a filed lesson (WF63) about inspector copy
//  derived from stale facts shipping wrong advice. When engine behaviour changes, this file changes
//  in the SAME commit — treat it like `architecture_readme.md`, but for users.
//

import SwiftUI
import AppKit

// MARK: - Navigation Hierarchy

enum GuideSection: String, CaseIterable, Identifiable {
    case all = "all"
    case overview = "overview"
    case execution = "execution"
    case failure = "failure"
    case fanIn = "fan_in"
    case finalOutput = "final_output"
    case nodes = "nodes"
    case unattended = "unattended"
    case timeouts = "timeouts"
    case data = "data"
    case saving = "saving"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Topics"
        case .overview: return "What a Workflow Is"
        case .execution: return "How Execution Works"
        case .failure: return "Failure & Error Ports"
        case .fanIn: return "Merging Branches (Fan-In)"
        case .finalOutput: return "What Becomes the Final Answer"
        case .nodes: return "The Node Directory"
        case .unattended: return "Attended vs Unattended Runs"
        case .timeouts: return "Timeouts & Retries"
        case .data: return "Data, Variables & Files"
        case .saving: return "Saving, Running & Undo"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "All Documentation"
        case .overview: return "Workflow Concept"
        case .execution: return "Execution Engine"
        case .failure: return "Failure & Error Ports"
        case .fanIn: return "Merging Branches"
        case .finalOutput: return "Final Answer & Terminals"
        case .nodes: return "Node Directory"
        case .unattended: return "Attended vs Unattended"
        case .timeouts: return "Timeouts & Retries"
        case .data: return "Data & Variables"
        case .saving: return "Saving, Running & Undo"
        }
    }

    var icon: String {
        switch self {
        case .all: return "books.vertical.fill"
        case .overview: return "point.3.connected.trianglepath.dotted"
        case .execution: return "play.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .fanIn: return "arrow.triangle.merge"
        case .finalOutput: return "flag.checkered"
        case .nodes: return "square.grid.2x2.fill"
        case .unattended: return "person.fill.questionmark"
        case .timeouts: return "clock.arrow.circlepath"
        case .data: return "shippingbox.fill"
        case .saving: return "square.and.arrow.down.fill"
        }
    }

    var group: GuideGroup {
        switch self {
        case .all: return .overview
        case .overview, .execution, .finalOutput: return .coreEngine
        case .nodes: return .components
        case .failure, .fanIn, .timeouts: return .resilience
        case .unattended, .data, .saving: return .runtime
        }
    }

    var badgeText: String? {
        switch self {
        case .nodes: return "8 nodes"
        case .unattended: return "Matrix"
        case .failure: return "Safety"
        case .timeouts: return "Budgets"
        default: return nil
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return "Complete manual of WorkflowExecutor runtime mechanics, node kinds, and fail-safes."
        case .overview:
            return "Directed graph model, wire connections, entry nodes, and terminal points."
        case .execution:
            return "Parallel dependency levels, multi-upstream input merging, and full pass-through."
        case .failure:
            return "Per-node dedicated error output ports, failure isolation, and non-cancelling parallel paths."
        case .fanIn:
            return "Multi-wire synchronisation, dead-branch pruning, and unwired error skipping."
        case .finalOutput:
            return "Terminal identification, verbatim single output, and multi-terminal headings."
        case .nodes:
            return "Comprehensive reference of all 8 canvas node kinds, identity hues, and parameter rules."
        case .unattended:
            return "Attended interactive runs compared against scheduled tasks and remote chat bridges."
        case .timeouts:
            return "Per-node compute budgets, retry loops, and sub-workflow hierarchy ceilings."
        case .data:
            return "Input placeholder syntax, JSON extraction paths, and Code output variables."
        case .saving:
            return "Canvas snapshot undo stack, manual save discipline, and profile boundary limits."
        }
    }
}

enum GuideGroup: String, CaseIterable, Identifiable {
    case overview = "OVERVIEW"
    case coreEngine = "CORE ENGINE"
    case components = "NODES & PALETTE"
    case resilience = "FLOW CONTROL & SAFETY"
    case runtime = "RUNTIME & PERSISTENCE"

    var id: String { rawValue }
}

// MARK: - Main Guide View

struct WorkflowGuidelineView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSection: GuideSection = .all
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
        .frame(minWidth: 840, idealWidth: 960, minHeight: 620, idealHeight: 760)
        .background(theme.primaryBackground)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sidebar Header Branding
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Workflow Guide")
                        .font(theme.fontFootnote.weight(.bold))
                        .foregroundColor(theme.primaryText)
                    Text("Graph Engine & Reference")
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
                    prompt: Text("Search guide & nodes").foregroundColor(theme.placeholderText)
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

            // Navigation Topics
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(GuideGroup.allCases) { group in
                        let sections = GuideSection.allCases.filter { $0.group == group }
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

            // Footer Engine Verification Placard
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

    private func sidebarItemRow(_ section: GuideSection) -> some View {
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
                Text("Engine Verified")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
            }
            Text("Synchronised with WorkflowExecutor invariants and runtime safety boundaries.")
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
                    Text("Deterministic Multi-Branch Workflow Architecture")
                        .font(theme.fontSubheadline.weight(.bold))
                        .foregroundColor(theme.primaryText)
                }

                Text("Devgentic runs workflows as directed acyclic graphs organized into parallel execution levels. Text and structured documents stream downstream without truncation, while dedicated error ports isolate branch failures.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                statPill(title: "Parallel Levels", count: "Auto", color: theme.accentColor)
                statPill(title: "Node Kinds", count: "8", color: .cyan)
                statPill(title: "Pass-Through", count: "100%", color: .green)
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
                .font(.system(size: 14, weight: .bold, design: .rounded))
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
            TactileButton(title: "Clear Filter", variant: .subtle, size: .compact) {
                searchText = ""
            }
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
                if shouldShow(.overview) { overviewContent }
                if shouldShow(.execution) { executionContent }
                if shouldShow(.failure) { failureContent }
                if shouldShow(.fanIn) { fanInContent }
                if shouldShow(.finalOutput) { finalOutputContent }
                if shouldShow(.nodes) { nodesContent }
                if shouldShow(.unattended) { unattendedContent }
                if shouldShow(.timeouts) { timeoutsContent }
                if shouldShow(.data) { dataContent }
                if shouldShow(.saving) { savingContent }
            }
        case .overview: overviewContent
        case .execution: executionContent
        case .failure: failureContent
        case .fanIn: fanInContent
        case .finalOutput: finalOutputContent
        case .nodes: nodesContent
        case .unattended: unattendedContent
        case .timeouts: timeoutsContent
        case .data: dataContent
        case .saving: savingContent
        }
    }

    private func shouldShow(_ section: GuideSection) -> Bool {
        if searchText.isEmpty { return true }
        return matchesSearch(section)
    }

    private func matchesSearch(_ section: GuideSection) -> Bool {
        if searchText.isEmpty { return true }
        let query = searchText.lowercased()
        if section.title.lowercased().contains(query) { return true }
        if section.shortTitle.lowercased().contains(query) { return true }
        if section.subtitle.lowercased().contains(query) { return true }

        // Specific keyword expansions
        switch section {
        case .overview:
            return "entry nodes terminals graph wires".contains(query)
        case .execution:
            return "parallel levels upstream truncation divider history rag".contains(query)
        case .failure:
            return "error port handler fail cancel partial".contains(query)
        case .fanIn:
            return "fan-in merge wait router gate unreachable".contains(query)
        case .finalOutput:
            return "terminal final answer heading verbatim empty".contains(query)
        case .nodes:
            return "profile sub-workflow router gate code action trigger sticky note mlx classifier hitl".contains(query)
        case .unattended:
            return "attended unattended telegram discord slack scheduled cron budget".contains(query)
        case .timeouts:
            return "timeout retry retries budget ceiling profile action sub-workflow".contains(query)
        case .data:
            return "json variables placeholder parsed attachments manifest input".contains(query)
        case .saving:
            return "autosave save changes discard changes undo snapshot 25 profile".contains(query)
        case .all:
            return true
        }
    }

    // MARK: - Section 1: Overview

    private var overviewContent: some View {
        modernCard(
            title: "What a workflow is",
            icon: "point.3.connected.trianglepath.dotted",
            tag: "Core Concept",
            tagColor: theme.accentColor
        ) {
            para("A workflow is a graph of nodes connected by wires. Each node does one job — run an AI profile, route by rules, transform text, call a tool, or wait for your approval — and passes its output to whatever is wired after it. You draw the graph on this canvas; running it executes the graph from its entry nodes to its ends.")

            visualDiagramView {
                HStack(spacing: 8) {
                    miniNode(title: "Message", subtitle: "User Input", icon: "bubble.left.and.bubble.right.fill", color: theme.secondaryText)
                    wireArrow()
                    miniNode(title: "Researcher", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                    wireArrow()
                    miniNode(title: "Router", subtitle: "Rules", icon: "arrow.triangle.branch", color: theme.nodeIdentityColor(for: .router))
                    wireArrow()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            portBadge("Urgent", color: .orange)
                            wireArrow()
                            miniNode(title: "Escalate", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                            wireArrow()
                            miniNode(title: "Answer", subtitle: "Terminal", icon: "flag.checkered", color: .green)
                        }
                        HStack(spacing: 6) {
                            portBadge("Billing", color: .cyan)
                            wireArrow()
                            miniNode(title: "Invoice bot", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                            wireArrow()
                            miniNode(title: "Answer", subtitle: "Terminal", icon: "flag.checkered", color: .green)
                        }
                    }
                }
            }

            diagram("""
            your message ──▶ [Researcher] ──▶ ⟨Router⟩ ──Urgent──▶ [Escalate] ──▶ answer
                              profile          rules  └─Billing──▶ [Invoice bot] ─┘
            """)

            para("Nodes with no incoming wires are entry nodes — they receive your message. Nodes whose outgoing wires never fired are the workflow's terminals — their output becomes the final answer.")
        }
    }

    // MARK: - Section 2: Execution

    private var executionContent: some View {
        modernCard(
            title: "How execution works",
            icon: "play.circle",
            tag: "Engine Model",
            tagColor: theme.accentColor
        ) {
            bullet("Independent nodes run in parallel. The engine groups nodes into levels by their dependencies; everything on one level that doesn't depend on a sibling runs at the same time.")
            bullet("A node's input is the joined output of the upstream nodes whose wires actually fired. One upstream arrives as-is; several arrive separated by a divider line.")
            bullet("Nothing is ever truncated. Upstream text and inlined documents pass through in full — if a downstream node's model has a small context window, pick a larger model or make upstreams less verbose. That trade is yours by design.")
            bullet("The workflow does not see your chat history or RAG context. Only the message that started the run (plus any knowledge-base and attachment text) reaches the entry nodes.")
        }
    }

    // MARK: - Section 3: Failure & Error Port

    private var failureContent: some View {
        modernCard(
            title: "Failure and the error port",
            icon: "exclamationmark.triangle",
            tag: "Fault Isolation",
            tagColor: .orange
        ) {
            para("Every node that can fail — Profile, Router, Code, Gate, Action — has a dedicated error output port beside its normal ones.")

            visualDiagramView {
                HStack(spacing: 12) {
                    miniNode(title: "Fetcher", subtitle: "Action / Tool", icon: "bolt.horizontal.fill", color: theme.nodeIdentityColor(for: .action))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            portBadge("default", color: theme.accentColor)
                            wireArrow()
                            miniNode(title: "Summarizer", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                        }
                        HStack(spacing: 6) {
                            portBadge("error", color: theme.errorColor)
                            wireArrow()
                            miniNode(title: "Notify on-call", subtitle: "Action", icon: "bell.badge.fill", color: theme.errorColor)
                            Text("← runs ONLY if Fetcher fails")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.errorColor)
                        }
                    }
                }
            }

            diagram("""
            [Fetcher] ──default──▶ [Summarizer]
                └──error────▶ [Notify on-call]     ← runs ONLY if Fetcher fails
            """)

            bullet("Wire the error port to handle a failure: the handler receives the failed node's partial output, annotated with the reason.")
            bullet("Leave it unwired and that branch simply stops there — the failure reason appears in the run's final output.")
            bullet("A failure never cancels parallel branches and never stops the whole run. Work that succeeded elsewhere keeps its results.")
            bullet("Pressing Stop is not a failure: cancelled nodes do not trigger error branches.")
        }
    }

    // MARK: - Section 4: Merging (Fan-In)

    private var fanInContent: some View {
        modernCard(
            title: "Merging branches (fan-in)",
            icon: "arrow.triangle.merge",
            tag: "Graph Synchronization",
            tagColor: .cyan
        ) {
            para("A node with several incoming wires waits for all of them — except a branch that could never fire because a Router or Gate chose a different way. The engine works that out from the graph; there is nothing to configure.")

            visualDiagramView {
                HStack(spacing: 10) {
                    miniNode(title: "Router", subtitle: "Rules", icon: "arrow.triangle.branch", color: theme.nodeIdentityColor(for: .router))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            portBadge("Branch A", color: theme.accentColor)
                            wireArrow()
                            miniNode(title: "Draft A", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                        }
                        HStack(spacing: 6) {
                            portBadge("Branch B", color: .purple)
                            wireArrow()
                            miniNode(title: "Draft B", subtitle: "Profile", icon: "person.crop.circle", color: ProfileType.bot.displayColor)
                        }
                    }
                    wireArrow()
                    miniNode(title: "Polish", subtitle: "Join Terminal", icon: "sparkles", color: .green)
                    Text("← runs when the CHOSEN side finishes")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
            }

            diagram("""
            ⟨Router⟩ ──A──▶ [Draft A] ──┐
                    └─B──▶ [Draft B] ──┴──▶ [Polish]   ← runs when the CHOSEN side finishes
            """)

            bullet("If genuinely independent branches merge and one of them failed with its error port unwired, the merge is skipped rather than run on partial input.")
        }
    }

    // MARK: - Section 5: Final Output

    private var finalOutputContent: some View {
        modernCard(
            title: "What becomes the final answer",
            icon: "flag.checkered",
            tag: "Terminal Outcomes",
            tagColor: .green
        ) {
            bullet("Terminals — nodes whose outgoing wires never fired, or that have none — produce the final output.")
            bullet("One terminal: its output is the answer, verbatim. Several: each appears under a heading with its node's name.")
            bullet("A branch the Router didn't take is quietly omitted; it is not an error and is not listed.")
            bullet("A terminal can succeed with empty text — for example an Action node whose job was a side effect. That's a valid outcome, not a failure.")
        }
    }

    // MARK: - Section 6: Nodes

    private var nodesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            modernSectionHeader(title: "The nodes", icon: "square.grid.2x2", count: "8 Node Kinds")

            VStack(spacing: 12) {
                nodeCard(
                    name: "Profile",
                    roleBadge: "AI Profile • Retries",
                    color: ProfileType.bot.displayColor,
                    icon: "person.crop.circle",
                    description: "Runs a Bot or Agent profile. The card takes the profile's OWN colour — blue for a Bot, green for an Agent — so this swatch shows the Bot case. What it does is the profile's system instructions; what it acts on is its input — the message that started the run for entry nodes, upstream output below them. Supports per-node retries and its own Per-Node Timeout. An agent's tool confirmations pause the run just like a Gate.",
                    warning: nil
                )

                nodeCard(
                    name: "Sub-workflow",
                    roleBadge: "Child Graph • 3-Level Nesting",
                    color: ProfileType.workflow.displayColor,
                    icon: "point.3.connected.trianglepath.dotted",
                    description: "A Profile node bound to another Workflow profile — it runs that workflow's canvas as a child. Text-only handoff: the child gets this node's input as its message; variables and artifacts do not cross in (artifacts produced inside do flow out). Nesting is limited to 3 levels and cycles are blocked at design time.",
                    warning: "⚠️ This node's Per-Node Timeout bounds the child's ENTIRE run — size it for the whole child, not one step. Retries share this one ceiling."
                )

                nodeCard(
                    name: "Router",
                    roleBadge: "Rule Matching • Local Classifier",
                    color: theme.nodeIdentityColor(for: .router),
                    icon: "arrow.triangle.branch",
                    description: "Matches the input against labelled rules, top to bottom; each rule's label is an output port. Exactly one match routes there. Anything else — SEVERAL rules matching, or NONE — is decided by one setting, 'When Routing Can't Decide': ask you to pick, route to a rule of your choosing, end the workflow here, or fail onto the error port. Unattended runs (scheduled or chat-bridge) never pause; an Ask uses its 'If nobody can answer' fallback instead. An optional AI Classifier (local MLX model) can name a branch when no pattern rule matched, and its answer follows the same rules — one label routes, none or several fall to the setting.",
                    warning: "⚠️ A classifier that could not RUN fails the node regardless of that setting."
                )

                nodeCard(
                    name: "Gate",
                    roleBadge: "Human-In-The-Loop • Pauses Run",
                    color: theme.nodeIdentityColor(for: .gate),
                    icon: "hand.raised",
                    description: "Pauses the run and asks you to choose. Each option is its own output port — the chosen option's branch runs. An optional timeout fails the node (onto its error port) if nobody answers; without one the gate waits indefinitely on an attended run. Parallel branches keep running while it waits, and the wait never counts against any timeout.",
                    warning: "⚠️ A scheduled run can never answer a gate, so it ends on the error port either way — wire that port. A timeout does not rescue it; it only delays the same failure, and one longer than the run's overall budget cancels the whole run. See 'Attended vs unattended' below."
                )

                nodeCard(
                    name: "Code",
                    roleBadge: "Deterministic • Variable Writer",
                    color: theme.nodeIdentityColor(for: .code),
                    icon: "chevron.left.forwardslash.chevron.right",
                    description: "A deterministic text transform — no AI involved. Write a template using {{ input }}, {{ input.json.path }} for a field of JSON output, and {{ var.name }}; optionally store the result in a variable for later nodes.",
                    warning: "⚠️ A placeholder that can't be resolved (e.g. a misspelled variable) is left in the output verbatim — check spelling; the validator does not lint Code templates. Never retries; failure routes to the error port."
                )

                nodeCard(
                    name: "Action",
                    roleBadge: "Tool Invocation • Deterministic",
                    color: theme.nodeIdentityColor(for: .action),
                    icon: "bolt.horizontal.fill",
                    description: "Calls one tool directly — no AI, deterministic. Bind each argument to a literal or a placeholder. Supports Retries (a tool call that threw is retried; a tool that RETURNED an error is not, because its side effect may already have happened) and a per-attempt timeout. Tools marked as requiring confirmation pause the run for your approval.",
                    warning: nil
                )

                nodeCard(
                    name: "Trigger",
                    roleBadge: "Entry Marker • Legacy Canvas Support",
                    color: theme.nodeIdentityColor(for: .trigger),
                    icon: "bolt",
                    description: "An entry-point marker. It has no configuration and no error port, and passes its input straight through — as the first node it hands the run's message to whatever follows, so it makes a starting point explicit without changing what the next node receives. Canvases built in earlier versions may contain one; there is no palette entry for adding a new one.",
                    warning: nil
                )

                nodeCard(
                    name: "Sticky note",
                    roleBadge: "Canvas Note • Invisible to Execution",
                    color: StickyNoteColor.yellow.swiftUIColor,
                    icon: "note.text",
                    description: "Annotation only — invisible to execution. Document your graph for whoever opens it next.",
                    warning: nil
                )
            }
        }
    }

    // MARK: - Section 7: Attended vs Unattended

    private var unattendedContent: some View {
        modernCard(
            title: "Attended vs unattended runs",
            icon: "person.fill.questionmark",
            tag: "Environment Matrix",
            tagColor: .orange
        ) {
            para("A run is attended when you start it from the app; it is unattended when the scheduler or a chat bridge (Telegram / Discord / Slack) starts it. Anything that waits for a human behaves differently:")

            VStack(spacing: 12) {
                comparisonCard(
                    situation: "Router — can't decide",
                    attended: "Follows 'When Routing Can't Decide' — with the default (Ask) a banner asks you to pick.",
                    unattended: "Never pauses — applies that setting's 'If nobody can answer' action, which by default fails the node onto its error port. A Router saved before this setting existed instead takes the first matching rule when SEVERAL match, and follows its own no-match behaviour when NONE does."
                )

                comparisonCard(
                    situation: "Gate (Human Choice)",
                    attended: "Banner appears; waits indefinitely for your choice (unless an optional gate timeout is configured).",
                    unattended: "Scheduled: no banner is shown, and the node ends up on its ERROR port either way — immediately if no gate timeout is set (nobody could answer), or when the timeout elapses if one is. No option branch is ever taken, so wire the error port. Chat bridge: answerable remotely via buttons, but there is no automatic deadline."
                )

                comparisonCard(
                    situation: "Tool confirmation",
                    attended: "Banner appears; pauses run until you approve or deny the action.",
                    unattended: "Same as Gate — nothing on screen for scheduled runs. Ends on the error port."
                )
            }

            alertNotice(
                type: .info,
                title: "Run Budget Limits",
                message: "Scheduled runs have a fixed overall time budget, counted from the moment the run starts — a long-running workflow eats into it before any pause begins. Chat-bridge runs have no overall deadline."
            )
        }
    }

    // MARK: - Section 8: Timeouts & Retries

    private var timeoutsContent: some View {
        modernCard(
            title: "Timeouts and retries",
            icon: "clock.arrow.circlepath",
            tag: "Execution Budgets",
            tagColor: theme.accentColor
        ) {
            bullet("Each node gets a compute budget (default 120 seconds) — EXCEPT a Sub-workflow node, which has none by default (see below). Time spent waiting for a human — a gate, a confirmation, a routing question — never counts against it.")
            bullet("Profile and Action nodes can raise or lower that budget from their inspector — ‘Per-Node Timeout’ on a Profile node, ‘Timeout’ on an Action node. On expiry the node fails onto its error port and any partial result is discarded.")
            bullet("Only Profile and Action nodes retry; Router, Code and Gate never do. ⚠️ Retrying a Profile node re-runs its whole agent turn — including tool side effects it already performed.")
            bullet("A Sub-workflow node has NO outer budget by default — its child canvas is already bounded, node by node, on its own terms. Setting its Per-Node Timeout adds a ceiling over the child's ENTIRE run (not one step); with retries configured, every attempt shares that ONE ceiling rather than each getting its own.")
        }
    }

    // MARK: - Section 9: Data & Variables

    private var dataContent: some View {
        modernCard(
            title: "Data, variables and files",
            icon: "shippingbox",
            tag: "Syntax & State",
            tagColor: .cyan
        ) {
            bullet("{{ input }} is the upstream text; if an upstream produced JSON, {{ input.json.path }} reads a field from it.")
            bullet("{{ input.parsed.path }} parses this node's OWN input as JSON — use it when the JSON arrived as text, including at an entry node reading what you typed in chat. {{ input.json }} needs a node upstream that actually produced JSON; {{ input.parsed }} needs only text that looks like it.")
            bullet("Variables are written ONLY by Code nodes (their Output Variable). Routers can test them; Code and Action nodes can substitute them.")
            bullet("Files and images produced by nodes flow downstream as attachments: later nodes see a manifest naming each file, and agents with file tools can read them.")
            bullet("Knowledge-base and attachment text from your message ride into the entry nodes as part of the input.")
        }
    }

    // MARK: - Section 10: Saving & Running

    private var savingContent: some View {
        modernCard(
            title: "Saving and running",
            icon: "square.and.arrow.down",
            tag: "Persistence & Undo",
            tagColor: theme.accentColor
        ) {
            bullet("⚠️ There is no autosave. Save Changes writes the canvas; Discard Changes throws away everything since the last save — and is itself one Undo away. Unsaved edits survive switching screens and are offered for saving when you quit.")
            bullet("⚠️ A run executes the last SAVED graph, not your unsaved edits — save before you start one. If you start one anyway, the run says so in its own timeline, so a result that doesn't match your canvas is never a mystery.")
            bullet("Undo (⌘Z, or the Undo button) steps back through the last 25 canvas edits — adding, deleting, rewiring, moving a node or a note, a node's own name and workflow settings, and even Clear Canvas or Discard Changes.")
            bullet("⚠️ Undo does NOT cover a node's PROFILE — its model, instructions, tools or knowledge. Those are saved to the profile itself, and not only when you press Done: deleting the node, opening another node's inspector, or starting a run — which switches away from the canvas — all save them too. Cancel is the one way to throw them away. The canvas cannot take them back.")
            bullet("A run of typing in one inspector field counts as a single step, so that is 25 edits, not 25 keystrokes. Pause for a few seconds, switch to another node, or make any structural change, and the next edit starts its own step.")
            bullet("The validation panel lists everything that would block a run — a graph with errors refuses to start before spending any tokens.")
        }
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

    private func modernCard<Content: View>(
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

    private func nodeCard(
        name: LocalizedStringKey,
        roleBadge: String,
        color: Color,
        icon: String,
        description: LocalizedStringKey,
        warning: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color)
                }

                Text(name)
                    .font(theme.fontFootnote.weight(.bold))
                    .foregroundColor(theme.primaryText)

                Text(roleBadge)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()
            }

            Text(description)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = warning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                    Text(warning)
                        .font(theme.fontCaption2)
                        .foregroundColor(.orange.opacity(0.95))
                        .lineSpacing(2.2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    private func comparisonCard(
        situation: LocalizedStringKey,
        attended: LocalizedStringKey,
        unattended: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(situation)
                .font(theme.fontFootnote.weight(.semibold))
                .foregroundColor(theme.primaryText)

            HStack(alignment: .top, spacing: 10) {
                // Attended Box
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("ATTENDED (IN-APP)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    }

                    Text(attended)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.green.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.green.opacity(0.2), lineWidth: 0.8)
                )

                // Unattended Box
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text("UNATTENDED (HEADLESS)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                    }

                    Text(unattended)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.orange.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 0.8)
                )
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

    private func alertNotice(type: AlertType, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: type.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(type.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(message)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(type.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(type.color.opacity(0.25), lineWidth: 0.8)
        )
    }

    enum AlertType {
        case info
        case warning

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            }
        }
    }

    // MARK: - Visual Flow Diagram Helpers

    private func visualDiagramView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(12)
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

    private func miniNode(title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.surfaceOverlayStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func wireArrow() -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.secondaryText.opacity(0.7))
    }

    private func portBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func para(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(theme.fontCaption2)
            .foregroundColor(theme.secondaryText)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 4.5, height: 4.5)
                .padding(.top, 6)
            Text(text)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A monospaced mini-diagram. Horizontal scroll keeps long lines intact instead of wrapping
    /// them into nonsense; the box makes it read as an illustration, not body text.
    /// ⚠️ `String`, NOT `LocalizedStringKey`, and deliberately so: this is monospaced ASCII art whose
    /// alignment IS its meaning. Translating it would reflow the box drawing into nonsense, and the
    /// extractor would offer a translator a diagram they cannot safely touch. Every OTHER copy
    /// helper in this file takes a `LocalizedStringKey` (register CVV-8) — this is the one
    /// exception, recorded here so it does not read as an oversight.
    private func diagram(_ art: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(art)
                .font(theme.fontCodeCaption)
                .foregroundColor(theme.primaryText.opacity(0.85))
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.controlBackground.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
        )
    }
}
