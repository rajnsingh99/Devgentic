// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPConnectionCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPConnectionCoordinator")

/// Owns when Devgentic connects to MCP servers: connects every enabled server at launch, concurrently,
/// and owns rescan and reconnect so the UI has one place to call.
@Observable @MainActor
final class MCPConnectionCoordinator {

    static let shared = MCPConnectionCoordinator()
    private init() {}

    /// True while the launch sweep is running, so the UI can say "connecting…" rather than
    /// briefly showing every server as down.
    private(set) var isPerformingLaunchConnect = false

    /// Guards against a second sweep (e.g. a window reopening) racing the first.
    private var launchConnectTask: Task<Void, Never>?

    // MARK: - Launch

    /// Connects every enabled server. Safe to call more than once — later calls join the
    /// in-flight sweep rather than starting a second one.
    func connectEnabledServersAtLaunch() async {
        // Why: user-driven paths (Test Connection, explicit reconnect) stay unguarded: only the launch sweep runs unasked.
        // Refuse the automatic launch sweep under test: it spawns child processes (`npx` and friends) that inherit the
        // host environment and resolve credentials from the real login Keychain.
        guard TestHost.permits("connect enabled MCP servers at launch (this spawns child processes inheriting the full environment and reads the real login Keychain)", logger: logger) else { return }

        if let existing = launchConnectTask {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            await self.performLaunchConnect()
        }
        launchConnectTask = task
        await task.value
        launchConnectTask = nil
    }

    private func performLaunchConnect() async {
        let allSources = MCPHostBridge.configuredSources(context: "launch sweep")
        let enabled = allSources.filter { $0.isEnabled && $0.serverDefinition != nil }
        let disabledCount = allSources.count { !$0.isEnabled }
        let unconfigured = allSources.count { $0.isEnabled && $0.serverDefinition == nil }

        // Runs before the empty-guard: `enabled` excludes servers with no definition, so when every server is corrupt
        // the guard would return first and this diagnostic would never run.
        if unconfigured > 0 {
            logger.error("""
                [MCP-LAUNCH] \(unconfigured) enabled server(s) have NO serverDefinition and were \
                skipped — their tools cannot resolve and the user has no way to fix this from the \
                UI. Usual cause: a corrupt or undecodable mcpConfigData blob.
                """)
        }

        guard !enabled.isEmpty else {
            logger.info("""
                [MCP-LAUNCH] No MCP servers to connect (\(allSources.count) configured, \
                \(disabledCount) disabled, \(unconfigured) missing a server definition).
                """)
            return
        }

        isPerformingLaunchConnect = true
        let started = Date()
        logger.info("[MCP-LAUNCH] Connecting \(enabled.count) enabled MCP server(s) (\(disabledCount) disabled, skipped).")

        // Concurrent: a slow server must not delay every other server's availability.
        await withTaskGroup(of: Void.self) { group in
            for source in enabled {
                group.addTask { @MainActor in
                    await self.connect(source: source, reason: "launch")
                }
            }
            await group.waitForAll()
        }

        isPerformingLaunchConnect = false

        let summary = status()
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
        if summary.failed > 0 {
            logger.error("""
                [MCP-LAUNCH] Finished in \(elapsedMS)ms: \(summary.active)/\(summary.total) server(s) \
                active, \(summary.failed) FAILED. The agent is running without the failed servers' \
                tools; open the Tool Library and click a red status dot for the reason.
                """)
        } else {
            logger.info("[MCP-LAUNCH] Finished in \(elapsedMS)ms: \(summary.active)/\(summary.total) server(s) active.")
        }
    }

    // MARK: - Individual connects

