// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

// MARK: - Logger
private let logger = DGLogger(category: "OllamaConnect")

// MARK: - Ollama Data Structures

/// Represents the progress information during a model pull.
struct ModelPullProgress {
    let status: String
    let total: Int64?
    let completed: Int64?
    let percentage: Double?
    let error: String?
}

/// Represents the full details of a single model from the `/api/show` endpoint.
struct OllamaShowResponse: Codable {
    let license: String?
    let modelfile: String?
    let parameters: String?
    let template: String?
    let details: OllamaModelDetails?
    /// Authoritative capability list reported by Ollama 0.3.4+; nil on older releases, where the heuristic path runs.
    /// When present without `"tools"`, the server rejects the `tools` parameter with HTTP 400, so
    /// `cognitiveProfile(modelName:)` forces `.none`.
    let capabilities: [String]?
    /// Architectural metadata (GGUF keys such as `{family}.context_length`), returned only when `/api/show` is called
    /// with `verbose: true`. Nil when `verbose` was omitted or the Ollama version does not support it;
    /// `buildMetadata()` reads it for `ModelMetadata.contextWindow`.
    let modelInfo: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case license, modelfile, parameters, template, details, capabilities
        case modelInfo = "model_info"
    }

    /// Evaluates the model's true capabilities by inspecting the template, family, and modelfile.
    /// This dictates the cognitive tier of the model. (Backward-compatible accessor.)
    var cognitiveCapability: ModelCognitiveCapability {
        cognitiveProfile.capability
    }

    /// Detects whether the model supports Ollama's `think` parameter on /api/chat.
    /// Sending `think: true` to a model that doesn't support it returns HTTP 400,
    /// so this is used at model-selection time to seed `ProviderConfig.thinkingEnabled`.
    var supportsThinking: Bool {
        // Authoritative: the daemon declares `thinking` directly (Ollama 0.9+). Renderer-based models have no template
        // markers to sniff, so the declaration is the only signal.
        if capabilities?.contains("thinking") == true { return true }

        let templateStr = template?.lowercased() ?? ""
        let familyStr = details?.family?.lowercased() ?? ""
        let familiesArr = details?.families?.map { $0.lowercased() } ?? []
        let modelfileStr = modelfile?.lowercased() ?? ""

        // Strong signal: explicit thinking tokens in chat template
        if templateStr.contains("<think>") ||
           templateStr.contains("<|thinking|>") ||
           templateStr.contains("<|start_thinking|>") ||
           templateStr.contains("{{ .thinking }}") ||
           templateStr.contains("{{.thinking}}") {
            return true
        }

        // Known reasoning families (as of Ollama 2026-04)
        let thinkingFamilies = ["deepseek-r1", "qwq", "qwen3", "magistral", "gpt-oss"]
        if thinkingFamilies.contains(where: { familyStr.contains($0) }) ||
           familiesArr.contains(where: { fam in thinkingFamilies.contains(where: { fam.contains($0) }) }) {
            return true
        }

        // Modelfile declaration hint (weaker signal, but still useful)
        if modelfileStr.contains("<think>") || modelfileStr.contains("reasoning_content") {
            return true
        }

        return false
    }

    /// Computed form of `cognitiveProfile(modelName:)` with an empty model name. Prefer the method form when the name
    /// is known: it enables reasoning-only detection for distilled fine-tunes whose family hides behind a base family.
    var cognitiveProfile: CognitiveProfile {
        cognitiveProfile(modelName: "")
    }

    /// Returns the full `CognitiveProfile` (capability and dialect) for this Ollama model. A present `capabilities`
    /// field is authoritative (no `"tools"` gives `.none`, else `.parallelActions`); without it, name and template
    /// heuristics apply. `modelName` may be empty, which can miss distilled reasoning fine-tunes.
    func cognitiveProfile(modelName: String) -> CognitiveProfile {
        let metadata = buildMetadata()
        let familyStr = details?.family?.lowercased() ?? ""
        let familiesArr = details?.families?.map { $0.lowercased() } ?? []

        // Vision modality is independent of tool capability, so it is computed once and threaded into every return path.
        let modalities = Self.detectVisionModalities(capabilities: capabilities, details: details)

        let isReasoningFocused = ModelCapabilityHeuristics.isReasoningOnly(
            in: [modelName, familyStr] + familiesArr
        )

        // --- Capabilities field present: authoritative both ways ---
        if let caps = capabilities {
            if !caps.contains("tools") {
                // HARD deny — any tools-param request will 400.
                logger.info("cognitiveProfile: /api/show capabilities=\(caps) lacks 'tools' — forcing .none (authoritative)")
                return CognitiveProfile(capability: .none, dialect: .heuristicJson, metadata: metadata, modalities: modalities, toolSupportCaveat: .serverRejectsTools)
            }

            // Authoritative allow: heuristics may still contribute a dialect, but a no-signal template must not demote the
            // model; `.nativeJSON` is the default label because Ollama returns tool calls as standard JSON.
            let heuristic = computeHeuristicProfile(metadata: metadata)
            let dialect: ModelDialect = heuristic.dialect == .heuristicJson ? .nativeJSON : heuristic.dialect
            let caveat: ToolSupportCaveat? = isReasoningFocused ? .reasoningFocused : nil
            logger.info("cognitiveProfile: /api/show capabilities contains 'tools' — authoritative allow for '\(modelName)' (dialect: \(String(describing: dialect))\(isReasoningFocused ? ", reasoning-focused caveat" : ""))")
            return CognitiveProfile(capability: .parallelActions, dialect: dialect, metadata: metadata, modalities: modalities, toolSupportCaveat: caveat)
        }

        // --- No capabilities field: legacy daemon, heuristics only ---

        // Reasoning-only pattern match: without the authoritative field the server's tool acceptance cannot be verified
        // for these fine-tunes, so they stay blocked with the reason attached.
        if isReasoningFocused {
            logger.info("cognitiveProfile: reasoning-only pattern matched for name='\(modelName)' family='\(familyStr)' (no capabilities field) — forcing .none")
            return CognitiveProfile(capability: .none, dialect: .heuristicJson, metadata: metadata, modalities: modalities, toolSupportCaveat: .reasoningFocused)
        }

        // Template/family heuristics. A no-signal .none carries .undetected so the UI
        // can say "can't verify" rather than silently hiding the model.
        var profile = computeHeuristicProfile(metadata: metadata)
        profile.modalities = modalities
        if profile.capability == .none {
            profile.toolSupportCaveat = .undetected
        }
        return profile
    }

    /// Detects vision input for an Ollama model. Authoritative when the `capabilities` array is present: it contains
    /// `"vision"` or not, with no fallback. Older daemons fall back to a bundled CLIP projector in `details.families`.
    static func detectVisionModalities(capabilities: [String]?, details: OllamaModelDetails?) -> SupportedModalities {
        if let caps = capabilities {
            return caps.contains("vision") ? .visionCapable : .textOnly
        }
        return (details?.supportsVision == true) ? .visionCapable : .textOnly
    }

    /// Heuristic capability + dialect detection from template, modelfile, and family.
    /// Runs only after the authoritative and reasoning-only gates have passed.
    private func computeHeuristicProfile(metadata: ModelMetadata) -> CognitiveProfile {
        let templateStr = template?.lowercased() ?? ""
        let modelfileStr = modelfile?.lowercased() ?? ""
        let familyStr = details?.family?.lowercased() ?? ""
        let familiesArr = details?.families?.map { $0.lowercased() } ?? []

        // --- CAPABILITY DETECTION ---

        // 1. High Signal: Native Go Template Integration
        let hasNativeTemplateTools = templateStr.contains("{{ .tools }}") ||
                                     templateStr.contains("{{.tools}}") ||
                                     templateStr.contains("{{- if .tools }}")

        // Separate check: XML-style tool markers used by some Mistral variants in Ollama
        let hasMistralXMLMarker = templateStr.contains("<tool_call>") ||
                                  templateStr.contains("[tool_calls]") ||
                                  templateStr.contains("<function_call>")

        // [available_tools] is a ReAct-style injection marker
        let hasReActMarker = templateStr.contains("[available_tools]")

        // Secondary dialect signals: chat-format structure that reveals the trained output dialect when tool markers are
        // absent; tiebreakers for singleAction models.
        let hasMistralChatStructure = templateStr.contains("[inst]") || templateStr.contains("[/inst]")
        let hasReActStructureHints  = (templateStr.contains("thought:") && templateStr.contains("action:")) ||
                                      (modelfileStr.contains("thought:") && modelfileStr.contains("action:"))

        // 2. High Signal: Known Capable Architecture Families
        let knownParallelFamilies = ["llama3.1", "llama3.2", "qwen2", "qwen2.5", "mistral", "hermes", "command-r"]
        let isCapableFamily = knownParallelFamilies.contains(where: { familyStr.contains($0) }) ||
                              familiesArr.contains(where: { fam in knownParallelFamilies.contains(where: { fam.contains($0) }) })

        // 3. Fallback Signal: Modelfile hints
        let hasModelfileTools = modelfileStr.contains("tool") ||
                                modelfileStr.contains("function calling") ||
                                modelfileStr.contains("json_schema")

        let capability: ModelCognitiveCapability
        if hasNativeTemplateTools || hasMistralXMLMarker || hasReActMarker || isCapableFamily {
            capability = .parallelActions
        } else if hasModelfileTools {
            capability = .singleAction
        } else {
            capability = .none
        }

        // Dialect detection. Primary tool-marker signals are consumed by capability detection, so for singleAction models
        // they are false; secondary chat-format signals infer the dialect for that tier.

        let dialect: ModelDialect
        if capability == .none {
            dialect = .heuristicJson
        } else if hasMistralXMLMarker {
            // Template uses <tool_call> / <function_call> XML-style wrapping
            dialect = .mistralXML
        } else if hasReActMarker {
            // Template uses [available_tools] ReAct-style injection
            dialect = .reactMarkdown
        } else if hasNativeTemplateTools || isCapableFamily {
            // Modern {{ .Tools }} Go template: OpenAI-compatible native JSON arrays
            dialect = .nativeJSON
        } else if hasMistralChatStructure {
            // No explicit tool markers, but [INST]/[/INST] chat format reveals Mistral
            // lineage — these models were fine-tuned with XML-style tool output.
            dialect = .mistralXML
        } else if hasReActStructureHints {
            // Thought/Action markers in template or modelfile indicate ReAct prompting.
            dialect = .reactMarkdown
        } else {
            // No structural dialect hints: fall back to prompted flat JSON
            dialect = .heuristicJson
        }

        return CognitiveProfile(capability: capability, dialect: dialect, metadata: metadata)
    }

    /// Populates `ModelMetadata` from the `/api/show` details, so the short-circuit paths and the heuristic path all
    /// return full metadata.
    private func buildMetadata() -> ModelMetadata {
        var metadata = ModelMetadata(tier: .small) // Default

        if let detailObj = details {
            if let billions = ModelFitAdvisor.parseParameterCount(detailObj.parameterSize) {
                if billions < 4 { metadata.tier = .tiny }
                else if billions < 15 { metadata.tier = .small }
                else if billions < 45 { metadata.tier = .medium }
                else if billions < 100 { metadata.tier = .large }
                else { metadata.tier = .ultra }
            }

            metadata.quantization = detailObj.quantizationLevel
            metadata.family = detailObj.family
            metadata.parameterCount = detailObj.parameterSize
        }

        // Context window from the GGUF `model_info`, available only when `/api/show` is called with `verbose: true`.
        // Drives the UI's `numCtx` upper bound and the memory-budget calculation in AgentConnect.
        metadata.contextWindow = inferredContextWindow

        return metadata
    }

    /// Extracts the context length from `model_info[*.context_length]`: tries the family-prefixed key first, then a
    /// suffix scan for non-standard architectures. Returns nil when `model_info` is missing or has no
    /// `*.context_length` key.
    private var inferredContextWindow: Int? {
        guard let info = modelInfo else { return nil }
        let family = details?.family?.lowercased() ?? ""
        // 1. Exact family-prefixed key
        if !family.isEmpty, let v = info["\(family).context_length"]?.intValue, v > 0 {
            return v
        }
        // 2. Fallback: any key ending in `.context_length`
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let v = value.intValue, v > 0 { return v }
        }
        return nil
    }
}

