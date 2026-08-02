//
//  MCPRegistryInstallPlan.swift
//  Devgentic
//
//  Created 2026-08-01 — turns a registry entry into something the user can review.
//
//  This is the seam where third-party metadata becomes a command we would run. It produces
//  a PLAN, never an action: the plan is rendered for review, and only an explicit
//  confirmation turns it into a saved server. The MCP Registry indexes; it does not vet
//  publishers — so a listing is data, not permission.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPRegistryInstall")

/// Everything the review sheet needs to show, and everything `ServerDefinition` needs to be
/// built, derived from one registry entry.
struct MCPRegistryInstallPlan {

    enum Kind {
        /// Runs as a child process on this Mac. Code is downloaded by the runtime.
        case local(runtime: String, command: String, arguments: [String])
        /// Talks to a URL over HTTPS. Nothing is downloaded.
        case remote(url: String, transport: MCPTransportMode)
    }

    let server: MCPRegistryServer
    let kind: Kind
    /// Values the user must supply before this can connect.
    let environmentVariables: [MCPRegistryEnvironmentVariable]
    /// nil when the plan is runnable; a user-facing reason when it is not.
    let blockedReason: String?

    var isRunnable: Bool { blockedReason == nil }

    /// The exact command line, for display. The user cannot consent to what they cannot see.
    var displayCommand: String {
        switch kind {
        case .local(_, let command, let arguments):
            return ([command] + arguments).joined(separator: " ")
        case .remote(let url, _):
            return url
        }
    }

    var requiredVariables: [MCPRegistryEnvironmentVariable] {
        environmentVariables.filter(\.isRequired)
    }

    // MARK: - Construction

    @MainActor
    static func make(for server: MCPRegistryServer) -> MCPRegistryInstallPlan {

        // Local wins when an entry offers both: running locally keeps the user's data on
        // their machine, where sending it to a third-party endpoint would not.
        if let package = server.primaryPackage {
            let runtime = package.effectiveRuntime

            guard !runtime.isEmpty else {
                logger.warning("""
                    [MCP-REGISTRY] '\(server.name)' has a \(package.registryType) package but no \
                    usable runtime hint — cannot build a launch command, so it is offered as \
                    unrunnable rather than guessed at.
                    """)
                return MCPRegistryInstallPlan(
                    server: server, kind: .local(runtime: "", command: "", arguments: []),
                    environmentVariables: package.environmentVariables,
                    blockedReason: "Unsupported package type (\(package.registryType))"
                )
            }

            let arguments = buildArguments(for: package)
            let available = MCPRuntimeProbe.isAvailable(runtime)

            logger.info("""
                [MCP-REGISTRY] Plan for '\(server.name)': LOCAL via \(runtime) \
                (\(package.registryType) \(package.pinnedIdentifier)), \
                \(arguments.count) arg(s), \(package.environmentVariables.count) env var(s) \
                (\(package.environmentVariables.count(where: \.isRequired)) required), \
                runtime \(available ? "available" : "MISSING").
                """)

            return MCPRegistryInstallPlan(
                server: server,
                kind: .local(runtime: runtime, command: runtime, arguments: arguments),
                environmentVariables: package.environmentVariables,
                blockedReason: available ? nil : MCPRuntimeProbe.installHint(for: runtime)
            )
        }

        if let remote = server.primaryRemote {
            let isSecure = remote.url.lowercased().hasPrefix("https://")
                || remote.url.lowercased().hasPrefix("http://localhost")
                || remote.url.lowercased().hasPrefix("http://127.0.0.1")

            logger.info("""
                [MCP-REGISTRY] Plan for '\(server.name)': REMOTE \
                \(MCPRedaction.redact(url: remote.url)) transport=\(remote.transportMode.rawValue) \
                secure=\(isSecure).
                """)

            if !isSecure {
                logger.error("""
                    [MCP-REGISTRY] ⚠️ '\(server.name)' advertises a NON-HTTPS remote \
                    (\(MCPRedaction.redact(url: remote.url))) — refused. Credentials and tool \
                    arguments would travel in clear text.
                    """)
            }

            return MCPRegistryInstallPlan(
                server: server,
                kind: .remote(url: remote.url, transport: remote.transportMode),
                environmentVariables: [],
                blockedReason: isSecure ? nil : "Insecure endpoint (not HTTPS)"
            )
        }

        logger.warning("[MCP-REGISTRY] '\(server.name)' has neither package nor remote; nothing to plan.")
        return MCPRegistryInstallPlan(
            server: server, kind: .remote(url: "", transport: .streamableHTTP),
            environmentVariables: [], blockedReason: "Nothing to connect to"
        )
    }

    /// argv for a local launch: runtime arguments, then the PINNED package spec, then the
    /// package's own arguments.
    ///
    /// Pinning is the point. `npx -y pkg` re-resolves "latest" on every launch, so an
    /// unpinned entry means the code reviewed today is not necessarily the code that runs
    /// next week — a silent supply-chain drift the user never sees.
    private static func buildArguments(for package: MCPRegistryPackage) -> [String] {
        var arguments = package.runtimeArguments.flatMap(\.argvComponents)

        // npx needs `-y` or it prompts on stdin — which, on a stdio transport, deadlocks the
        // handshake instead of asking anyone anything.
        if package.effectiveRuntime == "npx" && !arguments.contains("-y") && !arguments.contains("--yes") {
            arguments.insert("-y", at: 0)
        }

        arguments.append(package.pinnedIdentifier)
        arguments.append(contentsOf: package.packageArguments.flatMap(\.argvComponents))
        return arguments
    }

    // MARK: - Persistence shape

    /// The `ServerDefinition` this plan would save. Secrets are NOT included — env values
    /// go to Keychain via `MCPRuntimeSecrets`, per the definition's secret-handling contract.
    func makeServerDefinition() -> ServerDefinition? {
        switch kind {
        case .local(_, let command, let arguments):
            guard !command.isEmpty else { return nil }
            let keys = environmentVariables.map(\.name).filter { !$0.isEmpty }.sorted()
            return ServerDefinition(
                command: command,
                args: arguments,
                envKeys: keys.isEmpty ? nil : keys
            )
        case .remote(let url, let transport):
            guard !url.isEmpty else { return nil }
            return ServerDefinition(url: url, transport: transport)
        }
    }
}
