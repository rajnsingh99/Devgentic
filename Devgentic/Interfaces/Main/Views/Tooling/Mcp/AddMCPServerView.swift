// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AddMCPServerView.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Refactored on 30/04/26 for in-window stack navigation. Layout now mirrors
//  CreateScheduledTaskView / AgentConfigDetailView (DynamicIslandBar + SettingsCard
//  stack) and the Test Connection control moved out of the bottom footer into a
//  floating bottom-right FAB.
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

private enum ConfigMode: String, CaseIterable {
    case wizard = "Visual"
    case json = "JSON"

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
                            }

                            SettingsCard(
                                title: "Environment Variables",
                                icon: "list.bullet.rectangle.portrait.fill",
                                theme: theme
                            ) {
                                environmentVariablesCard
                            }
                        } else {
                            SettingsCard(title: "Remote Connection", icon: "network", theme: theme) {
                                remoteConnectionCard
                            }
                        }
                    } else {
                        SettingsCard(title: "Configuration JSON", icon: "doc.text", theme: theme) {
                            jsonEditorCard
                        }
                    }

                    SettingsCard(title: "Diagnostics", icon: "stethoscope", theme: theme) {
                        diagnosticsCard
                    }
                }
                .padding(ViewLayout.containerPadding)
                // Reserve space for the floating FAB so it never covers the
                // bottom of the diagnostics card on short windows.
                .padding(.bottom, 96)
                .frame(maxWidth: ViewLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            floatingTestButton
                .padding(.trailing, 28)
                .padding(.bottom, 24)
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
            Image(systemName: isEditing ? "pencil.and.outline" : "server.rack")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .foregroundColor(theme.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    isEditing ? "Server name" : "Name your server (e.g. github, brave, filesystem)",
                    text: $formData.serverName
                )
                .font(theme.fontTitle2)
                .fontWeight(.bold)
                .textFieldStyle(.plain)
                .foregroundColor(theme.primaryText)
                .accessibilityLabel("Server name")

                Text("Model Context Protocol — local process or remote endpoint.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
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

    /// Two segmented controls inline above the dynamic content. They drive
    /// what's rendered below (transport → local-process vs remote card;
    /// mode → visual cards vs JSON editor) so they read as tabs rather than
    /// first-class settings. No card wrapper — keeps the meta-controls
    /// visually distinct from the configuration sections.
    private var transportAndModeRow: some View {
        HStack(alignment: .top, spacing: 16) {
            controlColumn(label: "TRANSPORT") {
                Picker("", selection: $formData.connectionType) {
                    ForEach(ConnectionType.allCases) { type in
                        Label(type.localizedTitle, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            controlColumn(label: "CONFIG MODE") {
                Picker("", selection: $configMode) {
                    ForEach(ConfigMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func controlColumn<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cards

    private var localProcessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Executable Command")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                TextField("e.g. 'npx', 'uvx', 'python3'…", text: $formData.command)
                    .textFieldStyle(.roundedBorder)
                Text("Must be on PATH or an absolute path.")
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                TextField("-y @modelcontextprotocol/server-filesystem /Users/…", text: $formData.arguments)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var environmentVariablesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($formData.environmentVariables) { $item in
                HStack(spacing: 8) {
                    TextField("KEY", text: $item.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                    Text("=")
                        .font(theme.fontBody)
                        .foregroundColor(theme.tertiaryText)

                    TextField("VALUE", text: $item.value)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        formData.environmentVariables.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove variable")
                }
            }

            Button {
                formData.environmentVariables.append(KeyValueItem())
            } label: {
                Label("Add Variable", systemImage: "plus")
                    .font(theme.fontCaption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remoteConnectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                TextField("https://… or http://localhost…", text: $formData.url)
                    .textFieldStyle(.roundedBorder)
                Text("HTTPS is enforced when an auth scheme is set. `localhost` is allowed for development.")
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
            }

            // Transport picker.
            //
            // Remote servers were always constructed with SSE streaming on. That is correct
            // for the Streamable HTTP standard, but a server that only implements POST just
            // failed to connect with nothing the user could do about it.
            VStack(alignment: .leading, spacing: 6) {
                Text("Transport")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                Picker("", selection: $formData.transport) {
                    ForEach(MCPTransportMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: formData.transport) { _, _ in
                    // The transport determines how we connect, so a prior successful test
                    // says nothing about the new one.
                    invalidateVerifiedState()
                }
                Text(formData.transport.explanation)
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Auth scheme picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Authentication")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                Picker("", selection: $formData.authScheme) {
                    ForEach(AuthFormScheme.allCases) { scheme in
                        Text(scheme.localizedTitle).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: formData.authScheme) { _, newValue in
                    // Reset cross-scheme state so changing scheme doesn't
                    // smuggle stale tokens or bundles.
                    if newValue != .oauth {
                        oauthBundle = nil
                        oauthError = nil
                    }
                    if newValue == .oauth, formData.oauthIssuer.isEmpty {
                        // Auto-fill issuer with the scheme+host of the
                        // server URL — most providers serve metadata at the
                        // server's host root.
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bearer Token")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.secondaryText)
                    SecureField("Token…", text: $formData.authSecret)
                        .textFieldStyle(.roundedBorder)
                    if formData.unreadableScopes.contains(MCPSecretScope.bearerToken.rawScope) {
                        unreadableSecretNotice
                    } else {
                        Text("Stored in the macOS Keychain. Sent as `Authorization: Bearer …`.")
                            .font(.caption2)
                            .foregroundColor(theme.tertiaryText)
                    }
                }

            case .apiKeyHeader:
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Header Name")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                        TextField("X-API-Key", text: $formData.apiKeyHeaderName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 180)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Value")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                        SecureField("API key…", text: $formData.authSecret)
                            .textFieldStyle(.roundedBorder)
                        if formData.unreadableScopes.contains(MCPSecretScope.apiKeyHeaderValue.rawScope) {
                            unreadableSecretNotice
                        }
                    }
                }

            case .oauth:
                oauthSection
            }
        }
    }

    /// Shown in place of the usual caption when a stored secret could not be READ. Register KC-1.
    ///
    /// ⚠️ WHY THIS EXISTS AT ALL. The field below it is blank, and a blank field means "no secret
    /// configured" everywhere else in this form. When the Keychain is unreadable that reading is
    /// wrong and dangerous: the user concludes the secret was lost, retypes or clears it, and saves.
    /// The persistence layer already refuses to DELETE what it could not read, so nothing is
    /// destroyed either way — but without this line the user has no way to tell a blank field
    /// caused by an outage from one caused by an empty Keychain, and would have no reason to wait.
    @ViewBuilder
    private var unreadableSecretNotice: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("A secret is stored for this server but the Keychain could not be read, so this "
                 + "field is blank. Nothing has been lost. Leave it empty and save to keep the "
                 + "stored value; unlock your Keychain (or re-grant access after an app update) to "
                 + "see or change it.")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.warningColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - OAuth Section

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Issuer URL")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                TextField("https://auth.example.com", text: $formData.oauthIssuer)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn || oauthBundle != nil)
                Text("Authorization-server root. We probe `\(formData.oauthIssuer.isEmpty ? "<issuer>" : formData.oauthIssuer)/.well-known/oauth-authorization-server`.")
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Scopes (Optional)")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                TextField("space-separated, e.g. mcp:tools profile email", text: $formData.oauthScopes)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn || oauthBundle != nil)
            }

            // Status row + action button
            HStack(spacing: 10) {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                } else if let bundle = oauthBundle {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in to \(bundle.issuer.host ?? bundle.issuer.absoluteString)")
                            .font(theme.fontCaption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("scopes: \(bundle.grantedScopes.isEmpty ? "—" : bundle.grantedScopes.joined(separator: " "))")
                            .font(.caption2)
                            .foregroundColor(theme.tertiaryText)
                    }
                } else if let oauthError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.warningColor)
                    Text(oauthError)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.warningColor)
                        .lineLimit(2)
                } else {
                    Image(systemName: "lock.shield")
                        .foregroundColor(theme.secondaryText)
                    Text("Click Sign In to authorize via the system browser.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button {
                    if oauthBundle != nil {
                        // Re-auth: discard current bundle and run a fresh flow.
                        oauthBundle = nil
                        oauthError = nil
                    }
                    triggerOAuthSignIn()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: oauthBundle == nil ? "person.badge.key" : "arrow.clockwise")
                            .font(.system(.caption, weight: .semibold))
                        Text(oauthBundle == nil ? "Sign In" : "Re-authenticate")
                            .font(.system(.caption, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accentColor.opacity(canStartOAuth ? 1.0 : 0.4)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canStartOAuth || isSigningIn)
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
                    resource: URL(string: formData.url.trimmingCharacters(in: .whitespaces))
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
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $configInput)
                // .callout (12pt) renders code at a comfortable density without
                // shouting like .body monospaced. Lets a 30-line config fit in
                // the editor frame without scrolling.
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(theme.primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isJSONValid ? theme.surfaceOverlayStrong.opacity(0.4) : theme.errorColor,
                            lineWidth: isJSONValid ? 1 : 1.5
                        )
                )
                .frame(minHeight: 240)
                .onChange(of: configInput) { _, _ in
                    parseJSONAndUpdateForm()
                }

            HStack(spacing: 6) {
                Image(systemName: isJSONValid ? "checkmark.seal" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isJSONValid ? "Valid JSON" : "Invalid JSON syntax")
                    .font(.system(.caption2, weight: .medium))
            }
            .foregroundColor(isJSONValid ? theme.successColor : theme.errorColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsCard: some View {
        if isConnecting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Attempting handshake with server…")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = activeError {
            errorContent(error)
        } else if let tools = discoveredTools {
            successContent(tools: tools)
        } else {
            // Idle / never-tested. The play FAB is already on screen, so this
            // hint is intentionally low-contrast — just enough to anchor the
            // empty card without competing for attention.
            Text("Tap the play button to verify the configuration.")
                .font(theme.fontCaption)
                .foregroundColor(theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorContent(_ error: MCPUserError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.fontTitle3)
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(error.title)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(error.message)
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 2)

                HStack(alignment: .top, spacing: 6) {
                    Text("Fix:")
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    Text(error.suggestion)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let raw = error.rawLog {
                    DisclosureGroup("Raw log") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(raw)
                                .font(.caption2.monospaced())
                                .padding(8)
                                .foregroundColor(theme.primaryText)
                        }
                        .background(theme.primaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .font(theme.fontCaption)
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func successContent(tools: [ToolDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(theme.successColor)
                Text("Connection verified")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(theme.successColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.successColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Divider()

            Text("AVAILABLE CAPABILITIES")
                .font(.system(.caption2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)

            // Denser grid + smaller chips read more like a list of code symbols
            // and let the user scan the surface area at a glance. 110pt minimum
            // accommodates short names like `read`, `write` without one-per-row.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(tools.prefix(12), id: \.name) { tool in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(theme.accentColor.opacity(0.55))
                            .frame(width: 4, height: 4)
                        Text(tool.name)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(theme.primaryText)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.primaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(theme.surfaceOverlayStrong.opacity(0.35), lineWidth: 1)
                    )
                }
                if tools.count > 12 {
                    Text("+\(tools.count - 12) more")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
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
                accessibilityLabel: isEditing ? "Save changes" : "Add server to library",
                keyboardShortcut: hasVerifiedConnection ? .defaultAction : nil
            ) {
                if hasVerifiedConnection {
                    saveAndDismiss()
                } else {
                    isShowingUnverifiedSaveAlert = true
                }
            }
            // Editing an EXISTING server no longer requires a live connection.
            //
            // Save used to be gated on a successful Test Connection, which is backwards for
            // the case that matters most: a server is failing BECAUSE its config is wrong,
            // and the user cannot save the fix without first making the broken config work.
            // A server that is simply down (laptop offline, endpoint restarting) had the
            // same problem. Adding a NEW server still requires verification — there is no
            // prior good state to preserve there, and saving something never seen to work
            // would just produce a broken entry.
            .disabled(!hasVerifiedConnection && !canSaveUnverified)
        }
    }

    // MARK: - Floating FAB

    @ViewBuilder
    private var floatingTestButton: some View {
        // Hidden once we already have a verified config — the trailing Save pill
        // becomes the primary action and the FAB would just be redundant. It
        // re-appears as soon as the form changes (via invalidateVerifiedState).
        if !hasVerifiedConnection {
            Button {
                testConnection()
            } label: {
                Group {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            // Slight optical offset — `play.fill` has visual weight on the right.
                            .offset(x: 1.5)
                    }
                }
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(theme.accentColor.opacity(canTestConnection ? 1.0 : 0.5))
                        .shadow(color: theme.primaryText.opacity(0.18), radius: 14, x: 0, y: 6)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canTestConnection || isConnecting)
            .help(isConnecting ? "Connecting…" : "Test Connection")
            .accessibilityLabel(isConnecting ? "Connecting" : "Test Connection")
            .keyboardShortcut(.return, modifiers: [.command])
            .transition(.scale(scale: 0.8).combined(with: .opacity))
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
