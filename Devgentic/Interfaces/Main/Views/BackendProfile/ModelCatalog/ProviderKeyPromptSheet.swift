// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderKeyPromptSheet.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Modal sheet for entering a remote provider's API key and custom gateway or proxy endpoint, with Keychain
/// persistence.
struct ProviderKeyPromptSheet: View {

    let category: ModelCatalogProviderCategory
    var initialEndpoint: String? = nil
    var onSaved: ((_ key: String, _ endpoint: String?) -> Void)? = nil
    var onKeySaved: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var apiKeyDraft: String = ""
    @State private var endpointDraft: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isSaving: Bool = false

    private var existingKey: String? {
        AppProviderKeyStore.load(forAccount: category.vendorKey)
    }

    private var existingEndpoint: String? {
        AppProviderKeyStore.loadEndpoint(forAccount: category.vendorKey)
    }

    private var defaultEndpoint: String {
        category.defaultBaseURL ?? ProviderDefaults.baseURLString(for: category.apiProvider)
    }

    private var keyHint: String {
        switch category {
        case .huggingFace:
            return "hf_…"
        case .anthropic:
            return "sk-ant-…"
        case .openAI:
            return "sk-…"
        case .google:
            return "AIza…"
        case .openRouter:
            return "sk-or-…"
        default:
            return "API Key"
        }
    }

    private var transportWarning: String? {
        let trimmed = endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return EndpointTransportSecurity.warning(
            for: EndpointTransportSecurity.evaluate(
                baseURL: trimmed,
                apiKey: apiKeyDraft
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: category.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 40, height: 40)
                    .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title + " Configuration")
                        .font(theme.fontHeadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Stored securely in macOS Keychain across the app lifetime.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                TactileIconButton(icon: "xmark", tooltip: "Close", size: .compact) {
                    dismiss()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Form Body
            VStack(alignment: .leading, spacing: 14) {
                // 1. API Key Input
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("API Key / Access Token")
                            .font(theme.fontFootnote.weight(.medium))
                            .foregroundColor(theme.primaryText)

                        Spacer()

                        if let existing = existingKey, !existing.isEmpty {
                            Text("Current: \(AppProviderKeyStore.mask(existing))")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    // Secret input field
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .accessibilityHidden(true)

                        if isKeyVisible {
                            TextField(
                                "",
                                text: $apiKeyDraft,
                                prompt: Text("Enter \(keyHint)").foregroundColor(theme.placeholderText)
                            )
                            .textFieldStyle(.plain)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.primaryText)
                            .disableAutocorrection(true)
                        } else {
                            SecureField(
                                "",
                                text: $apiKeyDraft,
                                prompt: Text("Enter \(keyHint)").foregroundColor(theme.placeholderText)
                            )
                            .textFieldStyle(.plain)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.primaryText)
                            .disableAutocorrection(true)
                        }

                        if !apiKeyDraft.isEmpty {
                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor(enabled: true)
                            .help(isKeyVisible ? "Hide Key" : "Show Key")

                            Button {
                                apiKeyDraft = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor(enabled: true)
                            .help("Clear Key")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                    )
                }

                // 2. API Endpoint Input (Optional Gateway / Proxy Override)
                VStack(alignment: .leading, spacing: 5) {
                    if category == .custom {
                        HStack(spacing: 6) {
                            Text("Presets:")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)

                            ForEach(CompatibleEndpointPreset.all) { preset in
                                let current = endpointDraft.isEmpty ? defaultEndpoint : endpointDraft
                                let isSelected = CompatibleEndpointPreset.matching(current)?.id == preset.id
                                TactileButton(
                                    title: LocalizedStringKey(preset.name),
                                    variant: isSelected ? .primary : .secondary,
                                    size: .compact
                                ) {
                                    endpointDraft = preset.url
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }

                    HStack {
                        Text(category == .custom ? "Gateway Base URL" : "API Endpoint (Optional)")
                            .font(theme.fontFootnote.weight(.medium))
                            .foregroundColor(theme.primaryText)

                        Spacer()

                        let trimmed = endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && trimmed != defaultEndpoint {
                            TactileButton(title: "Reset to Default", variant: .subtle, size: .compact) {
                                endpointDraft = ""
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .accessibilityHidden(true)

                        TextField(
                            "",
                            text: $endpointDraft,
                            prompt: Text(defaultEndpoint).foregroundColor(theme.placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.primaryText)
                        .disableAutocorrection(true)

                        if !endpointDraft.isEmpty {
                            Button {
                                endpointDraft = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor(enabled: true)
                            .help("Clear Endpoint")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                    )

                    Text("Leave empty to use official vendor endpoint: \(defaultEndpoint)")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                if let warning = transportWarning {
                    Label(warning, systemImage: "lock.open.trianglebadge.exclamationmark")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.errorColor)
                }

                // Security Advisory Box
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 15))
                        .foregroundColor(theme.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("One-Time Setup")
                            .font(theme.fontCaption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Once saved, this key and endpoint will be used across all profiles without asking again.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.5))

                Spacer()

                // Actions Footer
                HStack {
                    if existingKey != nil {
                        TactileButton(title: "Remove Key", icon: "trash", variant: .destructive, size: .regular) {
                            AppProviderKeyStore.delete(forAccount: category.vendorKey)
                            AppProviderKeyStore.deleteEndpoint(forAccount: category.vendorKey)
                            dismiss()
                        }
                    }

                    Spacer()

                    TactileButton(title: "Cancel", variant: .secondary, size: .regular) {
                        dismiss()
                    }

                    TactileButton(
                        title: category == .custom ? "Save Gateway" : "Save Key",
                        icon: "checkmark",
                        variant: .primary,
                        size: .regular,
                        isLoading: isSaving,
                        isDisabled: category == .custom ? false : apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        save()
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 440)
        .background(theme.primaryBackground)
        .onAppear {
            if let existing = existingKey {
                apiKeyDraft = existing
            }
            if let custom = AppProviderKeyStore.loadEndpoint(forAccount: category.vendorKey) {
                endpointDraft = custom
            } else if let initial = initialEndpoint, initial != defaultEndpoint {
                endpointDraft = initial
            }
        }
    }

    private func save() {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if category != .custom && trimmedKey.isEmpty {
            errorMessage = "Please enter a valid API key."
            return
        }

        let trimmedEndpoint = endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEndpoint: String?
        if trimmedEndpoint.isEmpty || (category != .custom && trimmedEndpoint == defaultEndpoint) {
            finalEndpoint = category == .custom ? defaultEndpoint : nil
        } else {
            finalEndpoint = trimmedEndpoint
        }

        isSaving = true
        var keySaved = true
        if !trimmedKey.isEmpty {
            keySaved = AppProviderKeyStore.save(trimmedKey, forAccount: category.vendorKey)
        } else if category == .custom {
            AppProviderKeyStore.delete(forAccount: category.vendorKey)
        }
        AppProviderKeyStore.saveEndpoint(finalEndpoint, forAccount: category.vendorKey)
        isSaving = false

        if keySaved {
            onKeySaved?(trimmedKey)
            onSaved?(trimmedKey, finalEndpoint)
            dismiss()
        } else {
            errorMessage = "Failed to save key to Keychain."
        }
    }
}
