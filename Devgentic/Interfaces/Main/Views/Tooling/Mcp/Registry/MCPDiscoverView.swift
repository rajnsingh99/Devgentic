// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPDiscoverView.swift
//  Devgentic
//
//  Created 2026-08-01 — the Discover half of the Tool Library.
//
//  Browsing the official MCP Registry. Search is server-side; results are never mirrored
//  locally. Every row states LOCAL or REMOTE first, because that single fact decides whether
//  code runs on this machine or the user's data leaves it.
//
//  Nothing here connects anything. Selecting a row opens a review sheet showing the exact
//  command, the values the server needs, and what it will do — and only an explicit
//  confirmation there creates a server. The registry lists servers; it does not review them.
//

import SwiftUI
import os

private let logger = DGLogger(category: "MCPDiscoverView")

// MARK: - Localized chip titles

extension ToolDiscoverFilter {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so the filter chips were invisible to the
    /// String Catalog extractor and would have shipped untranslated inside otherwise-translated
    /// chrome. `rawValue` stays as the `Identifiable` id and for logging only.
    ///
    /// Declared here rather than next to the enum in `ToolLibraryNavigation.swift` because this
    /// is the only surface that renders these as labels.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all:    return "All"
        case .local:  return "Local"
        case .remote: return "Remote"
        }
    }
}

struct MCPDiscoverView: View {

    /// Called when the user confirms a plan. The host performs the actual add so this view
    /// stays free of persistence concerns.
    let onAdd: (MCPRegistryInstallPlan, [String: String]) -> Void

    @Environment(\.appTheme) private var theme

    @State private var servers: [MCPRegistryServer] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedPlan: MCPRegistryInstallPlan?

    private var installedNames: Set<String> {
        Set(MCPToolStore.shared.sources.map { $0.serverName.lowercased() })
    }

    /// One search field, not two. The view used to carry its own "Search the MCP registry…"
    /// box directly beneath the island bar's "Search tools…" — two inputs, stacked, for one
    /// job. The island bar now drives this, and its placeholder changes to match.
    private var searchText: String { ToolLibraryNavigationState.shared.searchText }

    private var filter: ToolDiscoverFilter { ToolLibraryNavigationState.shared.discoverFilter }

