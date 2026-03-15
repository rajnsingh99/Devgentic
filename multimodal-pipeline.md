# Devgentic Architecture: Multimodal Pipeline Migration — Final Blueprint

## Executive Summary

This document is the finalized, gap-resolved migration plan for transitioning Devgentic from a text-optimized orchestration engine to a natively multimodal system. It addresses 11 architectural blind spots discovered during critical analysis of the initial proposal against the actual codebase, and is structured for strict sequential rollout with zero disruption to existing HITL, Ghost Protocol, workflow DAG, and dialect-routing systems.

The migration is organized into 7 phases, ordered by dependency depth and blast radius.

---

## Phase 1A: Core Type System — The Block Protocol

### 1A.1 Introduce `MessageBlock` (New File: `Core/Types/MessageBlock.swift`)

```swift
/// Atomic unit of multimodal content.
/// Sendable + Codable by construction — safe across all actor boundaries.
public enum MessageBlock: Sendable, Codable, Hashable {
    case text(String)
    case image(ImagePayload)
    case toolCall(id: String, name: String, arguments: [String: JSONValue])
    case toolResult(toolCallId: String, content: [MessageBlock])
    case audio(AudioPayload)    // Future: pluggable
    case video(VideoPayload)    // Future: pluggable

    /// Deterministic text projection for contexts that cannot handle media.
    /// Used by context compressors, working memory, and non-vision models.
    var textFallback: String { ... }
}
```

**Supporting payload structs** (same file):

```swift
public struct ImagePayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String           // "image/png", "image/jpeg", "image/webp"
    public let alt: String?               // Accessibility text
    public let dimensions: CGSize?        // Optional, populated after load
}

public struct AudioPayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String
    public let durationSeconds: Double?
}

public struct VideoPayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String
    public let durationSeconds: Double?
    public let thumbnailReference: MediaReference?
}

/// Unified reference: binary data lives on disk, never in message graphs.
public enum MediaReference: Sendable, Codable, Hashable {
    case diskPath(URL)                    // File URL — primary storage
    case remoteURL(URL)                   // External URL (e.g., user-provided image link)
    case ephemeralData(Data)              // Transient only — must be flushed to disk before storage

    /// Resolves to raw bytes. Loads from disk/network as needed.
    func resolve() async throws -> Data
}
```

### 1A.2 Introduce `Payload` Typealias (NOT `MessageContent`)

**Critical:** The name `MessageContent` is already taken by the UI layer's `ChatMessage.MessageContent` enum. We use `Payload` to avoid collision.

```swift
/// A complete multimodal message payload.
public typealias Payload = [MessageBlock]

extension Array where Element == MessageBlock {
    /// Concatenated text projection (for backward-compat and memory).
    var textContent: String {
        compactMap { block in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    /// All non-text media blocks.
    var mediaBlocks: [MessageBlock] { filter { if case .text = $0 { return false }; return true } }

    /// True if payload contains only text blocks.
    var isTextOnly: Bool { mediaBlocks.isEmpty }
}
```

### 1A.3 Introduce `SupportedModalities` on `CognitiveProfile`

The current `CognitiveProfile` has `capability` (tool-calling tier) and `dialect` (output format). It lacks modality awareness.

```swift
/// Add to CognitiveProfile.swift
public struct SupportedModalities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    static let textInput     = SupportedModalities(rawValue: 1 << 0)
    static let textOutput    = SupportedModalities(rawValue: 1 << 1)
    static let visionInput   = SupportedModalities(rawValue: 1 << 2)
    static let imageOutput   = SupportedModalities(rawValue: 1 << 3)  // Future: imageGen
    static let audioInput    = SupportedModalities(rawValue: 1 << 4)  // Future
    static let audioOutput   = SupportedModalities(rawValue: 1 << 5)  // Future

    /// Default for text-only models.
    static let textOnly: SupportedModalities = [.textInput, .textOutput]

    /// Cloud frontier models with vision.
    static let visionCapable: SupportedModalities = [.textInput, .textOutput, .visionInput]
}

// Update CognitiveProfile:
public struct CognitiveProfile: Codable, Hashable, Sendable {
    let capability: ModelCognitiveCapability
    let dialect: ModelDialect
    var metadata: ModelMetadata?
    var modalities: SupportedModalities = .textOnly  // NEW — backward-compat default

    static let cloudNative = CognitiveProfile(
        capability: .parallelActions, dialect: .nativeJSON, modalities: .visionCapable
    )
    // ... existing presets updated
}
```

