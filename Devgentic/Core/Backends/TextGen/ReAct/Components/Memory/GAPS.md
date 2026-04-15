# Memory System — Known Gaps & Future Work

Tracked during the Working Memory Production Readiness Analysis (April 2026).
Items here are scoped, analysed, and ready to be picked up when prioritised.

---

## G8 — Artifact Retrieval for Vision-Capable Models

**Status:** Open
**Severity:** Medium (becomes High when vision-local models are a primary use case)
**Identified:** 2026-04-09

### Problem

When a tool produces a `MediaArtifact` (screenshot, generated chart, etc.), the binary data flows through `.artifactProduced` to the UI and is stored in `MemoryAction.artifacts` in `SessionGraph`. However, there is **no reverse path** for the model to consume that image in subsequent reasoning iterations.

The scratchpad only contains a text reference:
```
- [Step 3] screen_capture (id: call_xyz):
Screenshot saved to ~/Desktop/screenshot.png [1 artifact(s)]
```

If the user swaps to a vision-capable model (LLaVA, Pixtral) mid-conversation, that model cannot request or receive the actual image data — it only sees the text metadata.

### Scope

This is deeper than a working memory fix. It touches the generator-to-provider pipeline:

1. `CognitiveGenerator.compileMessages()` returns `[[String: String]]` — no multimodal slot.
2. `ProviderMessage` would need to carry `MessageBlock` arrays (which already support `.image(ImagePayload)`) instead of plain strings.
3. A mechanism is needed for the model to access prior artifacts — either via a tool or automatic injection.

### Possible Approaches

**Approach A — `retrieve_artifact` tool:**
- New tool that accepts a step number or artifact ID.
- Loads the `MediaArtifact` from `SessionGraph` or `MediaStore`.
- Returns the image as an `ImagePayload` block injected into the next LLM call.
- Requires extending `ToolExecutionResult` to carry multimodal content blocks, not just strings.

**Approach B — Automatic vision injection:**
- When the active model has `SupportedModalities.visionInput`, the generator strategy detects artifact references in the scratchpad.
- Automatically attaches the N most recent image artifacts to the `ProviderMessage`.
- Budget-aware: only inject if within context/token limits.
- Requires `compileProviderMessages()` to return `[ProviderMessage]` with `MessageBlock` content instead of `[[String: String]]`.

**Approach C — Hybrid:**
- Auto-inject the most recent artifact (if vision-capable).
- Provide `retrieve_artifact` tool for explicit lookups of older artifacts.

### Dependencies

- `MessageBlock` and `Payload` types already exist in `Core/Types/MessageBlock.swift` with `.image(ImagePayload)` support and `textFallback` for non-vision models.
- `MediaArtifact` stores references via `MediaReference` (disk path / remote URL / ephemeral data) — never raw bytes in memory.
- `SupportedModalities` in `CognitiveProfile.swift` already tracks `.visionInput` per model.
- `ProviderMessage` wrapper exists but currently just wraps legacy `[String: String]` dicts.

### Files Likely Affected

- `CognitiveGeneratorProtocol.swift` — `compileMessages` / `compileProviderMessages` return types
- `NativeStructuredGenerator.swift` + other generator strategies — message construction
- Provider adapters (Anthropic, OpenAI, Google, MLX, Ollama) — multimodal message formatting
- `ToolExecutionLoop.swift` — if using the tool-based approach
- `WorkingMemoryStrategy.swift` — artifact reference format in scratchpad
- `AgentConnect.swift` — modality-aware artifact injection gating

---


