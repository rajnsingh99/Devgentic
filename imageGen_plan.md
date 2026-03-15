# Devgentic: ImageGen Integration — Consolidated Implementation Plan

> Merged from the initial design draft (edge cases, modality considerations) and the refined architecture plan (capability detection, executor pipeline, workflow integration). Cross-referenced against the live codebase to confirm every integration point.

---

## Guiding Principles

1. **Zero breakage** — No edits to existing `LLMProvider` text-generation methods. ImageGen gets its own protocol.
2. **Profile parity** — ImageGen profiles sit alongside Bot/Agent/Workflow with the same persistence, selection, and routing patterns.
3. **Multimodal-first** — Reuses `MediaArtifact`, `MediaReference`, `MediaStore`, `AgentStreamEvent.artifactProduced`, and `NodeResultEnvelope.artifacts` already shipped in the multimodal pipeline.
4. **Workflow-native** — ImageGen nodes work inside DAG workflows, receiving upstream context and emitting `MediaArtifact` outputs downstream.
5. **Extendable** — New providers plug in by conforming to `ImageGenProvider`; no switch-case edits elsewhere.

---

## Phase 1: Data Model & Profile Layer

### 1.1 Extend `ProfileType` enum
**File:** `BackendProfile.swift`

```swift
enum ProfileType: String, Codable, CaseIterable, Identifiable {
    case bot = "Bot"
    case agent = "Agent"
    case workflow = "Workflow"
    case imageGen = "Image Generator"  // NEW
}
```

### 1.2 Extend `ProfileDetails` enum
**File:** `BackendProfile.swift`

```swift
case imageGen(
    llmConfig: ProviderConfig,
    negativePrompt: String?,
    defaultAspectRatio: ImageAspectRatio?,
    advancedSettings: [String: JSONValue]?
)
```

Add `ImageAspectRatio` enum:
```swift
enum ImageAspectRatio: String, Codable, CaseIterable, Identifiable, Hashable {
    case square     = "1:1"
    case landscape  = "16:9"
    case portrait   = "9:16"
    case wide       = "21:9"
    case photo      = "4:3"
    case photoPort  = "3:4"
    var id: String { rawValue }
}
```

Update `ProfileDetails` Codable (encoder + decoder) with the new case and its coding keys.

### 1.3 Core Data Persistence
**File:** `BackendProfileStore.swift`

- Add `ImageGenConfigEntity` (or reuse `BotConfigEntity` pattern):
  - `llmConfig: Data` (encoded `ProviderConfig`)
  - `negativePrompt: String?`
  - `defaultAspectRatio: String?`
  - `advancedSettings: Data?`
- Add relationship `imageGenConfig` on `BackendProfileEntity`.
- Add `configure()` and `createImageGenDetails()` mappings mirroring the bot path.
- Clean up other relationships when type is `.imageGen` (set `botConfig = nil`, `agentConfig = nil`, `workflowConfig = nil`).

### 1.4 Update `BackendProfileService`
No structural changes needed — `saveProfile` / `loadProfiles` / `deleteProfile` are type-agnostic.

---

## Phase 2: Capability Detection

### 2.1 `ImageCapabilityAnalyzer`
**New file:** `Core/Backends/ImageGen/ImageCapabilityAnalyzer.swift`

```swift
public struct ImageModalitySupport: Sendable, Hashable {
    public let supportsTextToImage: Bool
    public let supportsImageToImage: Bool
    public let maxResolution: (width: Int, height: Int)?
    public let supportedAspectRatios: [ImageAspectRatio]?
}

public enum ImageCapabilityAnalyzer {
    /// Returns capability flags for the given provider + model.
    static func analyze(
        provider: ApiProvider,
        modelName: String,
        modelMetadata: ModelMetadata?
    ) -> ImageModalitySupport
}
```

**Per-provider detection logic:**

| Provider | T2I | I2I | Detection Method |
|----------|-----|-----|------------------|
| **OpenAI** | `dall-e-3`, `dall-e-2`, `gpt-image-1` | `gpt-image-1` only | Hardcoded model name map |
| **Gemini** | `gemini-2.0-flash-preview-image-generation`, `imagen-3.0-*` | `gemini-2.0-flash-preview-image-generation` | Hardcoded model name map |
| **MLX (Flux2)** | Klein 4B, Klein 9B, Dev 32B | Klein 4B, Klein 9B, Dev 32B (all support I2I) | Model variant enum from Flux2Core library |
| **Ollama** | Experimental (model tag inspection) | `false` (not supported) | `/api/show` response → check `modelfile` for diffusion-related keywords |

