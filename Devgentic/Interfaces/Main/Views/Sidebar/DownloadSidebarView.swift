//
//  DownloadSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Rewritten 2026-04-21 — fetches from `DownloadHistoryStore` so completed
//  downloads now survive app relaunches. History is grouped by date;
//  in-progress downloads sit above the groupings with a cancel affordance
//  and live progress bar. Right-click on any row for Re-download / Remove.
//

import SwiftUI
import SwiftData

struct DownloadSidebarView: View {

    @Query(sort: \DownloadRecord.updatedAt, order: .reverse)
    private var allRecords: [DownloadRecord]

    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var recordPendingDeletion: DownloadRecord? = nil
    @State private var recordPendingRedownload: DownloadRecord? = nil
    @State private var showingClearHistoryAlert: Bool = false

    // MARK: - Partitions

    private var activeRecords: [DownloadRecord] {
        allRecords.filter { $0.isActive }
    }

    private var historyRecords: [DownloadRecord] {
        allRecords.filter { !$0.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if allRecords.isEmpty {
                SidebarEmptyStateView(
                    title: "No Downloads",
                    subtitle: "Model downloads from Ollama, MLX, and Whisper will appear here.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !activeRecords.isEmpty {
                            sectionHeader("In Progress", count: activeRecords.count)
                            ForEach(activeRecords) { record in
                                ActiveDownloadRowView(record: record)
                                    .contextMenu { activeContextMenu(for: record) }
                            }
                        }

                        ForEach(groupedHistory, id: \.title) { group in
                            sectionHeader(LocalizedStringKey(group.title), count: group.records.count)
                            ForEach(group.records) { record in
                                HistoryDownloadRowView(record: record)
                                    .contextMenu { historyContextMenu(for: record) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
            }
        }
        .alert(
            "Remove from history?",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            presenting: recordPendingDeletion
        ) { record in
            Button("Remove", role: .destructive) {
                _ = DownloadHistoryStore.shared.delete(id: record.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("“\(record.displayName)” will be removed from your download history. The model file (if any) is not affected.")
        }
        .alert(
            "Re-download \(recordPendingRedownload?.displayName ?? "model")?",
            isPresented: Binding(
                get: { recordPendingRedownload != nil },
                set: { if !$0 { recordPendingRedownload = nil } }
            ),
            presenting: recordPendingRedownload
        ) { record in
            Button("Download") {
                triggerRedownload(record)
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Re-pull \(record.displayName) from \(record.backend?.rawValue ?? "the backend")? Existing files will be overwritten.")
        }
        .alert(
            "Clear download history?",
            isPresented: $showingClearHistoryAlert
        ) {
            Button("Clear", role: .destructive) {
                let cleared = (try? DownloadHistoryStore.shared.deleteAllHistory(keepingActive: true).get()) ?? 0
                toastManager.show("Removed \(cleared) record\(cleared == 1 ? "" : "s")", style: .success)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every completed, failed, and cancelled record from your download history. Active downloads are kept.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Downloads")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            if !historyRecords.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        showingClearHistoryAlert = true
                    } label: {
                        Label("Clear History…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(.caption, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundColor(theme.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.surfaceOverlay)
                        )
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("More actions")
                .accessibilityLabel("Download history actions")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("(\(count))")
                .font(.system(.caption2))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Date grouping

    private struct HistoryGroup {
        let title: String
        let records: [DownloadRecord]
    }

    /// Groups terminal records into Today / Yesterday / This Week / This Month /
    /// Earlier buckets, matching the Conversation sidebar's pattern. Sort
    /// within each group by `updatedAt` descending (already satisfied by the
    /// outer @Query sort).
    private var groupedHistory: [HistoryGroup] {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)

        var today: [DownloadRecord] = []
        var yesterday: [DownloadRecord] = []
        var thisWeek: [DownloadRecord] = []
        var thisMonth: [DownloadRecord] = []
        var earlier: [DownloadRecord] = []

        for record in historyRecords {
            let date = record.updatedAt
            if calendar.isDateInToday(date) {
                today.append(record)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(record)
            } else if let weekAgo, date >= weekAgo {
                thisWeek.append(record)
            } else if let monthAgo, date >= monthAgo {
                thisMonth.append(record)
            } else {
                earlier.append(record)
            }
        }

        var groups: [HistoryGroup] = []
        if !today.isEmpty     { groups.append(HistoryGroup(title: "Today", records: today)) }
        if !yesterday.isEmpty { groups.append(HistoryGroup(title: "Yesterday", records: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(HistoryGroup(title: "This Week", records: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(HistoryGroup(title: "This Month", records: thisMonth)) }
        if !earlier.isEmpty   { groups.append(HistoryGroup(title: "Earlier", records: earlier)) }
        return groups
    }

    // MARK: - Context menus

    @ViewBuilder
    private func activeContextMenu(for record: DownloadRecord) -> some View {
        Button(role: .destructive) {
            DownloadManager.shared.cancelDownload(record)
        } label: {
            Label("Cancel Download", systemImage: "xmark.circle")
        }
    }

    @ViewBuilder
    private func historyContextMenu(for record: DownloadRecord) -> some View {
        Button {
            recordPendingRedownload = record
        } label: {
            Label("Re-download…", systemImage: "arrow.clockwise")
        }

        Divider()

        Button(role: .destructive) {
            recordPendingDeletion = record
        } label: {
            Label("Remove from History", systemImage: "trash")
        }
    }

    // MARK: - Re-download

    private func triggerRedownload(_ record: DownloadRecord) {
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
            announce(outcome: outcome, displayName: record.displayName)
        }
    }

    private func announce(outcome: DownloadStartOutcome, displayName: String) {
        switch outcome {
        case .alreadyInstalled:
            toastManager.show("\(displayName) is already installed", style: .success)
        case .alreadyInProgress:
            toastManager.show("Download already in progress", style: .warning)
        case .resumedFromHistory:
            toastManager.show("Re-downloading \(displayName)…", style: .success)
        case .startedFresh:
            toastManager.show("Downloading \(displayName)…", style: .success)
        case .failed(let reason):
            toastManager.show(reason, style: .error)
        }
    }
}

// MARK: - Active row

private struct ActiveDownloadRowView: View {
    let record: DownloadRecord

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var tint: Color { record.backend?.tintColor ?? .blue }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }

    /// Live speed/ETA snapshot for this record. Reading the observable
    /// `activeSpeeds` dict means this view re-renders whenever the sampler
    /// publishes a new snapshot — no custom subscriber needed.
    private var speedSnapshot: DownloadSpeedSnapshot? {
        DownloadManager.shared.activeSpeeds[record.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(.caption))
                    .foregroundColor(tint)
                    .frame(width: 20)

                Text(record.displayName)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(record.progress * 100))%")
                    .font(.system(.caption2, weight: .bold).monospacedDigit())
                    .foregroundColor(tint)

                if isHovering {
                    Button {
                        DownloadManager.shared.cancelDownload(record)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel \(record.displayName) download")
                    .transition(.opacity)
                }
            }

            ProgressView(value: record.progress)
                .progressViewStyle(.linear)
                .tint(tint)
                .controlSize(.small)

            Text(DownloadSpeedFormatter.compactLine(snapshot: speedSnapshot))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.displayName), \(Int(record.progress * 100))% downloaded, \(DownloadSpeedFormatter.compactLine(snapshot: speedSnapshot))")
    }
}

// MARK: - History row

private struct HistoryDownloadRowView: View {
    let record: DownloadRecord

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var tint: Color { record.backend?.tintColor ?? .blue }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(.caption))
                .foregroundColor(tint.opacity(0.7))
                .frame(width: 20)

            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(record.displayName)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.displayName), \(record.status?.rawValue ?? "unknown")")
    }

    private var subtitle: String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        let when = relative.localizedString(for: record.updatedAt, relativeTo: Date())
        let backendName = record.backend?.rawValue ?? "Unknown"
        let statusLabel: String
        switch record.status {
        case .completed:   statusLabel = "Completed"
        case .failed:      statusLabel = "Failed"
        case .cancelled:   statusLabel = "Cancelled"
        case .interrupted: statusLabel = "Interrupted"
        default:           statusLabel = record.status?.rawValue.capitalized ?? ""
        }
        return "\(backendName) · \(statusLabel) \(when)"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(.caption))
                .foregroundColor(theme.successColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.caption))
                .foregroundColor(theme.errorColor)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(.caption))
                .foregroundColor(theme.warningColor)
        case .interrupted:
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(.caption))
                .foregroundColor(theme.warningColor)
        default:
            Image(systemName: "questionmark.circle")
                .font(.system(.caption))
                .foregroundColor(theme.tertiaryText)
        }
    }
}
