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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            // Animated download icon
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundColor(theme.accentColor)
                // Pulsed for the entire download — the ProgressView already conveys activity.
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)

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
            // `.help()` is AX help, not the AX label — without this the only way to stop a
            // download announced as "button".
            .accessibilityLabel("Cancel download")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var displayName: String {
        if let modelId = service.downloadingModelId,
           let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
            return String(localized: "Downloading \(model.displayName)…")
        }
        return String(localized: "Downloading model…")
    }
}