**Detection integration:**
- `MLXTokenizerAnalyzer.detectCognitiveProfile()` → set `.textOnly` or `.visionCapable` based on model config (e.g., LLaVA variants get `.visionCapable`).
- `OllamaShowResponse.cognitiveProfile` → parse `modelfile` capabilities for vision support.
- Cloud providers (Anthropic/OpenAI/Gemini) → hardcode `.visionCapable` for known vision models, `.textOnly` otherwise.

**Risk:** Low. Additive change with backward-compatible defaults.

---

## Phase 1B: Type Safety — `AnyCodable` → `JSONValue` Migration

This phase was originally "Phase 6 — optional." It is **mandatory** because `AnyCodable` wraps `Any` with `@unchecked Sendable`, which is a correctness hazard under Swift 6 strict concurrency when values cross actor boundaries (e.g., `ExecutionSuspensionService`, `WorkflowExecutor`).

### 1B.1 Migration Targets

| Location | Current Type | New Type |
|----------|-------------|----------|
| `PendingToolCall.arguments` | `[String: AnyCodable]` | `[String: JSONValue]` |
| `ToolExecutionMediator.prepareDispatch(arguments:)` | `[String: AnyCodable]` | `[String: JSONValue]` |
| `ToolExecutionMediator.executePreparedTool(arguments:)` | `[String: AnyCodable]` | `[String: JSONValue]` |
| `ProviderConfig.advancedConfiguration` | `[String: AnyCodable]?` | `[String: JSONValue]?` |
| `AgentTool.run` closure input | `Data` (JSON bytes) | `Data` (unchanged — tools deserialize internally) |

### 1B.2 Bridge Extension

To minimize churn in tool implementations that currently decode from `AnyCodable`:

```swift
extension JSONValue {
    /// Lossless conversion from AnyCodable during migration.
    init(anyCodable: AnyCodable) { ... }

    /// Serialize to Data for tool argument dispatch.
    func toJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
```

### 1B.3 Deprecation Path

1. Add `@available(*, deprecated, renamed: "JSONValue")` to `AnyCodable`.
2. Update all call sites file-by-file.
3. Remove `AnyCodable.swift` once zero references remain.

**Risk:** Low. Mechanical find-and-replace with type-safe compiler verification.

---

## Phase 2: Media Artifact & Disk-Backed Storage

### 2.1 Define `MediaArtifact` (New File: `Core/Types/MediaArtifact.swift`)

```swift
public struct MediaArtifact: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let kind: MediaKind
    public let reference: MediaReference
    public let mimeType: String
    public let label: String?                  // Human-readable label ("Generated chart", "Screenshot")
    public let metadata: [String: JSONValue]   // Extensible (dimensions, duration, model used, etc.)
    public let createdAt: Date

    public enum MediaKind: String, Sendable, Codable, Hashable {
        case image
        case audio
        case video
        case document   // Future: PDF artifacts, etc.
    }
}
```

### 2.2 Disk-Backed `MediaStore` Actor (New File: `Core/Storage/MediaStore.swift`)