**Edge Case B resolution:** Before execution, the executor calls `ImageCapabilityAnalyzer.analyze()` and compares against the resolved intent. Mismatch → immediate `.error()` stream event with actionable message.

---

## Phase 3: Provider Contract

### 3.1 `ImageGenProvider` Protocol
**New file:** `Core/Backends/ImageGen/ImageGenProvider.swift`

```swift
public struct ImageGenOptions: Sendable {
    public let aspectRatio: ImageAspectRatio
    public let numberOfImages: Int          // default 1
    public let quality: ImageQuality        // .standard | .hd
    public let advancedSettings: [String: JSONValue]?
}

public enum ImageQuality: String, Sendable, Codable {
    case standard = "standard"
    case hd = "hd"
}

public protocol ImageGenProvider: Sendable {
    /// Text-to-Image generation.
    func generateImage(
        prompt: String,
        negativePrompt: String?,
        options: ImageGenOptions
    ) async throws -> MediaArtifact

    /// Image-to-Image generation (variation/edit).
    /// Throws `ImageGenError.imageToImageNotSupported` if the model lacks I2I.
    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions
    ) async throws -> MediaArtifact
}
```

> **Design note:** Two separate methods instead of a single method with `inputImage: Data?` — this makes the contract explicit and lets conforming types throw at compile time if they only implement T2I.

### 3.2 `ImageGenError`
```swift
public enum ImageGenError: LocalizedError, Sendable {
    case imageToImageNotSupported(modelName: String)
    case textToImageNotSupported(modelName: String)
    case invalidAspectRatio(requested: String, supported: [String])
    case contentPolicyViolation(detail: String)
    case providerError(underlying: String)
    case modelNotLoaded
}
```

### 3.3 Provider Implementations
**New files** (one per provider):

| File | Class | Notes |
|------|-------|-------|
| `OpenAIImageGenService.swift` | `OpenAIImageGenService` | Uses `/v1/images/generations` (T2I) and `/v1/images/edits` (I2I for supported models). Returns base64 → store via `MediaStore` → `MediaArtifact` with `.diskPath`. |
| `GeminiImageGenService.swift` | `GeminiImageGenService` | Uses `generateContent` with `responseModalities: ["TEXT", "IMAGE"]` for T2I. I2I uses inline image parts. |
| `MLXImageGenService.swift` | `MLXImageGenService` | Wraps Flux2Core library calls. Must handle GPU memory contention with text-gen models (see Phase 7). |
| `OllamaImageGenService.swift` | `OllamaImageGenService` | Uses `/api/generate` with image-capable models. T2I only; `generateImageVariation` throws `.imageToImageNotSupported`. |

**All implementations must:**
1. Store generated image bytes via `MediaStore.shared.store(data:mimeType:conversationID:)`.
2. Return `MediaArtifact` with `.diskPath` reference (never `.ephemeralData` for persistence).
3. Populate `metadata` with generation params: `["prompt": .string(...), "model": .string(...), "provider": .string(...)]`.

### 3.4 `ImageGenProviderFactory`
**New file:** `Core/Backends/ImageGen/ImageGenProviderFactory.swift`

```swift
enum ImageGenProviderFactory {
    static func create(
        for config: ProviderConfig
    ) throws -> ImageGenProvider
}
```

Switch on `config.apiProvider` → return the corresponding service, initialized with API key, base URL, model name from `config`.

---

## Phase 4: Execution Pipeline

### 4.1 Intent Resolution
**New file:** `Core/Backends/ImageGen/ImageIntentResolver.swift`

Resolves the user's intent from query + chat history + attachments:

```swift
public enum ImageIntent: Sendable {
    case textToImage(prompt: String)
    case imageToImage(prompt: String, sourceImage: Data)
}

public enum ImageIntentResolver {
    static func resolve(
        userQuery: String,
        attachedFiles: [Data]?,
        chatHistory: [ChatMessage],
        intelligenceCore: IntelligenceCoreService?
    ) async -> ImageIntent
}
```

**Resolution logic (Edge Cases A.1, A.2):**

