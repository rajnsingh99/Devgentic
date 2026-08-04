//
//  AccountSettingsView.swift
//  Devgentic
//
//  Created for Account Management.
//

import SwiftUI
import AppKit

/// A view for managing user account settings, specifically Google Sign-In.
struct AccountSettingsView: View {
    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

    // Mock state for Google Sign-In
    @AppStorage("isMockGoogleSignedIn") private var isSignedIn: Bool = false
    @AppStorage("mockGoogleUserEmail") private var userEmail: String = "user@example.com"
    @AppStorage("mockGoogleUserName") private var userName: String = "Devgentic User"

    // MARK: - HuggingFace token (G4)

    /// Draft value while editing. The stored token is never written back into this field —
    /// the UI shows a masked form instead, so a saved secret is not sitting in view state.
    @State private var tokenDraft: String = ""
    @State private var tokenSaved: Bool = false
    @State private var showTokenWarning: Bool = false

    private var tokenStore: HuggingFaceTokenStore { .shared }

    @ViewBuilder
    private var huggingFaceSection: some View {
        SettingsCard(title: "HuggingFace", icon: "key.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Needed only for gated or private models. Without a token those downloads fail, and anonymous requests hit HuggingFace's rate limit sooner.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if tokenStore.hasToken, let masked = tokenStore.maskedToken {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(theme.successColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Token saved")
                                .font(.callout.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            // Masked, never the value — a settings screen is shoulder-surfable
                            // and gets screenshotted into bug reports.
                            Text(masked)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            _ = tokenStore.clear()
                            tokenDraft = ""
                            tokenSaved = false
                        }
                    }
                } else {
                    // `SecureField` so the token isn't rendered in plain text as it's typed.
                    SecureField("hf_…", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("HuggingFace access token")

                    if showTokenWarning {
                        Text("That doesn't look like a HuggingFace token (they usually start with \"hf_\"). It has been saved anyway — if downloads still fail, check it on huggingface.co.")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Link("Create a token on HuggingFace",
                             destination: URL(string: "https://huggingface.co/settings/tokens")!)
                            .font(.caption)
                        Spacer()
                        Button("Save") {
                            // Shape check only — HuggingFace has shipped more than one token
                            // format, so an unrecognised shape warns rather than refuses.
                            showTokenWarning = !HuggingFaceTokenStore.looksLikeToken(tokenDraft)
                            tokenSaved = tokenStore.store(tokenDraft)
                            tokenDraft = ""
                        }
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if tokenSaved == false && tokenStore.hasToken == false && !tokenDraft.isEmpty {
                    Text("Couldn't save to the Keychain.")
                        .font(.caption)
                        .foregroundColor(theme.errorColor)
                }
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Where downloaded models are stored. Useful if your boot volume is small and you have a faster or larger external drive.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(locationPath.isEmpty ? "Default (Application Support)" : locationPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        MLXModelService.shared.revealModelsDirectoryInFinder()
                    }
                    Button("Change…") { chooseDirectory() }
                    if MLXModelsLocation.hasCustomDirectory {
                        Button("Reset") {
                            Task {
                                await MLXModelService.shared.resetModelsDirectory()
                                locationPath = ""
                                locationError = nil
                            }
                        }
                    }
                }

                // Stated plainly: this is the surprising part of every app that offers it.
                if MLXModelsLocation.hasCustomDirectory {
                    Text("Changing this does not move existing models. Anything in the previous folder stays there and stops being listed.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let locationError {
                    Text(locationError)
                        .font(.caption)
                        .foregroundColor(theme.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text("Already have models from mlx_lm, LM Studio or a manual download? Import the folder instead of downloading it again.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Import Model Folder…") { importFolder() }
                    Spacer()
                }

                if let importResult {
                    Text(importResult)
                        .font(.caption)
                        .foregroundColor(importResult.hasPrefix("Imported") ? theme.successColor : theme.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        ScrollView {
            VStack(spacing: 32) {

                modelsLocationSection

                huggingFaceSection

                // User Account Section
                SettingsCard(title: "Google Account", icon: "person.crop.circle.badge.checkmark", theme: theme) {
                    
                    if isSignedIn {
                        // Signed In State
                        VStack(spacing: 0) {
                            HStack(spacing: 20) {
                                // Profile Picture Placeholder
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [theme.accentColor.opacity(0.25), theme.accentColor.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Text(String(userName.prefix(1)).uppercased())
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(theme.accentColor)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(userName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(theme.primaryText)

                                    Text(userEmail)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation {
                                        isSignedIn = false
                                    }
                                }) {
                                    Text("Sign Out")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            
                            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                            
                            SettingsRow(
                                title: "Sync Data",
                                description: "Synchronize your application settings and preferences across devices using your Google Account.",
                                theme: theme
                            ) {
                                Toggle("", isOn: .constant(true))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(theme.accentColor)
                            }
                        }
                    } else {
                        // Signed Out State
                        VStack(alignment: .center, spacing: 20) {
                            
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                                .padding(.top, 24)
                                .accessibilityHidden(true)
                            
                            Text("Sign in with your Google account to sync your workflow, manage backend profiles across devices, and unlock full Devgentic capabilities.")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.horizontal, 24)
                            
                            Button(action: {
                                withAnimation {
                                    isSignedIn = true
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "g.circle.fill")
                                        .font(.system(size: 14))
                                        .accessibilityHidden(true)
                                    Text("Sign in with Google")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentColor)
                            .controlSize(.regular)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}