/// Represents the detailed information about a model's capabilities.
struct OllamaModelDetails: Codable, Hashable {
    let format: String?
    let family: String?
    let families: [String]?
    let parameterSize: String?
    let quantizationLevel: String?
    
    // Computed properties to determine capabilities
    var supportsVision: Bool {
        return family?.lowercased() == "clip" || families?.contains("clip") ?? false
    }
    
    /// Parses `parameterSize` (e.g. "7B", "70B", "1.5B", "400M") into a sortable numeric value in billions.
    var parameterSizeValue: Double {
        guard let raw = parameterSize?.uppercased() else { return 0 }
        let numeric = raw.filter { $0.isNumber || $0 == "." }
        guard let value = Double(numeric) else { return 0 }
        if raw.hasSuffix("M") { return value / 1000 }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case format, family, families
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

// MARK: - API Client

struct OllamaConnect {
    
    // MARK: - Core Server Status

    static func checkOllamaServerStatus(baseURL: String) async -> Bool {
        logger.debug("Checking Ollama server status at \(baseURL)...")
        do {
            let (_, response) = try await performRequest(
                endpoint: "/api/version",
                method: "GET",
                baseURL: baseURL,
                timeout: 5.0
            )
            return (200..<300).contains(response.statusCode)
        } catch {
            logger.error("Server status check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Model Management

    /// One `/api/tags` entry: model name plus its blob digest. The digest is the
    /// cheap change-detector — same digest ⇒ the expensive `/api/show` detection
    /// result is still valid and can be reused from cache.
    struct OllamaTagEntry: Equatable, Sendable {
        let name: String
        let digest: String?
    }

    static func fetchLocalOllamaModels(baseURL: String) async throws -> [String] {
        try await fetchLocalOllamaModelTags(baseURL: baseURL).map(\.name)
    }

    static func fetchLocalOllamaModelTags(baseURL: String) async throws -> [OllamaTagEntry] {
        let (data, response) = try await performRequest(endpoint: "/api/tags", method: "GET", baseURL: baseURL)

        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        return modelsArray.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return OllamaTagEntry(name: name, digest: entry["digest"] as? String)
        }
    }

    /// Daemon version from `/api/version`, for invalidating cached model detection (an upgrade can change what
    /// `/api/show` reports). Returns nil on any failure, meaning digest-only revalidation.
    static func fetchDaemonVersion(baseURL: String) async -> String? {
        do {
            let (data, response) = try await performRequest(endpoint: "/api/version", method: "GET", baseURL: baseURL, timeout: 5.0)
            guard (200..<300).contains(response.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["version"] as? String
        } catch {
            return nil
        }
    }

    static func fetchModelDetails(name: String, baseURL: String) async throws -> OllamaShowResponse {
        // `verbose: true` requests the GGUF `model_info` block (for `{family}.context_length`). Older Ollama versions
        // ignore it, leaving `model_info` nil, and the catalog/default applies.
        let (data, response) = try await performRequest(
            endpoint: "/api/show",
            method: "POST",
            baseURL: baseURL,
            payload: ["name": name, "verbose": true]
        )

        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(OllamaShowResponse.self, from: data)
    }

    static func removeOllamaModel(name: String, baseURL: String) async throws {
        let (data, response) = try await performRequest(
            endpoint: "/api/delete",
            method: "DELETE",
            baseURL: baseURL,
            payload: ["name": name]
        )
        
        guard response.statusCode == 200 else {
            if let errorMsg = parseOllamaErrorResponse(data: data) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama Error: \(errorMsg)"])
            }
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - VRAM / Lifecycle Management

    static func fetchRunningModels(baseURL: String) async throws -> [String] {
        let (data, response) = try await performRequest(endpoint: "/api/ps", method: "GET", baseURL: baseURL)
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Minimal decoder for /api/ps response
        struct ProcessResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        
        let processResponse = try JSONDecoder().decode(ProcessResponse.self, from: data)
        return processResponse.models.map { $0.name }
    }

    static func unloadModel(name: String, baseURL: String) async throws {
        let payload: [String: Any] = [
            "model": name,
            "keep_alive": 0
        ]
        
        let (_, response) = try await performRequest(
            endpoint: "/api/chat", // The chat endpoint handles memory lifecycle when generating is skipped
            method: "POST",
            baseURL: baseURL,
            payload: payload
        )
        
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        logger.info("Successfully sent unload request for model '\(name)'.")
    }

    // MARK: - Streaming Operations (Pull Model)

    /// How long a pull may go without receiving ANY data before it fails. Ollama streams a
    /// progress line for every chunk it writes, so five quiet minutes means the transfer is dead.
    static let pullIdleTimeout: TimeInterval = 300

    /// The cap on the whole pull; the idle timeout above is the real liveness check. This is only a backstop (7 days)
    /// against a connection that trickles forever, and must stay long enough for very large models.
    static let pullResourceTimeout: TimeInterval = 7 * 24 * 60 * 60

    static func pullSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = pullIdleTimeout
        config.timeoutIntervalForResource = pullResourceTimeout
        return config
    }

    @discardableResult
    static func pullOllamaModel(name: String, baseURL: String, progressHandler: @escaping (ModelPullProgress) -> Void) -> Task<Void, Error> {
        return Task {
            guard let url = URL(string: baseURL + "/api/pull") else {
                throw URLError(.badURL)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

            let session = URLSession(configuration: pullSessionConfiguration())

            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                guard let data = line.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let status = json["status"] as? String ?? "unknown status"
                let total = json["total"] as? Int64 ?? json["total_bytes"] as? Int64
                let completed = json["completed"] as? Int64
                let errorMsg = json["error"] as? String

                var percentage: Double? = nil
                if let t = total, let c = completed, t > 0 {
                    percentage = Double(c) / Double(t)
                }

                progressHandler(ModelPullProgress(status: status, total: total, completed: completed, percentage: percentage, error: errorMsg))

                if let streamedError = errorMsg {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: streamedError])
                }
            }
        }
    }

    // MARK: - Internal Networking Helpers
    
    /// A central helper to reduce boilerplate for standard REST requests
    private static func performRequest(
        endpoint: String,
        method: String,
        baseURL: String,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> (Data, HTTPURLResponse) {
        
        guard let url = URL(string: baseURL + endpoint) else {
            logger.error("Invalid URL: \(baseURL)\(endpoint)")
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        
        if let payload = payload {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP Response received."])
        }
        
        return (data, httpResponse)
    }

    private static func parseOllamaErrorResponse(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        return error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
