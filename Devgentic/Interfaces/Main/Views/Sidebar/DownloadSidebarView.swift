//
//  DownloadSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Sidebar pane for the Downloads tab. Shows active and recently
//  completed model downloads across all backends (Ollama, MLX).
//

import SwiftUI

struct DownloadSidebarView: View {

    @ObservedObject private var manager = DownloadManager.shared
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SidebarHeaderView(
                title: "Downloads",
                buttonTitle: manager.completedDownloads.isEmpty ? nil : "Clear",
                systemImage: manager.completedDownloads.isEmpty ? nil : "trash",
                onAction: manager.completedDownloads.isEmpty ? nil : {
                    withAnimation { manager.clearCompleted() }
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if manager.activeDownloads.isEmpty && manager.completedDownloads.isEmpty {
                SidebarEmptyStateView(
                    title: "No Downloads",
                    subtitle: "Model downloads will appear here.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // Active Downloads
                        if !manager.activeDownloads.isEmpty {
                            sectionHeader("Active")

                            ForEach(manager.activeDownloads) { entry in
                                ActiveDownloadRowView(entry: entry, manager: manager)
                            }
                        }

                        // Completed Downloads
                        if !manager.completedDownloads.isEmpty {
                            sectionHeader("Recent")

                            ForEach(manager.completedDownloads) { entry in
                                CompletedDownloadRowView(entry: entry, manager: manager)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

// MARK: - Active Download Row

private struct ActiveDownloadRowView: View {

    let entry: DownloadEntry
    let manager: DownloadManager
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.backend.icon)
                    .font(.system(size: 12))
                    .foregroundColor(entry.backend.tintColor)
                    .frame(width: 20)

                Text(entry.modelName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(entry.progress * 100))%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(theme.accentColor)

                if isHovering {
                    Button {
                        manager.cancelDownload(for: entry)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Download")
                    .transition(.opacity)
                }
            }

            ProgressView(value: entry.progress)
                .progressViewStyle(.linear)
                .tint(entry.backend.tintColor)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Completed Download Row

private struct CompletedDownloadRowView: View {

    let entry: DownloadEntry
    let manager: DownloadManager
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.backend.icon)
                .font(.system(size: 12))
                .foregroundColor(entry.backend.tintColor)
                .frame(width: 20)

            statusIcon

            Text(entry.modelName)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            if isHovering {
                Button {
                    withAnimation { manager.removeCompleted(entry) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.successColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.warningColor)
        case .downloading:
            ProgressView()
                .controlSize(.mini)
        }
    }
}
