// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AddMCPServerView.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Refactored on 30/04/26 for in-window stack navigation. Layout now mirrors
//  CreateScheduledTaskView / AgentConfigDetailView (DynamicIslandBar + SettingsCard
//  stack) and refined for Tactile Dark Glass guidelines with inline Diagnostics verification.
//

import SwiftUI

private let logger = DGLogger(category: "AddMCPServerView")

// MARK: - Local UI Models

private enum ConnectionType: String, CaseIterable, Identifiable {
    case localProcess = "Local Process"
    case remoteURL = "Remote URL"
    var id: Self { self }

    var icon: String {
        switch self {
        case .localProcess: return "terminal.fill"
        case .remoteURL: return "network"
        }
    }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .localProcess: return "Local Process"
        case .remoteURL:    return "Remote URL"
        }
    }
}

private struct KeyValueItem: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// User-facing auth picker. Maps onto `MCPAuthenticationScheme` at save time.
/// `oauth` is shown but disabled until Phase 2 lands the full client.
private enum AuthFormScheme: String, CaseIterable, Identifiable, Hashable {
    case none = "None"
    case bearer = "Bearer"
    case apiKeyHeader = "API Key"
    case oauth = "OAuth"

    var id: Self { self }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so the picker's segment titles were
    /// invisible to the String Catalog extractor. `rawValue` stays for identity/logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .none:         return "None"
        case .bearer:       return "Bearer"
        case .apiKeyHeader: return "API Key"
        case .oauth:        return "OAuth"
        }
    }
}

private struct ServerConfigFormData: Hashable {
    var serverName: String = ""
    var connectionType: ConnectionType = .localProcess

    // Local
    var command: String = ""
    var arguments: String = ""
    var environmentVariables: [KeyValueItem] = [KeyValueItem()]

    // Remote
    var url: String = ""
    var authScheme: AuthFormScheme = .none
    /// Remote transport. Ignored for local-process servers, which are always stdio.
    var transport: MCPTransportMode = .streamableHTTP
    var authSecret: String = ""              // bearer token or API key value

    /// Scopes whose stored secret could not be READ when this form was hydrated. Register KC-1.
    ///
    /// ⚠️ NOT the same as "empty". An empty field means the user has no secret configured; a scope
    /// in here means one exists and we could not look at it, so the blank field on screen is a lie.
    /// The persistence layer refuses to delete these regardless (`MCPSecretStore.clear`); this set
    /// exists so the UI stops telling the user the secret is gone.
    var unreadableScopes: Set<String> = []
    var apiKeyHeaderName: String = "X-API-Key"

    // OAuth
    /// Issuer URL for OAuth (the auth server, not the MCP server). When the
    /// MCP server's `url` advertises OAuth via `.well-known`, we auto-fill
    /// this with `url`'s host root.
    var oauthIssuer: String = ""
    /// Space-separated scope list to request. Free-form so users can paste
    /// what their provider docs ask for.
    var oauthScopes: String = ""
}

private enum ConfigMode: String, CaseIterable, Identifiable {
    case wizard = "Visual"
    case json = "JSON"

    var id: Self { self }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so the segment titles were invisible to
    /// the String Catalog extractor. `rawValue` stays for identity/logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .wizard: return "Visual"
        case .json:   return "JSON"
        }
    }
}

// MARK: - Reusable Tactile Controls

