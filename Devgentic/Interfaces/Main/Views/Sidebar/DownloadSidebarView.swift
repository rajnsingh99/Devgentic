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

private let logger = DGLogger(category: "DownloadSidebarView")

/// Bounded history query shared by the sidebar and the Downloads screen.
///
/// ⚠️ Both views previously used an UNBOUNDED `@Query`, loading every row ever written and then
/// re-filtering the whole array in each computed property on every body pass. `fetchHistory`
/// already capped at 200; these bypassed it entirely. The limit matches that cap so the two
/// paths agree.
private let boundedDownloadRecords: FetchDescriptor<DownloadRecord> = {
    var descriptor = FetchDescriptor<DownloadRecord>(
        sortBy: [SortDescriptor(\DownloadRecord.updatedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 200
    return descriptor
}()

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

                        ForEach(groupedHistory, id: \.id) { group in
                            sectionHeader(group.bucket.localizedTitle, count: group.records.count)
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
        // ⚠️ Two different questions behind one menu item. For a completed or cancelled row,
        // removing it really is a neutral tidy-up. For a PAUSED or interrupted one the partial
        // folder is hidden from the installed list, so this row is the only handle the app has
        // on those bytes — and the old copy ("The model file (if any) is not affected") told
        // the user the opposite of what was about to happen.
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
            // ⚠️ The fallback "the backend" is prose and never reached the String Catalog,
            // because interpolating a `String` into a `Text` leaves it untranslatable. The
            // product name itself stays `verbatim` — "Ollama" is "Ollama" everywhere.
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

    /// Date bucket for the history list.
    ///
    /// ⚠️ A `String` title fed `LocalizedStringKey(group.title)` at the call site — a RUNTIME
    /// key, which the compiler cannot extract, so "Today"/"Yesterday"/"This Week"/"This Month"/
    /// "Earlier" were all absent from the String Catalog and would have shipped in English
    /// inside a translated sidebar. A case with a static key is extractable.
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
        // Pause is offered only for MLX: it is the backend whose transport (HubApi) resumes
        // from `.incomplete` files. Offering it for a backend that would restart from zero
        // would be a lie about what the button does.
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
            Label("Re-download…", systemImage: "arrow.clockwise")
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

    /// Shared by the context menu and the removal alert. ⚠️ The row is dropped only once the
    /// bytes are gone — after a refused reclaim it is the last handle on them.
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
        .sidebarRowBackground(isHovering: isHovering)
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
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .sidebarRowBackground(isHovering: isHovering)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        // ⚠️ `Text`, not a String: `accessibilityLabel(_: String)` does not localize, so this
        // read the persisted `rawValue` out to VoiceOver in English inside otherwise-translated
        // chrome — C2's trap, on the one surface where it is least noticeable.
        .accessibilityLabel(Text(record.displayName) + Text(verbatim: ", ")
                            + Text((record.status ?? .interrupted).localizedTitle))
    }

    // ⚠️ Composed as `Text`, not `String`. The old version built a `String` and fed it to
    // `Text(_: StringProtocol)`, which does NOT localize — the exact C2 trap. It also switched
    // over the status with a `default:` arm, so `.paused` (added by G2, in the same session)
    // rendered as a bare capitalized rawValue while `DownloadRecordStatus.localizedTitle` and
    // `ModelBackendType.localizedTitle` sat with zero call sites app-wide.
    private var subtitle: Text {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        let when = relative.localizedString(for: record.updatedAt, relativeTo: Date())
        // ⚠️ The backend name is `verbatim`: "Ollama" / "MLX" / "Whisper" are product names, and
        // putting them in the String Catalog invites a translator to localize a proper noun.
        // The FALLBACK is prose and must be translatable — that was the actual defect, since a
        // `String` interpolated into a `Text` never reaches the catalog at all.
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
