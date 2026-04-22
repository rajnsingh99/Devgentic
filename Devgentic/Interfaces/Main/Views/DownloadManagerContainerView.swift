//
//  DownloadManagerContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Rewritten 2026-04-21 — reads from `DownloadHistoryStore` directly via
//  `@Query` so history survives relaunches. Mirrors the sidebar's layout
//  (in-progress section + date-grouped history) at a roomier scale.
//

import SwiftUI
import SwiftData

struct DownloadManagerContainerView: View {

    @Query(sort: \DownloadRecord.updatedAt, order: .reverse)
    private var allRecords: [DownloadRecord]

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var showingClearAlert: Bool = false

    private var activeRecords: [DownloadRecord] { allRecords.filter { $0.isActive } }
    private var historyRecords: [DownloadRecord] { allRecords.filter { !$0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(title: "Download Manager", icon: "arrow.down.circle") {
                if !historyRecords.isEmpty {
                    IslandPillButton(
                        title: "Clear History",
                        style: .subtle,
                        accessibilityLabel: "Clear download history"
                    ) {
                        showingClearAlert = true
                    }
                }
            }

            if allRecords.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        if !activeRecords.isEmpty {
                            sectionView(title: "Active Downloads (\(activeRecords.count))") {
                                ForEach(activeRecords) { record in
                                    ActiveDownloadCardView(record: record)
                                }
                            }
                        }

                        if !historyRecords.isEmpty {
                            sectionView(title: "History (\(historyRecords.count))") {
                                ForEach(historyRecords) { record in
                                    HistoryDownloadCardView(record: record)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: ViewLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear download history?", isPresented: $showingClearAlert) {
            Button("Clear", role: .destructive) {
                let cleared = (try? DownloadHistoryStore.shared.deleteAllHistory(keepingActive: true).get()) ?? 0
                toastManager.show("Removed \(cleared) record\(cleared == 1 ? "" : "s")", style: .success)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all completed, failed, and cancelled records. Active downloads are kept.")
        }
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

// MARK: - Active card

private struct ActiveDownloadCardView: View {

    let record: DownloadRecord
    @Environment(\.appTheme) private var theme

    private var tint: Color { record.backend?.tintColor ?? .blue }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }
    private var backendName: String { record.backend?.rawValue ?? "Unknown" }

    private var speedSnapshot: DownloadSpeedSnapshot? {
        DownloadManager.shared.activeSpeeds[record.id]
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.displayName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(record.progress * 100))%")
                        .font(theme.fontBody.weight(.bold).monospacedDigit())
                        .foregroundColor(tint)
                }

                ProgressView(value: record.progress)
                    .progressViewStyle(.linear)
                    .tint(tint)

                HStack(spacing: 8) {
                    Text(backendName)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)

                    Text("·").foregroundColor(theme.tertiaryText)

                    Text(DownloadSpeedFormatter.compactLine(snapshot: speedSnapshot))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        DownloadManager.shared.cancelDownload(record)
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

// MARK: - History card

private struct HistoryDownloadCardView: View {

    let record: DownloadRecord
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme
    @State private var showingRedownloadAlert: Bool = false

    private var tint: Color { record.backend?.tintColor ?? .blue }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }
    private var backendName: String { record.backend?.rawValue ?? "Unknown" }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(tint.opacity(0.6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    statusView
                    Text("·").foregroundColor(theme.secondaryText)
                    Text(backendName).foregroundColor(theme.secondaryText)
                    Text("·").foregroundColor(theme.secondaryText)
                    Text(relativeDate).foregroundColor(theme.secondaryText)
                }
                .font(.caption)
            }

            Spacer()

            Menu {
                Button {
                    showingRedownloadAlert = true
                } label: {
                    Label("Re-download…", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    _ = DownloadHistoryStore.shared.delete(id: record.id)
                } label: {
                    Label("Remove from History", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(.body, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundColor(theme.secondaryText)
                    .background(Circle().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("Actions for \(record.displayName)")
        }
        .padding(16)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
        .alert(
            "Re-download \(record.displayName)?",
            isPresented: $showingRedownloadAlert
        ) {
            Button("Download") { triggerRedownload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-pull \(record.displayName) from \(backendName)? Existing files will be overwritten.")
        }
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: record.updatedAt, relativeTo: Date())
    }

    @ViewBuilder
    private var statusView: some View {
        switch record.status {
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .foregroundColor(theme.successColor)
        case .failed:
            Label(record.errorMessage ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(theme.errorColor)
                .lineLimit(1)
        case .cancelled:
            Label("Cancelled", systemImage: "minus.circle.fill")
                .foregroundColor(theme.warningColor)
        case .interrupted:
            Label("Interrupted", systemImage: "bolt.horizontal.circle.fill")
                .foregroundColor(theme.warningColor)
        default:
            Label(record.status?.rawValue.capitalized ?? "Unknown", systemImage: "questionmark.circle")
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func triggerRedownload() {
        guard let backend = record.backend else { return }
        Task { @MainActor in
            let outcome: DownloadStartOutcome
            switch backend {
            case .ollama:
                outcome = await DownloadCoordinator.startOllamaDownloadIfNeeded(
                    modelName: record.modelIdentifier,
                    profileID: record.profileID
                )
            case .mlx:
                outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(
                    repoId: record.modelIdentifier,
                    profileID: record.profileID
                )
            case .whisper:
                outcome = await DownloadCoordinator.startWhisperDownloadIfNeeded(
                    modelId: record.modelIdentifier,
                    profileID: record.profileID
                )
            }
            switch outcome {
            case .alreadyInstalled:
                toastManager.show("\(record.displayName) is already installed", style: .success)
            case .alreadyInProgress:
                toastManager.show("Already downloading", style: .warning)
            case .resumedFromHistory:
                toastManager.show("Re-downloading \(record.displayName)…", style: .success)
            case .startedFresh:
                toastManager.show("Downloading \(record.displayName)…", style: .success)
            case .failed(let reason):
                toastManager.show(reason, style: .error)
            }
        }
    }
}
