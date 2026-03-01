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
    let onSelectModel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider()
            modelList
        }
        .frame(width: 260)
        .padding(.bottom, 8)
    }

    // MARK: - Sub Views

    private var popoverHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speech Model")
                .font(.system(size: 13, weight: .semibold))
            Text("Select a model to enable voice input")
                .font(.system(size: 11))
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
                        onTap: {
                            onSelectModel(model.id)
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
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text(model.size)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
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
