//
//  ModelDownloadStatusView.swift
//  Devgentic
//
//  Created 2026-04-21.
//  Rewritten 2026-04-22 — dropped `@Query` with a captured-param predicate
//  because SwiftUI didn't reliably rebuild the fetch when rows were
//  recycled in `LazyVStack`, so the Download button could stay visible
//  on a model that was actively downloading. Now reads from
//  `DownloadManager.activeRecordIDsByKey` (observable stored dict) +
//  `DownloadHistoryStore.fetch(id:)` for the actual record.
//
//  Unified per-model download-status component. Used in:
//    · OllamaModelStoreView — registry browser rows
//    · MLXModelStoreView    — HF model cards
//    · GeneralSettingsView  — Whisper model rows
//
//  Renders one of three compact states:
//    · Available  → "Download" button (accent pill)
//    · Downloading→ progress bar + percentage + cancel + speed line
//    · Installed  → "Installed" label + overflow menu (Re-download / Delete)
//

import SwiftUI

struct ModelDownloadStatusView: View {
    let backend: ModelBackendType
    let modelIdentifier: String
    let displayName: String
    let isInstalled: Bool
    var profileID: UUID? = nil

    /// Called when the user confirms a fresh download. If `nil`, the view
    /// falls back to `DownloadCoordinator.start…IfNeeded` directly.
    var onDownloadRequested: (() -> Void)? = nil

    /// Called when the user confirms a delete of an installed model. If
    /// `nil`, the "Delete" menu item is hidden — managers that can't
    /// currently surface a delete UI should omit it rather than crash.
    var onDeleteRequested: (() -> Void)? = nil

    /// Opens the model's folder. Supplied only for backends whose models live in a folder the
    /// app knows about — the installed card previously showed the path as truncated caption
    /// text with no way to act on it.
    var onRevealRequested: (() -> Void)? = nil

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var showingRedownloadAlert: Bool = false
    @State private var showingCancelAlert: Bool = false

    /// MLX cancel path must wait for the in-flight HubApi task to observe
    /// cancellation and then delete the partial folder — during that window
    /// we show a "Cleaning up…" indicator instead of a frozen progress bar.
    /// Other backends cancel atomically and don't need this state.
    private var isCleaningUpCancel: Bool {
        backend == .mlx && MLXModelService.shared.isCancellingDownload(repoId: modelIdentifier)
    }

    init(
        backend: ModelBackendType,
        modelIdentifier: String,
        displayName: String? = nil,
        isInstalled: Bool,
        profileID: UUID? = nil,
        onDownloadRequested: (() -> Void)? = nil,
        onDeleteRequested: (() -> Void)? = nil,
        onRevealRequested: (() -> Void)? = nil
    ) {
        self.backend = backend
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName ?? modelIdentifier
        self.isInstalled = isInstalled
        self.profileID = profileID
        self.onDownloadRequested = onDownloadRequested
        self.onDeleteRequested = onDeleteRequested
        self.onRevealRequested = onRevealRequested
    }

    /// Most-recent active record for this model, if any. Reading
    /// `DownloadManager.shared.activeRecordIDsByKey` here registers view
    /// observation on the @Observable dict so updates — start, progress
    /// ticks (via the record's @Model observation), terminal transitions
    /// — all trigger re-renders.
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

    private func downloadingView(record: DownloadRecord) -> some View {
        // Live speed snapshot from DownloadManager's @Observable dict.
        // Reading it in the view body means the row re-renders every time
        // the sampler publishes a new MB/s value, ~1-2× per second.
        let snapshot = DownloadManager.shared.activeSpeeds[record.id]
        return VStack(alignment: .leading, spacing: 2) {
            if isCleaningUpCancel {
                // Post-cancel cleanup: HubApi task is winding down and we're
                // about to delete the partial folder. Replace the progress
                // bar with a spinner so the user doesn't think it's stuck.
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
        HStack(spacing: 4) {
            Label("Installed", systemImage: "checkmark.seal.fill")
                .font(.system(.caption, weight: .medium))
                .foregroundColor(theme.successColor)
                // ⚠️ A pill must keep its intrinsic width. This is a SHARED component dropped
                // into rows with very different width budgets — the MLX store card has room,
                // the Whisper settings row does not — and without this the label wrapped and
                // hyphenated INSIDE the capsule ("In-stal / led"). `fixedSize` opts the label
                // out of the parent's compression; `lineLimit(1)` stops the wrap outright.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.successColor.opacity(0.12))
                .clipShape(Capsule())

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

    /// Whether the host's pre-download hook should handle this request instead of the
    /// coordinator.
    ///
    /// ⚠️ Only a FRESH pull may be intercepted. The hook exists so the MLX store can raise its
    /// RAM-fit advisory before starting a download; a forced re-download is an explicit repair
    /// of a model already on disk, whose fit was accepted when it was first installed.
    /// Delegating a forced request would drop the `force` flag — the host's closure calls the
    /// coordinator without it, the install check short-circuits, and Re-download silently
    /// becomes the no-op that A7 existed to fix.
    ///
    /// Static and free of view state so the rule is testable without building a view.
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
            // `force` must reach the coordinator: deleting the history record above is not
            // enough, because the installed check reads the FILESYSTEM. Without this the
            // Re-download button was a guaranteed no-op on any installed model.
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