| Condition | Detection | Result |
|-----------|-----------|--------|
| User attaches an image + text | `attachedFiles` contains image data | `.imageToImage(prompt, sourceImage)` |
| User types "generate an image of X" | No image context | `.textToImage(prompt)` |
| Chat has prior generated images + user says "make it darker" | Pass last 3-4 messages to `IntelligenceCoreService` with classification prompt: `NEW_IMAGE` vs `VARIATION` | If `VARIATION` → extract last `MediaArtifact` from history → `.imageToImage(prompt, sourceImage)`. If `NEW_IMAGE` → `.textToImage(prompt)` |
| No IntelligenceCore available (not downloaded) | Fallback | Always `.textToImage(prompt)` |

> **IntelligenceCore usage:** The existing `IntelligenceCoreService` (Llama-3.2-3B local model) is text-only and lightweight. We use it strictly for intent classification — a single short LLM call to decide `NEW_IMAGE` vs `VARIATION`. If IntelligenceCore isn't downloaded, the system defaults to T2I (safe fallback).

### 4.2 `ImageGenExecutor`
**New file:** `Core/Backends/ImageGen/ImageGenExecutor.swift`

Lightweight, stateless executor — no iteration loops, no tool dispatch:

```swift
struct ImageGenExecutor: Sendable {
    func execute(
        intent: ImageIntent,
        provider: ImageGenProvider,
        capability: ImageModalitySupport,
        profile: BackendProfileModel,
        conversationID: UUID,
        options: ImageGenOptions
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}
```

**Execution flow (Edge Case C — Modality Orchestration):**

```
1. FEASIBILITY CHECK
   ├── intent == .imageToImage && !capability.supportsImageToImage
   │   └── yield .error("Model does not support Image-to-Image. Select MLX or Gemini model, or use a text prompt.")
   │       └── HALT
   ├── intent == .textToImage && !capability.supportsTextToImage
   │   └── yield .error("Model does not support Text-to-Image generation.")
   │       └── HALT
   └── OK → proceed

2. GENERATE
   ├── yield .thought("Generating image with {modelName}...", id: UUID())
   ├── yield .mediaProgress(toolName: "imageGen", percent: 0.0, status: "Starting")
   ├── Call provider.generateImage() or provider.generateImageVariation()
   ├── yield .mediaProgress(toolName: "imageGen", percent: 1.0, status: "Complete")
   └── yield .artifactProduced(mediaArtifact)

3. FINISH
   └── Stream closes. No looping.
```

### 4.3 Routing Integration
**File:** `BackendOrchestrationService.swift`

Add case to the profile type switch:

```swift
case .imageGen:
    // 1. Build ImageGenOptions from profile
    // 2. Create provider via ImageGenProviderFactory
    // 3. Analyze capability via ImageCapabilityAnalyzer
    // 4. Resolve intent via ImageIntentResolver
    // 5. Execute via ImageGenExecutor
    // 6. Forward stream events to continuation
```

---

## Phase 5: Workflow Integration

### 5.1 ImageGen as a Workflow Node

The existing workflow system already supports this natively:

- `WorkflowTaskEnvelope.targetModalities` can specify `.imageOutput` (from `SupportedModalities`).
- `NodeResultEnvelope.artifacts: [MediaArtifact]` carries generated images to downstream nodes.
- `NodeResultEnvelope.profileType` will include `.imageGen` for correct routing.

**What needs to change:**

1. **`WorkflowExecutor`** (or wherever nodes are dispatched): Add `.imageGen` case in the per-node profile-type dispatch, routing to `ImageGenExecutor` instead of `AgentConnect`.

2. **Upstream context injection:** When an ImageGen node receives `upstreamContext: [NodeResultEnvelope]`, extract text output from prior nodes and use as prompt enrichment. If upstream nodes produced `MediaArtifact` images, pass them as `inputImage` for I2I workflows.

3. **`ContextCompressor.compile()`:** When `targetModalities` includes `.imageOutput`, the compressor should preserve image references from upstream rather than stripping them.

### 5.2 Workflow Example: "Generate → Critique → Refine"

```
Node 1 (Agent):  "Describe a serene mountain landscape in detail"
    ↓ output: "A towering snow-capped peak rises above..."
Node 2 (ImageGen): "Generate image from upstream description"
    ↓ artifacts: [MediaArtifact(landscape.png)]
Node 3 (Agent):  "Critique the generated image and suggest improvements"
    ↓ output: "The image lacks foreground detail..."
Node 4 (ImageGen): "Refine image based on critique" (I2I from Node 2 artifact + Node 3 text)
    ↓ artifacts: [MediaArtifact(landscape_v2.png)]
```

