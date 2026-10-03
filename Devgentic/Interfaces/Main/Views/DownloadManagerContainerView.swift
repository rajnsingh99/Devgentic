// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
import AppKit

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
    var isEmbeddedInSettings: Bool = false

    @Query(boundedDownloadRecords)
    private var allRecords: [DownloadRecord]

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var showingClearAlert: Bool = false

    private var activeRecords: [DownloadRecord] { allRecords.filter { $0.isActive } }
    private var historyRecords: [DownloadRecord] { allRecords.filter { !$0.isActive } }

    /// Partial MLX downloads that no history row accounts for. Rows that DO point at their bytes
    /// (paused, interrupted, failed) show their own size and actions instead.
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

    private var isEmpty: Bool { allRecords.isEmpty && leftovers.isEmpty }

    var body: some View {
        Group {
            if isEmbeddedInSettings {
                settingsBody
            } else {
                standaloneBody
            }
        }
        .alert("Clear download history?", isPresented: $showingClearAlert) {
            Button("Clear", role: .destructive) {
                let cleared = (try? DownloadHistoryStore.shared.deleteAllHistory(keepingActive: true).get()) ?? 0
                toastManager.show("Removed \(cleared) record\(cleared == 1 ? "" : "s")", style: .success)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all completed, failed, and cancelled records. Active downloads are kept.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearDownloadHistory)) { _ in
            showingClearAlert = true
        }
        .onAppear {
            MLXModelService.shared.acknowledgeLeftovers()
            MLXModelService.shared.refreshPartialDownloads()
        }
    }

    @ViewBuilder
    private var settingsBody: some View {
        if isEmpty {
            emptyState
                .frame(minHeight: 320)
        } else {
            VStack(spacing: 20) {
                if !activeRecords.isEmpty {
                    sectionView(title: "Active Downloads (\(activeRecords.count))") {
                        ForEach(activeRecords) { record in
                            ActiveDownloadCardView(record: record)
                        }
                    }
                }

                if !leftovers.isEmpty {
                    LeftoverDownloadsSection(leftovers: leftovers)
                }

                if !historyRecords.isEmpty {
                    sectionView(
                        title: "History (\(historyRecords.count))",
                        trailing: {
                            TactileButton(
                                title: "Clear History",
                                icon: "trash",
                                variant: .subtle,
                                size: .compact
                            ) {
                                showingClearAlert = true
                            }
                        }
                    ) {
                        ForEach(historyRecords) { record in
                            HistoryDownloadCardView(record: record)
                        }
                    }
                }
            }
        }
    }

    private var standaloneBody: some View {
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

            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    downloadCards
                        .padding(24)
                        .frame(maxWidth: ViewLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var downloadCards: some View {
        VStack(spacing: 20) {
            if !activeRecords.isEmpty {
                sectionView(title: "Active Downloads (\(activeRecords.count))") {
                    ForEach(activeRecords) { record in
                        ActiveDownloadCardView(record: record)
                    }
                }
            }

            if !leftovers.isEmpty {
                LeftoverDownloadsSection(leftovers: leftovers)
            }

            if !historyRecords.isEmpty {
                sectionView(title: "History (\(historyRecords.count))") {
                    ForEach(historyRecords) { record in
                        HistoryDownloadCardView(record: record)
                    }
                }
            }
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

    private func sectionView<Content: View, Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(theme.fontSubheadline.weight(.bold))
                    .foregroundColor(theme.primaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                trailing()
            }

            content()
        }
    }

    private func sectionView<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionView(title: title, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Download Action Buttons

private struct DownloadActionPillButton: View {
    let title: LocalizedStringKey
    let icon: String
    var tint: Color? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeTint: Color {
        if isDestructive {
            return theme.errorColor
        }
        return tint ?? theme.accentColor
    }

    private var foregroundColor: Color {
        if isDestructive {
            return isHovered ? .white : theme.errorColor
        }
        return isHovered ? activeTint : activeTint.opacity(0.9)
    }

    private var backgroundColor: Color {
        if isDestructive {
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.10)
        }
        return isHovered ? activeTint.opacity(0.18) : activeTint.opacity(0.08)
    }

    private var borderColor: Color {
        if isDestructive {
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.25)
        }
        return isHovered ? activeTint.opacity(0.40) : activeTint.opacity(0.18)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

private struct DownloadActionIconButton: View {
    let icon: String
    var tooltip: String? = nil
    var accessibilityLabel: String? = nil
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isHovered ? (tint ?? theme.primaryText) : (tint ?? theme.secondaryText))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isHovered ? theme.secondaryText.opacity(0.35) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                )
                .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(tooltip ?? "")
        .accessibilityLabel(accessibilityLabel ?? tooltip ?? "")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct DownloadMoreActionsMenuLabel: View {
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 26)
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovered ? theme.secondaryText.opacity(0.35) : theme.dividerColor.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .pointingHandCursor()
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Active card

private struct ActiveDownloadCardView: View {

    let record: DownloadRecord
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false

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
                        DownloadActionPillButton(
                            title: "Pause",
                            icon: "pause.circle",
                            tint: theme.secondaryText
                        ) {
                            MLXModelService.shared.pauseDownload()
                        }
                        .help("Stops the download but keeps everything already fetched, so it can continue later.")
                    }

                    DownloadActionPillButton(
                        title: "Cancel",
                        icon: "xmark.circle",
                        isDestructive: true
                    ) {
                        DownloadManager.shared.cancelDownload(record)
                    }
                    .help("Stops the download and discards the partial files.")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? theme.controlBackground : theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor, lineWidth: 1)
        )
        .shadow(
            color: isHovered ? theme.shadowColor.opacity(0.12) : Color.clear,
            radius: 8,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - History card

private struct HistoryDownloadCardView: View {

    let record: DownloadRecord
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var showingRedownloadAlert: Bool = false
    /// Bytes still on disk for a row the user asked to remove — non-nil only while the
    /// "this would strand them" confirmation is up.
    @State private var strandedBytesOnRemoval: Int64?
    @State private var confirmingDiscard: Bool = false

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

    /// What this row's partial download occupies, from the last scan. Nil for any other row,
    /// and when nothing is left on disk.
    private var partialBytes: Int64? {
        guard isResumableMLX else { return nil }
        return MLXModelService.shared.partialBytes(for: record.modelIdentifier)
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(tint.opacity(0.85))
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
                    if let partialBytes {
                        Text("·").foregroundColor(theme.secondaryText)
                        Text("\(ByteCountFormatter.string(fromByteCount: partialBytes, countStyle: .file)) on disk")
                            .foregroundColor(theme.warningColor)
                    }
                }
                .font(.caption)

                if record.status == .failed, let error = record.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(theme.errorColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Resume continues from bytes already on disk; Re-download (in the menu) starts over.
            // Both exist because a resume can continue a partial but cannot repair a corrupt one.
            // ⚠️ On the row, not in the menu: tucked away, a paused or failed download's bytes
            // were easy to forget — gigabytes the user never knew were still there.
            if isResumableMLX {
                HStack(spacing: 8) {
                    DownloadActionPillButton(
                        title: "Resume",
                        icon: "play.circle",
                        tint: theme.accentColor
                    ) {
                        resume()
                    }
                    .help("Continues from the files already downloaded.")

                    DownloadActionPillButton(
                        title: "Discard",
                        icon: "trash.slash",
                        isDestructive: true
                    ) {
                        confirmingDiscard = true
                    }
                    .help("Deletes the partial files and removes this row.")
                }
            }

            Menu {
                Button {
                    showingRedownloadAlert = true
                } label: {
                    Label("Re-download", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    requestRemoval()
                } label: {
                    Label("Remove from History", systemImage: "trash")
                }
            } label: {
                DownloadMoreActionsMenuLabel()
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("Actions for \(record.displayName)")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? theme.controlBackground : theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor, lineWidth: 1)
        )
        .shadow(
            color: isHovered ? theme.shadowColor.opacity(0.12) : Color.clear,
            radius: 8,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
        .alert("Discard the partial download?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { discardPartialFiles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let partialBytes {
                Text("Deletes the \(ByteCountFormatter.string(fromByteCount: partialBytes, countStyle: .file)) already downloaded for \(record.displayName). A later download starts from zero.")
            } else {
                Text("Deletes whatever was already downloaded for \(record.displayName). A later download starts from zero.")
            }
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
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(theme.errorColor)
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
                toastManager.show("Re-downloading \(record.displayName)", style: .success)
            case .startedFresh:
                toastManager.show("Downloading \(record.displayName)", style: .success)
            case .failed(let reason):
                toastManager.show(reason, style: .error)
            }
        }
    }
}