```swift
/// Manages binary media lifecycle: write-to-disk, resolve, evict.
/// All binary data flows through this actor — MessageBlock and MediaArtifact
/// hold MediaReference.diskPath, never raw Data in long-lived structures.
public actor MediaStore {
    public static let shared = MediaStore()

    private let baseDirectory: URL  // ~/Library/Application Support/Devgentic/MediaCache/
    private let maxCacheSizeMB: Int = 500
    private var manifest: [UUID: MediaEntry] = [:]

    /// Persist ephemeral data to disk, return stable disk reference.
    public func store(
        data: Data,
        mimeType: String,
        conversationID: UUID
    ) async throws -> MediaReference {
        let fileURL = baseDirectory
            .appendingPathComponent(conversationID.uuidString)
            .appendingPathComponent(UUID().uuidString + mimeExtension(for: mimeType))
        try data.write(to: fileURL)
        return .diskPath(fileURL)
    }

    /// Evict media for a completed/deleted conversation.
    public func evict(conversationID: UUID) async { ... }

    /// LRU eviction when cache exceeds maxCacheSizeMB.
    public func pruneIfNeeded() async { ... }
}
```

**Integration point:** Any code path that receives raw `Data` (provider responses, tool outputs, user attachments) MUST call `MediaStore.store()` before constructing `MessageBlock.image/audio/video`. The `MediaReference.ephemeralData` case exists only for transient, in-flight data that hasn't been persisted yet — it must never appear in `SessionGraph` or `MemoryEpisode`.

**Risk:** Low. New isolated actor with no impact on existing code paths until consumers are wired in Phase 3+.

---

## Phase 3: Tool Execution Boundary

### 3.1 Evolve `ToolExecutionResult` (Preserve Enum, Add Artifacts)

The current enum must be preserved — Ghost Protocol, HITL, and retry logic depend on the error cases. We extend `.success` to carry artifacts:

```swift
public enum ToolExecutionResult: Sendable, Equatable {
    /// Extended: now carries optional media artifacts alongside text output.
    case success(output: String, artifacts: [MediaArtifact] = [])
    case hallucinated(toolName: String, availableTools: [String])
    case userDenied(toolName: String)
    case timedOut(toolName: String, duration: TimeInterval)
    case semanticFailure(toolName: String, output: String)
    case systemError(reason: String)

    /// LLM-facing text observation (unchanged contract).
    var llmObservation: String { ... }

    /// Media artifacts (empty for non-success cases).
    var artifacts: [MediaArtifact] {
        if case .success(_, let a) = self { return a }
        return []
    }

    var isSuccess: Bool { ... }
}
```

### 3.2 Extend `DevgenticTool` Protocol (Optional Multimodal Output)

```swift
protocol DevgenticTool: Sendable {
    associatedtype Arguments: Decodable & Sendable
    var name: String { get }
    var description: String { get }
    var parameterSchema: ToolParameters { get }

    // Existing: text-only tools implement this (unchanged).
    func call(arguments: Arguments) async throws -> String

    // NEW: multimodal tools override this. Default delegates to call().
    func execute(arguments: Arguments) async throws -> (output: String, artifacts: [MediaArtifact])
}

extension DevgenticTool {
    // Default: wraps legacy text-only call().
    func execute(arguments: Arguments) async throws -> (output: String, artifacts: [MediaArtifact]) {
        let text = try await call(arguments: arguments)
        return (text, [])
    }
}
```

### 3.3 Update `AgentTool` Wrapper

```swift
public struct AgentTool: Sendable {
    let name: String
    let description: String
    let parameters: ToolParameters
    let requiresConfirmation: Bool

    // CHANGED: closure now returns tuple.
    let run: @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])
}
```

`wrapTool()` in `AgentConnect` updated to call `execute()` instead of `call()`.

### 3.4 Update `ToolExecutionLoop` and `ToolExecutionMediator`

- `ToolExecutionLoop.executeToolCalls()` → captures artifacts from `ToolExecutionResult.success` and emits them via `AgentStreamEvent.artifactProduced` (see Phase 5).
- `ToolExecutionMediator.executePreparedTool()` → constructs `ToolExecutionResult.success(output:artifacts:)` from the new closure return.
- `ToolObservation` gains `artifacts: [MediaArtifact]` field for passing through the execution pipeline.