---

## Phase 6: UI Layer

### 6.1 `AddBackendProfileView` Update
**File:** `AddBackendProfileView.swift`

Add fourth `ProfileTypeCard` for `.imageGen` with icon `"paintbrush.fill"` and purple accent.

Update `createDefaultProfile()`:
```swift
case .imageGen:
    return BackendProfileModel(
        displayName: "New Image Generator",
        details: .imageGen(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3"),
            negativePrompt: nil,
            defaultAspectRatio: .square,
            advancedSettings: nil
        )
    )
```

### 6.2 `ImageGenConfigDetailView`
**New file:** `Interfaces/Main/Views/BackendProfile/ImageGenConfigDetailView.swift`

Mirrors `BotConfigDetailView` layout with:

| Section | Contents |
|---------|----------|
| **Identity Header** | Icon + name field + subtitle "AI-powered image generation" |
| **Inference Engine** | Provider picker (OpenAI, Gemini, MLX, Ollama) + model picker (filtered by `ImageCapabilityAnalyzer`) + API key + base URL |
| **Generation Defaults** | Aspect ratio picker (`ImageAspectRatio`) + quality selector (standard/HD) |
| **Negative Prompt** | `TextEditor` with expand button (reuse `SimplePromptWindowManager`) |
| **Advanced Settings** | Provider-specific (e.g., `steps`/`guidance` for Flux2, `style` for DALL-E) |
| **Capability Badge** | Shows "T2I ✓  I2I ✓" or "T2I ✓  I2I ✗" based on `ImageCapabilityAnalyzer` for selected model |

Apply the same `isLoadingAdvancedConfig` guard pattern from the BotConfigDetailView fix.

### 6.3 `BackendProfileDetailView` Routing
**File:** `BackendProfilePanelView.swift`

```swift
case .imageGen:
    ImageGenConfigDetailView(profile: $profile)
        .padding()
```

### 6.4 `ChatBubbleView` — Rich Image Rendering
**File:** `ChatBubbleView.swift`

Replace the placeholder `.mediaArtifact` case with full rendering:

```swift
case .mediaArtifact(let artifact):
    if artifact.kind == .image, case .diskPath(let url) = artifact.reference {
        MediaArtifactImageView(url: url, artifact: artifact)
    } else {
        // Fallback for non-image artifacts
        Text("[\(artifact.kind.rawValue): \(artifact.label ?? artifact.mimeType)]")
    }
```

`MediaArtifactImageView` (new component):
- Async image loading from disk URL
- Rounded corners + shadow
- Hover overlay with metadata (model, dimensions, prompt snippet)
- Context menu: "Save to Downloads", "Copy Image", "Use as Input" (starts I2I flow)

### 6.5 Profile Selector Integration
The main chat sidebar profile selector (driven by `BackendConfiguration.selectedProfileID`) already works with `BackendProfileStore.fetchProfiles()` — no changes needed. ImageGen profiles will appear alongside Bot/Agent/Workflow profiles automatically.

---

## Phase 7: Resource Management & Edge Cases

### 7.1 MLX GPU Memory Contention
When switching between text-gen and image-gen on Apple Silicon:
- `BackendOrchestrationService` already calls `mlxService.unloadIfNotRequired()` when the profile provider isn't MLX (line 69-71).
- For ImageGen MLX profiles: unload the text-gen model first, then load the Flux2 pipeline.
- Flux.1 models are large (Schnell ~12GB, Dev ~24GB). Add a memory check before loading: if available unified memory < model size + 2GB headroom, emit `.error("Insufficient GPU memory")`.

### 7.2 Conversation Continuity (Edge Case A — Existing Chat Swap)
When a user swaps from Bot/Agent to ImageGen mid-conversation:
1. The chat history is preserved (text messages from prior profile).
2. `ImageIntentResolver` receives the full chat history and can use it for context.
3. If the user says "generate an image of what we discussed," the resolver uses IntelligenceCore to extract a visual prompt from the conversation.
4. If IntelligenceCore is unavailable, the raw user query is passed as-is to the image provider.

