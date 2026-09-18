// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelDetailSheet.swift
//  Devgentic
//
//  Created 2026-08-03 for G6.
//
//  The decision aid the store never had: licence, size, quantization, architecture and the
//  publisher's own model card, shown BEFORE the user commits to a multi-gigabyte download.
//

import SwiftUI

struct MLXModelDetailSheet: View {

    let model: MLXDisplayModel
    let fitAssessment: ModelFitAssessment
    /// Invoked when the user chooses to download from here. The host owns the actual start so
    /// the RAM-fit advisory and the coordinator's pre-seed still apply.
    let onDownload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var detail: MLXModelDetail?
    @State private var loadError: HFRequestError?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(theme.dividerColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ⚠️ ABOVE the isLoading/detail switch, not inside `factsGrid`. This is the
                    // one fact about an installed copy that is known from DISK, so putting it in
                    // the grid would blank it during the HuggingFace fetch and on `errorState` —
                    // i.e. offline, which is exactly when someone inspects a model they already
                    // have. `if let` rather than a placeholder: a copy that predates revision
                    // tracking shows nothing instead of a made-up "unknown".
                    // ⚠️ RESOLVED HERE, NOT CARRIED ON THE CARD. The card's `revision` was
                    // populated only by the INSTALLED-tab mapping, so opening the sheet for the
                    // same installed model from All or Recommended showed no row at all — which
                    // reads as "this copy predates revision tracking", and is false. The service
                    // is the one source that is right on every tab.
                    if let revision = MLXModelService.shared.installedModel(named: model.id)?.revision {
                        fact("Installed revision", MLXModelRevision.shortForm(revision),
                             hint: "Full commit \(revision). This is the version on your disk; Check for Updates compares it against what the publisher has now.")
                    }

                    if isLoading {
                        loadingState
                    } else if let detail {
                        factsGrid(detail)
                        if detail.isGated { gatedWarning }
                        if !detail.baseModels.isEmpty { baseModels(detail) }
                        readme(detail)
                    } else if let loadError {
                        errorState(loadError)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(theme.dividerColor)

            footer
        }
        .frame(width: 640, height: 620)
        .task {
            let result = await MLXModelService.shared.fetchModelDetail(repoId: model.id)
            switch result {
            case .success(let value): detail = value
            case .failure(let error): loadError = error
            }
            isLoading = false
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)

                if !model.organization.isEmpty {
                    Text(model.organization)
                        .font(.callout)
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Link(destination: URL(string: "https://huggingface.co/\(model.id)")!) {
                Label("View on HuggingFace", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
        }
        .padding(20)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading model card…")
                .font(.callout)
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private func errorState(_ error: HFRequestError) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.icloud")
                .font(.largeTitle)
                .foregroundColor(theme.secondaryText.opacity(0.6))
            Text(error.errorDescription ?? "Couldn't load this model's details.")
                .font(.callout)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("You can still download the model.")
                .font(.caption)
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    @ViewBuilder
    private func factsGrid(_ detail: MLXModelDetail) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: 14) {

            fact("Licence", detail.license?.uppercased() ?? "Not stated",
                 hint: detail.license == nil
                    ? "The publisher didn't declare one — check the model card before commercial use."
                    : nil,
                 link: detail.licenseURL)

            fact("Download size",
                 detail.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")

            fact("Quantization", detail.quantizationSummary ?? "Not stated")

            fact("Architecture", detail.architecture ?? "Not stated")

            // ⚠️ Stated honestly. Verified across four MLX repos: HuggingFace's API never
            // publishes `max_position_embeddings`, so this genuinely cannot be known until
            // the model is on disk and its `config.json` can be read.
            fact("Context window", "Not published",
                 hint: "HuggingFace doesn't expose this before download. Devgentic reads it from the model once installed.")

            fact("Tensor elements",
                 detail.tensorElements.map { $0.formatted(.number.notation(.compactName)) } ?? "Not stated",
                 hint: "Stored tensors, not logical parameters — quantized weights are packed.")

            fact("Files", "\(detail.fileCount) (\(detail.weightFileCount) weight)")

            fact("Estimated RAM",
                 fitAssessment.estimatedRuntimeRAM > 0 ? fitAssessment.formattedEstimatedRAM : "Unknown",
                 hint: fitAssessment.explanation)

            if let updated = detail.lastModified {
                fact("Last updated", updated.formatted(date: .abbreviated, time: .omitted))
            }

            if let downloads = detail.downloads {
                fact("Downloads", downloads.formatted(.number.notation(.compactName)))
            }
        }
    }

    private var gatedWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This model is gated")
                    .font(.callout.weight(.semibold))
                Text("HuggingFace requires an access token for it. Devgentic doesn't support tokens yet, so this download will fail.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func baseModels(_ detail: MLXModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Based on")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
            ForEach(detail.baseModels, id: \.self) { base in
                Text(base)
                    .font(.callout)
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func readme(_ detail: MLXModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model card")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            if let readme = detail.readme, !readme.isEmpty {
                Text(readme)
                    .font(.callout)
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This publisher didn't include a model card.")
                    .font(.callout)
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let detail, let bytes = detail.totalBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button("Close") { dismiss() }
            Button {
                dismiss()
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentColor)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .background(theme.secondaryBackground)
    }

    // MARK: - Helper

    @ViewBuilder
    private func fact(_ label: String, _ value: String, hint: String? = nil, link: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
            if let link {
                Link(value, destination: link).font(.callout)
            } else {
                Text(value)
                    .font(.callout)
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
            }
        }
        .help(hint ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint(hint ?? "")
    }
}
