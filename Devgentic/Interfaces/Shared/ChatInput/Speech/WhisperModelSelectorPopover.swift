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
            Text("Select a model to enable voice input")
                .font(.system(.caption))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var modelList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(WhisperModelCatalog.availableModels) { model in
                    ModelRowView(
                        model: model,
                        isSelected: model.id == currentModelName,
                        isDownloaded: downloadedModelIds.contains(model.id),
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
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    let isSelected: Bool
    let isDownloaded: Bool
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
                    Text(model.size)
                        .font(.system(.caption))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Trash button for downloaded models (visible on hover)
                if isDownloaded && isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(.caption2))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete model")
                    .transition(.opacity)
                }

                if isSelected {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}
