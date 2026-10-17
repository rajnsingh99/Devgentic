// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchSettingsView.swift
//  Devgentic
//
//  Settings pane for the `web_search` tool: choose a provider, store its credentials (Keychain)
//  and run a real test query.
//  Aligned with Planout/UI_Guidelines.md for a premium, tactile developer experience.
//

import SwiftUI
import AppKit

struct WebSearchSettingsView: View {
    @Environment(\.appTheme) private var theme

    private let config = WebSearchConfig()

    @State private var provider: WebSearchProvider = WebSearchConfig().provider
    @State private var keyInput = ""
    @State private var engineID = ""
    @State private var searxngURL = ""
    @State private var storedKeyPresent = false
    @State private var status: Status = .idle
    @State private var lastResults: [WebSearchResult] = []
    @State private var isResultsExpanded: Bool = false

    private enum Status: Equatable {
        case idle
        case testing
        case ok(count: Int, latencyMs: Int)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            // MARK: 1. Search Engine Provider
            providerSelectionCard

            // MARK: 2. Provider Credentials & Endpoint Configuration
            credentialsCard(for: provider)

            // MARK: 3. Connection Diagnostics & Live Results
            diagnosticsCard(for: provider)

            // MARK: 4. Agent Capabilities & Privacy
            agentCapabilitiesCard
        }
        .onAppear {
            provider = config.provider
            engineID = config.googleEngineID
            searxngURL = config.searxngURL
            refreshStoredKey()
        }
    }

    // MARK: - Card 1: Search Engine Provider

    private var providerSelectionCard: some View {
        SettingsCard(title: "Search Provider", icon: "magnifyingglass", theme: theme) {
            VStack(spacing: 0) {
                // Intro Row
                SettingsRow(
                    title: "Active Engine",
                    description: LocalizedStringKey(provider.summary),
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(provider.brandColor)
                            .frame(width: 8, height: 8)
                        Text(provider.displayName)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(provider.brandColor.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(provider.brandColor.opacity(0.3), lineWidth: 0.5)
                    )
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Provider Options List
                VStack(spacing: 0) {
                    ForEach(WebSearchProvider.allCases) { p in
                        providerRow(for: p)

                        if p != WebSearchProvider.allCases.last {
                            Rectangle().fill(theme.dividerColor.opacity(0.2)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func providerRow(for p: WebSearchProvider) -> some View {
        ProviderOptionRow(
            title: p.displayName,
            subtitle: p.summary,
            icon: p.brandIcon,
            color: p.brandColor,
            badge: p.badgeText,
            isSelected: provider == p,
            theme: theme
        ) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                provider = p
                config.provider = p
                keyInput = ""
                status = .idle
                lastResults = []
                isResultsExpanded = false
                refreshStoredKey()
            }
        }
    }

    // MARK: - Card 2: Credentials & Endpoint

    private func credentialsCard(for provider: WebSearchProvider) -> some View {
        SettingsCard(title: "\(provider.displayName) Configuration", icon: "key.fill", theme: theme) {
            VStack(spacing: 0) {
                if provider.requiresAPIKey {
                    apiKeySection(for: provider)
                }

                if provider == .google {
                    if provider.requiresAPIKey {
                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    }
                    googleEngineIDSection
                }

                if provider == .searxng {
                    searxngURLSection
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Portal Guidance Banner
                portalGuidanceBanner(for: provider)
            }
        }
    }

    private func apiKeySection(for provider: WebSearchProvider) -> some View {
        SettingsRow(
            title: "API Key",
            description: LocalizedStringKey(storedKeyPresent
                ? String(localized: "A key is safely encrypted in your macOS Keychain. Enter a new one to replace it.")
                : String(localized: "Stored securely in your macOS Keychain. Never written to preferences or synced.")),
            theme: theme
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    SecretInputField(
                        placeholder: storedKeyPresent ? "••••••••••••••••" : "Paste API key",
                        text: $keyInput
                    )
                    .frame(width: 210)

                    TactileButton(
                        title: "Save Key",
                        icon: "checkmark",
                        variant: .primary,
                        size: .compact,
                        isEnabled: !keyInput.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        saveKey(for: provider)
                    }

                    if storedKeyPresent {
                        TactileIconButton(
                            icon: "trash",
                            tooltip: "Remove key from Keychain",
                            variant: .destructive,
                            size: .compact
                        ) {
                            removeKey(for: provider)
                        }
                    }
                }

                // Stored Confirmation Pill
                if storedKeyPresent {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Saved in macOS Keychain")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }

    private var googleEngineIDSection: some View {
        SettingsRow(
            title: "Search Engine ID (cx)",
            description: "From your Google Programmable Search Engine control panel (search engine ID).",
            theme: theme
        ) {
            CustomDarkTextField(
                text: $engineID,
                placeholder: "e.g. 0175766620121307...:imaze...",
                icon: "number",
                width: 250,
                theme: theme
            )
            .onSubmit { config.googleEngineID = engineID }
            .onChange(of: engineID) { _, v in config.googleEngineID = v }
        }
    }

    private var searxngURLSection: some View {
        SettingsRow(
            title: "Instance URL",
            description: "Base URL of your SearXNG instance (e.g. http://localhost:8080). Must allow JSON output (`format=json`).",
            theme: theme
        ) {
            CustomDarkTextField(
                text: $searxngURL,
                placeholder: "e.g. http://localhost:8080",
                icon: "link",
                width: 250,
                theme: theme
            )
            .onChange(of: searxngURL) { _, v in config.searxngURL = v }
        }
    }

    private func portalGuidanceBanner(for provider: WebSearchProvider) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(provider.brandColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 14))
                    .foregroundColor(provider.brandColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(provider == .searxng ? "SearXNG Setup Documentation" : "Get API Key for \(provider.displayName)")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(provider == .searxng
                    ? "Read deployment guides to enable JSON output formats."
                    : "Create a free account or generate credentials on the provider portal.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            TactileButton(
                title: provider == .searxng ? "Setup Docs" : "Open Console",
                icon: "arrow.up.right",
                variant: .secondary,
                size: .compact
            ) {
                NSWorkspace.shared.open(provider.signupURL)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surfaceOverlay.opacity(0.2))
    }

    // MARK: - Card 3: Live Diagnostics & Inspector

    private func diagnosticsCard(for provider: WebSearchProvider) -> some View {
        SettingsCard(title: "Connection Diagnostics", icon: "bolt.horizontal.fill", theme: theme) {
            VStack(spacing: 0) {
                // Trigger Row
                SettingsRow(
                    title: "Test Connection",
                    description: "Executes a live query ('Apple Swift programming language') through \(provider.displayName) using your saved credentials.",
                    theme: theme
                ) {
                    TactileButton(
                        title: "Run Test Search",
                        icon: "play.fill",
                        variant: .secondary,
                        size: .compact,
                        isLoading: status == .testing
                    ) {
                        runTest(for: provider)
                    }
                }

                // Diagnostics Feedback Surface
                if status != .idle {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    diagnosticsResultView(for: provider)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticsResultView(for provider: WebSearchProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch status {
            case .idle:
                EmptyView()

            case .testing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Querying \(provider.displayName)…")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            case .failed(let message):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.errorColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search Query Failed")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.errorColor)

                        Text(message)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2)
                    }

                    Spacer()

                    TactileButton(
                        title: "Retry",
                        icon: "arrow.clockwise",
                        variant: .subtle,
                        size: .compact
                    ) {
                        runTest(for: provider)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(theme.errorColor.opacity(0.08))

            case .ok(let count, let latencyMs):
                VStack(alignment: .leading, spacing: 12) {
                    // Header Bar
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.green)

                        Text("Connection Verified")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)

                        Spacer()

                        // Latency Chip
                        HStack(spacing: 4) {
                            Image(systemName: "stopwatch")
                                .font(.system(size: 10))
                            Text("\(latencyMs) ms")
                                .font(theme.fontCodeCaption)
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.surfaceOverlay))

                        // Count Chip
                        Text("\(count) hits")
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.surfaceOverlay))
                    }

                    // Live Results Accordion (§13.2)
                    if !lastResults.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                isResultsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(isResultsExpanded ? 90 : 0))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.secondaryText)

                                Text(isResultsExpanded ? "Hide Search Results Preview" : "View Returned Results Preview (\(lastResults.count))")
                                    .font(theme.fontCaption2.weight(.medium))
                                    .foregroundColor(theme.accentColor)

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        if isResultsExpanded {
                            VStack(spacing: 8) {
                                ScrollView(.vertical, showsIndicators: true) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(lastResults.enumerated()), id: \.offset) { _, item in
                                            SearchResultPreviewCard(result: item, theme: theme)
                                        }
                                    }
                                    .padding(.trailing, 6)
                                }
                                .frame(maxHeight: 220) // Generous sub-scrolling viewport (§13.4)
                            }
                            .transition(.opacity) // In-place accordion fade (§13.2)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.green.opacity(0.06))
            }
        }
    }

    // MARK: - Card 4: Agent Capabilities & Privacy

    private var agentCapabilitiesCard: some View {
        SettingsCard(title: "Agent Capabilities & Privacy", icon: "lock.shield.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Tool Availability",
                    description: "Status of the 'web_search' tool exposed to Devgentic AI agents and automated workflows.",
                    theme: theme
                ) {
                    let isReady = config.missingSetup(for: provider) == nil
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isReady ? Color.green : theme.warningColor)
                            .frame(width: 8, height: 8)
                        Text(isReady ? "Ready (Tool Active)" : "Setup Incomplete")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(isReady ? .green : theme.warningColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isReady ? Color.green.opacity(0.12) : theme.warningColor.opacity(0.12))
                    )
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Privacy Note
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Direct On-Device Dispatch")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Search requests are sent directly from your Mac to the selected provider endpoint. Devgentic operates zero intermediary servers, collecting no queries, search terms, or telemetry.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Actions

    private func refreshStoredKey() {
        guard provider.requiresAPIKey else { storedKeyPresent = false; return }
        if case .found = WebSearchKeyStore.read(for: provider) { storedKeyPresent = true } else { storedKeyPresent = false }
    }

    private func saveKey(for provider: WebSearchProvider) {
        if WebSearchKeyStore.save(keyInput, for: provider) {
            keyInput = ""
            status = .idle
            refreshStoredKey()
        } else {
            status = .failed(String(localized: "Could not save to the Keychain. Unlock your login keychain and try again."))
        }
    }

    private func removeKey(for provider: WebSearchProvider) {
        if !WebSearchKeyStore.delete(for: provider) {
            status = .failed(String(localized: "Could not remove the key from the Keychain."))
        }
        refreshStoredKey()
    }

    private func runTest(for provider: WebSearchProvider) {
        if let missing = config.missingSetup(for: provider) {
            status = .failed(missing.prefix(1).uppercased() + missing.dropFirst())
            return
        }
        status = .testing
        lastResults = []
        isResultsExpanded = false

        let client = WebSearchClient(
            provider: provider,
            apiKey: WebSearchKeyStore.load(for: provider) ?? "",
            googleEngineID: config.googleEngineID,
            searxngURL: config.searxngURL
        )

        let clock = ContinuousClock()
        Task {
            let start = clock.now
            do {
                let results = try await client.search(query: "Apple Swift programming language", count: 3)
                let elapsed = clock.now - start
                let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

                if results.isEmpty {
                    status = .failed(String(localized: "Connected, but the search query returned no results."))
                } else {
                    lastResults = results
                    status = .ok(count: results.count, latencyMs: ms)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        isResultsExpanded = true
                    }
                }
            } catch let error as WebSearchError {
                status = .failed(error.message)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Subcomponents

private extension WebSearchProvider {
    var brandIcon: String {
        switch self {
        case .brave:   return "shield.lefthalf.filled"
        case .tavily:  return "sparkles"
        case .google:  return "globe"
        case .searxng: return "server.rack"
        }
    }

    var brandColor: Color {
        switch self {
        case .brave:   return Color(red: 0.96, green: 0.45, blue: 0.16)
        case .tavily:  return Color(red: 0.12, green: 0.73, blue: 0.88)
        case .google:  return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .searxng: return Color(red: 0.13, green: 0.77, blue: 0.47)
        }
    }

    var badgeText: String {
        switch self {
        case .brave:   return "FREE TIER"
        case .tavily:  return "AI OPTIMIZED"
        case .google:  return "CUSTOM INDEX"
        case .searxng: return "SELF-HOSTED · PRIVATE"
        }
    }
}

private struct ProviderOptionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let badge: String
    let isSelected: Bool
    let theme: any Theme
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Branded Icon Box
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(isSelected ? 0.18 : 0.08))
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(color.opacity(isSelected ? 0.4 : 0.15), lineWidth: 1)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(color)
                }

                // Info & Badge
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)

                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(subtitle)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                // Trailing Selection Indicator (§5.4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                } else {
                    Circle()
                        .stroke(theme.dividerColor.opacity(isHovered ? 0.6 : 0.3), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? theme.accentColor.opacity(0.05)
                    : (isHovered ? theme.surfaceOverlay : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

private struct CustomDarkTextField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String
    let width: CGFloat
    let theme: any Theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(theme.placeholderText)
            )
            .textFieldStyle(.plain)
            .font(theme.fontCodeCaption)
            .foregroundColor(theme.primaryText)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct SearchResultPreviewCard: View {
    let result: WebSearchResult
    let theme: any Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.title)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                if let url = URL(string: result.url), let host = url.host {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Text(result.snippet)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)
                .lineLimit(3)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
        )
    }
}
