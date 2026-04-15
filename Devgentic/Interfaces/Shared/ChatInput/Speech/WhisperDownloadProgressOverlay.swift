//
//  WhisperDownloadProgressOverlay.swift
//  Devgentic
//
//  Floating progress bar shown inline in the Speech Recognition settings
//  card while a Whisper model download is active.
//

import SwiftUI

struct WhisperDownloadProgressOverlay: View {

    private var service: WhisperModelDownloadService { .shared }
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            // Animated download icon
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundColor(theme.accentColor)
                .symbolEffect(.pulse, options: .repeating)

            // Model name + progress
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(service.downloadProgress * 100))%")
                        .font(.system(.caption, weight: .bold).monospacedDigit())
                        .foregroundColor(theme.accentColor)
                }

                ProgressView(value: service.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
            }

            // Cancel button
            Button {
                Task { await service.cancelDownload() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(.body))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var displayName: String {
        if let modelId = service.downloadingModelId,
           let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
            return "Downloading \(model.displayName)…"
        }
        return "Downloading model…"
    }
}