### 7.3 Sequential Image Generation (Edge Case A.2.2)
When a user generates multiple images in sequence:
1. Each generation produces a `MediaArtifact` stored via `MediaStore`.
2. `ImageIntentResolver` inspects the last N messages for prior `MediaArtifact` entries.
3. If the user says "make it more colorful" → classified as `VARIATION` → last artifact's image data is extracted → I2I pipeline.
4. If the user says "now generate a sunset" → classified as `NEW_IMAGE` → T2I pipeline.
5. If the model doesn't support I2I but user wants a variation → error with suggestion to switch model.

### 7.4 Rate Limiting & Cost
- OpenAI DALL-E: Rate limited (5-7 images/min for free tier). Surface rate limit errors clearly.
- Gemini Imagen: May have usage quotas. Parse error responses.
- Local (MLX/Ollama): No rate limits but slow generation (30-120s). Use `.mediaProgress` events to show progress.

---

## External Dependencies

### flux-2-swift-mlx (Apple Silicon Image Generation)
**Required for:** MLX-based local image generation (Flux.2 models on Apple Silicon)

> **Dependency compatibility note:**
> - ~~MFLUX (`filipstrand/mflux`)~~ — Python-only, no `Package.swift`.
> - ~~flux.swift (`mzbac/flux.swift`)~~ — Pins `swift-transformers` to `0.1.x` and `mlx-swift` to `0.25.x`. Incompatible with project's `swift-transformers 1.1.7` and `mlx-swift 0.30.6`.
> - ~~DiffusionKit (`argmaxinc/DiffusionKit`)~~ — Pins `swift-transformers` to `exact: 0.1.8`. Incompatible.
> - ✅ **flux-2-swift-mlx** — Requires `mlx-swift ≥0.30.2` and `swift-transformers ≥1.1.6`. **Fully compatible.**

