// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeDedicatedView.swift
//  Devgentic
//
//  Dedicated view for the Code interface.
//  Wraps ChatHistoryView with an interactive breadcrumb status header and
//  actionable onboarding checklist cards with hover depth.
//  The sidebar (Explorer) and CodeViewerPanel are positioned at MainApplicationView level.
//

import SwiftUI
import AppKit

struct CodeDedicatedView: View {

    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    @State private var showingContextInspector: Bool = false
    @State private var showingToolsGuide: Bool = false
    @State private var isToolsCardHovered: Bool = false
    @State private var activeGitBranch: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if codeSessionManager.isConfigured || viewModel.selectedConversationID != nil {
                // Reuse the existing ChatHistoryView for message rendering, with a
                // code-specific "ready" overlay when no conversation is active yet.
                ChatHistoryView()
                    .environment(chatHistoryViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if viewModel.selectedConversationID == nil && codeSessionManager.isConfigured {
                            codeReadyState
                        }
                    }
            } else {
                codeEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingToolsGuide) {
            CodeToolsGuideView()
        }
        .onAppear {
            refreshGitBranch()
        }
        .onChange(of: codeSessionManager.projectPath) { _, _ in
            refreshGitBranch()
        }
    }

    private func refreshGitBranch() {
        if let path = codeSessionManager.projectPath {
            activeGitBranch = GitBranchReader.branch(for: path)
        } else {
            activeGitBranch = nil
        }
    }

    // MARK: - Ready State (configured, awaiting first message)

    private var codeReadyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 6) {
                Text("Ready to code")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                if let path = codeSessionManager.projectPath {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text(path.lastPathComponent)
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                        if let branch = activeGitBranch {
                            Text("·")
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundColor(.purple)
                            Text(branch)
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }

            // Project Structure button positioned directly below "Ready to code"
            projectStructureButton

            Text("Ask a question about your code to get started.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .multilineTextAlignment(.center)

            Button(action: {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                showingToolsGuide = true
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 10))
                    Text("16 Coding Tools Active · Know more")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .help("Inspect the 16 built-in developer tools and safety policies")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var projectStructureButton: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            showingContextInspector = true
        }) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                if let content = codeSessionManager.projectMemoryContent {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("Project Structure · \(content.count) chars")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                } else {
                    Text("Project Structure · Not indexed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.surfaceOverlay)
            )
            .overlay(
                Capsule()
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingContextInspector, arrowEdge: .bottom) {
            CodeContextInspectorPopover(
                projectURL: codeSessionManager.projectPath,
                contextContent: codeSessionManager.projectMemoryContent
            )
        }
        .help("Inspect the project structure and linked codebase context (.devgentic/context.md)")
    }

    // MARK: - Empty State (Actionable Onboarding Checklist Cards)

    private var codeEmptyState: some View {
        VStack(spacing: 24) {
            // Hero icon
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            // Title + subtitle
            VStack(spacing: 6) {
                Text("Start coding")
                    .font(theme.fontHeadline.weight(.bold))
                    .foregroundColor(theme.primaryText)

                Text("Configure your workspace and model to begin coding sessions.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            // Interactive setup cards
            VStack(spacing: 12) {
                CodeOnboardingCard(
                    icon: "folder.fill",
                    iconColor: .orange,
                    title: codeSessionManager.projectPath == nil ? "Open a Project Folder" : (codeSessionManager.projectPath?.lastPathComponent ?? "Folder Selected"),
                    subtitle: codeSessionManager.projectPath == nil ? "Choose your workspace directory to index and edit" : (codeSessionManager.projectPath?.path ?? ""),
                    isDone: codeSessionManager.projectPath != nil,
                    actionTitle: "Browse…",
                    action: openProjectFolderPicker
                )

                CodeOnboardingCard(
                    icon: "cpu.fill",
                    iconColor: theme.accentColor,
                    title: codeSessionManager.modelName.isEmpty ? "Select a Coding Model" : codeSessionManager.modelDisplayName,
                    // ⚠️ This used to read "14B+ model recommended for code synthesis" — the
                    // user-facing half of a size floor the picker enforced for Ollama only. Both
                    // are retired together: a promise that named a parameter count could not be
                    // kept honestly (it never applied to MLX or cloud models) and was measuring
                    // the wrong thing anyway. Tool calling is the capability that actually decides
                    // whether a model can drive the Code loop, and the picker annotates that.
                    subtitle: codeSessionManager.modelName.isEmpty ? "Any tool-capable model works best" : "\(codeSessionManager.provider.rawValue.capitalized) Provider",
                    isDone: !codeSessionManager.modelName.isEmpty,
                    actionTitle: "Choose…",
                    action: openModelPicker
                )

                // Built-in Tooling Highlight Card with "Know more"
                builtInToolsHighlightCard
            }
            .frame(maxWidth: 540)

            // Hint
            Text("You can also change folders and models anytime in the composer toolbar.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.6))
        }
        .padding(32)
    }

    private var builtInToolsHighlightCard: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            showingToolsGuide = true
        }) {
            HStack(spacing: 12) {
                // Icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                // Title & Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("16 Built-in Coding Tools")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text("ACTIVE")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text("AST search, atomic edits, terminal execution & git inspection")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Action Pill
                HStack(spacing: 4) {
                    Text("Know more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.12))
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isToolsCardHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isToolsCardHovered
                            ? theme.accentColor.opacity(0.4)
                            : theme.dividerColor.opacity(0.3),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isToolsCardHovered ? Color.black.opacity(0.12) : Color.clear,
                radius: 6,
                y: 2
            )
            .scaleEffect(isToolsCardHovered ? 1.01 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isToolsCardHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isToolsCardHovered = hovering
        }
    }

    // MARK: - User Actions

    private func openProjectFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = String(localized: "Select Project Folder")
        openPanel.message = String(localized: "Choose a folder for your Code session.")

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                Task { @MainActor in
                    viewModel.chooseCodeFolder(url)
                    activeGitBranch = GitBranchReader.branch(for: url)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            }
        }
    }

    private func openModelPicker() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        codeSessionManager.showModelPicker = true
    }
}

// MARK: - Code Onboarding Card Helper

private struct CodeOnboardingCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isDone: Bool
    let actionTitle: String
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isDone ? Color.green.opacity(0.15) : iconColor.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: isDone ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isDone ? .green : iconColor)
                }

                // Title & Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Action Pill / Status
                HStack(spacing: 4) {
                    Text(isDone ? "Change" : actionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isDone ? theme.secondaryText : theme.accentColor)

                    Image(systemName: isDone ? "arrow.triangle.2.circlepath" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isDone ? theme.secondaryText.opacity(0.7) : theme.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isDone ? theme.surfaceOverlay : theme.accentColor.opacity(0.12))
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? (isDone ? Color.green.opacity(0.4) : theme.accentColor.opacity(0.4))
                            : theme.dividerColor.opacity(0.3),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? Color.black.opacity(0.12) : Color.clear,
                radius: 6,
                y: 2
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