    /// Connects one source if it is enabled and not already connected.
    func connectIfNeeded(sourceID: UUID) async {
        let sources = MCPHostBridge.configuredSources(context: "connectIfNeeded \(sourceID)")
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            logger.warning("[MCP-CONNECT] connectIfNeeded for unknown source \(sourceID); ignoring.")
            return
        }
        guard source.isEnabled else {
            logger.info("[MCP-CONNECT] Skipping '\(source.serverName)' — the user has it disabled.")
            return
        }
        if MCPClientService.shared.connectionStates[sourceID]?.isActive == true { return }
        await connect(source: source, reason: "on demand")
    }

    /// Forces a fresh connect, discarding any existing session. Used by "Reconnect".
    func reconnect(sourceID: UUID) async {
        let sources = MCPHostBridge.configuredSources(context: "reconnect \(sourceID)")
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        logger.info("[MCP-CONNECT] User asked to reconnect '\(source.serverName)' (\(sourceID)).")
        await MCPClientService.shared.disconnect(sourceId: sourceID)
        await connect(source: source, reason: "user reconnect")
    }

    private func connect(source: ToolSource, reason: String) async {
        guard let definition = source.serverDefinition else {
            logger.error("""
                [MCP-CONNECT] '\(source.serverName)' (\(source.id)) has no serverDefinition — cannot \
                connect (\(reason)). Its tools will not resolve for the rest of the session.
                """)
            return
        }

        do {
            let (_, tools) = try await MCPClientService.shared.connect(sourceId: source.id, config: definition)
            // Refresh the persisted tool list: a server may have gained or lost tools since
            // the last time we looked, and nothing else would notice until it announced it.
            MCPHostBridge.requireToolListSink(context: "connect \(source.id) (\(reason))")?
                .replaceTools(forSourceID: source.id, with: tools)
            logger.info("[MCP-CONNECT] '\(source.serverName)' connected (\(reason)) with \(tools.count) tool(s).")
        } catch {
            // `connect` has already set `.error` state with the detail; this states the
            // consequence, which the state alone does not.
            logger.error("""
                [MCP-CONNECT] '\(source.serverName)' (\(source.id)) FAILED to connect (\(reason)): \
                \(error.localizedDescription). Its \(source.tools.count) tool(s) will not resolve; \
                the agent runs without them until a retry succeeds.
                """)
        }
    }

    // MARK: - Rescan

    /// Re-reads a server's tool list and persists the result.
    /// Covers servers that do not implement `tools/list_changed`.
    /// - Returns: the new tool count, or nil if the rescan failed.
    @discardableResult
    func rescan(sourceID: UUID) async -> Int? {
        let sources = MCPHostBridge.configuredSources(context: "rescan \(sourceID)")
        guard let source = sources.first(where: { $0.id == sourceID }),
              let definition = source.serverDefinition else {
            logger.error("[MCP-RESCAN] Cannot rescan \(sourceID): unknown source or missing definition.")
            return nil
        }

        let before = source.tools.count
        do {
            // Reconnect rather than reuse: a rescan is also the user's "is this thing even
            // alive?" gesture, and a stale session would answer from cache.
            await MCPClientService.shared.disconnect(sourceId: sourceID)
            let (_, tools) = try await MCPClientService.shared.connect(sourceId: sourceID, config: definition)
            MCPHostBridge.requireToolListSink(context: "rescan \(sourceID)")?
                .replaceTools(forSourceID: sourceID, with: tools)

            let delta = tools.count - before
            logger.info("""
                [MCP-RESCAN] '\(source.serverName)' rescanned: \(before) → \(tools.count) tool(s) \
                (\(delta >= 0 ? "+" : "")\(delta)).\(delta < 0 ? " Removed tools stay ticked in any profile that referenced them and will log as unresolved until untick." : "")
                """)
            return tools.count
        } catch {
            logger.error("""
                [MCP-RESCAN] '\(source.serverName)' rescan FAILED: \(error.localizedDescription). \
                The previously known \(before) tool(s) are left in place rather than blanked.
                """)
            return nil
        }
    }

    // MARK: - Status

    struct Status: Equatable {
        /// Enabled servers currently connected.
        let active: Int
        /// Enabled servers configured (the denominator the user sees).
        let total: Int
        /// Enabled servers in an error state.
        let failed: Int
        /// Servers the user has switched off — excluded from `total`.
        let disabled: Int

        var allActive: Bool { active == total }
        var hasAny: Bool { total > 0 || disabled > 0 }
    }

    /// Live connection summary for the composer banner and the Tool Library.
    func status() -> Status {
        let sources = MCPHostBridge.configuredSources(context: "status")
        let enabled = sources.filter(\.isEnabled)
        let states = MCPClientService.shared.connectionStates

        var active = 0
        var failed = 0
        for source in enabled {
            switch states[source.id] {
            case .connected: active += 1
            case .error:     failed += 1
            default:         break
            }
        }

        return Status(
            active: active,
            total: enabled.count,
            failed: failed,
            disabled: sources.count { !$0.isEnabled }
        )
    }
}