| Detail | Value |
|--------|-------|
| **Library** | [flux-2-swift-mlx](https://github.com/VincentGourbin/flux-2-swift-mlx) |
| **SPM URL** | `https://github.com/VincentGourbin/flux-2-swift-mlx.git` |
| **Min Version** | Latest available (check tags) |
| **Swift** | Requires Swift 6.0 |
| **Platform** | macOS 15.0+ with Apple Silicon (M1+) |
| **MLX** | `mlx-swift ≥0.30.2` (project has 0.30.6 ✓) |
| **Transformers** | `swift-transformers ≥1.1.6` (project has 1.1.7 ✓) |
| **Import** | `import Flux2Core` |

**Supported Models:**

| Model | Capability | Memory (int4) | Memory (qint8) | Memory (bf16) |
|-------|-----------|---------------|-----------------|---------------|
| **Klein 4B** | T2I + I2I | 16GB | 16GB | 24GB |
| **Klein 9B** | T2I + I2I | 16GB | 24GB | 32GB |
| **Dev 32B** | T2I + I2I | 32GB | 96GB | 96GB |

All models support both text-to-image AND image-to-image (with configurable strength + multi-image conditioning up to 3 reference images). On-the-fly quantization from a single bf16 download (no separate variant downloads needed).

**API surface:**
```swift
import Flux2Core

// Text-to-Image
let pipeline = Flux2Pipeline(...)
let image = try await pipeline.generateTextToImage(
    prompt: "A serene mountain landscape",
    height: 1024,
    width: 1024,
    steps: 20,
    guidance: 3.5
) { current, total in
    // Progress callback → emit .mediaProgress events
    let percent = Double(current) / Double(total)
}

// Image-to-Image
let variation = try await pipeline.generateImageToImage(
    prompt: "Make it more vibrant",
    images: [inputCGImage],
    strength: 0.7,
    height: 1024,
    width: 1024,
    steps: 20,
    guidance: 3.5
) { current, total in ... }
```

**Memory optimization:** Use `int4` quantization for 72% size reduction. Pre-flight check: `ProcessInfo.processInfo.physicalMemory` must exceed model requirement + 2GB headroom. Klein 4B at int4 fits on all Apple Silicon Macs (16GB minimum).

> **Performance note:** Dev 32B generation takes ~30 min for 1024x1024. Klein 4B/9B are significantly faster and recommended for interactive use.

> **Action required:** Add `flux-2-swift-mlx` as SPM dependency in `Devgentic.xcodeproj`. Link `Flux2Core` library target.

**No other external dependencies required.** OpenAI, Gemini, and Ollama integrations use their existing HTTP APIs.

---

## File Inventory

### New Files (12)

| # | Path | Purpose |
|---|------|---------|
| 1 | `Core/Backends/ImageGen/ImageGenProvider.swift` | Protocol + `ImageGenOptions` + `ImageGenError` + `ImageQuality` |
| 2 | `Core/Backends/ImageGen/ImageCapabilityAnalyzer.swift` | `ImageModalitySupport` + per-provider detection |
| 3 | `Core/Backends/ImageGen/ImageIntentResolver.swift` | `ImageIntent` enum + resolution logic |
| 4 | `Core/Backends/ImageGen/ImageGenExecutor.swift` | Stateless stream executor |
| 5 | `Core/Backends/ImageGen/ImageGenProviderFactory.swift` | Provider instantiation |
| 6 | `Core/Backends/ImageGen/Providers/OpenAIImageGenService.swift` | OpenAI DALL-E / gpt-image-1 |
| 7 | `Core/Backends/ImageGen/Providers/GeminiImageGenService.swift` | Gemini Imagen |
| 8 | `Core/Backends/ImageGen/Providers/MLXImageGenService.swift` | Flux2Core wrapper (flux-2-swift-mlx) |
| 9 | `Core/Backends/ImageGen/Providers/OllamaImageGenService.swift` | Ollama diffusion models |
| 10 | `Interfaces/Main/Views/BackendProfile/ImageGenConfigDetailView.swift` | Settings UI |
| 11 | `Interfaces/Shared/Chat/MediaArtifactImageView.swift` | Rich image rendering component |
| 12 | `Core Data Model: ImageGenConfigEntity` | Core Data entity (in `.xcdatamodeld`) |

### Modified Files (8)

| # | Path | Change |
|---|------|--------|
| 1 | `BackendProfile.swift` | Add `.imageGen` to `ProfileType` + `ProfileDetails`, add `ImageAspectRatio` |
| 2 | `BackendProfileStore.swift` | Add `configure()` + `createImageGenDetails()` for new entity |
| 3 | `BackendOrchestrationService.swift` | Add `.imageGen` routing case |
| 4 | `BackendProfilePanelView.swift` | Add `.imageGen` to `BackendProfileDetailView` switch |
| 5 | `AddBackendProfileView.swift` | Add ImageGen profile card + `createDefaultProfile()` case |
| 6 | `ChatBubbleView.swift` | Replace `.mediaArtifact` placeholder with rich `MediaArtifactImageView` |
| 7 | `ProfileRowView` (in `BackendProfilePanelView.swift`) | Add icon + color for `.imageGen` |
| 8 | `Workflow/WorkflowExecutor.swift` | Add `.imageGen` node dispatch |

---

## Implementation Order

```
Phase 1 (Data Model)          ─── Foundation, no UI impact
  ↓
Phase 2 (Capability Analyzer) ─── Standalone, testable in isolation
  ↓
Phase 3 (Provider Contract)   ─── Protocol + factory, no wiring yet
  ↓
Phase 3.5 (First Provider)    ─── OpenAI (simplest HTTP API, fastest to validate)
  ↓
Phase 4 (Executor + Routing)  ─── Wire up BackendOrchestrationService
  ↓
Phase 6 (UI)                  ─── Profile creation + settings + image display
  ↓
Phase 5 (Workflow)             ─── Node dispatch + upstream context
  ↓
Phase 3.6-3.8 (Other Providers) ─── Gemini, MFLUX, Ollama
  ↓
Phase 7 (Polish)               ─── Memory management, rate limits, error UX
```

> **Milestone checkpoint:** After Phase 4 + first OpenAI provider, a user can create an ImageGen profile, select DALL-E 3, type a prompt, and see a generated image in the chat. This is the minimum viable integration.

---

## Risk Matrix

| Risk | Severity | Mitigation |
|------|----------|------------|
| Flux2 library maturity / API changes | Medium | flux-2-swift-mlx is newer; pin version; Flux2Core API is small and wrappable |
| GPU memory OOM on Apple Silicon | High | Pre-flight memory check + clear error messaging |
| Ollama image model ecosystem is immature | Medium | Mark as experimental; T2I only; graceful fallback |
| IntelligenceCore not downloaded → intent misclassification | Low | Default to T2I (safe); prompt user to download for smarter behavior |
| Rate limiting on OpenAI/Gemini | Low | Surface error clearly; no retry loops (user can re-send) |
| Core Data migration for new entity | Low | Lightweight migration; new entity only, no existing schema changes |