**Risk:** Medium. Requires updating all `AgentTool` construction sites in `AgentConnect.resolveExecutableTools()`, but default implementation ensures existing tools compile unchanged.

---

## Phase 4: LLMProvider & Generation Pipeline

### 4.1 Extend `LLMProvider` Protocol

We do NOT replace the existing methods (that would break all 5 providers simultaneously). Instead, we add multimodal-aware overloads with default implementations:

```swift
protocol LLMProvider: Sendable {
    var modelName: String { get }

    // EXISTING — retained for backward compatibility during migration.
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error>
    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep

    // NEW — multimodal-aware. Providers implement these progressively.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String
    func generateCognitiveStep(payload: [ProviderMessage], tools: [[String: Any]]?) async throws -> ModernCognitiveStep
}
```

### 4.2 Introduce `ProviderMessage` (New File: `Core/Types/ProviderMessage.swift`)

This replaces `[String: String]` as the message format passed to providers:

```swift
/// Provider-agnostic message representation.
/// Each provider adapter maps this to its specific API format.
public struct ProviderMessage: Sendable {
    public let role: String              // "system", "user", "assistant", "tool"
    public let content: [MessageBlock]   // Multimodal content blocks
    public let toolCallId: String?       // For tool result messages

    /// Backward-compat: construct from legacy [String: String] dict.
    init(legacy dict: [String: String]) {
        self.role = dict["role"] ?? "user"
        self.content = [.text(dict["content"] ?? "")]
        self.toolCallId = nil
    }

    /// Downgrade to legacy format (for providers not yet migrated).
    func toLegacyDict() -> [String: String] {
        ["role": role, "content": content.textContent]
    }
}
```

### 4.3 Provider-Specific Content Block Mapping

Each provider adapter maps `[MessageBlock]` to its API's content format:

| Provider | Image Format | Implementation |
|----------|-------------|----------------|
| **Anthropic** | `{"type": "image", "source": {"type": "base64", "media_type": "...", "data": "..."}}` | `ClaudeLLMProvider.mapContentBlocks()` |
| **OpenAI** | `{"type": "image_url", "image_url": {"url": "data:mime;base64,..."}}` | `OpenAILLMProvider.mapContentBlocks()` |
| **Gemini** | `{"inlineData": {"mimeType": "...", "data": "..."}}` | `GeminiLLMProvider.mapContentBlocks()` |
| **Ollama** | `"images": ["base64..."]` (separate field, not in content array) | `OllamaLLMProvider.mapContentBlocks()` |
| **MLX** | Text-only fallback via `textFallback` | `MLXLLMProvider.mapContentBlocks()` |

Each provider's `mapContentBlocks()` method:
1. Checks the model's `SupportedModalities`.
2. For vision-capable models: resolves `MediaReference` → `Data` → base64, maps to API-specific JSON.
3. For text-only models: replaces media blocks with `textFallback`.

### 4.4 Update `CognitiveGenerator` and `SemanticContext`

```swift
protocol CognitiveGenerator: Sendable {
    var toolAdapter: ToolSchemaAdapter { get }

    // EXISTING (retained during migration)
    func compileMessages(from context: SemanticContext) -> [[String: String]]

    // NEW — multimodal compilation. Default delegates to legacy.
    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage]

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep
}

extension CognitiveGenerator {
    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage] {
        compileMessages(from: context).map { ProviderMessage(legacy: $0) }
    }
}
```

`SemanticContext` is extended to carry `Payload` alongside its existing string fields. Generators that support multimodal payloads (initially `NativeStructuredStrategy`) read from the payload; legacy generators continue reading strings.

### 4.5 Provider Migration Order

