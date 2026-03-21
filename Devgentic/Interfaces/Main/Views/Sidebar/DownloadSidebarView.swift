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
    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("DOWNLOADS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .tracking(0.5)

                Spacer()

                if !manager.completedDownloads.isEmpty {
                    Button {
                        withAnimation { manager.clearCompleted() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Completed")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()
                .background(theme.dividerColor)

            if manager.activeDownloads.isEmpty && manager.completedDownloads.isEmpty {
                PlaceholderSidebarView(
                    icon: "arrow.down.circle",
                    title: "No Downloads",
                    description: "Model downloads will appear here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // Active Downloads
                        if !manager.activeDownloads.isEmpty {
                            sectionHeader("Active")

                            ForEach(manager.activeDownloads) { entry in
                                ActiveDownloadRowView(entry: entry)
                            }
                        }

                        // Completed Downloads
                        if !manager.completedDownloads.isEmpty {
                            sectionHeader("Recent")

                            ForEach(manager.completedDownloads) { entry in
                                CompletedDownloadRowView(entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
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
    @ObservedObject private var manager = DownloadManager.shared
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
    @ObservedObject private var manager = DownloadManager.shared
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
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
        case .downloading:
            ProgressView()
                .controlSize(.mini)
        }
    }
}
