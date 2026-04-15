//
//  DownloadManagerContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Full detail view for the download manager, rendered in the
//  main content area. Shows active and completed downloads with
//  rich detail including progress, cancel/retry, and backend info.
//

import SwiftUI

struct DownloadManagerContainerView: View {

    var manager = DownloadManager.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(.caption))
                        .foregroundColor(theme.accentColor)
                    Text("Download Manager")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }
            } trailing: {
                if !manager.completedDownloads.isEmpty {
                    Button {
                        withAnimation { manager.clearCompleted() }
                    } label: {
                        Text("Clear History")
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if manager.activeDownloads.isEmpty && manager.completedDownloads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Active Downloads
                        if !manager.activeDownloads.isEmpty {
                            sectionView(title: "Active Downloads") {
                                ForEach(manager.activeDownloads) { entry in
                                    ActiveDownloadCardView(entry: entry)
                                }
                            }
                        }

                        // Completed Downloads
                        if !manager.completedDownloads.isEmpty {
                            sectionView(title: "Recent Downloads") {
                                ForEach(manager.completedDownloads) { entry in
                                    CompletedDownloadCardView(entry: entry)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(theme.secondaryText.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 36)) // Fixed size: intentional (icon)
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
            Text("No Downloads")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(theme.primaryText)
            Text("Model downloads from Ollama, MLX, and Whisper will appear here.")
                .font(.callout)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(theme.fontSubheadline.weight(.bold))
                .foregroundColor(theme.primaryText)
                .textCase(.uppercase)
                .tracking(0.5)

            content()
        }
    }
}

// MARK: - Active Download Card

private struct ActiveDownloadCardView: View {

    let entry: DownloadEntry
    var manager = DownloadManager.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            // Backend Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(entry.backend.tintColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: entry.backend.icon)
                    .font(.title3)
                    .foregroundColor(entry.backend.tintColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.modelName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(entry.progress * 100))%")
                        .font(theme.fontBody.weight(.bold).monospacedDigit())
                        .foregroundColor(entry.backend.tintColor)
                }

                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
                    .tint(entry.backend.tintColor)

                HStack {
                    Text(entry.backend.rawValue)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Button {
                        manager.cancelDownload(for: entry)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(theme.errorColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
    }
}

// MARK: - Completed Download Card

private struct CompletedDownloadCardView: View {

    let entry: DownloadEntry
    var manager = DownloadManager.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            // Backend Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(entry.backend.tintColor.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: entry.backend.icon)
                    .font(.title3)
                    .foregroundColor(entry.backend.tintColor.opacity(0.6))
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.modelName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    statusView
                    Text("·")
                        .foregroundColor(theme.secondaryText)
                    Text(entry.backend.rawValue)
                        .foregroundColor(theme.secondaryText)
                }
                .font(.caption)
            }

            Spacer()

            Button {
                withAnimation { manager.removeCompleted(entry) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .padding(6)
                    .background(Circle().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(16)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch entry.status {
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            Label(message ?? "Failed", systemImage: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .lineLimit(1)
        case .cancelled:
            Label("Cancelled", systemImage: "minus.circle.fill")
                .foregroundColor(.orange)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle")
                .foregroundColor(theme.accentColor)
        }
    }
}
