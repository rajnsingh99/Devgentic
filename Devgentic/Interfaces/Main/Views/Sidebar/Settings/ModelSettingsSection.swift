// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ModelSettingsSection.swift
//
//  Where MLX models live on disk, and the HuggingFace token used to fetch them. Rendered inside
//  Settings › General.
//
//  ⚠️ THIS FILE IS GUARDED BY PATH. `MLXStoreCapabilityTests` reads it by literal string to assert
//  the Keychain-failure row records an attempt rather than inferring one. Its helper XCTFails on a
//  missing path rather than skipping, so a rename fails the build loudly — repoint the test in the
//  same change. (It was `ModelSettingsView.swift` until the Models tab was merged into General and
//  the standalone `ModelSettingsView` wrapper, by then uncalled, was removed.)
//  Devgentic
//
//  Where MLX models live on disk, and the HuggingFace token used to fetch them.
//

import SwiftUI
import AppKit

/// Settings for where models are stored and the credential used to download them.
///
/// ⚠️ THIS PANE WAS CALLED "Account" AND ITS HEADLINE CARD WAS A MOCK GOOGLE SIGN-IN. Both buttons
/// only flipped an `@AppStorage` bool, "Sync Data" was bound to `.constant(true)` so it could not
/// be switched off, and the three `mockGoogle*` keys were read nowhere else in the app. There was
/// no Google SDK in any manifest, no OAuth, no registered URL scheme, no CloudKit — and no commit
/// in this repository's history ever contained one. It was born mock.
///
/// It is gone rather than finished because it also contradicted the project's own published
/// statements: `PRIVACY.md` says "No account, advertising identifier, or device fingerprint" and
/// `README.md` says the app "has no backend of its own". Shipping a sign-in panel that promises
/// cross-device sync alongside those made both untrue.
///
/// ⚠️ THE SECTIONS ARE RENDERED AS PART OF GENERAL SETTINGS. The two sections below
/// (MLX Models and HuggingFace) now live in GeneralSettingsView directly after the Observability section.
/// This file is retained to keep the section modular and satisfy drift tests asserting on its contents.
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
                if tokenStore.hasToken, let masked = tokenStore.maskedToken {
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
                            // ⚠️ VERIFY AFTER SAVING, NEVER AS A GATE. `looksLikeToken` warns and
                            // stores anyway on purpose — refusing something valid because it does
                            // not match a shape this app guessed is the worse failure. The same
                            // reasoning applies twice over to a network check: a user on a plane
                            // must still be able to paste a token. So the Keychain write is
                            // already done and unconditional by the time this runs, and the
                            // verdict only ever changes what is SAID.
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

            // ⚠️ Only `.rejected` is allowed to say anything about the TOKEN; every other verdict
            // reports that the CHECK failed and states the token was saved regardless. Telling
            // someone offline that their credential is invalid sends them to regenerate a working
            // one and teaches them to distrust the check.
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

            // ⚠️ THIS CONDITION WAS INVERTED. It read
            // `!tokenSaved && !hasToken && !tokenDraft.isEmpty`, which is true the moment a user
            // types the FIRST character with nothing saved — so the red "Couldn't save" row
            // appeared before they had attempted anything. And at the one moment it should fire,
            // a Keychain write that actually failed, the Save handler had already cleared
            // `tokenDraft` on the next line, so `!tokenDraft.isEmpty` was false and the row was
            // suppressed. It showed exactly when it was wrong and hid exactly when it was right.
            // `keychainSaveFailed` records the attempt instead of inferring it.
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