// MARK: - Unfinished downloads with no history row

/// Partial MLX downloads that no history row points at: what older builds leaked, what a crash
/// left before its row was saved, and what "Keep Files & Remove" deliberately leaves behind.
/// Before this section they were reachable from Finder alone, and the launch scan only logged
/// them.
private struct LeftoverDownloadsSection: View {

    let leftovers: [MLXModelService.OrphanedPartialDownload]
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme
    /// Non-empty only while the delete confirmation is up.
    @State private var pendingDiscard: [MLXModelService.OrphanedPartialDownload] = []

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func total(_ items: [MLXModelService.OrphanedPartialDownload]) -> Int64 {
        items.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Unfinished Downloads (\(leftovers.count))")
                    .font(theme.fontSubheadline.weight(.bold))
                    .foregroundColor(theme.primaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(verbatim: Self.size(Self.total(leftovers)))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.warningColor)

                Spacer()

                if leftovers.count > 1 {
                    TactileButton(
                        title: "Delete All",
                        icon: "trash",
                        variant: .subtle,
                        size: .compact
                    ) {
                        pendingDiscard = leftovers
                    }
                }
            }

            Text("These partial MLX downloads have no entry in your history. Resume one, or delete it to free the space.")
                .font(.caption)
                .foregroundColor(theme.secondaryText)

