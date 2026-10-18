// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalResidency.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MLX
import os

private let logger = DGLogger(category: "LocalResidency")

/// The unloads the coordinator orders. A protocol so tests can record them without a model or a server.
@MainActor
protocol LocalResidencyActions: AnyObject {
    /// Unloads the resident MLX agent model unless it is one of `names`. Does nothing when a name
    /// cannot be resolved to an installed model: an unknown keep-list must never evict.
    /// - Parameter reason: who ordered it (the run taking the lock, or quit) — every line names it.
    func unloadMLX(unlessResidentIn names: [String], reason: String) async
    /// Unloads one Ollama model by name — never "everything the server has loaded".
    func unloadOllama(model: String, baseURL: String, reason: String) async
}

/// The real unloads.
@MainActor
final class LiveLocalResidency: LocalResidencyActions {

    func unloadMLX(unlessResidentIn names: [String], reason: String) async {
        await MLXModelService.shared.ensureLoaded()
        let directories = names.compactMap { MLXModelService.shared.installedModel(named: $0)?.localPath }
        guard directories.count == names.count else {
            let unresolved = names.filter { MLXModelService.shared.installedModel(named: $0) == nil }
            logger.notice("[LOCAL-RESIDENCY] Not unloading MLX (\(reason)): \(unresolved.count) MLX model(s) to keep could not be resolved to an installed model [\(unresolved.joined(separator: ", "))]. CONSEQUENCE: whatever is resident stays; an unknown keep-list never evicts.")
            return
        }
        let unloaded = await MLXService.shared.unloadModel(unlessResidentIn: directories, reason: reason)
        logger.debug("[LOCAL-RESIDENCY] MLX residency step (\(reason)): \(unloaded ? "the resident model was unloaded" : "nothing unloaded — no model resident, it is one to keep, or a generation is in flight").")
    }

    func unloadOllama(model: String, baseURL: String, reason: String) async {
        do {
            try await OllamaConnect.unloadModel(name: model, baseURL: baseURL)
            logger.notice("[LOCAL-RESIDENCY] Unloaded Ollama model '\(model)' (\(baseURL)) — \(reason) and does not use it.")
        } catch {
            logger.error("[LOCAL-RESIDENCY] Could not unload Ollama model '\(model)' (\(baseURL)) (\(reason)): \(error.localizedDescription). CONSEQUENCE: it stays loaded until the server's keep-alive ends it; the run is unaffected.")
        }
    }
}

/// MLX's process-wide memory settings, owned in one place. Both MLX containers (the agent model in
/// `MLXService`, the Core Intelligence model) share the process's buffer cache.
enum MLXMemoryPolicy {

    /// The most freed GPU memory MLX keeps for reuse between generations: 2 GB, or a tenth of RAM on a
    /// smaller machine. MLX's own default is the whole memory limit — after a long run the cache could
    /// hold gigabytes nothing was using (gap G5).
    static func cacheLimitBytes(physicalMemory: UInt64) -> Int {
        Int(min(UInt64(2) << 30, physicalMemory / 10))
    }

    /// Sets the cache limit once per process. Idempotent.
    static func configure() {
        configureOnce
    }

    private static let configureOnce: Void = {
        let limit = cacheLimitBytes(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        MLX.Memory.cacheLimit = limit
        logger.notice("[LOCAL-RESIDENCY] MLX buffer cache capped at \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)) (RAM \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))). CONSEQUENCE: freed GPU memory above this is returned to the system instead of kept for reuse.")
    }()

    /// Returns the process's freed-but-cached MLX buffers to the system. The ONE caller of
    /// `Memory.clearCache` — it clears for every container in the process, so its callers are named.
    static func clearBufferCache(caller: String) {
        MLX.Memory.clearCache()
        logger.debug("[LOCAL-RESIDENCY] MLX buffer cache cleared by \(caller).")
    }
}