    private var resultSummary: String {
        let count = visible.count
        let noun = "\(count) server\(count == 1 ? "" : "s")"
        // While the corpus is still growing, say so — the number is a floor, not a total.
        if !MCPRegistryClient.isCorpusComplete && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(noun) · still loading"
        }
        return noun
    }

    private var visible: [MCPRegistryServer] {
        servers.filter { server in
            switch filter {
            case .all:    return true
            case .local:  return server.isLocal
            case .remote: return server.isRemote
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterChips
            Divider().opacity(0.5)
            content
        }
        .task(id: searchText) { await load() }
        .sheet(item: $selectedPlan) { plan in
            MCPRegistryReviewSheet(
                plan: plan,
                onCancel: { selectedPlan = nil },
                onConfirm: { values in
                    selectedPlan = nil
                    onAdd(plan, values)
                }
            )
        }
    }

    // MARK: - Header

    /// All / Local / Remote, occupying the space the duplicate search box used to.
    ///
    /// Local vs Remote leads because it is the one fact that decides whether code runs on
    /// this machine or the user's data leaves it.
    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(ToolDiscoverFilter.allCases) { option in
                Button {
                    ToolLibraryNavigationState.shared.discoverFilter = option
                } label: {
                    Text(option.localizedTitle)
                        .font(.system(size: 12, weight: filter == option ? .medium : .regular))
                        .foregroundColor(filter == option ? theme.accentColor : theme.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(filter == option ? theme.accentColor.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(
                                filter == option ? theme.accentColor.opacity(0.45) : theme.secondaryText.opacity(0.22),
                                lineWidth: 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            }
            // Says what the number actually covers. The registry's own search matches names
            // only, so description matches come from the locally-loaded slice — claiming a
            // flat count while still loading would overstate what was searched.
            Text(resultSummary)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .help(MCPRegistryClient.isCorpusComplete
                      ? "Searching names and descriptions across the whole registry."
                      : "Names are searched across the whole registry. Descriptions are searched across the \(MCPRegistryClient.corpusCount) servers loaded so far.")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            emptyState(
                icon: "exclamationmark.triangle",
                title: "Couldn't reach the registry",
                detail: loadError,
                actionTitle: "Retry",
                action: { Task { await load() } }
            )
        } else if isLoading && servers.isEmpty {
            emptyState(icon: "arrow.down.circle", title: "Loading servers…", detail: nil, actionTitle: nil, action: nil)
        } else if visible.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: searchText.isEmpty ? "No servers to show" : "No matches for “\(searchText)”",
                detail: searchText.isEmpty ? nil : "Try a broader term, or clear the filter.",
                actionTitle: nil, action: nil
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(visible) { server in
                        MCPDiscoverCard(
                            server: server,
                            isInstalled: installedNames.contains(server.displayName.lowercased())
                        ) {
                            open(server)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func emptyState(
        icon: String, title: String, detail: String?,
        actionTitle: String?, action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(theme.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func open(_ server: MCPRegistryServer) {
        let plan = MCPRegistryInstallPlan.make(for: server)
        logger.info("""
            [MCP-DISCOVER] Opened review for '\(server.name)' — \
            \(plan.isRunnable ? "runnable" : "BLOCKED: \(plan.blockedReason ?? "unknown")"). \
            Nothing is installed or connected until the user confirms.
            """)
        selectedPlan = plan
    }

    private func load(search: String? = nil) async {
        let term = (search ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty term: show the corpus, growing it in the background. Pages paint as they land
        // rather than the grid waiting on all ten.
        guard !term.isEmpty else {
            loadError = nil
            isLoading = !MCPRegistryClient.isCorpusComplete
            MCPRegistryClient.loadCorpus { loaded in
                servers = loaded
                isLoading = !MCPRegistryClient.isCorpusComplete && loaded.isEmpty
            }
            return
        }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Name + description. The registry cannot do the description half, so this is a union
        // of a local filter and the remote name search — see `MCPRegistryClient.search`.
        let results = await MCPRegistryClient.search(term)
        guard !Task.isCancelled else { return }

        servers = results
        if results.isEmpty {
            logger.info("[MCP-DISCOVER] No matches for '\(term)' across \(MCPRegistryClient.corpusCount) loaded server(s) + the registry name index.")
        }
    }
}

// MARK: - Card

private struct MCPDiscoverCard: View {

    let server: MCPRegistryServer
    let isInstalled: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme

    private var runtime: String { server.primaryPackage?.effectiveRuntime ?? "" }
    private var isRuntimeMissing: Bool {
        server.isLocal && !runtime.isEmpty && !MCPRuntimeProbe.isAvailable(runtime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.accentColor.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: server.isRemote ? "cloud" : "shippingbox")
                            .font(.system(size: 13))
                            .foregroundColor(theme.accentColor)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(server.publisher)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                actionLabel
            }

            if !server.description.isEmpty {
                Text(server.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                // Local vs remote leads, deliberately: it is the one fact that decides
                // whether code runs here or data goes there.
                badge(server.isRemote ? "Remote" : "Local", tint: server.isRemote ? .blue : .orange)
                if !runtime.isEmpty { badge(runtime, tint: theme.secondaryText) }
                if let version = server.primaryPackage?.version ?? server.version {
                    badge("v\(version)", tint: theme.secondaryText)
                }
                if isInstalled { badge("Installed", tint: .green) }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.surfaceOverlay))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isInstalled ? Color.green.opacity(0.35) : theme.secondaryText.opacity(0.14), lineWidth: 0.5)
        )
        .opacity(isRuntimeMissing ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .help(isRuntimeMissing ? "\(MCPRuntimeProbe.installHint(for: runtime)) — install it to add this server." : server.name)
    }

    @ViewBuilder
    private var actionLabel: some View {
        if isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.green)
        } else if isRuntimeMissing {
            Text(MCPRuntimeProbe.installHint(for: runtime))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().stroke(theme.secondaryText.opacity(0.25), lineWidth: 0.5))
        } else {
            Text("Add")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(theme.accentColor))
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
    }
}

// MARK: - Identifiable conformance for the sheet binding

extension MCPRegistryInstallPlan: Identifiable {
    var id: String { server.name }
}