            ForEach(leftovers) { leftover in
                LeftoverDownloadCardView(
                    leftover: leftover,
                    onResume: { resume(leftover) },
                    onDiscard: { pendingDiscard = [leftover] }
                )
            }
        }
        .alert(
            pendingDiscard.count == 1
                ? Text("Delete \(Text(verbatim: pendingDiscard[0].repoId))?")
                : Text("Delete \(pendingDiscard.count) unfinished downloads?"),
            isPresented: Binding(
                get: { !pendingDiscard.isEmpty },
                set: { if !$0 { pendingDiscard = [] } }
            )
        ) {
            Button("Delete", role: .destructive) {
                let targets = pendingDiscard
                pendingDiscard = []
                discard(targets)
            }
            Button("Cancel", role: .cancel) { pendingDiscard = [] }
        } message: {
            Text("Frees \(Self.size(Self.total(pendingDiscard))). This can't be undone; a later download starts from zero.")
        }
    }

    private func resume(_ leftover: MLXModelService.OrphanedPartialDownload) {
        Task { @MainActor in
            switch await DownloadCoordinator.resumeMLXDownload(repoId: leftover.repoId) {
            case .failed(let reason):
                toastManager.show(reason, style: .error)
            case .alreadyInstalled:
                toastManager.show("\(leftover.repoId) is already installed", style: .success)
            default:
                toastManager.show("Resuming \(leftover.repoId)", style: .success)
            }
        }
    }

    private func discard(_ targets: [MLXModelService.OrphanedPartialDownload]) {
        let freed = MLXModelService.shared.discardLeftovers(targets)
        let expected = Self.total(targets)
        if freed < expected {
            logger.error("[DOWNLOAD] Leftover delete freed \(Self.size(freed)) of \(Self.size(expected)) (see the [MLXSTORE] refusals above). CONSEQUENCE: the rest stays on disk and stays listed.")
            toastManager.show("Couldn't delete everything — \(Self.size(expected - freed)) is still on disk", style: .error)
        } else {
            toastManager.show("Freed \(Self.size(freed))", style: .success)
        }
    }
}

// MARK: - Leftover download card

private struct LeftoverDownloadCardView: View {
    let leftover: MLXModelService.OrphanedPartialDownload
    let onResume: () -> Void
    let onDiscard: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ModelBackendType.mlx.tintColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.title3)
                    .foregroundColor(ModelBackendType.mlx.tintColor.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: 4) {
                // A repo id is an identifier, not prose.
                Text(verbatim: leftover.repoId)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("\(Self.size(leftover.bytes)) on disk · not in your download history")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                DownloadActionPillButton(
                    title: "Resume",
                    icon: "play.circle",
                    tint: theme.accentColor
                ) {
                    onResume()
                }
                .help("Continues from the files already downloaded.")

                DownloadActionIconButton(
                    icon: "folder",
                    tooltip: "Show in Finder",
                    accessibilityLabel: "Show \(leftover.repoId) in Finder"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([leftover.path])
                }

                DownloadActionPillButton(
                    title: "Delete",
                    icon: "trash",
                    isDestructive: true
                ) {
                    onDiscard()
                }
                .help("Deletes these partial files.")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? theme.controlBackground : theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor, lineWidth: 1)
        )
        .shadow(
            color: isHovered ? theme.shadowColor.opacity(0.12) : Color.clear,
            radius: 8,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