private struct TactileSegmentedControl<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let labelFor: (T) -> (title: LocalizedStringKey, icon: String?)
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let isSelected = selection == item
                let info = labelFor(item)
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = info.icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(info.title)
                            .font(theme.fontFootnote.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? theme.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct TactileFormField: View {
    let label: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false
    var isRequired: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                if isRequired {
                    Text("*")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.accentColor)
                }
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(isMonospaced ? theme.fontCode : theme.fontFootnote)
                        .foregroundColor(theme.placeholderText)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }

                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(isMonospaced ? theme.fontCode : theme.fontFootnote)
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
            )

            if let caption {
                Text(caption)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TactileSecretFormField: View {
    let label: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    let placeholder: String
    @Binding var text: String
    var isConnected: Bool = false
    @State private var isRevealed: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(theme.fontFootnote.weight(.semibold))
                .foregroundColor(theme.primaryText)

            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .accessibilityHidden(true)

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(theme.fontCode)
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    if isRevealed {
                        TextField("", text: $text)
                            .textFieldStyle(.plain)
                            .font(theme.fontCode)
                            .foregroundColor(theme.primaryText)
                            .disabled(isConnected)
                    } else {
                        SecureField("", text: $text)
                            .textFieldStyle(.plain)
                            .font(theme.fontCode)
                            .foregroundColor(theme.primaryText)
                            .disabled(isConnected)
                    }
                }

                if !text.isEmpty && !isConnected {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "Hide value" : "Show value")

                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Clear value")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
            )

            if let caption {
                Text(caption)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Main View

struct AddMCPServerView: View {
    @Environment(\.appTheme) private var theme

    // Edit Mode Properties
    var existingSource: ToolSource? = nil

    /// Save callback for "Add to Library". Last param is the OAuth credential
    /// bundle when scheme = `.oauth` (otherwise nil). The outcome tells a
    /// duplicate from a failed save (register KC-5), so the form never
    /// dismisses over a sign-in that was not stored.
    var onToolAdded: ((String, ServerDefinition, MCPRuntimeSecrets, [ToolDefinition], MCPOAuthCredentialBundle?) -> MCPAddOutcome)?
    var onToolUpdated: ((UUID, String, ServerDefinition, MCPRuntimeSecrets, [ToolDefinition]) -> Void)? = nil

    /// Returns the user to the previous route when a save completes or the
    /// user cancels. Injected by `AddMCPServerContainerView`, which calls
    /// `router.goBack()`.
    var onDismiss: (() -> Void)?

    // MARK: - State

    @State private var formData = ServerConfigFormData()
    @State private var configInput: String = ""
    @State private var configMode: ConfigMode = .wizard

    // Connection State
    @State private var isConnecting = false
    @State private var activeError: MCPUserError? = nil
    @State private var discoveredTools: [ToolDefinition]? = nil
    @State private var verifiedConfig: ServerDefinition? = nil
    @State private var tempSourceId: UUID = UUID()

    /// Handle to the in-flight `testConnection` Task so we can cancel it on dismiss.
    /// Without this, leaving the view mid-handshake leaves the child process running
    /// and the session registered under `tempSourceId` with no UI to manage it.
    @State private var connectTask: Task<Void, Never>? = nil

    @State private var isShowingDuplicateAlert = false
    /// Confirms saving an existing server whose configuration has not been test-connected.
    @State private var isShowingUnverifiedSaveAlert = false
    @State private var isJSONValid = true

    // OAuth state (form-session only; bundle is committed to Keychain at save).
    @State private var oauthBundle: MCPOAuthCredentialBundle? = nil
    @State private var isSigningIn: Bool = false
    @State private var oauthError: String? = nil
    @State private var oauthTask: Task<Void, Never>? = nil

    private var isEditing: Bool { existingSource != nil }

    /// True once a Test Connection has succeeded for the current form values.
    /// Drives whether the trailing Save pill is enabled and whether the floating
    /// FAB shows a play icon vs. its post-success affordance.
    private var hasVerifiedConnection: Bool { discoveredTools != nil && verifiedConfig != nil }

    /// An EXISTING server may be saved without a live connection, provided the form is
    /// structurally complete. See the Save button for why.
    private var canSaveUnverified: Bool {
        guard isEditing else { return false }
        guard !formData.serverName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch formData.connectionType {
        case .localProcess:
            return !formData.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .remoteURL:
            let url = formData.url.trimmingCharacters(in: .whitespaces)
            return !url.isEmpty && URL(string: url)?.scheme != nil
        }
    }

    /// True when the name collides with a different server. Adding always checked this;
    /// renaming did not, so an edit could produce two servers sharing a name — and that
    /// name is the user's only handle on a server in the sidebar, in tool categories, and
    /// in every log line.
    private var isNameConflicting: Bool {
        UnifiedToolStore.shared.isServerNameTaken(formData.serverName, excluding: existingSource?.id)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(
                title: isEditing ? "Edit MCP Server" : "Add MCP Server",
                icon: "server.rack",
                onBack: { onDismiss?() }
            ) {
                trailingActionButtons
            }

            ScrollView {
                VStack(spacing: 24) {
                    identityHeader

                    transportAndModeRow

                    if configMode == .wizard {
                        if formData.connectionType == .localProcess {
                            SettingsCard(title: "Local Process", icon: "terminal.fill", theme: theme) {
                                localProcessCard
                                    .padding(16)
                            }

                            SettingsCard(
                                title: "Environment Variables",
                                icon: "list.bullet.rectangle.portrait.fill",
                                theme: theme
                            ) {
                                environmentVariablesCard
                                    .padding(16)
                            }
                        } else {
                            SettingsCard(title: "Remote Connection", icon: "network", theme: theme) {
                                remoteConnectionCard
                                    .padding(16)
                            }
                        }
                    } else {
                        SettingsCard(title: "Configuration JSON", icon: "doc.text", theme: theme) {
                            jsonEditorCard
                                .padding(16)
                        }
                    }

                    SettingsCard(title: "Diagnostics & Verification", icon: "stethoscope", theme: theme) {
                        diagnosticsCard
                            .padding(16)
                    }
                }
                .padding(ViewLayout.containerPadding)
                .padding(.bottom, ViewLayout.containerPadding)
                .frame(maxWidth: ViewLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Duplicate Server", isPresented: $isShowingDuplicateAlert) {
            Button("OK") { }
        } message: {
            Text("A tool with this server name already exists in your library.")
        }
        .alert("Save without testing?", isPresented: $isShowingUnverifiedSaveAlert) {
            Button("Save Anyway") { saveAndDismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This configuration hasn't been verified. Devgentic will keep the \(existingSource?.tools.count ?? 0) tool(s) it already knows about and try to connect on next use.\n\nUse this to fix a server that is currently unreachable or misconfigured.")
        }
        .task { setupView() }
        .onDisappear {
            // Cancel any in-flight connect first. Cancellation propagates through
            // `Task.sleep` and `withTimeout`'s task group inside MCPClientService.connect,
            // which lands in its catch block and tears down the shell process.
            // Then we wait for that task to fully unwind before calling disconnect —
            // this covers the narrow window where the session may have just been
            // registered in `activeSessions` immediately before cancellation.
            let inflight = connectTask
            connectTask = nil
            // Also abort any in-flight OAuth flow. The browser tab will redirect
            // to a now-dead loopback listener and the user sees a connection-
            // refused page — acceptable; the alternative is leaving the listener
            // bound for 5 minutes after the form closes.
            oauthTask?.cancel()
            oauthTask = nil
            Task {
                inflight?.cancel()
                _ = await inflight?.value
                await MCPClientService.shared.disconnect(sourceId: tempSourceId)
            }
        }
    }

    // MARK: - Identity Header

    /// Server name doubles as the page title — matches the CreateScheduledTaskView
    /// pattern where the user-typed name is the H1 of the form. Saves a full
    /// "Server Identity" card with a labelled "Server Name" field.
    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                Image(systemName: isEditing ? "pencil.and.outline" : "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 44, height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("SERVER IDENTIFIER")
                        .font(theme.fontCodeCaption.weight(.bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.6)

                    if isNameConflicting {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("Name already taken")
                                .font(theme.fontCaption2)
                        }
                        .foregroundColor(theme.warningColor)
                    }
                }

                ZStack(alignment: .leading) {
                    if formData.serverName.isEmpty {
                        Text("e.g. github-server, filesystem-tools")
                            .font(theme.fontFootnote)
                            .foregroundColor(theme.placeholderText)
                            .padding(.horizontal, 10)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $formData.serverName)
                        .textFieldStyle(.plain)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Server name")
                }
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isNameConflicting ? theme.warningColor.opacity(0.6) : theme.dividerColor.opacity(0.35), lineWidth: 1)
                )

                Text("Model Context Protocol — local stdio process or remote HTTP/SSE endpoint.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }

            Spacer(minLength: 8)
        }
        .onChange(of: formData) { _, _ in
            invalidateVerifiedState()
            generateJSON()
        }
        .onChange(of: configMode) { _, _ in
            generateJSON()
        }
    }

    // MARK: - Transport & Mode Row

    /// Two tactile segmented controls inline above the dynamic content. They drive
    /// what's rendered below (transport → local-process vs remote card;
    /// mode → visual cards vs JSON editor) with clean glass pills rather than
    /// saturated native accent tabs.
    private var transportAndModeRow: some View {
        HStack(alignment: .top, spacing: 16) {
            controlColumn(label: "TRANSPORT") {
                TactileSegmentedControl(
                    items: ConnectionType.allCases,
                    selection: $formData.connectionType
                ) { type in
                    (title: type.localizedTitle, icon: type.icon)
                }
            }

            controlColumn(label: "CONFIG MODE") {
                TactileSegmentedControl(
                    items: ConfigMode.allCases,
                    selection: $configMode
                ) { mode in
                    (title: mode.localizedTitle, icon: mode == .wizard ? "slider.horizontal.3" : "doc.text")
                }
            }
        }
    }

    private func controlColumn<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(theme.fontCodeCaption.weight(.bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cards

    private var localProcessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            TactileFormField(
                label: "Executable Command",
                caption: "Must be available on your PATH or provided as an absolute path.",
                placeholder: "e.g. npx, uvx, python3, or /usr/local/bin/server",
                text: $formData.command,
                isMonospaced: true,
                isRequired: true
            )

            TactileFormField(
                label: "Arguments",
                caption: "Space-separated arguments passed to the executable. Quotes are preserved.",
                placeholder: "e.g. -y @modelcontextprotocol/server-filesystem /Users/username/Desktop",
                text: $formData.arguments,
                isMonospaced: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var environmentVariablesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Environment variables are passed to the child process at launch and stored securely in macOS Keychain.")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)

            if formData.environmentVariables.isEmpty {
                Text("No environment variables configured.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText.opacity(0.6))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach($formData.environmentVariables) { $item in
                        HStack(spacing: 8) {
                            ZStack(alignment: .leading) {
                                if item.key.isEmpty {
                                    Text("e.g. API_KEY")
                                        .font(theme.fontCode)
                                        .foregroundColor(theme.placeholderText)
                                        .padding(.horizontal, 10)
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $item.key)
                                    .textFieldStyle(.plain)
                                    .font(theme.fontCode)
                                    .foregroundColor(theme.primaryText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                            }
                            .frame(width: 180)
                            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
                            )

                            Text("=")
                                .font(theme.fontCode.weight(.bold))
                                .foregroundColor(theme.secondaryText)

                            ZStack(alignment: .leading) {
                                if item.value.isEmpty {
                                    Text("e.g. secret_token_value")
                                        .font(theme.fontCode)
                                        .foregroundColor(theme.placeholderText)
                                        .padding(.horizontal, 10)
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $item.value)
                                    .textFieldStyle(.plain)
                                    .font(theme.fontCode)
                                    .foregroundColor(theme.primaryText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                            }
                            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
                            )

                            TactileIconButton(
                                icon: "trash",
                                tooltip: "Remove variable",
                                accessibilityLabel: "Remove variable",
                                variant: .subtle,
                                size: 28
                            ) {
                                formData.environmentVariables.removeAll { $0.id == item.id }
                            }
                        }
                    }
                }
            }

            TactileButton(
                title: "Add Variable",
                icon: "plus",
                variant: .secondary,
                size: .compact
            ) {
                formData.environmentVariables.append(KeyValueItem())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remoteConnectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            TactileFormField(
                label: "Server URL",
                caption: "HTTPS is enforced when an auth scheme is set. localhost is allowed for development.",
                placeholder: "e.g. https://api.example.com/mcp",
                text: $formData.url,
                isMonospaced: true,
                isRequired: true
            )

            // Transport picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Transport")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                TactileSegmentedControl(
                    items: MCPTransportMode.allCases,
                    selection: $formData.transport
                ) { mode in
                    (title: mode == .streamableHTTP ? "Streamable HTTP (SSE)" : "HTTP (No Streaming)",
                     icon: mode == .streamableHTTP ? "antenna.radiowaves.left.and.right" : "arrow.up.arrow.down")
                }
                .onChange(of: formData.transport) { _, _ in
                    invalidateVerifiedState()
                }

                Text(formData.transport.explanation)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Auth scheme picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                TactileSegmentedControl(
                    items: AuthFormScheme.allCases,
                    selection: $formData.authScheme
                ) { scheme in
                    (title: scheme.localizedTitle, icon: nil)
                }
                .onChange(of: formData.authScheme) { _, newValue in
                    if newValue != .oauth {
                        oauthBundle = nil
                        oauthError = nil
                    }
                    if newValue == .oauth, formData.oauthIssuer.isEmpty {
                        if let parsed = URLComponents(string: formData.url),
                           let scheme = parsed.scheme,
                           let host = parsed.host {
                            var rebuilt = URLComponents()
                            rebuilt.scheme = scheme
                            rebuilt.host = host
                            rebuilt.port = parsed.port
                            formData.oauthIssuer = rebuilt.url?.absoluteString ?? ""
                        }
                    }
                }
            }

            // Per-scheme secret fields
            switch formData.authScheme {
            case .none:
                EmptyView()

            case .bearer:
                TactileSecretFormField(
                    label: "Bearer Token",
                    caption: formData.unreadableScopes.contains(MCPSecretScope.bearerToken.rawScope) ? nil : "Stored in macOS Keychain. Sent as `Authorization: Bearer <token>`.",
                    placeholder: "e.g. bearer_token_abc123",
                    text: $formData.authSecret
                )
                if formData.unreadableScopes.contains(MCPSecretScope.bearerToken.rawScope) {
                    unreadableSecretNotice
                }

            case .apiKeyHeader:
                HStack(alignment: .top, spacing: 12) {
                    TactileFormField(
                        label: "Header Name",
                        placeholder: "e.g. X-API-Key",
                        text: $formData.apiKeyHeaderName,
                        isMonospaced: true
                    )
                    .frame(width: 180)

                    TactileSecretFormField(
                        label: "Header Value",
                        placeholder: "e.g. api_key_value",
                        text: $formData.authSecret
                    )
                }
                if formData.unreadableScopes.contains(MCPSecretScope.apiKeyHeaderValue.rawScope) {
                    unreadableSecretNotice
                }

            case .oauth:
                oauthSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown in place of the usual caption when a stored secret could not be READ. Register KC-1.
    @ViewBuilder
    private var unreadableSecretNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text("A secret is stored for this server but the Keychain could not be read, so this "
                 + "field is blank. Nothing has been lost. Leave it empty and save to keep the "
                 + "stored value; unlock your Keychain (or re-grant access after an app update) to "
                 + "see or change it.")
                .font(theme.fontCaption2)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .foregroundColor(theme.warningColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - OAuth Section

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TactileFormField(
                label: "Issuer URL",
                caption: "Authorization-server root. We probe \(formData.oauthIssuer.isEmpty ? "<issuer>" : formData.oauthIssuer)/.well-known/oauth-authorization-server.",
                placeholder: "e.g. https://auth.example.com",
                text: $formData.oauthIssuer,
                isMonospaced: true
            )
            .disabled(isSigningIn || oauthBundle != nil)

            TactileFormField(
                label: "Scopes (Optional)",
                caption: "Space-separated scopes requested from provider.",
                placeholder: "e.g. mcp:tools profile email",
                text: $formData.oauthScopes,
                isMonospaced: true
            )
            .disabled(isSigningIn || oauthBundle != nil)

            // Status row + action button
            HStack(spacing: 12) {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                } else if let bundle = oauthBundle {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in to \(bundle.issuer.host ?? bundle.issuer.absoluteString)")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Scopes: \(bundle.grantedScopes.isEmpty ? "—" : bundle.grantedScopes.joined(separator: " "))")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.tertiaryText)
                    }
                } else if let oauthError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.warningColor)
                    Text(oauthError)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.warningColor)
                        .lineLimit(2)
                } else {
                    Image(systemName: "lock.shield")
                        .foregroundColor(theme.secondaryText)
                    Text("Authorize via system browser.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                TactileButton(
                    title: oauthBundle == nil ? "Sign In" : "Re-authenticate",
                    icon: oauthBundle == nil ? "person.badge.key" : "arrow.clockwise",
                    variant: .primary,
                    size: .compact,
                    isEnabled: canStartOAuth && !isSigningIn
                ) {
                    if oauthBundle != nil {
                        oauthBundle = nil
                        oauthError = nil
                    }
                    triggerOAuthSignIn()
                }
            }
            .padding(.top, 4)
        }
    }

    private var canStartOAuth: Bool {
        guard URL(string: formData.oauthIssuer.trimmingCharacters(in: .whitespaces)) != nil else { return false }
        return !formData.oauthIssuer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func triggerOAuthSignIn() {
        guard let issuer = URL(string: formData.oauthIssuer.trimmingCharacters(in: .whitespaces)) else {
            oauthError = "Invalid issuer URL."
            return
        }

        isSigningIn = true
        oauthError = nil
        oauthTask?.cancel()
        oauthTask = Task { @MainActor in
            do {
                let scopes = formData.oauthScopes
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.isEmpty }
                let bundle = try await MCPOAuthCoordinator.performInitialAuthorizationWithLoopback(
                    issuer: issuer,
                    scopes: scopes,
                    clientName: "Devgentic — \(formData.serverName.isEmpty ? "MCP" : formData.serverName)",
                    // RFC 8707: the MCP server itself is the resource these tokens are for.
                    // Binding the audience here is what stops a token minted for this server
                    // being replayed against another resource on the same issuer.
                    resource: URL(string: formData.url.trimmingCharacters(in: .whitespaces)),
                    // Register KC-14: the bundle records WHICH URL the form held at sign-in
                    // time. `MCPOAuthBinding` enforces the match at attach, persist and save,
                    // so a URL edited after this moment cannot inherit these tokens.
                    serverURL: URL(string: formData.url.trimmingCharacters(in: .whitespaces))
                )
                try Task.checkCancellation()
                self.oauthBundle = bundle
                self.isSigningIn = false
                // Force the test/save flow to re-verify with the new token.
                self.invalidateVerifiedState()
            } catch is CancellationError {
                self.isSigningIn = false
            } catch {
                self.oauthError = error.localizedDescription
                self.isSigningIn = false
            }
        }
    }

    private var jsonEditorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $configInput)
                .font(theme.fontCode)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(theme.primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isJSONValid ? theme.dividerColor.opacity(0.35) : theme.errorColor,
                            lineWidth: 1
                        )
                )
                .frame(minHeight: 240)
                .onChange(of: configInput) { _, _ in
                    parseJSONAndUpdateForm()
                }

            HStack(spacing: 6) {
                Image(systemName: isJSONValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isJSONValid ? "Valid JSON configuration" : "Invalid JSON syntax")
                    .font(theme.fontCaption2.weight(.medium))
            }
            .foregroundColor(isJSONValid ? theme.successColor : theme.errorColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsCard: some View {
        if isConnecting {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                    ProgressView().controlSize(.small)
                }
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connecting to MCP server…")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Running handshake and probing tool capabilities.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                TactileButton(title: "Cancel", icon: "xmark", variant: .subtle, size: .compact) {
                    connectTask?.cancel()
                    connectTask = nil
                    isConnecting = false
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = activeError {
            VStack(alignment: .leading, spacing: 14) {
                errorContent(error)
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
                HStack {
                    Spacer()
                    TactileButton(
                        title: "Retry Connection",
                        icon: "arrow.clockwise",
                        variant: .primary,
                        size: .compact,
                        isEnabled: canTestConnection
                    ) {
                        testConnection()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let tools = discoveredTools {
            VStack(alignment: .leading, spacing: 14) {
                successContent(tools: tools)
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
                HStack {
                    Text("Configuration verified and ready to save.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    TactileButton(
                        title: "Re-test",
                        icon: "arrow.clockwise",
                        variant: .secondary,
                        size: .compact,
                        isEnabled: canTestConnection
                    ) {
                        testConnection()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                    Image(systemName: "stethoscope")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Handshake Not Verified")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Run a connection test to verify executable arguments or endpoint reachability before adding to your library.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2)
                }

                Spacer(minLength: 16)

                TactileButton(
                    title: "Test Connection",
                    icon: "play.fill",
                    variant: .primary,
                    size: .compact,
                    isEnabled: canTestConnection,
                    tooltip: canTestConnection ? "Test server handshake (⌘↵)" : "Fill required fields to test connection"
                ) {
                    testConnection()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorContent(_ error: MCPUserError) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.warningColor.opacity(0.12))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.warningColor)
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.warningColor.opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(error.title)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(error.message)
                    .font(theme.fontFootnote)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                HStack(alignment: .top, spacing: 6) {
                    Text("Remediation:")
                        .font(theme.fontCaption2.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    Text(error.suggestion)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                if let raw = error.rawLog {
                    DisclosureGroup("Raw diagnostic log") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(raw)
                                .font(theme.fontCodeCaption)
                                .padding(8)
                                .foregroundColor(theme.primaryText)
                        }
                        .background(theme.primaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func successContent(tools: [ToolDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.successColor.opacity(0.12))
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.successColor)
                }
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.successColor.opacity(0.25), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection Verified")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Handshake succeeded. Server is responding normally.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s") discovered")
                    .font(theme.fontCaption2.weight(.semibold))
                    .foregroundColor(theme.successColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(theme.successColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(theme.successColor.opacity(0.25), lineWidth: 0.5)
                    )
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            Text("DISCOVERED CAPABILITIES")
                .font(theme.fontCodeCaption.weight(.bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(tools.prefix(12), id: \.name) { tool in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.accentColor.opacity(0.7))
                            .frame(width: 5, height: 5)
                        Text(tool.name)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.primaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 1)
                    )
                }
                if tools.count > 12 {
                    Text("+\(tools.count - 12) more")
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trailing Island Actions

    private var trailingActionButtons: some View {
        HStack(spacing: 8) {
            IslandPillButton(
                title: isEditing ? "Save Changes" : "Add to Library",
                icon: isEditing ? "checkmark" : "plus",
                style: .primary,
                help: hasVerifiedConnection || canSaveUnverified ? nil : "Test connection before adding to library",
                accessibilityLabel: isEditing ? "Save changes" : "Add server to library",
                keyboardShortcut: hasVerifiedConnection ? .defaultAction : nil
            ) {
                if hasVerifiedConnection {
                    saveAndDismiss()
                } else {
                    isShowingUnverifiedSaveAlert = true
                }
            }
            .disabled(!hasVerifiedConnection && !canSaveUnverified)
        }
    }

    private var canTestConnection: Bool {
        guard !formData.serverName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch formData.connectionType {
        case .localProcess:
            return !formData.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .remoteURL:
            return !formData.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Logic Implementation

    private func setupView() {
        if let source = existingSource, let def = source.serverDefinition {
            formData.serverName = source.serverName
            if let cmd = def.command {
                formData.connectionType = .localProcess
                formData.command = cmd
                // Quote-aware: a plain join here meant opening an existing server for edit
                // and pressing Save re-split any space-bearing argument into two, silently
                // corrupting a config the user never touched.
                formData.arguments = MCPArgumentTokenizer.join(def.args ?? [])
                // Materialize env values from Keychain so the form shows what
                // the user previously entered. Missing values come back as
                // empty strings — the user can retype if they want.
                if let keys = def.envKeys, !keys.isEmpty {
                    formData.environmentVariables = keys.map { key in
                        // ⚠️ `read`, not `retrieve` — a failed read must not render as an empty
                        // field the user would then save over. Register KC-1.
                        switch MCPSecretStore.shared.read(.envValue(key: key), sourceID: source.id) {
                        case .found(let value):
                            return KeyValueItem(key: key, value: value)
                        case .notFound:
                            return KeyValueItem(key: key, value: "")
                        case .failed:
                            formData.unreadableScopes.insert(MCPSecretScope.envValue(key: key).rawScope)
                            return KeyValueItem(key: key, value: "")
                        }
                    }
                } else {
                    formData.environmentVariables = [KeyValueItem()]
                }
            } else if let url = def.url {
                formData.connectionType = .remoteURL
                formData.url = url
                formData.transport = def.transport
                switch def.auth {
                case .none:
                    formData.authScheme = .none
                case .bearer:
                    formData.authScheme = .bearer
                    switch MCPSecretStore.shared.read(.bearerToken, sourceID: source.id) {
                    case .found(let value): formData.authSecret = value
                    case .notFound:         formData.authSecret = ""
                    case .failed:
                        // Register KC-1: leave the field blank but REMEMBER why, so the
                        // UI can say "unreadable" instead of implying "not set".
                        formData.authSecret = ""
                        formData.unreadableScopes.insert(MCPSecretScope.bearerToken.rawScope)
                    }
                case .apiKeyHeader(let headerName):
                    formData.authScheme = .apiKeyHeader
                    formData.apiKeyHeaderName = headerName
                    switch MCPSecretStore.shared.read(.apiKeyHeaderValue, sourceID: source.id) {
                    case .found(let value): formData.authSecret = value
                    case .notFound:         formData.authSecret = ""
                    case .failed:
                        // Register KC-1: leave the field blank but REMEMBER why, so the
                        // UI can say "unreadable" instead of implying "not set".
                        formData.authSecret = ""
                        formData.unreadableScopes.insert(MCPSecretScope.apiKeyHeaderValue.rawScope)
                    }
                case .oauth(let issuer):
                    formData.authScheme = .oauth
                    formData.oauthIssuer = issuer.absoluteString
                    // Hydrate the in-memory bundle so the form shows the
                    // current "Signed in as …" state and lets the user
                    // re-auth or change scheme without retyping the issuer.
                    if let existingBundle = MCPOAuthCoordinator.loadBundle(sourceID: source.id) {
                        self.oauthBundle = existingBundle
                        formData.oauthScopes = existingBundle.grantedScopes.joined(separator: " ")
                    }
                }
            }
            generateJSON()
        } else {
            generateJSON()
        }
    }

    private func testConnection() {
        guard let config = buildServerDefinition() else {
            activeError = MCPUserError(
                title: "Invalid Configuration",
                message: "The server definition is incomplete.",
                suggestion: "Please check that all required fields are filled out.",
                rawLog: nil
            )
            return
        }

        let secrets = buildRuntimeSecrets()

        isConnecting = true
        activeError = nil
        discoveredTools = nil
        verifiedConfig = nil

        connectTask?.cancel()
        connectTask = Task {
            do {
                let result = try await MCPClientService.shared.connect(
                    sourceId: tempSourceId,
                    config: config,
                    secrets: secrets
                )

                // If the user navigated away during the handshake, bail before
                // touching @State. The onDisappear cleanup will still call disconnect.
                try Task.checkCancellation()

                await MainActor.run {
                    self.discoveredTools = result.tools
                    self.verifiedConfig = config
                    self.isConnecting = false
                }
            } catch is CancellationError {
                // Expected when the user leaves the route mid-connect.
                // MCPClientService.connect's catch block has already terminated the shell.
            } catch {
                await MainActor.run {
                    self.activeError = MCPErrorAnalyzer.analyze(error: error)
                    self.isConnecting = false
                }
            }
        }
    }

    private func saveAndDismiss() {
        // Renaming used to bypass the duplicate check that adding always performed, so an
        // edit could leave two servers sharing a name.
        guard !isNameConflicting else {
            logger.warning("""
                [MCP-CONFIG] Refused to save '\(formData.serverName)': another server already uses \
                that name. Nothing was written; the user is shown the duplicate alert.
                """)
            isShowingDuplicateAlert = true
            return
        }

        // Unverified save (existing servers only). Keep whatever tools we already know
        // about rather than blanking the server: the config may be being fixed precisely
        // BECAUSE the server is unreachable, and wiping its tools would break every profile
        // referencing them for no reason.
        let config: ServerDefinition
        let tools: [ToolDefinition]
        if let verified = verifiedConfig, let discovered = discoveredTools {
            config = verified
            tools = discovered
        } else if canSaveUnverified, let existing = existingSource, let built = buildServerDefinition() {
            config = built
            tools = existing.tools
            logger.info("""
                [MCP-CONFIG] Saving '\(formData.serverName)' (\(existing.id)) WITHOUT a verified \
                connection, at the user's confirmation. Retaining its \(tools.count) previously \
                known tool(s); the next connect attempt will reconcile them.
                """)
        } else {
            logger.error("[MCP-CONFIG] saveAndDismiss reached with no verified config and no unverified fallback — nothing saved.")
            return
        }

        let secrets = buildRuntimeSecrets()

        if let existing = existingSource, let onToolUpdated = onToolUpdated {
            // ⚠️ Register KC-14. The binding gate runs BEFORE the bundle persist below, so a
            // refusal leaves nothing half-written: the bundle that will be in effect after
            // this save must be bound to the URL being saved. A fresh sign-in binds to
            // whatever the URL field held at sign-in time; a stored bundle must still match.
            // `serverDefinition` is nil when the stored blob cannot be decoded, which the
            // gate treats as "previous binding unknown" and fails closed for a legacy stored
            // bundle (KC-37's lesson — never read an undecodable blob as "unchanged").
            switch MCPOAuthBinding.editDecision(
                isOAuth: config.auth.isOAuth,
                newURL: config.url,
                previousURL: existing.serverDefinition?.url,
                freshBundle: oauthBundle,
                storedRead: MCPSecretStore.shared.read(.oauthBundle, sourceID: existing.id)
            ) {
            case .proceed:
                break
            case .requiresReAuth(let error):
                logger.warning("""
                    [MCP-OAUTH] Refused to save '\(formData.serverName)' (\(existing.id)): the \
                    OAuth binding does not cover URL '\(MCPRedaction.redact(url: config.url ?? "—"))'. \
                    CONSEQUENCE: nothing was saved — no bundle was persisted and the row is \
                    untouched; the user is asked to re-authenticate against the new URL.
                    """)
                activeError = error
                return
            }
            // ⚠️ Register KC-5. A re-authenticated OAuth bundle is persisted BEFORE the update, so
            // a Keychain refusal is shown instead of swallowed by `try?` and nothing is
            // half-applied. An unchanged bundle (a plain rename) is not rewritten.
            do {
                try MCPServerAddFlow.persistIfChanged(
                    oauthBundle,
                    stored: MCPOAuthCoordinator.loadBundle(sourceID: existing.id),
                    sourceID: existing.id,
                    persist: { try MCPOAuthCoordinator.persist($0, sourceID: $1) }
                )
            } catch {
                logger.error("""
                    [MCP-OAUTH] Could not store the re-authenticated OAuth sign-in for \
                    '\(formData.serverName)' (\(existing.id)): \(error.localizedDescription). \
                    CONSEQUENCE: the edit was NOT applied and the user is shown the failure; the \
                    previously stored sign-in, if any, is untouched.
                    """)
                activeError = MCPUserError(
                    title: "Sign-in could not be saved",
                    message: "The new sign-in could not be written to the Keychain, so the changes were not saved.",
                    suggestion: "Unlock your login keychain (or allow Devgentic access if macOS asked), then press Save again — the sign-in you completed is still held by this form.",
                    rawLog: error.localizedDescription
                )
                return
            }
            onToolUpdated(existing.id, formData.serverName, config, secrets, tools)
            Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
            onDismiss?()
        } else if let onToolAdded = onToolAdded {
            // ⚠️ Register KC-14, add path. Same invariant as the edit gate: a fresh sign-in
            // must be bound to the URL being saved — the URL field may have been edited
            // AFTER the sign-in, and a bundle bound to the old one must not ride along.
            // Nothing is stored under the not-yet-chosen id, so the stored side cannot bind.
            switch MCPOAuthBinding.editDecision(
                isOAuth: config.auth.isOAuth,
                newURL: config.url,
                previousURL: nil,
                freshBundle: oauthBundle,
                storedRead: .notFound
            ) {
            case .proceed:
                break
            case .requiresReAuth(let error):
                activeError = error
                return
            }
            switch onToolAdded(formData.serverName, config, secrets, tools, oauthBundle) {
            case .added:
                Task { await MCPClientService.shared.disconnect(sourceId: tempSourceId) }
                onDismiss?()
            case .duplicate:
                isShowingDuplicateAlert = true
            case .failed(let error):
                // Register KC-5: stay on the form so the user sees what happened and can retry;
                // `oauthBundle` is still held, so a retry needs no second browser round trip.
                activeError = error
            }
        }
    }

    /// Build the persisted shape (no secrets inside) from form state.
    private func buildServerDefinition() -> ServerDefinition? {
        if formData.connectionType == .localProcess {
            // Quote-aware: a naive whitespace split broke every path containing a space.
            let args = MCPArgumentTokenizer.tokenize(formData.arguments)
            let envKeys = formData.environmentVariables
                .map { $0.key.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted()
            return ServerDefinition(
                command: formData.command,
                args: args,
                envKeys: envKeys.isEmpty ? nil : envKeys
            )
        } else {
            let auth: MCPAuthenticationScheme = {
                switch formData.authScheme {
                case .none: return .none
                case .bearer: return .bearer
                case .apiKeyHeader:
                    let name = formData.apiKeyHeaderName.trimmingCharacters(in: .whitespaces)
                    return .apiKeyHeader(headerName: name.isEmpty ? "X-API-Key" : name)
                case .oauth:
                    // Use the issuer the user actually signed in against —
                    // form-typed `oauthIssuer` may have been canonicalized by
                    // discovery, so prefer the bundle's issuer when present.
                    if let bundle = oauthBundle {
                        return .oauth(issuer: bundle.issuer)
                    }
                    if let url = URL(string: formData.oauthIssuer) {
                        return .oauth(issuer: url)
                    }
                    return .none
                }
            }()
            return ServerDefinition(url: formData.url, auth: auth, transport: formData.transport)
        }
    }

    /// Build the in-memory secrets bundle from form state. Used for the test
    /// connect (in-memory only) and again at save time (passed to the store
    /// which writes it to Keychain under the final source ID).
    private func buildRuntimeSecrets() -> MCPRuntimeSecrets {
        var bundle = MCPRuntimeSecrets()

        if formData.connectionType == .localProcess {
            for item in formData.environmentVariables {
                let key = item.key.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                bundle.env[key] = item.value
            }
        } else {
            switch formData.authScheme {
            case .none:
                break
            case .bearer:
                let token = formData.authSecret.trimmingCharacters(in: .whitespaces)
                if !token.isEmpty {
                    bundle.authorizationHeader = ("Authorization", "Bearer \(token)")
                }
            case .apiKeyHeader:
                let value = formData.authSecret
                let name = formData.apiKeyHeaderName.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    bundle.authorizationHeader = (name.isEmpty ? "X-API-Key" : name, value)
                }
            case .oauth:
                // For the in-memory test path we attach the access token as a
                // bearer header directly. The full bundle (refresh token,
                // expiry, registration metadata) is persisted to Keychain at
                // save time; until then `secrets` carries enough for connect.
                if let oauthBundle {
                    bundle.authorizationHeader = ("Authorization", "Bearer \(oauthBundle.accessToken)")
                }
            }
        }

        return bundle
    }

    /// Drops any prior verified state. Called whenever the form changes so the
    /// Save pill never fires with config that no longer matches what the user sees.
    private func invalidateVerifiedState() {
        guard hasVerifiedConnection || activeError != nil else { return }
        discoveredTools = nil
        verifiedConfig = nil
        activeError = nil
    }

    private func generateJSON() {
        let serverKey = formData.serverName.isEmpty ? "new-server" : formData.serverName
        guard let def = buildServerDefinition() else { return }
        let config = MCPConfiguration(mcpServers: [serverKey: def])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            self.configInput = String(data: data, encoding: .utf8) ?? ""
            self.isJSONValid = true
        }
    }

    private func parseJSONAndUpdateForm() {
        // Parsing lives in `MCPConfigPaste` so it can be tested: this is the one parse in the
        // subsystem that can silently discard credentials, and while it was a private method
        // on this view nothing could reach it. The view keeps only the form mapping.
        do {
            let parsed = try MCPConfigPaste.parse(configInput)
            let name = parsed.serverName
            let def = parsed.definition
            let sidecar = (env: parsed.envValues, headers: parsed.headers)

            var newForm = ServerConfigFormData()
            newForm.serverName = name
            if let cmd = def.command {
                newForm.connectionType = .localProcess
                newForm.command = cmd
                // Quote-aware join so an arg containing a space survives the round-trip.
                newForm.arguments = MCPArgumentTokenizer.join(def.args ?? [])

                // Prefer pasted env values; fall back to the key list with blank values
                // (the user fills them in, or existing Keychain values are reused).
                if !sidecar.env.isEmpty {
                    newForm.environmentVariables = sidecar.env
                        .sorted { $0.key < $1.key }
                        .map { KeyValueItem(key: $0.key, value: $0.value) }
                } else if let keys = def.envKeys, !keys.isEmpty {
                    newForm.environmentVariables = keys.map { KeyValueItem(key: $0, value: "") }
                } else {
                    newForm.environmentVariables = [KeyValueItem()]
                }
            } else if let url = def.url {
                newForm.connectionType = .remoteURL
                newForm.url = url
                newForm.transport = def.transport
                switch def.auth {
                case .none:
                    newForm.authScheme = .none
                case .bearer:
                    newForm.authScheme = .bearer
                case .apiKeyHeader(let headerName):
                    newForm.authScheme = .apiKeyHeader
                    newForm.apiKeyHeaderName = headerName
                case .oauth:
                    newForm.authScheme = .oauth
                }

                // A pasted `headers` map carrying an Authorization bearer is the other
                // common README shape. Map what we can represent; anything else is
                // reported by the parser rather than dropped in silence.
                if let bearer = parsed.inferredBearerToken {
                    newForm.authScheme = .bearer
                    newForm.authSecret = bearer
                }
            }

            self.formData = newForm
            isJSONValid = true
        } catch {
            logger.warning("[MCP-CONFIG] Pasted configuration rejected: \(error.localizedDescription)")
            isJSONValid = false
        }
    }
}
