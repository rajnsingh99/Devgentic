// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import SwiftData

private let logger = DGLogger(category: "DownloadSidebarView")

// Why: an unbounded `@Query` loads every row ever written and re-filters the whole array on every body pass
/// Bounded history query shared by the sidebar and the Downloads screen, capped at 200 rows to match
/// `fetchHistory`.
private let boundedDownloadRecords: FetchDescriptor<DownloadRecord> = {
    var descriptor = FetchDescriptor<DownloadRecord>(
        sortBy: [SortDescriptor(\DownloadRecord.updatedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 200
    return descriptor
}()

/// The downloads sidebar: history from `DownloadHistoryStore` grouped by date, with in-progress downloads
/// above showing a cancel affordance and live progress bar; right-click a row for Re-download / Remove.
struct DownloadSidebarView: View {

    @Query(boundedDownloadRecords)
    private var allRecords: [DownloadRecord]

    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var recordPendingDeletion: DownloadRecord? = nil
    /// Reclaimable bytes behind `recordPendingDeletion`, measured when the alert is raised —
    /// never during render, since it walks the partial-download folder.
    @State private var pendingDeletionBytes: Int64 = 0
    @State private var recordPendingRedownload: DownloadRecord? = nil
    /// The row whose partial files the user asked to discard from its hover button.
    @State private var recordPendingDiscard: DownloadRecord? = nil
    @State private var showingClearHistoryAlert: Bool = false

    @State private var focusedRecordID: UUID? = nil
    @FocusState private var isListFocused: Bool

    // MARK: - Partitions

    private var activeRecords: [DownloadRecord] {
        allRecords.filter { $0.isActive }
    }

    private var historyRecords: [DownloadRecord] {
        allRecords.filter { !$0.isActive }
    }

    /// Partial MLX downloads no history row points at. Listed in full on the Download Manager;
    /// the sidebar only links there.
    private var leftovers: [MLXModelService.OrphanedPartialDownload] {
        let mlx = MLXModelService.shared
        let tracked = Set(allRecords
            .filter { $0.backend == .mlx && $0.status?.isResumable == true }
            .map(\.modelIdentifier))
        return MLXModelService.untracked(
            mlx.partialDownloads,
            trackedRepoIds: tracked,
            downloading: mlx.isDownloading ? mlx.currentDownloadName : nil
        )
    }

    /// Size on disk of a resumable MLX row's partial download, from the last scan.
    private func partialBytes(for record: DownloadRecord) -> Int64? {
        guard record.backend == .mlx, record.status?.isResumable == true else { return nil }
        return MLXModelService.shared.partialBytes(for: record.modelIdentifier)
    }

    private var orderedRecords: [DownloadRecord] {
        var result: [DownloadRecord] = []
        result.append(contentsOf: activeRecords)
        for group in groupedHistory {
            result.append(contentsOf: group.records)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !leftovers.isEmpty {
                leftoversBanner
            }

            if allRecords.isEmpty {
                SidebarEmptyStateView(
                    title: "No Downloads",
                    subtitle: "Model downloads from Ollama, MLX, and Whisper will appear here.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                downloadsScrollView
            }
        }
        // Removing a completed or cancelled row is a neutral tidy-up; for a paused or interrupted one the partial
        // folder is hidden from the installed list, so this row is the only handle on those bytes.
        .alert(
            "Remove from history?",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil; pendingDeletionBytes = 0 } }
            ),
            presenting: recordPendingDeletion
        ) { record in
            if pendingDeletionBytes > 0 {
                Button("Delete Files & Remove", role: .destructive) {
                    discardPartialFiles(for: record)
                }
                Button("Keep Files & Remove") {
                    logger.notice("[DOWNLOAD] Removing history row for '\(record.modelIdentifier)' while its partial files remain on disk, at the user's explicit choice. CONSEQUENCE: those bytes are no longer reachable from the app — only via Finder, or by re-downloading the model.")
                    _ = DownloadHistoryStore.shared.delete(id: record.id)
                }
            } else {
                Button("Remove", role: .destructive) {
                    _ = DownloadHistoryStore.shared.delete(id: record.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            if pendingDeletionBytes > 0 {
                Text("“\(record.displayName)” has \(ByteCountFormatter.string(fromByteCount: pendingDeletionBytes, countStyle: .file)) already downloaded. Removing this row is the last way to reach those files from Devgentic.")
            } else {
                Text("“\(record.displayName)” will be removed from your download history. The model file (if any) is not affected.")
            }
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
            // The fallback "the backend" is prose; interpolating a `String` into a `Text` would keep it out of the
            // String Catalog. The product name stays `verbatim`.
            Text("Re-pull \(record.displayName) from \(record.backend.map { Text(verbatim: $0.rawValue) } ?? Text("the backend"))? Existing files will be overwritten.")
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
        .alert(
            "Discard the partial download?",
            isPresented: Binding(
                get: { recordPendingDiscard != nil },
                set: { if !$0 { recordPendingDiscard = nil } }
            ),
            presenting: recordPendingDiscard
        ) { record in
            Button("Discard", role: .destructive) { discardPartialFiles(for: record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            if let bytes = partialBytes(for: record) {
                Text("Deletes the \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) already downloaded for “\(record.displayName)”. A later download starts from zero.")
            } else {
                Text("Deletes whatever was already downloaded for “\(record.displayName)”. A later download starts from zero.")
            }
        }
        .onAppear {
            if focusedRecordID == nil {
                focusedRecordID = orderedRecords.first?.id
            }
            MLXModelService.shared.acknowledgeLeftovers()
            MLXModelService.shared.refreshPartialDownloads()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearDownloadHistory)) { _ in
            showingClearHistoryAlert = true
        }
        .onChange(of: orderedRecords.map(\.id)) { _, newIDs in
            if let id = focusedRecordID, !newIDs.contains(id) {
                focusedRecordID = newIDs.first
            }
        }
    }

    @ViewBuilder
    private var activeDownloadsSection: some View {
        if !activeRecords.isEmpty {
            sectionHeader("In Progress", count: activeRecords.count)
            ForEach(activeRecords) { record in
                ActiveDownloadRowView(
                    record: record,
                    isSelected: focusedRecordID == record.id
                )
                .id(record.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedRecordID = record.id
                }
                .contextMenu { activeContextMenu(for: record) }
            }
        }
    }

    @ViewBuilder
    private var historyDownloadsSection: some View {
        ForEach(groupedHistory, id: \.id) { group in
            sectionHeader(group.bucket.localizedTitle, count: group.records.count)
            ForEach(group.records) { record in
                HistoryDownloadRowView(
                    record: record,
                    isSelected: focusedRecordID == record.id,
                    partialBytes: partialBytes(for: record),
                    onResume: { resume(record) },
                    onDiscard: { recordPendingDiscard = record }
                )
                .id(record.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedRecordID = record.id
                }
                .contextMenu { historyContextMenu(for: record) }
            }
        }
    }

    @ViewBuilder
    private var downloadsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    activeDownloadsSection
                    historyDownloadsSection
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveFocus(direction)
                if let id = focusedRecordID {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.return) {
                handleReturnKey()
            }
            .onKeyPress(.delete) {
                handleDeleteKey()
            }
            .onKeyPress("r") {
                handleRedownloadKey()
            }
            .onKeyPress("c") {
                handleCancelKey()
            }
        }
    }

    private func handleReturnKey() -> KeyPress.Result {
        if let id = focusedRecordID,
           let record = orderedRecords.first(where: { $0.id == id }) {
            if record.isActive {
                router.navigateToDownloadManager()
            } else {
                recordPendingRedownload = record
            }
            return .handled
        }
        return .ignored
    }

    private func handleDeleteKey() -> KeyPress.Result {
        if let id = focusedRecordID,
           let record = orderedRecords.first(where: { $0.id == id }) {
            if !record.isActive {
                pendingDeletionBytes = reclaimableBytes(for: record)
                recordPendingDeletion = record
                return .handled
            }
        }
        return .ignored
    }

    private func handleRedownloadKey() -> KeyPress.Result {
        if let id = focusedRecordID,
           let record = orderedRecords.first(where: { $0.id == id }),
           !record.isActive {
            recordPendingRedownload = record
            return .handled
        }
        return .ignored
    }

    private func handleCancelKey() -> KeyPress.Result {
        if let id = focusedRecordID,
           let record = orderedRecords.first(where: { $0.id == id }),
           record.isActive {
            DownloadManager.shared.cancelDownload(record)
            return .handled
        }
        return .ignored
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let records = orderedRecords
        guard !records.isEmpty else { return }
        guard let currentID = focusedRecordID,
              let currentIndex = records.firstIndex(where: { $0.id == currentID }) else {
            focusedRecordID = records.first?.id
            return
        }

        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, records.count - 1)
            focusedRecordID = records[nextIndex].id
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            focusedRecordID = records[prevIndex].id
        default:
            break
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Downloads")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            // Opens the Download Manager screen via `MainViewRouter.navigateToDownloadManager()`.
            TactileIconButton(
                icon: "arrow.down.circle",
                tooltip: "Open the Download Manager",
                accessibilityLabel: "Open the Download Manager",
                variant: .secondary,
                size: 22
            ) {
                router.navigateToDownloadManager()
            }

            if !historyRecords.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        showingClearHistoryAlert = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
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
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .menuIndicator(.hidden)
                .help("More actions")
                .accessibilityLabel("Download history actions")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Leftovers banner

    private var leftoversBanner: some View {
        let total = leftovers.reduce(Int64(0)) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return Button {
            router.navigateToDownloadManager()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundColor(theme.warningColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(leftovers.count == 1
                         ? "1 unfinished download · \(size)"
                         : "\(leftovers.count) unfinished downloads · \(size)")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text("Not in your history. Review to resume or delete.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.warningColor.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .help("Open the Download Manager")
    }

    // MARK: - Section header

    private func sectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(theme.fontCaption2.weight(.semibold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("(\(count))")
                .font(theme.fontCaption2)
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Date grouping

    // Why: a static case key is extractable into the String Catalog; a runtime
    // `LocalizedStringKey(group.title)` is not and ships in English
    /// Date bucket for the history list.
    private enum HistoryBucket: String, CaseIterable {
        case today, yesterday, thisWeek, thisMonth, earlier

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .today:     return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek:  return "This Week"
            case .thisMonth: return "This Month"
            case .earlier:   return "Earlier"
            }
        }
    }

    private struct HistoryGroup {
        let bucket: HistoryBucket
        let records: [DownloadRecord]
        /// Stable identity for `ForEach` — not user-facing.
        var id: String { bucket.rawValue }
    }

    /// Groups terminal records into Today / Yesterday / This Week / This Month / Earlier buckets, matching the
    /// Conversation sidebar's pattern; sorted within each group by `updatedAt` descending.
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
        if !today.isEmpty     { groups.append(HistoryGroup(bucket: .today, records: today)) }
        if !yesterday.isEmpty { groups.append(HistoryGroup(bucket: .yesterday, records: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(HistoryGroup(bucket: .thisWeek, records: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(HistoryGroup(bucket: .thisMonth, records: thisMonth)) }
        if !earlier.isEmpty   { groups.append(HistoryGroup(bucket: .earlier, records: earlier)) }
        return groups
    }

    // MARK: - Context menus

    @ViewBuilder
    private func activeContextMenu(for record: DownloadRecord) -> some View {
        // Pause is offered only for MLX: its transport (HubApi) resumes from `.incomplete` files, so offering it for
        // a backend that restarts from zero would misstate what the button does.
        if record.backend == .mlx {
            Button {
                MLXModelService.shared.pauseDownload()
            } label: {
                Label("Pause Download", systemImage: "pause.circle")
            }
        }

        Button(role: .destructive) {
            DownloadManager.shared.cancelDownload(record)
        } label: {
            Label("Cancel Download", systemImage: "xmark.circle")
        }
    }

    @ViewBuilder
    private func historyContextMenu(for record: DownloadRecord) -> some View {
        // Resume continues from bytes already on disk; Re-download starts over. Both are
        // offered because a resume can't repair a corrupt partial, only continue it.
        if record.backend == .mlx, record.status?.isResumable == true {
            Button {
                resume(record)
            } label: {
                Label("Resume Download", systemImage: "play.circle")
            }

            Button(role: .destructive) {
                discardPartialFiles(for: record)
            } label: {
                Label("Discard Partial Files", systemImage: "trash.slash")
            }

            Divider()
        }

        Button {
            recordPendingRedownload = record
        } label: {
            Label("Re-download", systemImage: "arrow.clockwise")
        }

        Divider()

        Button(role: .destructive) {
            pendingDeletionBytes = reclaimableBytes(for: record)
            recordPendingDeletion = record
        } label: {
            Label("Remove from History", systemImage: "trash")
        }
    }

    /// Bytes a resume would re-use, or 0 when there is nothing at stake in removing the row.
    /// Only MLX retains partials, and only a resumable status kept them.
    private func reclaimableBytes(for record: DownloadRecord) -> Int64 {
        guard record.backend == .mlx, record.status?.isResumable == true else { return 0 }
        let folder = MLXModelService.shared.partialDownloadFolder(for: record.modelIdentifier)
        return MLXModelService.resumableBytes(at: folder)
    }

    /// Shared by the context menu and the removal alert. The row is dropped only once the bytes are gone: after a
    /// refused reclaim it is the last handle on them.
    private func discardPartialFiles(for record: DownloadRecord) {
        if MLXModelService.shared.discardPartialDownload(repoId: record.modelIdentifier) {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
        } else {
            logger.error("[DOWNLOAD] Discard of '\(record.modelIdentifier)' reclaimed nothing (see the [MLXSTORE] refusal above). CONSEQUENCE: the history row is KEPT so the user still has a handle on those bytes; it would otherwise be the last reference to them.")
            toastManager.show("Couldn't remove the partial files for \(record.displayName)", style: .error)
        }
    }

    private func resume(_ record: DownloadRecord) {
        Task { @MainActor in
            let outcome = await DownloadCoordinator.resumeMLXDownload(repoId: record.modelIdentifier)
            switch outcome {
            case .failed(let reason):
                toastManager.show(reason, style: .error)
            case .alreadyInstalled:
                toastManager.show("\(record.displayName) is already installed", style: .success)
            default:
                toastManager.show("Resuming \(record.displayName)…", style: .success)
            }
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
                // Explicit user re-download: bypass the installed short-circuit so a
                // corrupt or truncated model can actually be repaired.
                outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(
                    repoId: record.modelIdentifier,
                    profileID: record.profileID,
                    force: true
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
    var isSelected: Bool = false

    @Environment(\.appTheme) private var theme
    // B19 shipped Dynamic Type but not Reduce Motion, and this file was the gap: both hover
    // transitions animated unconditionally.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var tint: Color { record.backend?.tintColor ?? theme.accentColor }
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
                    .font(theme.fontCaption2.weight(.bold).monospacedDigit())
                    .foregroundColor(tint)

                if isHovering {
                    Button {
                        DownloadManager.shared.cancelDownload(record)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .pointingHandCursor()
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
                .font(theme.fontCodeCaption)
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.displayName), \(Int(record.progress * 100))% downloaded, \(DownloadSpeedFormatter.compactLine(snapshot: speedSnapshot))")
    }
}

// MARK: - History row

private struct HistoryDownloadRowView: View {
    let record: DownloadRecord
    var isSelected: Bool = false
    /// Size of this row's partial download; non-nil only for a resumable MLX row with bytes.
    var partialBytes: Int64? = nil
    var onResume: (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    // B19 shipped Dynamic Type but not Reduce Motion, and this file was the gap: both hover
    // transitions animated unconditionally.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var tint: Color { record.backend?.tintColor ?? theme.accentColor }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(theme.fontCaption)
                .foregroundColor(tint.opacity(0.7))
                .frame(width: 20)

            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(record.displayName)
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                subtitle
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                if let partialBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: partialBytes, countStyle: .file)) on disk")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.warningColor)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Shown on hover or selection rather than only in the context menu, so a paused or failed download's bytes
            // are not forgotten.
            if partialBytes != nil, isHovering || isSelected, let onResume, let onDiscard {
                HStack(spacing: 4) {
                    SidebarRowActionButton(
                        icon: "play.circle",
                        tint: theme.accentColor,
                        tooltip: "Resume Download",
                        accessibilityLabel: "Resume \(record.displayName)",
                        action: onResume
                    )

                    SidebarRowActionButton(
                        icon: "trash.slash",
                        tint: theme.errorColor,
                        tooltip: "Discard Partial Files",
                        accessibilityLabel: "Discard partial files for \(record.displayName)",
                        action: onDiscard
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        // `Text`, not a String: `accessibilityLabel(_: String)` does not localize, so the persisted `rawValue` would
        // be read to VoiceOver in English.
        .accessibilityLabel(Text(record.displayName) + Text(verbatim: ", ")
                            + Text((record.status ?? .interrupted).localizedTitle))
    }

    // Composed as `Text`, not `String`, because `Text(_: StringProtocol)` does not localize.
    private var subtitle: Text {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        let when = relative.localizedString(for: record.updatedAt, relativeTo: Date())
        // The backend name is `verbatim` ("Ollama" / "MLX" / "Whisper" are product names, not for translators); the
        // fallback is prose and stays translatable.
        let backend = record.backend.map { Text(verbatim: $0.rawValue) } ?? Text("Unknown")
        // Switching over a non-optional means a status added later fails to compile here
        // rather than silently falling into a question-mark arm.
        let status = (record.status ?? .interrupted).localizedTitle
        return backend + Text(verbatim: " · ") + Text(status) + Text(verbatim: " \(when)")
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
        case .paused:
            // Pause is a deliberate user action with the bytes intact — not an anomaly.
            Image(systemName: "pause.circle.fill")
                .font(.system(.caption))
                .foregroundColor(theme.warningColor)
        default:
            Image(systemName: "questionmark.circle")
                .font(.system(.caption))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

// MARK: - Sidebar Row Action Button

private struct SidebarRowActionButton: View {
    let icon: String
    let tint: Color
    let tooltip: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isButtonHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isButtonHovered ? tint : tint.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isButtonHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isButtonHovered ? tint.opacity(0.35) : theme.dividerColor.opacity(0.3), lineWidth: 0.5)
                )
                .scaleEffect(isButtonHovered && !reduceMotion ? 1.08 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isButtonHovered = hovering
            }
        }
    }
}