1. **Anthropic** (Claude) — native content block support, lowest risk.
2. **OpenAI** — well-documented vision API.
3. **Gemini** — inline data format.
4. **Ollama** — images field quirk requires special handling.
5. **MLX** — text-only fallback, last priority.

**Risk:** High. Each provider must be individually tested with vision payloads. Mitigated by default implementations that delegate to legacy methods.

---

## Phase 5: Memory & Context Engine Overhaul

### 5.1 Modality-Aware `ContextCompressor`

```swift
enum ContextCompressor {
    static let maxCharsPerUpstream: Int = 2000
    static let maxTotalContextChars: Int = 6000
    static let maxImageBytesPerPayload: Int = 5_242_880  // 5MB per image

    /// Updated: compiles multimodal NodeResultEnvelopes.
    static func compile(
        results: [NodeResultEnvelope],
        targetModalities: SupportedModalities,
        budget: Int = maxTotalContextChars
    ) -> Payload {
        results.flatMap { envelope in
            var blocks: [MessageBlock] = []

            // Text: truncate per existing logic.
            let trimmedText = String(envelope.output.prefix(maxCharsPerUpstream))
            blocks.append(.text("[\(envelope.profileName)]: \(trimmedText)"))

            // Media: include only if target model supports the modality.
            if targetModalities.contains(.visionInput) {
                for artifact in envelope.artifacts {
                    if case .image = artifact.kind {
                        blocks.append(.image(ImagePayload(
                            reference: artifact.reference,
                            mimeType: artifact.mimeType,
                            alt: artifact.label,
                            dimensions: nil
                        )))
                    }
                }
            }
            // Non-vision models: media blocks are silently dropped (text fallback in output).
            return blocks
        }
    }
}
```

### 5.2 Image Size Guards

Before passing image data to local models (MLX/Ollama), apply size constraints:

```swift
/// New file: Core/Utils/ImageConstraints.swift
enum ImageConstraints {
    static let maxDimensionForLocalModels: Int = 1024
    static let maxBytesForLocalModels: Int = 2_097_152  // 2MB
    static let jpegCompressionQuality: CGFloat = 0.8

    /// Downscale and compress an image if it exceeds local model limits.
    static func constrainForLocalModel(_ data: Data, mimeType: String) throws -> Data { ... }
}
```

### 5.3 Update `SessionGraph` Storage

```swift
struct MemoryAction: Sendable, Codable, Identifiable {
    let id: UUID
    let intent: String
    var status: String
    var logs: [String]
    var artifacts: [MediaArtifact]   // NEW — media produced during this action
}
```

`MemoryEpisode` and `SessionGraph` remain structurally unchanged. Binary data is never stored inline — `MediaArtifact.reference` points to disk paths managed by `MediaStore`.

`compressWithPointers()` and `compressForPrompt()` continue producing `String` output for LLM context windows. Artifacts are available for UI rendering but do not inflate prompt sizes.

### 5.4 Update `WorkingMemoryStrategy`

```swift
protocol WorkingMemoryStrategy: Sendable {
    mutating func recordObservation(stepId: Int, toolName: String, result: String, artifacts: [MediaArtifact])
    mutating func recordSystemAlert(msg: String)
    func compileForPrompt() -> String    // Still text — artifacts tracked but not injected into prompt
    mutating func clear()
}
```

Default parameter `artifacts: [MediaArtifact] = []` ensures existing call sites compile unchanged.

**Risk:** Medium. Requires careful testing of compression/downgrade logic. Unit tests must cover: text-only model receiving image payload → graceful text fallback.

---

## Phase 6: Event Streaming & UI Contract

### 6.1 Extend `AgentStreamEvent` (Additive Only)

**Critical:** We do NOT replace existing cases. We ADD new multimodal cases:

