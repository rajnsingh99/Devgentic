// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WhisperModelSelectorPopover.swift
//  Devgentic
//
//  Popover for selecting a WhisperKit speech model when none is loaded.
//

import SwiftUI

struct WhisperModelSelectorPopover: View {
    @Binding var isPresented: Bool
    let currentModelName: String?
    let downloadedModelIds: Set<String>
    let onSelectModel: (String) -> Void
    let onSelectUndownloadedModel: (String) -> Void
    let onDeleteModel: (String) -> Void

    /// @Observable — reading its download state in `body` re-renders the rows as a pull advances.
    private var downloadService: WhisperModelDownloadService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider()
            modelList
        }
        .frame(width: 280)
        .padding(.bottom, 8)
    }

    // MARK: - Sub Views

    private var popoverHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speech Model")
                .font(.system(size: 13, weight: .semibold))
            if let downloadingId = downloadService.downloadingModelId {
                Text("Downloading \(displayName(for: downloadingId))…")
                    .font(.system(.caption))
                    .foregroundColor(.accentColor)
            } else if let error = downloadService.downloadError {
                Text("Download failed: \(error)")
                    .font(.system(.caption))
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else {
                Text("Select a model to enable voice input")
                    .font(.system(.caption))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var modelList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(WhisperModelCatalog.availableModels) { model in
                    let isDownloaded = downloadedModelIds.contains(model.id)
                    let isDownloading = downloadService.downloadingModelId == model.id
                    ModelRowView(
                        model: model,
                        // ⚠️ Selected means USABLE. The stored choice outlives its files (deleted,
                        // moved, or never downloaded), and a check on a model that is not on disk
                        // told the user voice input was ready when it was not.
                        isSelected: isDownloaded && model.id == currentModelName,
                        isDownloaded: isDownloaded,
                        downloadProgress: isDownloading ? downloadService.downloadProgress : nil,
                        // One pull at a time (the service refuses a second), so while one runs the
                        // other undownloaded rows are inert rather than inviting a tap that is dropped.
                        isEnabled: isDownloaded || !downloadService.isDownloading,
                        onTap: {
                            if downloadedModelIds.contains(model.id) {
                                onSelectModel(model.id)
                                isPresented = false
                            } else {
                                onSelectUndownloadedModel(model.id)
                                isPresented = false
                            }
                        },
                        onDelete: {
                            onDeleteModel(model.id)
                            isPresented = false
                        }
                    )
                }
            }
        }
        .frame(maxHeight: 350)
    }

    private func displayName(for modelId: String) -> String {
        WhisperModelCatalog.availableModels.first { $0.id == modelId }?.displayName ?? modelId
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    let isSelected: Bool
    let isDownloaded: Bool
    /// Non-nil while THIS model is downloading: 0…1 (0 until the first progress report).
    let downloadProgress: Double?
    let isEnabled: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    if let progress = downloadProgress {
                        Text(progress > 0 ? "Downloading… \(Int(progress * 100))%" : "Starting download…")
                            .font(.system(.caption))
                            .foregroundColor(.accentColor)
                            .monospacedDigit()
                    } else {
                        Text(model.size)
                            .font(.system(.caption))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Trash button for downloaded models (visible on hover).
                // Hover is a MOUSE affordance — VoiceOver and keyboard never set `isHovering`,
                // so this button doesn't exist in the tree for them. It is not their route to
                // delete; the accessibility action and context menu below are. (It's also a
                // Button nested in a Button, which VoiceOver reaches unreliably at best.)
                if isDownloaded && isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(.caption2))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete model")
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }

                // Status is encoded ONLY in these three glyphs. Hidden from VoiceOver and
                // folded into the row's label instead, so state is spoken rather than
                // announced as "checkmark.circle.fill".
                Group {
                    if let progress = downloadProgress {
                        DownloadRing(progress: progress)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(.body))
                            .foregroundColor(.accentColor)
                    } else if isDownloaded {
                        Image(systemName: "checkmark.circle")
                            .font(.system(.caption))
                            .foregroundColor(.green.opacity(0.7))
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(.caption))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || downloadProgress != nil)
        .opacity(isEnabled || downloadProgress != nil ? 1 : 0.45)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // Delete WAS mouse-only. These are the non-mouse routes: the VoiceOver actions rotor
        // (VO-Command-Space) and Control-click / the keyboard context menu.
        .accessibilityAction(named: "Delete model") {
            guard isDownloaded else { return }
            onDelete()
        }
        .contextMenu {
            if isDownloaded {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Model", systemImage: "trash")
                }
            }
        }
    }

    /// State lives entirely in glyph and colour otherwise — a VoiceOver user heard
    /// "whisper-small, 466 MB" and was never told which model was actually active.
    private var accessibilityLabel: String {
        let state: String
        if let progress = downloadProgress {
            state = String(localized: "downloading, \(Int(progress * 100)) percent")
        } else if isSelected {
            state = String(localized: "selected")
        } else if isDownloaded {
            state = String(localized: "downloaded")
        } else {
            state = String(localized: "not downloaded, activate to download")
        }
        return "\(model.displayName), \(model.size), \(state)"
    }
}

// MARK: - Download Ring

/// Determinate ring once progress arrives; a spinner before the first report (the handshake).
private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        if progress > 0 {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            .frame(width: 14, height: 14)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        }
    }
}
