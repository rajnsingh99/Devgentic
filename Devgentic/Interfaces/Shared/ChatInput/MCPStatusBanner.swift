// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPStatusBanner.swift
//  Devgentic
//
//  Created 2026-08-01 — MCP connection summary above the composer.
//
//  Server health lived entirely inside the Tool Library, on 8×8pt dots the user had to go
//  looking for. So the failure mode was: send a message, watch the agent behave as if a
//  capability does not exist, and have no idea a server had failed to connect. The
//  information has to be where the user is about to act.
//
//  Deliberately quiet: when everything is connected this is a single muted line, and when
//  no MCP servers are configured at all it renders nothing. It only raises its voice —
//  colour and an explicit count — when something is actually down.
//

import SwiftUI

struct MCPStatusBanner: View {

    /// Opens the Tool Library so the user can act on what the banner reports.
    let onOpenToolLibrary: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var status = MCPConnectionCoordinator.Status(active: 0, total: 0, failed: 0, disabled: 0)
    @State private var isConnecting = false

    var body: some View {
        Group {
            // Nothing configured — say nothing. A banner reading "0/0 servers" is noise
            // for the majority of users who have never added one.
            if status.hasAny {
                content
            }
        }
        .task(id: pollKey) {
            refresh()
        }
    }

    private var content: some View {
        Button(action: onOpenToolLibrary) {
            HStack(spacing: 6) {
                icon

                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(tint)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("Manage")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(status.failed > 0 ? 0.09 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(message)
        .accessibilityHint("Opens the Tool Library")
    }

    @ViewBuilder
    private var icon: some View {
        if isConnecting {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - Copy

    private var message: String {
        if isConnecting {
            return "Connecting to MCP servers…"
        }
        if status.total == 0 {
            // Everything the user has is switched off — worth saying, since their tools are
            // absent by their own earlier choice and that is easy to forget.
            return "All MCP servers are off"
        }
        if status.failed > 0 {
            return "\(status.active)/\(status.total) MCP servers active · \(status.failed) failed"
        }
        if status.active < status.total {
            return "\(status.active)/\(status.total) MCP servers active"
        }
        return status.total == 1
            ? "MCP server active"
            : "\(status.total) MCP servers active"
    }

    private var helpText: String {
        var parts = ["\(status.active) of \(status.total) enabled MCP server(s) connected."]
        if status.failed > 0 {
            parts.append("\(status.failed) failed to connect — their tools are unavailable to the agent.")
        }
        if status.disabled > 0 {
            parts.append("\(status.disabled) server(s) are disabled.")
        }
        return parts.joined(separator: " ")
    }

    private var tint: Color {
        if isConnecting { return theme.secondaryText }
        if status.failed > 0 { return .orange }
        if status.total == 0 { return theme.secondaryText }
        return status.allActive ? .green : .orange
    }

    // MARK: - Refresh
    //
    // Driven off an observation-derived key rather than a timer: `connectionStates` and
    // `sources` are both @Observable, so reading them here re-runs `.task(id:)` whenever
    // they actually change. No polling, and no wakeups while idle.

    private var pollKey: String {
        let states = MCPClientService.shared.connectionStates
        let sources = MCPToolStore.shared.sources
        let connecting = MCPConnectionCoordinator.shared.isPerformingLaunchConnect
        let stateFingerprint = states
            .map { "\($0.key.uuidString.prefix(8)):\(describe($0.value))" }
            .sorted()
            .joined(separator: ",")
        return "\(sources.count)|\(connecting)|\(stateFingerprint)"
    }

    private func describe(_ state: MCPConnectionState) -> String {
        switch state {
        case .disconnected:   return "d"
        case .connecting:     return "c"
        case .connected:      return "a"
        case .reconnecting:   return "r"
        case .error:          return "e"
        }
    }

    private func refresh() {
        status = MCPConnectionCoordinator.shared.status()
        isConnecting = MCPConnectionCoordinator.shared.isPerformingLaunchConnect
    }
}
