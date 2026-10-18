// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  IntelligenceCoreService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import os

// MARK: - IC Caller Identification

/// Identifies which feature is invoking the Intelligence Core.
/// Used for structured logging and diagnostics.
enum ICCallerFeature: String, Sendable {
    case ragRewriting = "RAG Query Rewriting"
    case briefing = "Briefing"
    case suggestion = "Context-Aware Suggestion"
    case userPersonal = "User Personal"
    case responseSynthesis = "Response Synthesis"
    case historyCompaction = "History Compaction"
    case unknown = "Unknown"
}

/// A service for managing the Intelligence Core MLX model.
/// Uses whichever model the user has selected in Core Intelligence settings
/// from the standard MLX Model Store — no bundled/built-in model.
actor IntelligenceCoreService {

    static let shared = IntelligenceCoreService()

    private static let logger = DGLogger(category: "IntelligenceCoreService")
    private var logger: DGLogger { Self.logger }

    /// Which model is resident and the one load in flight; see `ICModelResidency`.
    private let residency: ICModelResidency<ModelContainer>

    /// Cumulative inference count since app launch.
    private var totalInferenceCount: Int = 0

    // Why: a session that never starts `MLXService` would otherwise run with MLX's default cache, as large as the memory limit.
    /// Configures the MLX memory policy at init: the buffer-cache cap is set by whichever MLX container starts first.
    private init() {
        MLXMemoryPolicy.configure()
        residency = ICModelResidency(
            selection: { Self.selectedModelName },
            idleReleaseSeconds: Self.idleReleaseSeconds,
            loader: { name, caller, loadID in try await Self.loadContainer(named: name, caller: caller, loadID: loadID) },
            onFree: { name, _, _ in Self.didFree(name) }
        )
    }

    // MARK: - Model Resolution

    /// The user-selected model name from UserDefaults, or empty if none selected.
    private static var selectedModelName: String {
        UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? ""
    }

    /// Whether a model has been selected in Core Intelligence settings.
    var hasModelSelected: Bool {
        !Self.selectedModelName.isEmpty
    }

    /// Resolves the local path of `modelName` from MLXModelService.
    private static func resolveModelPath(_ modelName: String) async -> URL? {
        guard !modelName.isEmpty else { return nil }
        // See AgentConnect: the scan is off-actor, so wait for it rather than risk
        // reading an empty list and rejecting a model that is installed.
        await MLXModelService.shared.ensureLoaded()
        return await MainActor.run {
            MLXModelService.shared.installedModel(named: modelName)?.localPath
        }
    }

    // MARK: - Memory Snapshot

    /// Captures a snapshot of current memory state for logging.
    private static func memorySnapshot() -> (available: String, gpuCache: String) {
        let profile = SystemHardwareProfiler.shared.profile
        let gpuActive = MLX.GPU.activeMemory
        let gpuCache = MLX.GPU.cacheMemory
        let availableStr = profile.formattedAvailableRAM
        let gpuStr = "active=\(ByteCountFormatter.string(fromByteCount: Int64(gpuActive), countStyle: .memory)), cache=\(ByteCountFormatter.string(fromByteCount: Int64(gpuCache), countStyle: .memory))"
        return (availableStr, gpuStr)
    }

    // MARK: - Model Lifecycle

    /// Loads the user-selected model into memory (or reuses it if it is already resident).
    /// - Parameter caller: The feature requesting the load — used for diagnostics.
    func load(caller: ICCallerFeature = .unknown) async throws {
        _ = try await residency.prepare(caller: caller)
    }

    /// The residency's loader: resolves `name` on disk and loads it. Only `ICModelResidency` calls
    /// this, and it never runs two at once.
    private static func loadContainer(named name: String, caller: ICCallerFeature, loadID: String) async throws -> ModelContainer {
        guard !name.isEmpty else {
            logger.error("[IC Load] load \(loadID) REJECTED — No model selected. Caller: \(caller.rawValue)")
            throw NSError(
                domain: "IntelligenceCoreService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "No Intelligence Core model selected. Choose one in Settings → Core Intelligence."]
            )
        }

        guard let localPath = await resolveModelPath(name) else {
            logger.error("[IC Load] load \(loadID) REJECTED — Model '\(name)' not found on disk. Caller: \(caller.rawValue)")
            throw NSError(
                domain: "IntelligenceCoreService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Selected model '\(name)' not found. It may have been deleted from the Model Store."]
            )
        }

        let preMemory = memorySnapshot()
        let loadStart = CFAbsoluteTimeGetCurrent()

        logger.notice("[IC Load] load \(loadID) BEGIN — Model: \(name), Caller: \(caller.rawValue)")
        logger.info("[IC Load] load \(loadID) Pre-load memory — System: \(preMemory.available), GPU: \(preMemory.gpuCache)")

        // `loadModelContainer(from:using:)` takes the tokenizer from our own bridge, backed by swift-transformers'
        // AutoTokenizer (see MLXTokenizerBridge.swift).
        let container = try await MLXLMCommon.loadModelContainer(
            from: localPath,
            using: HuggingFaceTokenizerLoader()
        )

        let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
        let postMemory = memorySnapshot()

        logger.notice("[IC Load] load \(loadID) COMPLETE — '\(name)' in \(String(format: "%.2f", loadDuration))s, Caller: \(caller.rawValue)")
        logger.info("[IC Load] load \(loadID) Post-load memory — System: \(postMemory.available), GPU: \(postMemory.gpuCache)")
        return container
    }

    // MARK: - Release Policy
    // The IC model is shared by features that run in sequence in one turn, so `releaseHold` only marks it
    // releasable and the free happens after an idle grace period; leases stop one feature freeing it mid-generation.

    /// Seconds the model stays resident after the last feature releases it.
    private static let idleReleaseSeconds: Double = 60

    /// Signals that `caller` is finished with the model. Does NOT free immediately — see
    /// the release-policy note above. Safe to call while other features are mid-flight.
    func releaseHold(caller: ICCallerFeature = .unknown) async {
        await residency.requestRelease(caller: caller)
    }

    /// Frees the model as soon as it is safe to do so, skipping the idle grace period.
    /// For deliberate teardown, e.g. Core Intelligence switched off; a changed IC model is swapped by the next request.
    func unloadNow(caller: ICCallerFeature = .unknown) async {
        await residency.requestImmediateRelease(caller: caller)
    }

    /// The residency dropped `name`: give the buffer cache back and log the effect.
    private static func didFree(_ name: String) {
        let preMemory = memorySnapshot()
        MLXMemoryPolicy.clearBufferCache(caller: "Core Intelligence unload")
        let postMemory = memorySnapshot()
        logger.info("[IC Unload] '\(name)' memory freed — Before GPU: \(preMemory.gpuCache) → After GPU: \(postMemory.gpuCache)")
    }

    // MARK: - Inference

    /// Generates a response from the Intelligence Core model (collects all tokens).
    /// `messages` are `[role: content]` chat messages; `maxTokens` and `temperature` bound sampling;
    /// `caller` names the requesting feature.
    func generate(messages: [[String: String]], maxTokens: Int = 1024, temperature: Float = 0.6, caller: ICCallerFeature = .unknown) async throws -> String {
        // Loads (or joins the load of, or reuses) the SELECTED model and takes a lease in one step,
        // so no other feature can free the model (or clear the GPU cache) mid-inference.
        let container = try await residency.beginGeneration(caller: caller)

        let genStart = CFAbsoluteTimeGetCurrent()
        let promptTokenCount = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) / 4 } // Rough estimate
        totalInferenceCount += 1
        let inferenceNum = totalInferenceCount

        logger.notice("[IC Generate #\(inferenceNum)] BEGIN — Caller: \(caller.rawValue), maxTokens: \(maxTokens), temp: \(temperature), ~promptTokens: \(promptTokenCount)")

        let wrapped = UnsafeSendable(messages)
        let result: String
        do {
            result = try await container.perform { context in
                let promptTokens = try context.tokenizer.applyChatTemplate(messages: wrapped.value.map { $0 as [String: any Sendable] })
                let lmInput = LMInput(tokens: MLXArray(promptTokens))
                let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)

                let stream = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context
                )

                var fullText = ""
                for await generation in stream {
                    if case .chunk(let text) = generation {
                        fullText += text
                    }
                }
                return fullText
            }
        } catch {
            await residency.endGeneration(caller: caller)
            throw error
        }
        await residency.endGeneration(caller: caller)

        // `MLXLMCommon.generate`'s stream ends normally on cancellation, so a stopped call must not return its partial text
        // as the answer: a half-written synthesis would be reported as success.
        if Task.isCancelled {
            logger.notice("[IC Generate #\(inferenceNum)] CANCELLED after \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - genStart))s, \(result.count) chars, Caller: \(caller.rawValue). CONSEQUENCE: the partial text is discarded and the caller sees a cancellation.")
            throw CancellationError()
        }

        let genDuration = CFAbsoluteTimeGetCurrent() - genStart
        let outputTokenEstimate = result.count / 4
        let tokPerSec = genDuration > 0 ? Double(outputTokenEstimate) / genDuration : 0

        logger.notice("[IC Generate #\(inferenceNum)] COMPLETE — \(String(format: "%.2f", genDuration))s, ~\(outputTokenEstimate) output tokens, ~\(String(format: "%.1f", tokPerSec)) tok/s, Caller: \(caller.rawValue)")

        let postMemory = Self.memorySnapshot()
        logger.info("[IC Generate #\(inferenceNum)] Post-generate GPU: \(postMemory.gpuCache)")

        return result
    }
}
