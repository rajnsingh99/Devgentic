// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSettingsSection.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

/// Settings for where models are stored and the credential for downloading them.
/// Rendered as part of General Settings (MLX Models and HuggingFace sections, after Observability).
struct ModelSettingsSection: View {
    @Environment(\.appTheme) private var theme

    // MARK: - HuggingFace token (G4)

    /// Draft value while editing. The stored token is never written back into this field —
    /// the UI shows a masked form instead, so a saved secret is not sitting in view state.
    @State private var tokenDraft: String = ""
    @State private var tokenSaved: Bool = false
    @State private var showTokenWarning: Bool = false

    /// Set only when a Keychain write was ATTEMPTED and failed. Never inferred from the draft.
    @State private var keychainSaveFailed: Bool = false

    /// Result of asking HuggingFace whether it accepts the saved token, or nil before any check.
    @State private var tokenVerdict: HuggingFaceAccountCheck.Verdict?
    @State private var isVerifyingToken: Bool = false

    private var tokenStore: HuggingFaceTokenStore { .shared }

    @ViewBuilder
    private var huggingFaceSection: some View {
        SettingsCard(title: "HuggingFace", icon: "key.fill", theme: theme) {
            SettingsRow(
                title: "Access Token",
                description: "Needed only for gated or private models. Without a token those downloads fail, and anonymous requests hit HuggingFace's rate limit sooner.",
                theme: theme
            ) {
                if tokenStore.readFailed {
                    // Without this the card shows the same empty state as a new user, so someone whose Keychain was momentarily
                    // unreadable is told they have no token and re-pastes one they never lost.
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("A token is stored but the Keychain could not be read. Nothing has been "
                             + "lost — unlock your Keychain, or re-grant access after an app update, "
                             + "then reopen this pane.")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(theme.warningColor)
                } else if tokenStore.hasToken, let masked = tokenStore.maskedToken {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(theme.successColor)
                                .font(.system(size: 11))
                            Text(masked)
                                .font(theme.fontCodeCaption)
                                .foregroundColor(theme.primaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                        )

                        TactileButton(
                            title: "Remove",
                            icon: "trash",
                            variant: .destructive
                        ) {
                            _ = tokenStore.clear()
                            tokenDraft = ""
                            tokenSaved = false
                            keychainSaveFailed = false
                            // The verdict described the token that just left the Keychain.
                            tokenVerdict = nil
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("hf_…", text: $tokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .accessibilityLabel("HuggingFace access token")

                        TactileButton(
                            title: "Save",
                            icon: "checkmark",
                            variant: .primary,
                            isEnabled: !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            showTokenWarning = !HuggingFaceTokenStore.looksLikeToken(tokenDraft)
                            tokenSaved = tokenStore.store(tokenDraft)
                            keychainSaveFailed = !tokenSaved
                            tokenDraft = ""
                            // Verify after saving, never as a gate: `looksLikeToken` warns and stores anyway, and a network check must not
                            // block a user who is offline. The Keychain write is already done by now; the verdict only changes what is said.
                            guard tokenSaved else { return }
                            tokenVerdict = nil
                            isVerifyingToken = true
                            Task { @MainActor in
                                let outcome = await HuggingFaceAccountCheck.verify()
                                isVerifyingToken = false
                                tokenVerdict = outcome
                            }
                        }
                    }
                }
            }

            if !tokenStore.hasToken {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack {
                    Link("Create a token on HuggingFace ↗",
                         destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if isVerifyingToken {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking this token with HuggingFace…")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Only `.rejected` may say anything about the token; every other verdict reports that the check failed
            // and that the token was saved regardless.
            if let tokenVerdict, !isVerifyingToken {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: {
                        switch tokenVerdict {
                        case .valid:        return "checkmark.seal.fill"
                        case .rejected:     return "xmark.octagon.fill"
                        case .inconclusive: return "exclamationmark.triangle.fill"
                        }
                    }())
                    .foregroundColor({
                        switch tokenVerdict {
                        case .valid:        return theme.successColor
                        case .rejected:     return theme.errorColor
                        case .inconclusive: return .orange
                        }
                    }())
                    .font(.system(size: 11))
                    Text(HuggingFaceAccountCheck.message(for: tokenVerdict))
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if showTokenWarning {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("That doesn't look like a HuggingFace token (they usually start with “hf_”). It has been saved anyway — if downloads still fail, check it on huggingface.co.")
                        .font(theme.fontCaption2)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // `keychainSaveFailed` records the failed attempt instead of inferring it from the draft: the Save handler clears
            // `tokenDraft`, so inferring from it would hide the row exactly when a write fails.
            if keychainSaveFailed {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                        .font(.system(size: 11))
                    Text("Couldn't save to the Keychain.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.errorColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        // Re-derive from the Keychain when this pane appears: the store caches its one launch-time read, so a failed read
        // would otherwise stay "no token" until the app quits.
        .onAppear { tokenStore.refreshFromKeychain() }
    }

    // MARK: - Models location (G14)

    @State private var locationPath: String = MLXModelsLocation.displayPath ?? ""
    @State private var locationError: String?
    @State private var importResult: String?

    @ViewBuilder
    private var modelsLocationSection: some View {
        SettingsCard(title: "MLX Models", icon: "internaldrive", theme: theme) {
            SettingsRow(
                title: "Storage Location",
                description: "Where downloaded models are stored. Useful if your boot volume is small and you have a faster or larger external drive.",
                theme: theme
            ) {
                HStack(spacing: 6) {
                    Text(locationPath.isEmpty ? "Default (Application Support)" : locationPath)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200)

                    TactileIconButton(
                        icon: "folder",
                        tooltip: "Reveal in Finder"
                    ) {
                        MLXModelService.shared.revealModelsDirectoryInFinder()
                    }

                    TactileButton(
                        title: "Change",
                        icon: "folder.badge.gearshape",
                        variant: .secondary
                    ) {
                        chooseDirectory()
                    }

                    if MLXModelsLocation.hasCustomDirectory {
                        TactileIconButton(
                            icon: "arrow.counterclockwise",
                            tooltip: "Reset to Default"
                        ) {
                            Task {
                                await MLXModelService.shared.resetModelsDirectory()
                                locationPath = ""
                                locationError = nil
                            }
                        }
                    }
                }
            }

            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

            SettingsRow(
                title: "Import Existing Models",
                description: "Already have models from mlx_lm, LM Studio or a manual download? Import the folder instead of downloading it again.",
                theme: theme
            ) {
                TactileButton(
                    title: "Import",
                    icon: "square.and.arrow.down",
                    variant: .secondary
                ) {
                    importFolder()
                }
            }

            if MLXModelsLocation.hasCustomDirectory {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .font(.system(size: 11))
                    Text("Changing this does not move existing models. Anything in the previous folder stays there and stops being listed.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let locationError {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                        .font(.system(size: 11))
                    Text(locationError)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.errorColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let importResult {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: importResult.hasPrefix("Imported") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(importResult.hasPrefix("Imported") ? theme.successColor : theme.errorColor)
                        .font(.system(size: 11))
                    Text(importResult)
                        .font(theme.fontCaption2)
                        .foregroundColor(importResult.hasPrefix("Imported") ? theme.successColor : theme.errorColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Devgentic should store MLX models."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            if await MLXModelService.shared.setModelsDirectory(url) {
                locationPath = url.path
                locationError = nil
            } else {
                // The resolver has already logged the specific reason.
                locationError = "Couldn't use that folder. It needs to be a folder Devgentic can read and write — folders inside Desktop, Documents or Downloads may need permission in System Settings › Privacy & Security."
            }
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a model folder containing config.json and its weights."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let repoId = MLXModelService.suggestedRepoId(for: url)
        Task {
            switch await MLXModelService.shared.importModel(from: url, as: repoId) {
            case .success(let id):
                importResult = "Imported \(id)."
            case .failure(let error):
                importResult = error.errorDescription ?? "Import failed."
            }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            modelsLocationSection
            huggingFaceSection
        }
    }
}
