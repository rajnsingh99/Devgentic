// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelDownloadStatusView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Unified per-model download-status component shared by the Ollama and MLX store rows and the Whisper rows.
/// Renders one of three states: Available (Download button), Downloading (progress, cancel, speed) or Installed (menu).
/// Reads `DownloadManager.activeRecordIDsByKey` and `DownloadHistoryStore.fetch(id:)` rather than a `@Query`.
struct ModelDownloadStatusView: View {
    let backend: ModelBackendType
    let modelIdentifier: String
    let displayName: String
    let isInstalled: Bool
    var profileID: UUID? = nil
    var showInstalledLabel: Bool = true

    /// Non-nil when Devgentic can never run this model (decision/classifier, speech, image or embedding model).
    /// Swaps the Download pill for a disabled "Not supported" pill using this text as its tooltip.
    /// Consulted only after the in-progress and installed states, so existing copies stay deletable and cancellable.
    var unsupportedReason: String? = nil

    /// Called when the user confirms a fresh download. If `nil`, the view
    /// falls back to `DownloadCoordinator.start…IfNeeded` directly.
    var onDownloadRequested: (() -> Void)? = nil

    /// Called when the user confirms a delete of an installed model. If
    /// `nil`, the "Delete" menu item is hidden — managers that can't
    /// currently surface a delete UI should omit it rather than crash.
    var onDeleteRequested: (() -> Void)? = nil

    /// Opens the model's folder; supplied only for backends whose models live in a folder the app knows about.
    var onRevealRequested: (() -> Void)? = nil

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var showingRedownloadAlert: Bool = false
    @State private var showingCancelAlert: Bool = false

    /// MLX cancel waits for the in-flight HubApi task to observe cancellation and then deletes the partial folder;
    /// this drives a "Cleaning up..." indicator. Other backends cancel atomically.
    private var isCleaningUpCancel: Bool {
        backend == .mlx && MLXModelService.shared.isCancellingDownload(repoId: modelIdentifier)
    }

    init(
        backend: ModelBackendType,
        modelIdentifier: String,
        displayName: String? = nil,
        isInstalled: Bool,
        profileID: UUID? = nil,
        showInstalledLabel: Bool = true,
        unsupportedReason: String? = nil,
        onDownloadRequested: (() -> Void)? = nil,
        onDeleteRequested: (() -> Void)? = nil,
        onRevealRequested: (() -> Void)? = nil
    ) {
        self.backend = backend
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName ?? modelIdentifier
        self.isInstalled = isInstalled
        self.profileID = profileID
        self.showInstalledLabel = showInstalledLabel
        self.unsupportedReason = unsupportedReason
        self.onDownloadRequested = onDownloadRequested
        self.onDeleteRequested = onDeleteRequested
        self.onRevealRequested = onRevealRequested
    }

    /// Most-recent active record for this model, if any.
    /// Reading `activeRecordIDsByKey` registers observation so start, progress and terminal changes re-render.
    private var activeRecord: DownloadRecord? {
        DownloadManager.shared.activeRecord(
            backend: backend,
            modelIdentifier: modelIdentifier
        )
    }

