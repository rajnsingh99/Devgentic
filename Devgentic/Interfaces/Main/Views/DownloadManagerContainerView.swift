// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

private let logger = DGLogger(category: "DownloadManagerContainer")

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

struct DownloadManagerContainerView: View {

    @Query(boundedDownloadRecords)
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
    /// ⚠️ `Text`, not `String`. "Ollama" / "MLX" / "Whisper" are product names and are
    /// deliberately `verbatim` — translating them would be wrong. The FALLBACK is ordinary
    /// prose, and as a `String` in a `Text` it never reached the String Catalog at all.
    private var backendLabel: Text {
        guard let backend = record.backend else { return Text("Unknown") }
        return Text(verbatim: backend.rawValue)
    }

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
                    backendLabel
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)

                    Text("·").foregroundColor(theme.tertiaryText)

                    Text(DownloadSpeedFormatter.compactLine(snapshot: speedSnapshot))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)

                    Spacer()

                    // ⚠️ Pause is offered for MLX ONLY. It is the one backend whose transport
                    // resumes (HubApi re-reads the `.incomplete` files via a `Range` header);
                    // offering it elsewhere would promise a continuation that cannot happen.
                    // G2 shipped this on the sidebar but not here, so the Downloads screen
                    // could only cancel — discarding bytes the user meant to keep.
                    if record.backend == .mlx {
                        Button {
                            MLXModelService.shared.pauseDownload()
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Stops the download but keeps everything already fetched, so it can continue later.")
                    }

                    Button {
                        DownloadManager.shared.cancelDownload(record)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(theme.errorColor)
                    }
                    .buttonStyle(.plain)
                    .help("Stops the download and discards the partial files.")
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
    /// Bytes still on disk for a row the user asked to remove — non-nil only while the
    /// "this would strand them" confirmation is up.
    @State private var strandedBytesOnRemoval: Int64?

    private var tint: Color { record.backend?.tintColor ?? .blue }
    private var icon: String { record.backend?.icon ?? "arrow.down.circle" }
    /// ⚠️ `Text`, not `String`. "Ollama" / "MLX" / "Whisper" are product names and are
    /// deliberately `verbatim` — translating them would be wrong. The FALLBACK is ordinary
    /// prose, and as a `String` in a `Text` it never reached the String Catalog at all.
    private var backendLabel: Text {
        guard let backend = record.backend else { return Text("Unknown") }
        return Text(verbatim: backend.rawValue)
    }

    private var isResumableMLX: Bool {
        record.backend == .mlx && record.status?.isResumable == true
    }

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
                    backendLabel.foregroundColor(theme.secondaryText)
                    Text("·").foregroundColor(theme.secondaryText)
                    Text(relativeDate).foregroundColor(theme.secondaryText)
                }
                .font(.caption)
            }

            Spacer()

            Menu {
                // Resume continues from bytes already on disk; Re-download starts over. Both
                // are offered because a resume can continue a partial but cannot repair a
                // corrupt one. MLX only — see the Pause button on the active card.
                if isResumableMLX {
                    Button {
                        resume()
                    } label: {
                        Label("Resume Download", systemImage: "play.circle")
                    }
                    Button(role: .destructive) {
                        discardPartialFiles()
                    } label: {
                        Label("Discard Partial Files", systemImage: "trash.slash")
                    }
                    Divider()
                }

                Button {
                    showingRedownloadAlert = true
                } label: {
                    Label("Re-download…", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    requestRemoval()
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
            // The backend name is NESTED as a `Text`, not interpolated as a String — the
            // sentence around it must reach the String Catalog with a `%@` placeholder.
            Text("Re-pull \(record.displayName) from \(backendLabel)? Existing files will be overwritten.")
        }
        // ⚠️ Removing the row of a paused/interrupted download is not a neutral tidy-up: the
        // partial folder is hidden from the installed list, so that row is the ONLY handle on
        // those bytes. Deleting it leaves them reachable from Finder alone. Ask instead of
        // silently stranding them.
        .alert(
            "Keep the partial download?",
            isPresented: Binding(
                get: { strandedBytesOnRemoval != nil },
                set: { if !$0 { strandedBytesOnRemoval = nil } }
            )
        ) {
            Button("Delete Files & Remove", role: .destructive) {
                strandedBytesOnRemoval = nil
                discardPartialFiles()
            }
            Button("Keep Files & Remove") {
                strandedBytesOnRemoval = nil
                logger.notice("[DOWNLOAD] Removing history row for '\(record.modelIdentifier)' while its partial files remain on disk, at the user's explicit choice. CONSEQUENCE: those bytes are no longer reachable from the app — only via Finder, or by re-downloading the model.")
                _ = DownloadHistoryStore.shared.delete(id: record.id)
            }
            Button("Cancel", role: .cancel) { strandedBytesOnRemoval = nil }
        } message: {
            Text("\(record.displayName) has \(ByteCountFormatter.string(fromByteCount: strandedBytesOnRemoval ?? 0, countStyle: .file)) already downloaded. Removing this row is the last way to reach those files from Devgentic.")
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
        case .paused:
            // G2 added `.paused` but this surface never got an arm, so a paused download —
            // the one state whose bytes are deliberately still on disk — rendered as a grey
            // question mark labelled with a non-localizing `rawValue.capitalized`.
            Label("Paused", systemImage: "pause.circle.fill")
                .foregroundColor(theme.warningColor)
        default:
            Label(record.status?.localizedTitle ?? "Unknown", systemImage: "questionmark.circle")
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func resume() {
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

    /// ⚠️ Drop the row only once the bytes are actually gone — the row is the sole remaining
    /// handle on a partial folder, so removing it after a refused reclaim strands them for good.
    private func discardPartialFiles() {
        if MLXModelService.shared.discardPartialDownload(repoId: record.modelIdentifier) {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
        } else {
            logger.error("[DOWNLOAD] Discard of '\(record.modelIdentifier)' reclaimed nothing (see the [MLXSTORE] refusal above). CONSEQUENCE: the history row is KEPT so the user still has a handle on those bytes.")
            toastManager.show("Couldn't remove the partial files for \(record.displayName)", style: .error)
        }
    }

    /// Removing a history row is normally free. It is not when the row points at bytes that
    /// nothing else in the app can reach, so measure first and ask only in that case.
    private func requestRemoval() {
        guard isResumableMLX else {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
            return
        }
        // Off the render path deliberately — this walks the partial folder.
        let folder = MLXModelService.shared.partialDownloadFolder(for: record.modelIdentifier)
        let bytes = MLXModelService.resumableBytes(at: folder)
        if bytes > 0 {
            strandedBytesOnRemoval = bytes
        } else {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
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
