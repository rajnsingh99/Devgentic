//
//  CodeDedicatedView.swift
//  Devgentic
//
//  Dedicated view for the Code interface.
//  Wraps ChatHistoryView with a code-specific status header and empty state.
//  The sidebar (Explorer) and CodeViewerPanel are already positioned at MainApplicationView level.
//

import SwiftUI

struct CodeDedicatedView: View {

    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if codeSessionManager.isConfigured || viewModel.selectedConversationID != nil {
                if codeSessionManager.isConfigured {
                    codeStatusHeader
                }

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
    }

    // MARK: - Ready State (configured, awaiting first message)

    private var codeReadyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.cyan.opacity(0.5))

            VStack(spacing: 6) {
                Text("Ready to code")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                if let path = codeSessionManager.projectPath {
                    Text(path.lastPathComponent)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Text("Ask a question about your code to get started.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }

    // MARK: - Status Header

    private var codeStatusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.cyan)

            if let path = codeSessionManager.projectPath {
                Text(path.lastPathComponent)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Project context indicator — labels the char-count as "context" so the
            // brain-icon + number isn't mistaken for a token-usage badge.
            if let content = codeSessionManager.projectMemoryContent {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text("Context · \(content.count) chars")
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .help("Project context from .devgentic/context.md — injected into the system prompt on every message (\(content.count) characters).")
            }

            if !codeSessionManager.modelName.isEmpty {
                Text(codeSessionManager.modelDisplayName)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.primaryBackground.opacity(0.8))
    }

    // MARK: - Empty State

    private var codeEmptyState: some View {
        VStack(spacing: 24) {
            // Hero icon
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 40))
                .foregroundColor(.cyan.opacity(0.4))

            // Title + subtitle
            VStack(spacing: 6) {
                Text("Start coding")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
            }

            // Setup steps
            VStack(alignment: .leading, spacing: 10) {
                setupRow(
                    icon: "folder",
                    color: .orange,
                    text: "Open a project folder",
                    isDone: codeSessionManager.projectPath != nil
                )

                setupRow(
                    icon: "cpu",
                    color: .cyan,
                    text: "We allow 14B or larger models",
                    isDone: !codeSessionManager.modelName.isEmpty
                )
            }
            .padding(16)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 340)

            // Hint
            Text("Use the toolbar below to select a folder and model.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.6))
        }
    }

    private func setupRow(icon: String, color: Color, text: String, isDone: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isDone ? .green : color)
                .frame(width: 20)

            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(isDone ? theme.secondaryText : theme.primaryText)

            Spacer()
        }
    }
}