```swift
enum AgentStreamEvent: Sendable {
    // === EXISTING (unchanged) ===
    case thought(_ message: String, id: UUID = UUID())
    case toolCall(name: String, params: String)
    case requestConfirmation(toolName: String, params: String)
    case toolOutput(ToolOutput)
    case content(String)
    case requestClarification(question: String)
    case error(String)
    case workflowNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int)
    case workflowNodeCompleted(nodeID: UUID, profileName: String, summary: String)
    case workflowNodeFailed(nodeID: UUID, profileName: String, error: String)
    case workflowProgress(completed: Int, total: Int)

    // === NEW: Multimodal Events ===
    /// Long-running media generation progress (e.g., image generation at 45%).
    case mediaProgress(toolName: String, percent: Double, status: String)

    /// A completed media artifact ready for UI rendering.
    case artifactProduced(MediaArtifact)
}
```

### 6.2 UI Layer Updates

**`ActiveStreamManager`** — add handler for new cases:
- `.mediaProgress` → update a progress indicator on the active tool card.
- `.artifactProduced` → append inline media to the chat bubble.

**`ChatMessage.MessageContent`** — the existing UI enum already has `.image(url:alt:imageData:)`. For richer artifact display, extend:

```swift
// Existing enum — add case:
enum MessageContent: Equatable, Codable {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    case error(title: String?, details: String)
    case image(url: URL?, alt: String?, imageData: Data?)
    case mediaArtifact(MediaArtifact)   // NEW — renders via dedicated ArtifactView
}
```

**`ChatBubbleView`** — add `ArtifactCardView` subview that renders `MediaArtifact` based on `.kind` (image → AsyncImage, audio → waveform, video → thumbnail+play).

### 6.3 `TimelineEvent` Extension

```swift
// Add to existing TimelineEvent enum:
case mediaGeneration(id: UUID, toolName: String, artifact: MediaArtifact?, isComplete: Bool)
```

**Risk:** Medium. UI changes are additive — existing rendering paths untouched.

---

## Phase 7: Workflow DAG Multimodal Adaptation

### 7.1 Update `NodeResultEnvelope`

```swift
struct NodeResultEnvelope: Sendable {
    let taskID: UUID
    let nodeID: UUID
    let sourceProfileID: UUID
    let profileName: String
    let profileType: ProfileType
    let status: NodeExecutionStatus
    let output: String                      // Text output (unchanged)
    let artifacts: [MediaArtifact]          // CHANGED: from [ToolOutput] to [MediaArtifact]
    let metadata: NodeExecutionMetadata
}
```

### 7.2 Update `WorkflowTaskEnvelope`

```swift
struct WorkflowTaskEnvelope: Sendable {
    let taskID: UUID
    let nodeID: UUID
    let sourceProfileID: UUID
    let query: String
    let upstreamContext: [NodeResultEnvelope]
    let constraints: ExecutionConstraints
    let targetModalities: SupportedModalities  // NEW — downstream model's capabilities
}
```

The `targetModalities` field allows `ContextCompressor.compile()` to strip unsupported media before delivering the payload to the downstream agent node.

### 7.3 Edge Mapping

When `WorkflowExecutor` connects an upstream node's output to a downstream node:
1. Read the downstream agent's `CognitiveProfile.modalities`.
2. Call `ContextCompressor.compile(results:targetModalities:budget:)`.
3. Deliver the modality-appropriate `Payload` to the downstream agent via `AgentInput`.

**Risk:** Medium. Workflow DAG tests must verify cross-node media passing and modality-downgrade at edges.

---

## AgentInput Evolution

```swift
struct AgentInput: Sendable {
    let userInput: String                               // Retained for text-only entry points
    let userPayload: Payload?                           // NEW — multimodal user input (images, etc.)
    let chatHistory: [ChatMessage]
    let conversationID: UUID
    let tools: [AgentTool]
    let longTermMemory: any LongTermMemoryStrategy

    let activeState: SessionGraph?
    let recentHistory: String?

    let generatorStrategy: any CognitiveGenerator
    let workingMemory: any WorkingMemoryStrategy

    let rateLimitCategory: RateLimitCategory
    let instructions: String?
    let traceContext: TraceContext

    /// Resolved input: multimodal if available, text fallback otherwise.
    var resolvedPayload: Payload {
        userPayload ?? [.text(userInput)]
    }
}
```