    var body: some View {
        Group {
            if let active = activeRecord {
                downloadingView(record: active)
            } else if isInstalled {
                installedView
            } else if let reason = unsupportedReason {
                unsupportedView(reason: reason)
            } else {
                availableView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isInstalled)
        .animation(.easeInOut(duration: 0.2), value: activeRecord?.id)
        .alert(
            "Re-download \(displayName)?",
            isPresented: $showingRedownloadAlert
        ) {
            Button("Re-download") {
                Task { await triggerDownload(force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing files will be overwritten.")
        }
    }

    // MARK: - State views

    private var availableView: some View {
        Button {
            Task { await triggerDownload(force: false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(.caption, weight: .semibold))
                Text("Download")
                    .font(.system(.caption, weight: .medium))
            }
            // Same intrinsic-width rule as `installedView` — a squeezed row must not be able
            // to wrap the primary action's label inside its pill.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backend.tintColor.opacity(0.15))
            .foregroundColor(backend.tintColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Download \(displayName)")
        .accessibilityLabel("Download \(displayName)")
    }

    /// Disabled stand-in for `availableView`. A real `Button` with `.disabled(true)` rather than
    /// bare text, so VoiceOver announces it as a dimmed control and the tooltip still shows why.
    private func unsupportedView(reason: String) -> some View {
        Button {} label: {
            HStack(spacing: 4) {
                Image(systemName: "nosign")
                    .font(.system(.caption, weight: .semibold))
                Text("Not supported")
                    .font(.system(.caption, weight: .medium))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.secondaryText.opacity(0.12))
            .foregroundColor(theme.secondaryText)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help(reason)
        .accessibilityLabel("\(displayName) is not supported")
        .accessibilityHint(reason)
    }

    private func downloadingView(record: DownloadRecord) -> some View {
        // Live speed snapshot from `DownloadManager`'s observable dict; the row re-renders on each new MB/s sample.
        let snapshot = DownloadManager.shared.activeSpeeds[record.id]
        return VStack(alignment: .leading, spacing: 2) {
            if isCleaningUpCancel {
                // Post-cancel cleanup: shows a spinner instead of the progress bar while the partial folder is deleted.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning up…")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView(value: record.progress)
                        .progressViewStyle(.linear)
                        .tint(backend.tintColor)
                        .frame(width: 100)

                    Text("\(Int(record.progress * 100))%")
                        .font(.system(.caption2, weight: .bold).monospacedDigit())
                        .foregroundColor(backend.tintColor)
                        .frame(minWidth: 32, alignment: .trailing)

                    Button {
                        showingCancelAlert = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel download of \(displayName)")
                }

                Text(DownloadSpeedFormatter.compactLine(snapshot: snapshot))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), downloading, \(Int(record.progress * 100)) percent, \(DownloadSpeedFormatter.compactLine(snapshot: snapshot))")
        .alert("Cancel Download?", isPresented: $showingCancelAlert) {
            Button("Cancel Download", role: .destructive) {
                DownloadManager.shared.cancelDownload(record)
            }
            Button("Keep Downloading", role: .cancel) { }
        } message: {
            Text(cancelAlertMessage)
        }
    }

    /// Backend-specific cancel confirmation copy. MLX leaves partial files on
    /// disk (HubApi writes `config.json` early), so we tell the user those
    /// will be removed. Ollama/Whisper cancel atomically — generic copy.
    private var cancelAlertMessage: String {
        switch backend {
        case .mlx:
            return "The in-progress download of '\(displayName)' will be stopped and any partial files removed from disk."
        case .ollama, .whisper:
            return "The in-progress download of '\(displayName)' will be stopped."
        }
    }

    private var installedView: some View {
        HStack(spacing: 6) {
            if showInstalledLabel {
                Label("Installed", systemImage: "checkmark.seal.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.successColor)
                    // A pill must keep its intrinsic width: this shared component sits in rows with different width budgets.
                    // `fixedSize` opts out of parent compression and `lineLimit(1)` stops wrapping inside the capsule.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.successColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Menu {
                Button {
                    showingRedownloadAlert = true
                } label: {
                    Label("Re-download…", systemImage: "arrow.clockwise")
                }

                if let onReveal = onRevealRequested {
                    Button {
                        onReveal()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }

                if let onDelete = onDeleteRequested {
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(.caption, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundColor(theme.secondaryText)
                    .background(Circle().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More actions for \(displayName)")
        }
    }

    // MARK: - Download trigger

    /// Whether the host's pre-download hook should handle this request instead of the coordinator.
    /// Only a fresh pull is intercepted; delegating a forced re-download would drop the `force` flag. Free of view state.
    static func shouldDelegateToHost(force: Bool, hasHook: Bool) -> Bool {
        !force && hasHook
    }

    /// Kicks off the idempotent coordinator flow. `force: true` skips the
    /// "already installed" short-circuit by deleting the current record
    /// first (used for the Re-download path).
    @MainActor
    private func triggerDownload(force: Bool) async {
        if force {
            if let record = DownloadHistoryStore.shared.fetchMostRecent(
                backend: backend,
                modelIdentifier: modelIdentifier
            ) {
                _ = DownloadHistoryStore.shared.delete(id: record.id)
            }
        }

        if Self.shouldDelegateToHost(force: force, hasHook: onDownloadRequested != nil),
           let onDownloadRequested {
            onDownloadRequested()
            return
        }

        let outcome: DownloadStartOutcome
        switch backend {
        case .ollama:
            outcome = await DownloadCoordinator.startOllamaDownloadIfNeeded(
                modelName: modelIdentifier,
                profileID: profileID
            )
        case .mlx:
            // `force` must reach the coordinator: the installed check reads the filesystem,
            // so deleting the history record is not enough.
            outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(
                repoId: modelIdentifier,
                profileID: profileID,
                force: force
            )
        case .whisper:
            outcome = await DownloadCoordinator.startWhisperDownloadIfNeeded(
                modelId: modelIdentifier,
                profileID: profileID
            )
        }

        switch outcome {
        case .alreadyInstalled:
            toastManager.show("\(displayName) is already installed", style: .success)
        case .alreadyInProgress:
            toastManager.show("Already downloading", style: .warning)
        case .resumedFromHistory:
            toastManager.show("Re-downloading \(displayName)…", style: .success)
        case .startedFresh:
            toastManager.show("Downloading \(displayName)…", style: .success)
        case .failed(let reason):
            toastManager.show(reason, style: .error)
        }
    }
}
