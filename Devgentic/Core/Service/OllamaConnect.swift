//
//  OllamaConnect.swift
//  Devgentic
//
//  Refactored to pure API Client.
//  Handles server status, model management, and VRAM memory lifecycle.
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
    /// Authoritative capability list reported by Ollama 0.3.4+.
    /// When present and missing `"tools"`, the server WILL return HTTP 400 if
    /// we pass the `tools` parameter — that's the signal we use to force
    /// `capability = .none` in `cognitiveProfile(modelName:)`. Absent on older
    /// Ollama releases; in that case the heuristic fallback path runs.
    let capabilities: [String]?
    /// Architectural metadata block returned only when `/api/show` is called
    /// with `verbose: true`. Carries GGUF metadata keys like
    /// `{family}.context_length`, `general.parameter_count`, etc. Nil when
    /// `verbose` was omitted or the Ollama version doesn't support it.
    /// Consumed by `buildMetadata()` to populate `ModelMetadata.contextWindow`.
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
        // Authoritative: the daemon declares `thinking` directly (Ollama 0.9+).
        // Renderer-based models (gemma4, qwen3.5, kimi) have no template markers
        // to sniff — the declaration is the only signal they emit.
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

    /// Backward-compatible computed property — delegates to `cognitiveProfile(modelName:)`
    /// with an empty model name. Callers that have the model name available should prefer
    /// the method form because it enables reasoning-only detection for distilled fine-tunes
    /// (deepseek-r1 family reports family="qwen2" which would otherwise bypass the gate).
    var cognitiveProfile: CognitiveProfile {
        cognitiveProfile(modelName: "")
    }

    /// Returns the full CognitiveProfile (capability + dialect) for this Ollama model.
    ///
    /// Resolution, with `toolSupportCaveat` qualifying every non-clean verdict so
    /// pickers can explain instead of silently hiding:
    ///
    /// **Capabilities field present** (Ollama 0.3.4+ — authoritative both ways):
    /// 1. Lacks `"tools"` → `.none` + `.serverRejectsTools`. The server WILL reject
    ///    any tools-param request with HTTP 400; no heuristic may second-guess this.
    /// 2. Contains `"tools"` → `.parallelActions`. That IS the server's contract —
    ///    it accepts the tools param and normalizes calls to standard JSON regardless
    ///    of template internals. Renderer-based models (gemma4, qwen3.5, kimi-k2:
    ///    template is just `{{ .Prompt }}`, unknown family) carry no heuristic signal,
    ///    so falling through would misclassify them. Reasoning-focused fine-tunes
    ///    (deepseek-r1, qwq, gpt-oss) additionally get `.reasoningFocused` — they stay
    ///    selectable (the server accepts tools) but pickers surface a reliability
    ///    warning; hiding them was a quality judgment expressed as a protocol gate.
    ///
    /// **No capabilities field** (legacy daemons):
    /// 3. Reasoning-only pattern match → `.none` + `.reasoningFocused`. Without the
    ///    authoritative field we can't verify the server accepts tools for these
    ///    distilled fine-tunes (deepseek-r1:14b reports the tool-capable BASE family
    ///    qwen2), so they stay blocked — but visibly, with the reason attached.
    /// 4. Template/family heuristics, unchanged. A no-signal `.none` result carries
    ///    `.undetected` so the UI can say "can't verify" rather than nothing.
    ///
    /// - Parameter modelName: The Ollama model identifier (e.g. `"deepseek-r1:14b"`).
    ///   Pass `""` if unavailable — reasoning-only detection will still run against
    ///   family/families, but will miss distilled fine-tunes that hide behind a base family.
    func cognitiveProfile(modelName: String) -> CognitiveProfile {
        let metadata = buildMetadata()
        let familyStr = details?.family?.lowercased() ?? ""
        let familiesArr = details?.families?.map { $0.lowercased() } ?? []

        // Vision modality is independent of tool capability — a vision model may not do
        // tools, and a tool model may not do vision — so it's computed once here and
        // threaded into every return path below (incl. the `.none` short-circuits).
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

            // Authoritative allow. Heuristics may still contribute a specific dialect
            // (e.g. <tool_call> templates → .mistralXML), but a no-signal template must
            // not demote the model. `.nativeJSON` is the honest default label: Ollama's
            // API returns tool calls as standard JSON whatever the template looks like.
            // Reasoning-focused fine-tunes stay selectable (the server accepts tools)
            // and carry the reliability caveat for pickers to surface.
            let heuristic = computeHeuristicProfile(metadata: metadata)
            let dialect: ModelDialect = heuristic.dialect == .heuristicJson ? .nativeJSON : heuristic.dialect
            let caveat: ToolSupportCaveat? = isReasoningFocused ? .reasoningFocused : nil
            logger.info("cognitiveProfile: /api/show capabilities contains 'tools' — authoritative allow for '\(modelName)' (dialect: \(String(describing: dialect))\(isReasoningFocused ? ", reasoning-focused caveat" : ""))")
            return CognitiveProfile(capability: .parallelActions, dialect: dialect, metadata: metadata, modalities: modalities, toolSupportCaveat: caveat)
        }

        // --- No capabilities field: legacy daemon, heuristics only ---

        // Reasoning-only pattern match. Without the authoritative field we can't verify
        // the server accepts tools for these distilled fine-tunes (family reports the
        // tool-capable BASE architecture, e.g. qwen2 for deepseek-r1:14b) — blocked,
        // but with the reason attached so pickers can explain it.
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

    /// Vision-input detection for an Ollama model, in priority order:
    /// 1. AUTHORITATIVE — the `/api/show` `capabilities` array contains `"vision"`
    ///    (Ollama ~0.3.4+; the same array we already trust for tool-capability gating).
    /// 2. FALLBACK (older daemons with no `capabilities` field) — a bundled CLIP vision
    ///    projector reported in `details.families` (`OllamaModelDetails.supportsVision`).
    /// When `capabilities` IS present but lacks `"vision"`, that's an authoritative NO —
    /// we do NOT fall back (avoids a false positive from a stray projector entry).
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

        // Secondary dialect signals: chat-format structure that reveals the model's
        // trained output dialect even when explicit tool injection points are absent.
        // Used as tiebreakers for singleAction models that only have modelfile hints.
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

        // --- DIALECT DETECTION ---
        //
        // Primary signals (tool markers) are consumed by capability detection above,
        // so for singleAction models they are guaranteed false. Secondary signals
        // (chat-format structure) provide dialect inference for that tier.

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

    /// Populates `ModelMetadata` from the `/api/show` details. Extracted so both
    /// the short-circuit paths (capabilities-authoritative, reasoning-only) and the
    /// heuristic path produce fully-populated metadata instead of defaulting the
    /// tier/quant/family fields to nil when the model is force-classified as `.none`.
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

        // Extract context window from GGUF model_info when available
        // (Ollama returns this only when /api/show is called with verbose: true).
        // Drives the UI's `numCtx` upper bound and the runtime memory-budget
        // calculation in AgentConnect.
        metadata.contextWindow = inferredContextWindow

        return metadata
    }

    /// Extracts the context length from `model_info[*.context_length]`. GGUF
    /// metadata uses the architecture name as a prefix (e.g.
    /// `llama.context_length` for Llama models, `mistral.context_length` for
    /// Mistral). Tries the family-prefixed key first; falls back to a
    /// suffix scan for non-standard architectures or multi-family models
    /// where `details.family` doesn't match the GGUF architecture identifier.
    /// Returns nil when `model_info` is missing (older Ollama, non-verbose
    /// response) or no `*.context_length` key is present.
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
    
    // Note: supportsToolUse was relocated to OllamaShowResponse because
    // it requires access to the model 'template' property to accurately evaluate.

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

    /// Daemon version from `/api/version`. Used to invalidate cached model detection:
    /// a daemon upgrade can change what `/api/show` reports (capabilities, template)
    /// for the SAME model digest. Returns nil on any failure — absence just means
    /// digest-only revalidation.
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
        // `verbose: true` requests the GGUF `model_info` block in addition to
        // the basic fields. Used to extract `{family}.context_length` for
        // populating `ModelMetadata.contextWindow`. Older Ollama versions
        // (pre-0.3.x) silently ignore the param — `model_info` simply stays
        // nil in the decoded response and we fall back to the catalog/default.
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

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300.0
            config.timeoutIntervalForResource = 1800.0
            let session = URLSession(configuration: config)

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