---

## Execution Sequence & Risk Matrix

| Order | Phase | Description | Risk | Dependencies |
|-------|-------|-------------|------|-------------|
| 1 | **1A** | Core types: `MessageBlock`, `Payload`, `SupportedModalities` | Low | None |
| 2 | **1B** | `AnyCodable` → `JSONValue` migration | Low | None (parallel with 1A) |
| 3 | **2** | `MediaArtifact` + `MediaStore` actor | Low | 1A |
| 4 | **3** | Tool boundary: `ToolExecutionResult`, `DevgenticTool`, `AgentTool` | Medium | 1A, 1B, 2 |
| 5 | **5** | Memory & context: `SessionGraph`, `WorkingMemory`, `ContextCompressor` | Medium | 2, 3 |
| 6 | **4** | LLM providers: `ProviderMessage`, provider adapters (one-by-one) | High | 1A, 1B |
| 7 | **6** | Event streaming & UI: `AgentStreamEvent`, `ChatBubbleView` | Medium | 2, 3 |
| 8 | **7** | Workflow DAG: `NodeResultEnvelope`, edge mapping | Medium | 5, 6 |

### Key Risk Mitigations

1. **No breaking changes in early phases.** Phases 1A, 1B, and 2 are purely additive — new types, no existing code modified.
2. **Default implementations everywhere.** `DevgenticTool.execute()` defaults to wrapping `call()`. `CognitiveGenerator.compileProviderMessages()` defaults to wrapping `compileMessages()`. `LLMProvider.generate(payload:)` defaults to converting to legacy format. Existing tools/generators/providers compile and run unchanged until individually migrated.
3. **Provider migration is isolated.** Each provider adapter is updated independently. Failed provider migration doesn't block others.
4. **Binary data never in memory graphs.** `MediaStore` actor ensures all binary data is disk-backed. `MediaReference.ephemeralData` is transient-only and validated at storage boundaries.
5. **Modality downgrade is explicit.** `SupportedModalities` on `CognitiveProfile` drives compile-time decisions about what content reaches which model. Text-only models never receive raw image data.

---

## Future Pluggability: ImageGen / VideoGen Modules

This architecture is designed for future generation capabilities to plug in cleanly:

### ImageGen (Text-to-Image)

1. **New tool:** `ImageGenerationTool: DevgenticTool` — calls external API (DALL-E, Stable Diffusion, etc.).
2. **Returns:** `execute()` → `(output: "Generated image: sunset over mountains", artifacts: [MediaArtifact(kind: .image, ...)])`.
3. **Storage:** `MediaStore.store()` persists the generated image to disk.
4. **Streaming:** `ToolExecutionLoop` emits `.mediaProgress` during generation, `.artifactProduced` on completion.
5. **UI:** `ChatBubbleView` renders via existing `.mediaArtifact` case.
6. **Workflow:** Downstream nodes receive the image via `NodeResultEnvelope.artifacts`, filtered by `SupportedModalities`.

### Image-to-Image / VideoGen

Same pattern. The `MediaArtifact.kind` enum gains new cases. `MessageBlock` already has `.video(VideoPayload)`. Provider adapters that don't support the modality fall back to `textFallback`. No architectural changes required — only new tool implementations.

### Agent-to-Agent (A2A)

`ToolExecutionResult.success(output:artifacts:)` combined with `structuredData: JSONValue?` (added when A2A is implemented) allows Agent B to return both human-readable output and machine-readable structured data to Agent A. The multimodal pipeline ensures media artifacts flow between agents without re-encoding.

---

## Testing Strategy

| Phase | Test Type | Focus |
|-------|-----------|-------|
| 1A | Unit | `MessageBlock` encoding/decoding, `Payload` text projection, `SupportedModalities` OptionSet operations |
| 1B | Unit | `JSONValue` ↔ `AnyCodable` bridge, `PendingToolCall` serialization roundtrip |
| 2 | Unit + Integration | `MediaStore` write/read/evict, `MediaReference.resolve()`, LRU pruning |
| 3 | Unit | `ToolExecutionResult.success` with artifacts, `DevgenticTool` default implementation, `AgentTool` closure dispatch |
| 4 | Integration | Per-provider vision payload construction, text-only model fallback, `ProviderMessage` legacy conversion |
| 5 | Unit + Integration | `ContextCompressor` modality filtering, `SessionGraph` artifact storage, `WorkingMemoryStrategy` with artifacts |
| 6 | UI + Integration | `AgentStreamEvent` new case handling, `ArtifactCardView` rendering, `TimelineEvent` media generation |
| 7 | Integration | Cross-node artifact passing, modality downgrade at workflow edges, `WorkflowTaskEnvelope` target modalities |

---

## Files Created / Modified Summary

### New Files
- `Core/Types/MessageBlock.swift` — `MessageBlock`, `ImagePayload`, `AudioPayload`, `VideoPayload`, `MediaReference`, `Payload`
- `Core/Types/MediaArtifact.swift` — `MediaArtifact`
- `Core/Types/ProviderMessage.swift` — `ProviderMessage`
- `Core/Storage/MediaStore.swift` — `MediaStore` actor
- `Core/Utils/ImageConstraints.swift` — Image downscaling for local models

### Modified Files
- `Core/Backends/TextGen/AgentModel.swift` — `ToolExecutionResult`, `PendingToolCall`, `AgentInput`, `ModernCognitiveStep`
- `Core/Backends/TextGen/ReAct/Generation/CognitiveProfile.swift` — `SupportedModalities`, `CognitiveProfile`
- `Core/Backends/TextGen/ReAct/Generation/CognitiveGeneratorProtocol.swift` — `compileProviderMessages()`
- `Core/Backends/LLMProviders.swift` — `LLMProvider` protocol multimodal overloads
- `Core/Backends/ClaudeLLMProvider.swift` — Vision content block mapping
- `Core/Backends/OpenAILLMProvider.swift` — Vision content block mapping
- `Core/Backends/GeminiLLMProvider.swift` — Vision content block mapping
- `Core/Backends/OllamaLLMProvider.swift` — Vision content block mapping
- `Core/Backends/MLXLLMProvider.swift` — Text-only fallback
- `Core/Backends/TextGen/Shared/Execution/ToolExecutionLoop.swift` — Artifact capture and streaming
- `Core/Backends/TextGen/ReAct/Components/Execution/ToolExecutionMediator.swift` — Artifact dispatch
- `Core/Backends/TextGen/ReAct/Components/Memory/SessionGraph.swift` — `MemoryAction` artifacts
- `Core/Backends/TextGen/ReAct/Components/Memory/WorkingMemoryStrategy.swift` — Artifact-aware recording
- `Core/Backends/Workflow/ContextCompressor.swift` — Modality-aware compilation
- `Core/Backends/Workflow/WorkflowTaskProtocol.swift` — `NodeResultEnvelope`, `WorkflowTaskEnvelope`
- `Core/Utils/AgentStreamEvent.swift` — New multimodal event cases
- `Core/Utils/AnyCodable.swift` — Deprecation annotation, then removal
- `Engine/DevgenticTool.swift` — `execute()` method with default
- `Interfaces/Shared/Chat/ChatMessage.swift` — `.mediaArtifact` case
- `Interfaces/Main/Views/Tooling/ToolModel.swift` — No changes needed (schema types are format-agnostic)
- `Interfaces/Main/Views/Chat/ChatBubbleView.swift` — `ArtifactCardView`
- `Interfaces/Main/Views/Chat/ActiveStreamManager.swift` — Handle new stream events
