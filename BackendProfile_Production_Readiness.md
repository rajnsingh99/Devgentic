# BackendProfile — production readiness

**Scope:** `Devgentic/Interfaces/Main/Views/BackendProfile/` — 47 Swift files, ~17,759 lines
(profile model + edit buffer + store + service, the five detail editors, `AdvanceConfig/` (7 files),
`MlxLLM/` (16 files), `OllamaLLM/` (2 files)), plus the seams it drives: `ClaudeLLMProvider`,
`GeminiLLMProvider`/`GeminiService`, `OpenAILLMProvider`, `AgentConnect`, `PlanningCapability`,
`ToolLibraryContainerView`, `ProfileSidebarListView`, `WorkflowCanvasView`, `CapabilityToolbarButtons`.

**Audit:** 2026-08-07. Eight independent source reviews across eight dimensions (state/data-flow,
validation/limits, concurrency, error-handling/logging, security/secrets, provider-config, UX/a11y,
coverage/dead-code), then an adversarial verification pass over the six highest-severity findings.
89 raw findings → **74 after cross-dimension merge**, 1 refuted. Two further P2s were added to Part A
during the fix clusters, so the table now holds **76 rows** (P1 27 / P2 42 / P3 7) — the "74" above
is the audit's own number and is left as the historical record.

**Deliberately excluded (already catalogued elsewhere — do not re-report here):**
`MLX_Model_Manager_Production_Readiness.md` (59 findings on the MlxLLM download/network/persistence
lifecycle), `MLXModel_Production_Readiness.md`, and `ui_audit_backendprofile.md` (2026-04-10
typography/spacing tokens). The MlxLLM items below are ones those docs do **not** contain, or where
their claim is now wrong.

**How to use this doc.** Part A is defects in shipped code. Part B is the coverage map. §Refuted is
the register of claims that did not survive verification — do not re-report them. Every finding cites
a file:line verified in the working tree (which contains large uncommitted work — this is the shipping
candidate, not `HEAD`).

---

## Executive summary

**Verdict (2026-08-08): all 27 P1 findings are fixed, all 7 P3s, and 35 of 42 P2s. 7 open, all P2.** The two clusters that
dominated the original audit are closed, and the module's log-visibility gaps (A45–A50, A68) are
closed against the project standard — a failure on the profile read, decode, save and model-fetch
paths is now diagnosable from the log alone. What remains is P2/P3. The original assessment follows.

**Verdict at audit time: not production-ready.** Two clusters dominate.

**1. The edit buffer has three writers that bypass it.** `ProfileEditBuffer` is a correct, tested
design (`isDirty` = pure value comparison against an immutable `original`), but the Tool Library, the
workflow canvas, and the chat composer's capability chips all write profile state to disk *around* it
and never re-baseline. The results are user-visible and contradictory: a Revert that silently doesn't,
a just-saved workflow that is permanently dirty, and a composer chip that writes a stale whole-profile
snapshot over edits made minutes earlier in the editor. Nothing here is exotic — it is one missing
`markSaved()` at each of three write sites, plus keying one binding on ID instead of array index.

**2. The Anthropic provider is broken against the current API, and three other providers ship dead
knobs.** Enabling Extended Thinking swaps in an `anthropic-version` header value that does not exist
(only `2023-06-01` and `2023-01-01` are valid), which breaks the *entire profile*, not just thinking.
The thinking block itself is built on `budget_tokens`, which is **rejected with a 400** on every
current flagship model, and `temperature`/`top_p`/`top_k` are sent unconditionally though they are
removed on those same models. Meanwhile Gemini Safety Settings is four pickers no backend reads,
Ollama/Gemini advanced defaults are displayed but never persisted (so the agent-tuned preset the panel
shows is not the one that runs), and Ollama Bot profiles silently get the agent-strict preset
including `seed: 42`.

Underneath both: `advancedConfiguration` has a load-time write-back guard (`isLoading`) that cannot
fire, because SwiftUI defers `.onChange` past the synchronous `load()` that sets and clears the flag.

**Genuinely well built, and worth preserving as-is:** the unreadable-blob machinery in
`BackendProfileSD` (`primeDecodeState()` makes the decode-failure flag a function of the bytes on
disk rather than access order, and the "written by a newer build" path correctly refuses the
destructive action); `BackendProfileStore.saveProfile`'s compiler-supplied caller attribution plus its
explicit REDUNDANT-save log; `ProfileValidator`'s blocking/advisory split and the property test
pinning strict ⊇ lenient; and `HuggingFaceTokenStore`, which is the Keychain pattern the rest of the
module should follow.

| Severity | Count | Meaning |
|---|---|---|
| **P0** | 0 | — |
| **P1** | 27 (**27 fixed — all clear**) | Wrong behaviour, silent data loss, or user-visible breakage on a reachable path |
| **P2** | 40 (**3 fixed, 1 partial**) | Degraded UX, undiagnosable failure, real maintainability risk |
| **P3** | 7 | Polish |
| **Total** | **74** | |

### Fix this first

**F1 — the edit-buffer bypasses** (A1–A6) — ✅ **SHIPPED 2026-08-07**, all six as one change.
The shared fix is a new `ProfileEditBuffer.rebase(onto:)` primitive; see the changelog.

**F2 — the Anthropic request builder** (A20–A23) — ✅ **SHIPPED 2026-08-07**, all four as one change
(fixing the header alone would only have surfaced the next 400). The request shape is now selected
per model by `AnthropicModelGeneration`; see the changelog entry for what landed.

**F3 — `AgentSkillsSection`** (A11, A12) — ✅ **SHIPPED 2026-08-07**. ⚠️ Not the "two-line fixes"
this line originally called them: correcting the write sites only helps NEW data, and both defects
are unrecoverable by hand, so A12 also needed a **v7 blob migration** to repair profiles already
on disk. See the changelog.

---

## Part A — Defects

### P1 (27) — ✅ all fixed

| # | Finding | File:line | Failure scenario | Fix |
|---|---|---|---|---|
| A1 ✅ | ~~Tool Library persists tool changes but never re-baselines the edit buffer — **Revert silently lies**~~ **FIXED 2026-08-07** | `Interfaces/Main/Views/ToolLibraryContainerView.swift:353` | Agent profile → "Manage tools" → enable a tool → Back. Tools were written to `buffer.draft` *and* to disk, but `markSaved()` is never called, so `original` still holds the old list. Save/Revert pills appear for an edit the user never made; pressing **Revert** removes the tool from the editor while disk and every send still use the new set — the user is told the change was discarded and it was not. ✅ **CONFIRMED** | After each successful `saveProfile` (:366 and the binding setter at :447-456), call `profileService.editBuffer?.markSaved()` when `buffer.draft.id == profileID` |
| A2 ✅ | ~~`activateEditBuffer` seeds the editor from a stale array — the next save reverts auto-healed settings~~ **FIXED 2026-08-07** | `BackendProfile/BackendProfileService.swift:89` | Provider returns "does not support thinking"; `BackendOrchestrationService.disableThinkingOnProfile` writes `thinkingEnabled=false` straight to the store (:838). The service array is not reloaded. User opens the profile: switch shows ON, and saving *any* unrelated field (a rename) writes `true` back — undoing the auto-heal, so the 400 recurs on every send. Same mechanism reverts `MLXContextWindowHealer`'s backfilled context window. ✅ **CONFIRMED** | Have `activateEditBuffer` fetch via `profileStore.fetchProfile(byId:)` rather than the cached array, and/or post a change notification from `saveProfile` that the service observes |
| A3 ✅ | ~~Capability chips write a whole stale snapshot back, clobbering editor edits (and resurrecting a deleted profile)~~ **FIXED 2026-08-07** | `Interfaces/Shared/ChatInput/CapabilityToolbarButtons.swift:65` | Select Agent A in chat → edit A's instructions/model/tools in the sidebar → Save → back to chat (never torn down; `selectedProfileID` unchanged, so the snapshot is pre-edit) → toggle the Planning chip. The setter writes the whole stale snapshot via `saveProfile`; instructions, model and tool edits are silently reverted on disk | Re-read the row inside the setter, apply only the capability delta, then save; refresh `selectedProfile` on store change, not only on ID change |
| A4 ✅ | ~~Workflow-canvas edits from the profile editor have **no** unsaved-changes guard~~ **FIXED 2026-08-07** | `BackendProfile/BackendProfileDetailView.swift:57` | Open a Workflow profile → add nodes/edges/drag layout → click another sidebar row. The sidebar guard consults only `editBuffer?.isDirty`, and canvas geometry lives in `canvasState`/`WorkflowLayoutSD` — so `isDirty` is false, no confirmation appears, and every unsaved node is destroyed. `WorkflowCanvasView(profile:onDelete:)` is constructed with no `editGuard`, and the comment claiming the editor "has its own guard" is wrong | Pass an edit guard from the profile editor, or OR `canvasState.hasUnsavedChanges` into `ProfileSidebarListView`'s check |
| A5 ✅ | ~~Saving a workflow never re-baselines the buffer — a just-saved workflow is permanently dirty~~ **FIXED 2026-08-07** | `Interfaces/Main/Views/WorkflowCanvas/WorkflowCanvasView.swift:620` | Save on the canvas toolbar mutates `profile.details` (which *is* `editBuffer.draft`), persists, then calls `canvasState.markSaved()` only. Clicking any other profile now shows "You have unsaved changes. Discard them?" for a workflow saved seconds ago — and there is no Save/Revert pill in the canvas UI to clear it. Only exits: a phantom discard, or relaunch | Thread an `onSaved` closure from `BackendProfileDetailView` that calls `editBuffer.markSaved()` after :627 |
| A6 ✅ | ~~Profile `Binding` captures an array **index**; a reorder makes it address a different profile~~ **FIXED 2026-08-07** | `Interfaces/Shared/Chat/WorkflowExecution/WorkflowDedicatedView.swift:178` | Create a profile while the workflow canvas is open. `loadProfiles()` re-sorts by `lastSelected` desc (and `saveProfile` stamps `lastSelected` on every write), so the new profile lands at index 0 and every index shifts. Worst case: the settings panel is an AppKit panel created once, so its captured binding is never refreshed — editing node timeout there writes to the wrong workflow | Key the binding on profile ID, not index |
| A7 ✅ | ~~A `.code` profile's persisted `executionTimeout` is silently ignored~~ **FIXED 2026-08-07** | `Core/Backends/TextGen/AgentConnect.swift:508` | `CodeSessionManager` persists `executionTimeout: 300`. `AgentConnect` extracts it with `if case .agent(let c) = profile.details`, and `.code(AgentConfig)` is a different enum case → `nil` → the timeout race at :522 is skipped entirely. A stalled tool loop streams unbounded, and nothing is logged (:514 proves `.code` reaches this code) | Extract from `.agent` **and** `.code`; log the resolved timeout (or its absence) with `[EXEC_LIMITS]` + conversation ID |
| A8 ✅ | ~~Plan truncation to `maxSubtasks` drops steps with no log~~ **FIXED 2026-08-07** (both cap sites) | `Core/Backends/TextGen/Capabilities/PlanningCapability.swift:204` | Planning on, Max Subtasks at its default 5, user gives an 8-step task. `subtasks = Array(subtasks.prefix(config.maxSubtasks))` discards steps 6–8 silently; the card renders 5, the agent runs 5, reports completion. The user's only signal is a wrong answer. Every neighbouring failure path in the same function logs. Duplicated at `PlanGeneratorStrategy.swift:311` | Log at `warning` with `[PLANNING]`, generated-vs-kept counts and the consequence; surface the dropped count on the plan card |
| A9 ✅ | ~~`ProviderAdvancedConfigManager.isLoading` **can never fire**~~ **FIXED 2026-08-07** — SwiftUI defers `.onChange` past the synchronous `load()` that sets and clears it, so merely opening a profile writes the decoded (or defaulted) advanced config back into the draft | `BackendProfile/ProviderAdvancedConfigManager.swift:77` (guard at :83, handlers at :106-140) | `load()` sets `isLoading = true`, assigns, sets `false` — all in one MainActor turn. The `.onChange` handlers run on the *next* update pass, by which point the flag is false, so `encode` returns non-nil and the handler writes `advancedConfiguration = encoded`. Two outcomes: the profile is dirty on open (phantom Save pill), and a config that fails to decode is silently overwritten with `.default()` on the next save. *(Merged: reported independently by the concurrency, error-logging and coverage passes.)* | Clear the flag on the next runloop turn, or drop it and have `load` record the decoded dictionary as a baseline that `encode` compares against before writing. Log any write-back that actually changes the stored value |
| A10 ✅ | ~~`fetchModels()` fires an unowned, un-debounced, never-cancelled `Task` per keystroke; the slowest response wins~~ **FIXED 2026-08-07** | `BackendProfile/ModelPickerView.swift:611` | `baseURLBinding` commits per keystroke, so `.onChange(of: baseURL)` calls `fetchModels()` once per character. Each launches a bare `Task {}` with no handle, no debounce, no generation token and no `.onDisappear` cancellation — unlike the three sibling pickers in the same file, which all hold `@State fetchTask` and cancel it | Mirror the siblings: stored task + cancel-before-start + 500 ms debounce + `.onDisappear` cancel + monotonic generation guard |
| A11 ✅ | ~~Rescan **silently deletes** any skill folder whose scan throws~~ **FIXED 2026-08-07** | `BackendProfile/AgentSkillsSection.swift:271` | Two skill folders, one on an external volume (or renamed). Click Rescan → `scanDetailed` throws → the folder is never appended to `validFolderURLs` → :278-282 rewrites `skillConfig` with only the survivors. The row disappears, the profile goes dirty, and the next Save makes the loss permanent. Remounting does not bring it back. *(Merged ×3.)* | On failure keep the folder URL and carry its previous manifests forward as stale; only remove on explicit user action. Log with profile ID, path and consequence |
| A12 ✅ | ~~Auto-injected `execute_shell` gets a **random** `sourceId` — un-removable from any UI~~ **FIXED 2026-08-07** (incl. a v7 migration repairing profiles already on disk) | `BackendProfile/AgentSkillsSection.swift:298` | `UUID(uuidString: "00000000-SKIL-AUTO-SHEL-000000000000") ?? UUID()` — `S`,`K`,`I`,`L`,`U`,`T`,`O`,`H` are not hex, so the parse always fails and a fresh UUID is minted per import. `ToolLibraryView` matches on `(name, sourceId)`, so the row renders unchecked; enabling appends a *second* entry; disabling removes only the built-in-sourced copy. `AgentConnect` still resolves it via the native fallback, so the tool runs. **⚠️ NARROWED from P0:** an import-time banner announces it and it is constructed `requiresConfirmation: true` (Ask mode) — this is a state/removability defect, not an unannounced grant of shell access. *(Merged ×4.)* | Use `ToolSource.builtInSourceID` (force-unwrapped, so a typo fails the build) and add a test asserting the constant parses |
| A13 ✅ | ~~Ollama model store: pull **and** delete failures are invisible in both UI and logs~~ **FIXED 2026-08-07** | `BackendProfile/OllamaLLM/OllamaModelStoreViewModel.swift:111` | Delete: user confirms, `deleteModel` discards the outcome; `OllamaService.removeModel` writes `modelRemoveError`, which `setupBindings` does not track and **nothing app-wide reads**. Four of its guard arms return with no logger call at all. The card stays on screen with no message. `downloadErrorMessage` has exactly two references in the repo: its declaration and its assignment | Track `modelRemoveError`/`isRemovingModel`, render both error strings, and add `[DOWNLOAD]`-tagged logs with model name + consequence to every guard |
| A14 ✅ | ~~Sidebar profile delete uses `try?` and navigates away regardless~~ **FIXED 2026-08-07** | `Interfaces/Main/Views/Sidebar/ProfileSidebarListView.swift:178` | `deleteProfile` throws → `try?` discards it → no toast. Because the throw precedes `WorkflowLayoutStore.delete` and `loadProfiles()`, the row stays. Lines 179-181 then run `router.returnToChat()` unconditionally, yanking the user out of a profile that still exists. The create/duplicate arms ten lines above do this correctly. *(Merged ×2.)* | `do/catch` with a toast; make the navigation conditional on success |
| A15 ✅ | ~~"Discard and Reconfigure" can no-op silently on 2 of 3 paths~~ **FIXED 2026-08-07** | `BackendProfile/BackendProfileStore.swift:201` | Amber "configuration could not be read" banner → user confirms the destructive alert → if `mainContext` is nil (:201) or the `try?` fetch fails / the flag has flipped (:205), the function returns `false` with **no log**. `BackendProfileDetailView.swift:164` does `guard didDiscard else { return } // store logged it` — factually wrong for both paths. User sees: destructive confirmation accepted, banner still up, nothing anywhere. *(Merged with the store's other silent no-op arms.)* | Add `[PERSISTENCE]` error lines to both early returns naming the reason and the consequence; show a toast on `didDiscard == false` |
| A16 ✅ | ~~Every cloud API key is persisted in **cleartext** in the SwiftData blob~~ **FIXED 2026-08-07** (incl. a launch-time migration sweep) | `BackendProfile/BackendProfile.swift:1271` (`ProviderConfig.encode`) | `encodeIfPresent(apiKey,…)` lands the key in `~/Library/Application Support/DevgenticSD.store` (+ `-wal`); `strings … \| grep sk-ant` returns the live key. Any process running as the user, any Time Machine/iCloud/Dropbox backup of Application Support, or any log-collection tool recovers every OpenAI/Anthropic/Google/OpenRouter/compatible key. **⚠️ NARROWED from P0:** deliberate, documented design (`BackendProfileStore.swift:76`) with local-only exposure — no network or privilege-boundary breach. Hardening-grade | Keep `apiKey` in the struct for in-flight use but skip it in `encode(to:)`; store in `SecureKeyStorage` under `com.devgentic.provider`/`<profileID>`, mirroring `MCPSecretStore`. Delete the item in `deleteProfile` |
| A17 ✅ | ~~The Gemini model-list call puts the API key in the **URL query string**~~ **FIXED 2026-08-07** (3 sites + a 4th found outside the audited scope) | `Core/Backends/GeminiService.swift:52` | `queryItems = [URLQueryItem(name:"key",…)]` then `URLSession.shared` with default cache policy → the response is written to `~/Library/Caches/<bundle-id>/` keyed by the **full URL including the key**, a directory no uninstall path clears. Also lands in any TLS-terminating proxy's access log. Contrast `GeminiLLMProvider.swift:507`, which uses the `x-goog-api-key` header precisely so "the secret never appears in the URL" | Use the header; set `cachePolicy = .reloadIgnoringLocalCacheData` on authenticated listing calls; apply to the two `GeminiImageGenService` sites |
| A18 ✅ | ~~Cloud model pickers ignore the profile's configured **API Endpoint**~~ **FIXED 2026-08-07** | `BackendProfile/ProviderConfigSection.swift:334` | User on a corporate gateway sets API Endpoint to `https://llm-gw.internal.corp/v1` on an Anthropic profile and pastes the gateway-scoped key. `modelPicker(apiKey:)` passes only the key; `AnthropicService.verifyAndFetchModels` builds its URL from `ProviderDefaults.anthropicBaseURL` — so the key goes to `api.anthropic.com`, a host the user deliberately routed around and policy may forbid. The endpoint field is rendered directly above the picker | Thread `providerConfig.baseURL` into `modelPicker` and give each `verifyAndFetchModels` a `baseURL:` parameter defaulting to `ProviderDefaults` — the same `?? ProviderDefaults.x` shape `AgentConnect` already uses |
| A19 ✅ | ~~**Gemini Safety Settings is a completely dead knob**~~ **FIXED 2026-08-07** | `BackendProfile/AdvanceConfig/GeminiAdvancedConfig.swift:37` | User sets all four harm categories to "Block None" for a legitimate red-team/medical prompt; the setting persists. Every request still ships Google's account defaults and `GeminiLLMProvider` throws "Generation blocked by Gemini Safety Settings." The inverse fails too: tightening for a kids-facing bot adds no filtering. `buildGenerationConfig()` copies maxOutputTokens/temperature/topP/topK/stopSequences and nothing else | Read `safetySettings` in `GeminiLLMProvider` and set `body["safetySettings"]` in all three request builders — or remove the section rather than ship a safety control that does nothing |
| A20 ✅ | ~~Enabling Extended Thinking swaps in an `anthropic-version` header value **that does not exist**~~ **FIXED 2026-08-07** | `Core/Backends/ClaudeLLMProvider.swift:92` | `let apiVersion = extendedThinking ? "2025-04-14" : "2023-06-01"`. Verified against the current Anthropic API reference: the version header has exactly two valid values (`2023-06-01`, `2023-01-01`); every dated capability since ships behind `anthropic-beta`. An unrecognised value is rejected as `invalid_request_error`, so the **whole profile** stops working, not just thinking. Toggling it back off "fixes" it, making this near-impossible for a user to attribute. The stale claim is repeated in a doc comment at `AnthropicAdvancedConfig.swift:36` | Always send `2023-06-01`; put any opt-in in `anthropic-beta`. Fix the doc comment in the same change |
| A21 ✅ | ~~Extended Thinking is wired to the **removed** `budget_tokens` contract~~ **FIXED 2026-08-07** | `Core/Backends/ClaudeLLMProvider.swift:282` and `:370` | `body["thinking"] = ["type":"enabled","budget_tokens": thinkingBudget]`. Verified against the current API reference: `budget_tokens` is **rejected with a 400** on Opus 5 / 4.8 / 4.7, Sonnet 5 and Fable 5 (deprecated on Opus 4.6 / Sonnet 4.6). The agent fails on its first reasoning step, and the UI's Thinking Budget stepper (1024–100000) steers a parameter the model no longer accepts | Send `{"type":"adaptive"}` and expose the `low/medium/high/xhigh/max` ladder via `output_config.effort`; keep `budget_tokens` only behind an explicit legacy-model branch. Replace the stepper with an effort picker |
| A22 ✅ | ~~Extended Thinking is silently ignored on the chat/streaming and multimodal paths~~ **FIXED 2026-08-07** | `Core/Backends/ClaudeLLMProvider.swift:439` | On a Bot profile: (1) no `thinking` block is ever added (`body["thinking"]` appears at only two sites, both inside `generateCognitiveStep`), so the toggle is inert; (2) `applyGenerationParams` still branches on `extendedThinking` and drops the user's temperature, so the bot reverts to the provider default while the UI greys the slider and says "Locked to 1.0"; (3) `max_tokens` is not raised, so a 10000-budget profile with 4096 max_tokens gets truncated answers with no explanation | Either add the thinking block (+ max_tokens bump) to all five builders, or scope the temperature suppression to the paths that actually send thinking. Log an `[ANTHROPIC]` warning when a configured thinking budget is dropped |
| A23 ✅ | ~~Anthropic panel exposes Top P / Top K / temperature unconditionally~~ **FIXED 2026-08-07** | `Core/Backends/ClaudeLLMProvider.swift:79` | Verified: `temperature`, `top_p`, `top_k` are rejected with a 400 on Opus 5 / 4.8 / 4.7, Sonnet 5 and Fable 5. Nudging any control in the panel persists the whole struct including the default `temperature: 1.0`, so every request now 400s. temperature is gated on `!extendedThinking`, but `top_p` (:79) and `top_k` (:80) are unconditional and the UI guards only the temperature slider | Gate sampling params on model generation and hide the sliders for models that reject them; at minimum extend the `extendedThinking` guard to `top_p`/`top_k` |
| A24 ✅ | ~~Ollama and Gemini Advanced panels **display defaults that are never sent**~~ **FIXED 2026-08-07** — `advancedConfiguration` stays nil until the user edits something | `BackendProfile/ProviderAdvancedConfigManager.swift:36` | User creates an Ollama Agent, opens Advanced, sees Temperature 0.10 / Top P 0.60 / Top K 40 / Seed 42 / Repeat Penalty 1.10 — the agent preset whose stated purpose is deterministic tool calls — and closes it satisfied. Nothing was written: `advancedConfiguration` is still nil, so `mapToOllamaOptions` gets nothing and Ollama runs at its own default (~0.8) with random sampling. The agent then emits exactly the loose tool calls the preset exists to prevent. Same class for Gemini's Max Output Tokens | Persist the resolved default at the end of `load(from:)` when decoding returned nil, or make the executors fall back to the same `default()` structs the UI displays. Log `[PROFILE]` when a profile executes with no advanced configuration |
| A25 ✅ | ~~**Bot** profiles get the agent-strict Ollama preset (temp 0.1, fixed seed 42)~~ **FIXED 2026-08-07** | `BackendProfile/ProviderAdvancedConfigManager.swift:17` | `localOllamaConfig = .default()` → `.preset(for:.smallMedium)` → the **agent** ladder (temperature 0.1, topP 0.6, seed 42); the chat ladder is the separate `botPreset` (temp 0.7, seed nil). Adjust anything at all and the whole struct persists including `seed: 42`, so the bot returns byte-identical replies to repeated prompts at temperature 0.1 — the opposite of what `botPreset` exists to provide. The `defaultProfile` parameter that is supposed to select this never reaches `load()` | Thread `defaultProfile` into `load(from:)` and use `.botPreset(for:)` for chat hosts, mirroring the Reset button's dispatch |
| A26 ✅ | ~~**The Delete button on an Image Generator profile does nothing**~~ **FIXED 2026-08-07** | `BackendProfile/ImageGenConfigDetailView.swift:438` | Trash icon sets `showingDeleteAlert = true` and nothing renders. No alert, no toast, no log, no deletion. `grep "showingDeleteAlert\|\.alert("` over the 488-line file returns exactly two hits — line 34 and line 438. `AgentConfigDetailView:799` and `BotConfigDetailView:294` both attach one. The user clicks repeatedly and concludes the app is frozen | Attach the same `.alert` block used in `BotConfigDetailView:294-305`, calling `deleteProfile(withId:)` and surfacing errors via `toastManager` |
| A27 ✅ | ~~Navigating away **silently discards everything typed in the floating "Expand" prompt editor**~~ **FIXED 2026-08-07** | `BackendProfile/AdvancedPromptEditor.swift:85` | Expand → type a 3,000-char system prompt → click the back chevron. `onDisappear` fires `closeWindow()` → `NSWindow.close()`, which per AppKit does **not** consult `windowShouldClose(_:)`, so the "Unsaved Changes" alert at :100-125 never appears. The editor keeps its text in `@State localText` and only writes back inside `saveAndClose()`. Nothing is logged. The footer at :317 says changes sync automatically | Use `window?.performClose(nil)` (routes through `windowShouldClose`) or run the `checkChanges`/`saveChanges` handshake before closing; log the discard with a char count; fix the footer copy |

### P2 (42) — 35 fixed, 7 open

| # | Finding | File:line | Impact |
|---|---|---|---|
| A28 ✅ | ~~Workflow modal editor's X calls `dismiss()` directly, bypassing the dirty guard the same view uses everywhere else~~ **FIXED 2026-08-07** — one `leaveEditor()` per view, shared by the button and the guard; sheet dismissal disabled while dirty | `AgentConfigDetailView.swift:298` | Esc or X in the workflow node editor destroys every sheet-local edit with no prompt |
| A29 ✅ | ~~⌘Q with a dirty profile editor discards edits — no prompt, **and no log line**~~ **FIXED 2026-08-07** — `applicationShouldTerminate` prompts Save / Discard / Cancel before any teardown, and a failed save cancels the quit | `AppDelegate.swift:185` | 2,000-char unsaved prompt gone; the loss is invisible in a support log, contrary to the project logging standard |
| A30 ✅ | ~~Deleting a profile cascades only to its own workflow layout — scheduled tasks and other workflows' `agentProfileIDs` keep pointing at a dead ID~~ **FIXED 2026-08-08** — scheduled tasks are DISABLED (not deleted) instead of failing forever; the delete confirmation names what breaks. ⚠️ **The workflow half was already covered** — see changelog | `BackendProfileService.swift:76` | A nightly scheduled task bound to the deleted agent fires and fails forever; the alert says only "cannot be undone" |
| A31 ✅ | ~~Duplicating a profile silently drops `fileContextStrategy`~~ **FIXED 2026-08-07** — duplication is now copy-by-default via `BackendProfileSnapshot.duplicated(as:)`. ⚠️ **The stated direction was backwards** (corrected below) | `BackendProfileDetailView.swift:367` | A `.stateless` agent's copy silently attaches file **content** instead — the copy behaves differently from the original at send time |
| A32 ✅ | ~~Send **button** silently does nothing when the selected profile was deleted, while Enter opens the picker for the identical condition~~ **FIXED 2026-08-07** — both entry points now share `attemptSend`, and the dangling selection is cleared so the composer stops naming a deleted profile | `ChatInputAreaView.swift:733` | Composer still shows the dead profile's name from a stale snapshot; clicking send logs one line and returns with no visible feedback |
| A33 ✅ | ~~⌘⇧P fabricates a UUID when no profiles exist~~ **FIXED 2026-08-08** — with no profiles it selects the Profiles sidebar (empty state / Retry) instead of navigating to an invented ID | `DevgenticApp.swift:686` | First-run user lands on "Profile Not Found" for a profile that never existed; the previous edit buffer is left active |
| A34 ✅ | ~~`Severity.advisory` is computed on every save but has **no return path to any UI** — it can only ever be logged~~ **FIXED 2026-08-08** — `saveProfile` returns the advisories (`@discardableResult`); the three editors show a dismissible `SaveAdvisoryBanner` | `ProfileValidator.swift:71` | The tool-capability advisory is recomputed and discarded on every save; `validationFailed` carries `blocking` only |
| A35 ✅ | ~~The blocking "System instructions are required" rule lives in two views, not in `ProfileValidator` — creation and every other save path bypass it~~ **FIXED 2026-08-08** — one definition in `ProfileValidator`, both editors delegate. ⚠️ **Advisory at the store, not blocking** — see changelog | `AgentConfigDetailView.swift:881` | An Agent created from the + button persists with `instructions == nil` and is never caught |
| A36 ✅ | ~~Thinking Budget can exceed Max Output Tokens; the caption states the constraint but nothing enforces it~~ **FIXED 2026-08-08** — `validateAdvancedConfiguration` is the validator's first look inside the blob at all | `AdvanceConfigurationView.swift:661` | Budget 64000 with max 2048 saves fine; `ProfileValidator` never inspects `advancedConfiguration` at all |
| A37 ✅ | ~~Ollama picker silently rewrites the profile's persisted `modelName` on appear when the stored model is gone~~ **FIXED 2026-08-08** — all four pickers now share `ModelSelectionPolicy`; only an EMPTY selection is filled | `ModelPickerView.swift:647` | Open a profile pinned to a since-deleted model to change something unrelated → a *different* model is written into the binding with no notice |
| A38 ✅ | ~~`TraceConfigSnapshot` records no `resilienceOverrides` and stores `maxIterations` as nil when defaulted~~ **FIXED 2026-08-08** — records RESOLVED caps via the runtime resolver; new `AgentExecutionDefaults` ends a 15-vs-20 drift the dump was already lying about | `TraceConfigSnapshot.swift:185` | The limits that terminated a run are unrecoverable from telemetry — only the circuit-breaker's own line survives |
| A39 | MLX advanced config silently clamps maxTokens/repetitionContextSize with no log and no feedback — the Ollama panel beside it makes the opposite choice | `MLXAdvancedConfig.swift:299` | Re-pointing a profile at a smaller-context model silently discards a tuned 8192 down to 2048 |
| A40 ✅ | ~~Skill import swallows `fileImporter` `.failure` and silently drops duplicate-named manifests~~ **FIXED 2026-08-07** — shared `FileImportOutcome` separates cancellation from failure; duplicates ride the existing `skipped` list and name which copy won | `AgentSkillsSection.swift:203` | Permission denial / ejected volume is indistinguishable from cancelling: no error, no banner, no log. *(Merged ×4.)* |
| A41 ✅ | ~~The `seedUserPreferences: false` guard protecting Extended Thinking (G98) is bypassed — the fetch's own `selectedModel` write re-enters via `.onChange` with `true`~~ **FIXED 2026-08-08** — the fetch's own write is recognised by VALUE token, not a synchronous flag | `ModelPickerView.swift:670` | Reopening a profile whose model vanished re-seeds a user preference the guard exists to protect |
| A42 | `OllamaModelStoreViewModel` tracks `pullProgress` in an app-lifetime `ObservationStream` — every NDJSON chunk triggers a full re-filter + re-sort + six `@Observable` writes, even off screen | `OllamaModelStoreViewModel.swift:100` | The exact anti-pattern the MLX view model documents having removed; a multi-GB pull degrades the whole app |
| A43 | Typing in the Installed-tab filter triggers a **forced, uncoalescable recursive disk walk** per debounce pause | `MLXModelStoreViewModel.swift:344` | `force: true` was designed for post-mutation callers; a keystroke is not a mutation. (`isRemoteSearchEnabled` is initialised `true` and never assigned, so its guard is dead) |
| A44 ✅ | ~~`MLXModelPickerView` hops out of structured concurrency with `DispatchQueue.main.async` after its `.task` await — no cancellation check, no logging~~ **FIXED 2026-08-08** — direct MainActor writes inside the `.task` scope, `Task.isCancelled` honoured, and the file gained a logger | `MLXModelPickerView.swift:121` | A slow first-run scan writes model identity and metadata into a profile editor the user already left |
| A45 ✅ | ~~A store fetch failure is converted into "no profiles are unreadable" / "this profile is fine" with no log~~ **FIXED 2026-08-07** — all four fail-open paths are do/catch with `[PERSISTENCE]` logs naming the consequence | `BackendProfileStore.swift:170` | Four fail-open paths (`:167`, `:170`, `:187`, `:191`), none logged; the whole unreadable-blob UX depends on them |
| A46 ✅ | ~~All four provider model pickers log nothing on fetch failure~~ **FIXED 2026-08-07** — Ollama arm was done first; the three cloud pickers and the OpenAI-compatible arm now log the endpoint, the error and the consequence | `ModelPickerView.swift:675` | TLS failure, 403 from a proxy, JSON decode error and a genuinely-down daemon are indistinguishable to the user **and absent from the log** |
| A47 ✅ | ~~A profile-fetch failure at launch produces an empty sidebar that reads as "you have no profiles", behind one untagged log line~~ **FIXED 2026-08-07** — `lastLoadError` + a distinct "Couldn't Load Profiles" / Retry empty state | `BackendProfileService.swift:50` | `loadProfiles()` from `init` has nothing to keep on failure; the user sees a first-run empty state instead of an error |
| A48 ✅ | ~~Advanced-config decode failure is one untraceable line, answered by substituting app defaults over the user's stored settings~~ **FIXED 2026-08-07** — `decodeConfig` takes a `context:` and logs profile, target type, stored keys and the defaults fallback | `BackendProfileService.swift:185` | No bracket tag, no profile ID, no provider, no target type, no consequence — then all seven `load` arms answer nil with `?? .default()` |
| A49 ✅ | ~~`getAdvancedConfig` and `logProfileSelection` (160 lines) have **zero callers**, and the dead one contains an MLX routing bug~~ **FIXED 2026-08-07** — `getAdvancedConfig` **deleted** (not revived: a second source of truth for advanced config is what caused A24/A25); `logProfileSelection` given a caller under A50 | `BackendProfileService.swift:103` | Not live today. On revival, `getAdvancedConfig`'s `default:` clause hands an **Ollama** parameter set back for an MLX profile, and the non-exhaustive switch means the compiler will not flag it. *(Merged with the two diagnostic-dump findings.)* |
| A50 ✅ | ~~`logProfileSelection` — the module's only full profile dump — is never invoked, so no run records which settings it used~~ **FIXED 2026-08-07** — called from `activateEditBuffer`; content split into `profileSelectionSummary` and covered by 6 tests (key masking, per-tool ON/OFF) | `BackendProfileService.swift:193` | "My agent stopped calling tools" has no log-side answer: no provider, model, capability, per-tool state or advanced-config keys anywhere |
| A51 | `HFRequest.perform` reads the Keychain singleton directly, defeating the documented HF-token injection seam `MLXModelService` advertises | `MLXModelService.swift:1830` | A test constructing `MLXModelService(modelsRootOverride:)` still hits the real login Keychain — contradicting the doc comment at :220-227 and the 2026-08-03 changelog entry |
| A52 ✅ | ~~A cloud profile's endpoint may be plain `http://` with no warning, and the key is sent to it in the clear~~ **FIXED 2026-08-08** — `EndpointTransportSecurity` classifies it; inline warning under the endpoint field + an advisory validator rule. Loopback exempt | `ProfileValidator.swift:232` | `Authorization: Bearer <key>` over unencrypted HTTP to a non-loopback host; Rule 5 accepts any `http` scheme |
| A53 ✅ | ~~`GeminiService` writes the raw key to `UserDefaults` (`gemini_api_key`) as a pure side effect~~ **FIXED 2026-08-08** — write deleted, and a launch purge removes copies earlier builds already wrote of every successful model-list fetch — never read back, never cleared, survives profile deletion | `ModelPickerView.swift:111` → `GeminiService` | Second cleartext copy in `~/Library/Preferences/`. **⚠️ NARROWED:** no new exposure class beyond A16; the distinct harms are the key outliving its profile forever and an undocumented, unlogged secret write |
| A54 ✅ | ~~Gemini's shipped default `topK: 1` forces greedy decoding, silencing the temperature and Top P the same panel exposes~~ **FIXED 2026-08-08** — default omitted, stored `1` repaired on decode, and the drop that would have made the fix inert (B43) closed | `GeminiAdvancedConfig.swift:44` | Panel shows Temperature 0.90 next to Top K 1; dragging temperature persists `topK: 1`, so the "creative" bot returns identical flat output and the slider is decorative |
| A55 ✅ | ~~Reasoning Effort is exposed with no o-series gating and is sent to arbitrary OpenAI-compatible endpoints~~ **FIXED 2026-08-08** — `OpenAIModelFamily` gates the whole request shape (`max_completion_tokens`, sampling, `reasoning_effort`); the picker is hidden for models that reject it | `OpenAILLMProvider.swift:71` | Reasoning models reject `max_tokens` (need `max_completion_tokens`) and non-default temperature — both are sent alongside `reasoning_effort` |
| A56 ✅ | ~~ImageGen "Quality" is labelled as applying to all providers, but only OpenAI and MLX read it~~ **FIXED 2026-08-07** | `ImageGenAdvancedConfig.swift:40` | HD on a Gemini or Ollama profile produces byte-identical output to Standard — decorative for half the supported providers |
| A57 ✅ | ~~`AdvancedConfigSyncModifier` discards user edits behind seven unlogged guards~~ **FIXED 2026-08-08** — seven copies collapsed into one logged `sync(_:)`; the provider check now runs BEFORE `encode`, which had a baseline side effect | `ProviderAdvancedConfigManager.swift:106` | Edit the Ollama temperature then switch provider in the same view pass → the pending `.onChange` fires, the provider check fails, the edit is dropped with no log, no toast, no trace |
| A58 ✅ | ~~Deleting from a detail view lands on "Profile Not Found"~~ **FIXED 2026-08-07** | `AgentConfigDetailView.swift:799` | A deliberate, confirmed action is reported as an error; the `onDelete` callback threaded through four views is never invoked |
| A59 ✅ | ~~"Remove All" wipes every skill folder and all per-skill enable state with **no confirmation** and no targeted undo~~ **FIXED 2026-08-07** — confirmation states the folder count, skill count and the per-skill choices being discarded | `AgentSkillsSection.swift:52` | One click nils `skillConfig` outright; the only recovery is the profile-wide Revert, which also throws away every other unsaved edit |
| A60 ✅ | ~~Three `fileImporter` result handlers discard `.failure` entirely — no message, no log, no retry hint~~ **FIXED 2026-08-07** — all three route through `FileImportOutcome`; the two knowledge importers share one `KnowledgeSourceImport.apply` | `AgentSkillsSection.swift:203` | An iCloud placeholder that fails to materialise looks exactly like cancelling |
| A61 ✅ | ~~Every slider, stepper and picker in Advanced Configuration is unlabeled and valueless to VoiceOver~~ **FIXED 2026-08-08** — 24 control sites labelled across all five provider panels; `AdvancedConfigNumericField` now REQUIRES an accessibility name | `AdvanceConfigurationView.swift:58` (28 control sites) | The whole panel is unusable without a pointer: controls announce as bare "slider, 45%" with the parameter name stranded in a sibling `Text` |
| A62 ✅ | ~~The entire Agent Configuration Guide — 44 user-facing strings — is invisible to the String Catalog extractor~~ **FIXED 2026-08-08** — every guide helper takes `LocalizedStringKey`, so the literals become extractable keys | `AgentConfigGuideView.swift:200` | In a French build the sheet chrome is translated and every word of content renders in English; unfixable by a translator |
| A63 | Execution-policy and Conversation-Memory option labels are `String`-typed `displayName`s, so the whole Execution card ships untranslated | `BackendProfile.swift:288` | Translated section headers sit directly above English-only "Abort / Skip & Continue / Fallback Prompt", plus four memory cards and their descriptions |
| A64 ✅ | ~~The New Profile sheet dismisses **before** the save is attempted, so a rejected save discards the name and type the user entered~~ **FIXED 2026-08-07** — `onContinue` throws; the sheet dismisses only on success and shows the reason inline | `AddBackendProfileView.swift:144` | A 150-char name fails Rule 2 after the sheet is already gone; the toast has nothing to return to |
| A65 ✅ | ~~A healthy reference document is drawn in the **warning** colour~~ **FIXED 2026-08-07** — healthy takes the accent and a document glyph, missing takes the error colour AND a warning triangle, so the states differ by shape as well as tint; row extracted so both editors share it | `AgentConfigDetailView.swift:596` | "File is fine" (orange) and "file is broken" (red) both read as alarm states, and colour is the only differentiator |
| A66 ✅ | ~~Agent delegation is still injected at runtime but its UI toggle was deleted — a profile that has it can never turn it off~~ **FIXED 2026-08-08** — an OFF switch that appears only for profiles that already have it, and disappears once used. Not re-offered to new profiles | `AgentCapabilitiesSection.swift:146` | `ProfileMigrator.migrateToV2` creates the config for legacy "Supervisor" profiles; `AgentConnect` injects `call_agent` on every run with no control and no indication |
| A67 ✅ | ~~`parallelSubtasks` is UI-hidden with a comment claiming it is "forced to false" — nothing forces it, and the planner still branches on a stored `true`~~ **FIXED 2026-08-08** — enforced at consumption by `PlanningCapability.parallelSubtasksSupported`; a stored `true` is logged and ignored, not rewritten | `AgentCapabilitiesSection.swift:49` | The tolerant decoder defaults only when the key is *absent*; a persisted `true` decodes as `true` and takes the parallel branch with no user control |
| A68 ✅ | ~~Profile save failure is a toast and nothing else — **no log line anywhere on the primary user-data write path**~~ **FIXED 2026-08-07** — all three detail views log `[PROFILE] Save FAILED for '<name>' (<id>, <kind>)` with the dirty-buffer consequence before the toast | `AgentConfigDetailView.swift:892` (all three detail views) | "My agent config won't stick" leaves nothing to correlate: no profile ID, no type, no error |
| A69 ✅ | ~~All six persisted `AdvanceConfig` Codables have zero tests~~ **FIXED 2026-08-07** — suite added, and it exposed 4 real decode defects in the two structs with no tolerant decoder (now hardened) | `MLXAdvancedConfig.swift:27` | These are the exact shapes inside the opaque `configData` blob the code itself flags as the layer SwiftData cannot see into, "where adding a field is not a schema change and the failure lands at READ time" |

### P3 (7) — ✅ all fixed

| # | Finding | File:line |
|---|---|---|
| A70 ✅ | ~~"Auto (3)" labels in Error Recovery / Loop Safety are hardcoded, but Auto resolves to the profile's legacy `retryPolicy.maxRetries` — the label lies for migrated profiles~~ **FIXED 2026-08-07** — labels read `ResolvedResiliencePolicy.autoDefault(legacy:)`, the same source the resolver uses | `ExecutionLimitsSection.swift:97` |
| A71 ✅ | ~~`SimplePromptWindowManager` sets no `NSWindowDelegate`: closing with the red button leaks a closed `NSWindow` + `NSHostingView`, and the file emits no lifecycle log at all~~ **FIXED 2026-08-07** — `NSObject` + `windowWillClose` releases on every close path; open/close/re-present all logged | `SimplePromptWindowManager.swift:76` |
| A72 ✅ | ~~`AdvancedPromptWindowManager` retain cycle — `checkChanges`/`saveChanges` capture the editor view strongly; only `discardChanges` was written `[weak manager]`~~ **FIXED 2026-08-07** — all four capture state BINDINGS (never the view) plus a weak manager; `commitChanges` had the same defect and is not in the original finding | `AdvancedPromptEditor.swift:363` |
| A73 ✅ | ~~Gemini temperature slider caps at 1.0 while the API accepts 0.0–2.0~~ **FIXED 2026-08-07** — range is `0.0...2.0`, matching the OpenAI panel, and the caption states the range | `AdvanceConfigurationView.swift:58` |
| A74 ✅ | ~~The Agent guide documents a "Parallel Subtasks" setting that was deliberately removed from the UI (see A67)~~ **FIXED 2026-08-07** — row removed; ⚠️ the stored field is still read by `PlanningCapability`, which is **A67 and remains open** | `AgentConfigGuideView.swift:76` |
| A75 ✅ | ~~The floating prompt editor's title goes stale on rename, and its context-window readout is dead code — no caller passes `contextWindow`~~ **FIXED 2026-08-07** — `botName` is a binding so the title follows automatically; the bot editor now passes a real `contextWindow` | `SimplePromptWindowManager.swift:152` |
| A76 ✅ | ~~New profiles are saved with the **untrimmed** display name while duplicate detection compares trimmed — whitespace-padded duplicates evade the warning forever~~ **FIXED 2026-08-07** — persists `trimmedName`, the same string every check already validated | `AddBackendProfileView.swift:181` |

---

## Part B — Test coverage

Method: for each of the 47 files, every top-level declared type was enumerated and each name grepped
separately across `DevgenticTests/`. (The first pass was invalidated by zsh not word-splitting an
unquoted variable — the project's own recorded trap — and was redone.)

**Tested — 18 files**, via `BackendProfileStoreTests`, `BackendProfileServiceTests`,
`ProfileEditBufferTests`, `ProfileValidatorTests`, `ProfileValidationSeverityTests`,
`ProviderConfigSwitchProviderTests`, `ToolCapabilityNoteTests`, `FileContextStrategyTests`,
`HuggingFaceTokenTests`, and the `MLX*` suites under `Core/Service/`.

**Untested — 29 of 47.** Ranked by risk:

| Risk | Files |
|---|---|
| **Higher — mutate or persist user data** | `ProviderAdvancedConfigManager`, `AgentSkillsSection`, `ImageGenConfigDetailView`, `AgentConfigDetailView`, `BotConfigDetailView`, `BackendProfileDetailView` (incl. `DuplicateProfileSheet`, which **is** live), `AddBackendProfileView`, `ProviderConfigSection`, `ExecutionLimitsSection`, `AdvanceConfigurationView`, the six persisted Codables (`MLXAdvancedConfig`, `ImageGenAdvancedConfig`, `OpenAIAdvancedConfig`, `AnthropicAdvancedConfig`, `GeminiAdvancedConfig`, `OllamaAdvancedConfig`), `OllamaModelStoreViewModel`, `AdvancedPromptEditor` (its `Coordinator` is a >3-state mention/autocomplete machine with zero tests), `SimplePromptWindowManager` |
| **Lower — pure presentation** | `AgentCapabilitiesSection`, `AgentConfigGuideView`, `FileContextStrategyPicker`, `ModelPickerView`, `MLXModelStoreView`, `MLXModelDetailSheet`, `MLXModelPickerView`, `MLXUIComponents`, `ModelFitBadgeView`, `OllamaModelStoreView` |

No `#if DEBUG` blocks exist anywhere in the module, so there is no debug/release behavioural
divergence here. The one release-compiled development leftover is a bare `print()` inside a
`PreviewProvider` at `AddBackendProfileView.swift:322-327`.

---

## Refuted

Do not re-report these.

| Claim | Verdict |
|---|---|
| `MLXModelDetailSheet.swift:87` force-unwraps `URL(string: "https://huggingface.co/\(model.id)")!` → crash on a model id containing a space | **REFUTED.** The cited code and its reachability are real (installed cards are built with `id: item.displayName`, and the sheet is presented from an unguarded `.onTapGesture`), but the crash mechanism is not: since macOS 14 `URL(string:)` is `init?(string:encodingInvalidCharacters:)` with `encodingInvalidCharacters` defaulting to `true`, so invalid characters are percent-encoded rather than returning nil. Latent style issue only — **P3**, not a crash |

Two items were **narrowed** rather than refuted and appear above at their corrected severity: A12
(P0 → P1 — announced by a banner and gated by `requiresConfirmation: true`, so this is a
state/removability defect, not an unannounced grant of shell access) and A16 (P0 → P1 — deliberate,
documented design with local-only exposure).

---

## Recommended sequencing

1. **F1 — edit-buffer bypasses as one change:** A1, A3, A4, A5 (+ A2 for the stale-array read). Fixing
   any one alone leaves the contradictory Revert in place.
2. **F2 — Anthropic request builder as one change:** A20 → A21 → A23 → A22. The version header alone
   bricks thinking-enabled profiles; fixing it just surfaces the next 400.
3. **F3 — `AgentSkillsSection`:** A11, A12, A40/A60, A59. Two-line fixes with permanent consequences.
4. **A9** (`isLoading` guard) before A24/A25/A57 — they all sit on the same write-back path.
5. **A7, A8** — two silent limit-drops on the execution path, each one `if case` / one log line.
6. **A26, A27** — two dead/destructive UI controls, each self-contained.
7. ~~Logging sweep: A45–A50, A68 close the module's log-visibility gaps against the project standard.~~ **DONE 2026-08-07.**
8. Secrets: A16 → A17 → A53 → A18 → A52.
9. Tests: start with the six `AdvanceConfig` Codables (A69) — they are the blob layer where a schema
   change fails at READ time.

---

## Part C — Audit scope (for the follow-up review)

**Status at hand-off (2026-08-08): 69 of 76 findings fixed. 7 open, all P2** — A39, A42, A43, A51,
A53, A54, A63. Every P1 and every P3 is closed.

⚠️ **Nothing in Part A has been reviewed by anyone other than its author.** The fixes were written,
built and tested in a single session against the same understanding that produced them — so a
mistaken premise would have propagated into the fix, its comment and its test alike. That is what
the follow-up audit is for, and it is why the manifest below exists.

### What changed

| | Count |
|---|---|
| Findings fixed | 69 (27 P1, 35 P2, 7 P3) |
| Source files modified | 42 (all carry a `register AXX` marker — that is how they were enumerated) |
| **New** source types | 12 |
| Test files added/extended | 22, **263 test cases** |

**New types introduced.** These carry the most risk: each one is a policy decision expressed as
code, and several centralise behaviour that was previously duplicated.

| File | Register | What it decides |
|---|---|---|
| `Core/Backends/AnthropicModelGeneration.swift` | A20–A23 | Which request contract a Claude model accepts |
| `Core/Backends/OpenAIModelFamily.swift` | A55 | Reasoning vs standard OpenAI request shape |
| `Core/Backends/AdvancedConfigEncoder.swift` | A24/A25 | The one struct→options encoder |
| `Core/Backends/TextGen/AgentExecutionDefaults.swift` | A38 | The iteration cap default (15) |
| `Core/Persistence/ProviderKeyStore.swift` | A16–A18 | Keychain storage for provider keys |
| `Interfaces/Shared/Components/FileImportOutcome.swift` | A40/A60 | Cancelled vs failed file import |
| `…/BackendProfile/ModelSelectionPolicy.swift` | A37 | When a saved model may be replaced |
| `…/BackendProfile/EndpointTransportSecurity.swift` | A52 | When plain HTTP is a risk |
| `…/BackendProfile/ProfileReferenceIndex.swift` | A30 | What references a profile |
| `…/BackendProfile/KnowledgeSourceImport.swift` | A60 | Shared knowledge-file import |
| `…/BackendProfile/KnowledgeSourceRow.swift` | A65 | Shared reference-document row |
| `…/BackendProfile/SaveAdvisoryBanner.swift` | A34 | How advisories reach the user |

### Where the risk concentrates

Ranked by blast radius, for an auditor deciding where to spend effort:

1. **Provider request shapes (A20–A23, A55).** `AnthropicModelGeneration` and `OpenAIModelFamily`
   decide the body of every cloud request. Both classify from a model-id string; both have an
   explicit unknown-id rule, and those rules are **deliberately opposite** (Anthropic: unknown =
   newest; OpenAI: unknown = standard). A wrong classification is a 400 on every send for that model.
   ⚠️ The Anthropic contract was verified against the `claude-api` skill, not from memory — anything
   re-checked here should be too.
2. **Credentials (A16–A18, A52, A53-open).** `ProviderKeyStore` moved keys to the Keychain with a
   migration over existing rows. Order matters: write before strip, strip only on success.
3. **Signature changes with wide reach.** `saveProfile` now returns `[ProfileValidationError]`
   (A34); `BackendProfileSnapshot.id` became `var` (A31); `showEditor(botName:)` takes a `Binding`
   (A75); `unsavedChangesBackGuard` requires `onLeave` (A28). Each has many call sites.
4. **Behaviour deliberately NOT changed.** Several findings were closed by *narrowing* rather than
   fixing — verify these judgements rather than assuming them: A44 keeps the MLX model rewrite
   (local disk check), A67 preserves a stored `true` instead of migrating it, A66 ships an exit
   rather than a toggle, A74 removed a guide row while A67's runtime behaviour persists, and A35's
   rule is advisory precisely so it cannot break the thinking auto-heal.
5. **Findings whose register text was WRONG and was corrected during the fix** — A31 (direction
   reversed), A75 (`updateTitle` had a caller), A30 (workflow half already covered). If the register
   was wrong three times, it can be wrong again.

### Known-open, deliberately

- `WorkflowConfig.agentProfileIDs` accumulates stale IDs after a profile delete (A30). Feeds only a
  count in the profile-selector popover; not worth a blob migration.
- `Severity.advisory` now has a surface (A34), but the tool-capability and transport rules still
  have their own bespoke UI as well. Not consolidated.
- ⚠️ **Pre-existing red, not caused by this work:** `TransportRetrierTests` is 7-of-10 failing at
  HEAD. `TransportRetrier.swift:91` deliberately nils `drainPenalty` for cloud 429s and the tests
  still assert the old contract. Spun out separately — do not attribute it to these changes.

---

## Changelog

- **2026-08-08** — **A33, A35, A36 and A38 fixed.**

  **A33.** `profiles.first?.id ?? UUID()` invented an ID that had never existed and navigated to it,
  so a first-run user pressing ⌘⇧P landed on "Profile Not Found" for a profile they had never
  created — the one state where the menu item most needs to help was the one it broke. With no
  profiles it now selects the Profiles sidebar, where the empty state offers "New Profile" (or the
  "Couldn't Load Profiles" Retry state from A47 if the read failed rather than came back empty).
  The `@AppStorage` key gained a home on `SidebarTab` so the menu and the container cannot drift
  over a string literal.

  **A35.** The rule lived in two views and nowhere else, so creation from +, the capability chips,
  the Tool Library, `CodeSessionManager`, the thinking auto-heal and the quit-time save (A29) all
  wrote instruction-less profiles unchecked. One definition now — `instructionsAreMissing` plus a
  shared message — with both editors delegating to it.

  ⚠️ **Advisory at the store, not blocking, and this was the whole design question.** Blocking there
  would refuse every out-of-band write to such a profile — including
  `BackendOrchestrationService.disableThinkingOnProfile`, whose job is to stop a recurring provider
  400. An agent created from + and not yet configured is *exactly* the profile the rule fires on, so
  those saves are not hypothetical. The editors keep their hard block, where the user is present and
  can act; everywhere else it is recorded and surfaced by A34's banner — which is the first cluster
  to make use of the channel A34 built.

  ⚠️ **A bug of mine that the existing suite caught.** The lenient arm also calls
  `validateInstructions` ("validate LENGTH if present"), so my first cut reported missing
  instructions at CREATION — on every new profile, where having none is correct.
  `RejectedProfileCreationTests` failed and named it. The presence check is now `requirePresence:`,
  passed only from the strict bot/agent arms.

  ⚠️ Three fixtures then failed asserting a profile was "fully valid" with no instructions — a state
  `BotConfigDetailView` has always refused to save. The fixtures predated the centralised rule, so
  they were given instructions rather than the assertions being loosened; each keeps its original
  precision and now tests one rule instead of two.

  **A36.** `ProfileValidator` never inspected `advancedConfiguration` **at all**, so a Thinking
  Budget of 64000 against Max Output Tokens of 2048 saved cleanly and then 400'd on every send — the
  panel's own caption stated the constraint and nothing enforced it. `validateAdvancedConfiguration`
  is the validator's first look inside the blob. ⚠️ Advisory: the blob cannot be decoded with
  certainty for every provider, and a false positive would refuse a legitimate save. ⚠️ Silent when
  thinking is OFF — the budget is inert then, and warning about it would be noise on a working
  profile.

  **A38.** The trace recorded no resilience caps and stored `maxIterations` as nil when defaulted,
  so the limit that terminated a run was unrecoverable — and `Auto` resolves through the profile's
  legacy `retryPolicy.maxRetries` (A70), which may since have changed, making it unreconstructable
  after the fact. New `ResilienceSnapshot` records the **resolved** caps through the same
  `ResolvedResiliencePolicy.resolved` the runtime uses, and `maxIterations` records the effective
  value plus whether it came from the default.

  ⚠️ **It exposed a live drift.** The iteration default was a bare `15` at four sites — and
  `logProfileSelection`, the dump a support engineer reads, used `?? 20`. The configuration record
  stated a cap of 20 for a run the executor bounded at 15. New `AgentExecutionDefaults.maxIterations`
  is the single definition; the executor, the panel's "Auto (N)" label, the dump and the trace all
  read it.

  Covered by 14 new tests in `ValidationAndTelemetryGapTests.swift`. A33 is a menu action with no
  testable seam. Regression-checked: 299 tests across 23 suites — all green; app builds clean.

- **2026-08-08** — **A34, A66 and A67 fixed.** A66 and A67 are the same defect in two places: a
  capability was withdrawn from the UI, and the RUNTIME was left doing whatever the stored blob said.

  **A34.** The `.advisory` severity existed, its rules ran on every save, and the result went nowhere
  but a log line. The tell is that both advisory rules had to hand-build their own bespoke view to be
  seen at all — `ModelPickerView`'s alert for tool capability, and the endpoint field's inline
  warning for A52. The severity had no surface of its own, only workarounds. `saveProfile` now
  **returns** the advisories, through the store protocol and the service, and the three editors show
  a dismissible `SaveAdvisoryBanner`.

  ⚠️ **Shown after a save, never continuously.** An advisory describes likely-degraded behaviour, not
  a fault; a permanent banner would nag the user about a choice they already made. Appearing in
  response to the save they just performed makes it solicited. ⚠️ **`@discardableResult`** — of ~23
  call sites only the editors have anywhere to show these, and forcing the rest to render something
  would put the same warning on screen from four directions. ⚠️ The G92 invariant is re-asserted in
  tests: returning advisories must not turn them into a gate by any route. ⚠️ The protocol change
  broke six test doubles, which is the good outcome — the compiler enumerated every implementer.

  **A67.** The UI comment claimed "Default is forced to false below" and nothing forced anything. The
  tolerant decoder defaults the field only when the key is ABSENT, so a profile saved while the
  toggle still existed decoded `true` and took the parallel branch, uncontrollably and invisibly.
  Enforcement now lives at consumption in `PlanningCapability.parallelSubtasksSupported` — one
  constant to flip when batch inference or multi-model routing makes parallelism real.

  ⚠️ The stored `true` is **logged and ignored, not rewritten**. Rewriting it would destroy a
  preference the user expressed, for a feature the team intends to restore; a migration here would
  be a one-way door. The log line exists because "my agent used to run subtasks in parallel and now
  doesn't" has no other answer anywhere in the app. ⚠️ `Self.` does not resolve to the struct inside
  the `AsyncThrowingStream` closure — the constant has to be spelled `PlanningCapability.`.

  **A66.** The delegation toggle was removed, and that removed the OFF switch with it: the gate in
  `AgentConnect.resolveTools` is the mere PRESENCE of `capabilities.agentDelegation` — there is no
  `isEnabled` flag — so a legacy "Supervisor" profile, whose config `ProfileMigrator` created,
  injects `call_agent` on every run forever with nothing on screen to say so.

  ⚠️ **Not a toggle — an exit.** The row appears ONLY when the profile already has delegation, and
  turning it off nils the config so the row disappears for good. That returns control to existing
  profiles without re-offering the capability to new ones, which is what the original hide decision
  was about. Reintroducing the toggle outright would have reversed a deliberate engineering call
  (sub-agents share one model, so they queue rather than run in parallel).

  Covered by 10 new tests in `AdvisorySurfacingTests.swift`. Regression-checked: 149 tests across 20
  suites — all green; app scheme builds clean.

- **2026-08-08** — **A30 fixed, and investigating it HALVED the finding.**

  ⚠️ **The workflow half was already covered, and the register did not know it.**
  `WorkflowValidator.validateProfileNode` already reports an unresolvable profile node as a blocking
  `.error` — *"Profile not found — it may have been deleted."* — and `WorkflowExecutor` runs that
  same validation **pre-flight** (step 2c) and throws `WorkflowError.validationFailed` before any
  node executes. So the gate is at the EXECUTOR, not just the canvas UI: a canvas run, a chat run
  and a scheduled workflow run are all blocked identically. The `profileMap` it checks against is
  built from a live `fetchProfiles()` filtered to the layout's IDs, so a deleted profile is simply
  absent — no staleness to defeat it.

  ⚠️ **The node's `profileID` is deliberately NOT cleared.** Clearing it was the obvious repair and
  it is strictly worse: `kind == .profile(id, type)` carries a non-optional UUID, so wiping it
  degrades the node to "nothing selected" and destroys the only record of what it referenced — the
  validator could no longer say which node broke or why. Leaving the dangling ID is what makes the
  error message specific. (Stripping the node outright is worse again: its edges then either dangle,
  silently splitting the graph, or get bridged, inventing a connection the user never drew.)

  **What actually needed fixing was the scheduler.** `fireTask`'s profile guard marked the run
  `.failed` and returned — and the timer fired again on the next schedule, and the next. A nightly
  task failed every night with "Backend profile not found." forever, with nothing stopping it. It
  now routes through `disableTaskWithMissingProfile`, which disables the task, clears `nextRunAt`,
  cancels the armed timer, and writes a summary the user can act on. ⚠️ **Disabled, not deleted**: a
  task is user-authored work — prompt, cron, conversation binding — and deleting it as a side effect
  of deleting a profile is data loss nobody asked for. Disabling is recoverable.

  **And the confirmation now names the cost.** "This action cannot be undone" is true and useless —
  it names no consequence beyond the profile itself. New `ProfileReferenceIndex` enumerates
  scheduled tasks and workflows that point at the profile, and the alert states the outcome per kind
  ("2 scheduled tasks will be stopped… their prompts and schedules are kept"), truncated past five
  so a heavily-referenced profile cannot produce an unreadable dialog. ⚠️ It reads each workflow's
  **layout**, not `WorkflowConfig.agentProfileIDs` — the layout is what the executor runs, while
  `agentProfileIDs` is a parallel list nothing keeps in step, so trusting it would both miss real
  references and invent absent ones. ⚠️ `DownloadRecordSD.profileID` is excluded on purpose: a
  historical record, not a live reference.

  **Left open deliberately:** `WorkflowConfig.agentProfileIDs` still accumulates stale IDs. It feeds
  only a count in the profile-selector popover — cosmetic — and is not worth a blob migration.

  Covered by 9 new tests in `ProfileDeletionCascadeTests.swift`. ⚠️ Four of them pin the
  *pre-existing* validator behaviour rather than new code, because A30's fix now depends on it: if
  "Profile not found" ever downgrades from error to warning, deleting a profile silently breaks
  workflows again and nothing else would catch it. Regression-checked: 193 tests across 14 suites —
  all green.

- **2026-08-08** — **A52, A55, A57, A61 and A62 fixed.** (A56 was already closed on 2026-08-07.)

  **A52.** Rule 5 accepted any `http` scheme, so a profile could point at
  `http://gateway.internal/v1` and the app sent `Authorization: Bearer <key>` unencrypted — readable
  on the path and logged in full by any intermediary that records headers. New
  `EndpointTransportSecurity` classifies it, and the user-facing half is an inline warning under the
  API Endpoint field. ⚠️ **Advisory, never blocking**: `http://localhost:11434` is how Ollama works
  and `http://127.0.0.1:1234/v1` is how LM Studio works, so refusing would break the app's own
  default local setup — the classifier exempts the whole 127/8 block and `::1`. ⚠️ `.local` is
  deliberately NOT loopback: mDNS resolves to a real LAN address and the traffic crosses the network.
  ⚠️ The validator rule is `.advisory`, and advisories still have **no return path to any UI**
  (A34, open) — which is exactly why the fix does not rely on it. The inline warning is the product
  half; the rule is there so the finding is recorded centrally and surfaces for free when A34 lands.

  **A55.** `applyGenerationParams` sent one shape to everything: `max_tokens`, `temperature`,
  `top_p`, plus `reasoning_effort` whenever the picker had been touched. Reasoning models reject
  that combination; normal models reject `reasoning_effort` outright. So the panel's own defaults
  400'd on o-series, and setting Reasoning Effort 400'd everywhere else. New `OpenAIModelFamily`
  gates the whole request shape, and the picker is **hidden** for models that cannot use it
  (the "hide, don't disable" rule from A56). ⚠️ **One rule deliberately inverted from
  `AnthropicModelGeneration`**: an unrecognised id classifies as `.standard`, not as the newest
  family. Anthropic ids come from a first-party `/v1/models`, so unknown means newer; this provider
  also serves LM Studio, vLLM and llama.cpp where an id can be anything, and `.standard` is the
  shape those universally accept. ⚠️ The matcher is anchored and boundary-checked so `orca-2` and
  `olmo-7b` are not swept in by a bare `hasPrefix("o1")`, and a vendor prefix is stripped first or
  every OpenRouter reasoning model would classify as standard.

  **A57.** Seven copies of the same two-clause `guard`, both clauses dropping the user's edit in
  silence. Collapsed into one logged `sync(_:)`. ⚠️ The provider check now runs **before** `encode`,
  which the original did not do — and `encode` has a side effect: it advances
  `loadedBaselines[provider]`. So a mismatched edit used to move the baseline for a write that never
  happened, after which returning the panel to that value read as "unchanged" and was skipped again.
  Discarding is still correct (a profile stores only the active provider's parameters); the defect
  was the silence.

  **A61.** 24 control sites across all five provider panels now carry `accessibilityLabel` and, where
  they have one, `accessibilityValue`. ⚠️ `AdvancedConfigNumericField` gained a **required**
  `accessibilityName` parameter rather than a defaulted one — the compiler immediately found two
  more unlabeled call sites in the MLX panel that a default would have hidden, and a new caller now
  cannot add an unlabeled field by omission.

  **A62.** Every guide helper took a `String`, and a `String` reaches `Text` two ways that both lose
  localization: `Text(someString)` binds to the non-localizing `StringProtocol` overload, and
  `Text(LocalizedStringKey(someString))` builds the key at RUNTIME, invisible to the extractor. The
  helpers now take `LocalizedStringKey`, so the call-site literals become extractable keys. ⚠️
  Markdown still renders — `Text` parses it from a `LocalizedStringKey`, which is why the old code
  reached for that type in the first place. `iterations` stays a `String`: it is a numeral
  interpolated into a literal, and the literal is the key.

  Covered by 19 new tests in `EndpointAndReasoningGatingTests.swift`. ⚠️ Most of them pin FALSE
  POSITIVES, because that is where both classifiers do damage: warning on `http://localhost` would
  fire on the app's own defaults, and a name lookalike classified as reasoning would be sent a shape
  it rejects. A61/A62 are declarative view attributes with no unit-testable seam; verified by
  re-scanning every control site for a label. Regression-checked: 201 tests across 20 suites — all
  green.

  ⚠️ One thing the tests taught: `ProfileValidator` only evaluates provider details in **strict**
  mode, and `BackendProfileStore` passes `strict: isUpdate`. So Rule 5b fires on every save of a
  configured profile but never at creation — correct, since a profile has no endpoint yet at
  creation, and now asserted so the placement is not misread as a miss.

- **2026-08-08** — **A37, A41 and A44 fixed — the silent-model-rewrite family, closed at the root.**

  **A37.** The Ollama picker's auto-select read
  `if !fetchedNames.contains(selectedModel) || selectedModel.isEmpty`, so a saved model the daemon
  no longer listed was replaced with a different one — on `.onAppear`, i.e. by opening the profile
  to change something unrelated. `ollama rm` on one model, or a daemon that had not finished
  starting, was enough to repoint a profile at another model with no notice and no undo.

  ⚠️ **This rule had now been broken and re-fixed four times in one file** — OpenRouter (G95), the
  cloud pickers (MP-01), and this — because each picker owned its own copy of it. Rather than fix a
  third copy, the rule is extracted to `ModelSelectionPolicy` and **all four pickers route through
  it**, the OpenAI-compatible one included: it already preserved the value correctly but said
  nothing, so "my model vanished from the list" had no explanation. The policy's contract is one
  sentence — *only a genuinely EMPTY selection is ever filled* — and it treats an empty fetch as the
  least safe moment to invalidate a saved model, since that means the daemon is down.

  **A41.** The `seedUserPreferences` flag guarding Extended Thinking was being bypassed, and the
  reason is worth keeping: assigning `selectedModel` inside the fetch fires
  `.onChange(of: selectedModel)` → `handleSelectionChange` → a *second*
  `updateCapabilityLevel(seedUserPreferences: true)`. So whenever the auto-select ran, the carefully
  computed flag was irrelevant — the preference had already been re-seeded by the re-entrant path,
  which is precisely the G98 defect the flag exists to prevent. Fixing A37 removes most of the
  trigger, but an empty-selection fill still writes and still re-enters, so the fetch now records
  the value it wrote and `handleSelectionChange` recognises its own write.

  ⚠️ Recorded as a **VALUE token, not a boolean flag** set and cleared around the write. `.onChange`
  runs on the NEXT update pass, so such a flag is always back to false by the time the handler reads
  it — exactly how `ProviderAdvancedConfigManager.isLoading` was a no-op for its entire life
  (register A9). The token is cleared when the change actually arrives.

  **A44.** `MLXModelPickerView` wrapped its post-`await` work in `DispatchQueue.main.async`. Both
  callers were already on the MainActor, so the hop bought nothing and cost the two things that
  matter: the work escaped the `.task`'s cancellation scope, and it ran where no `Task.isCancelled`
  check could reach it — so a slow first-run scan wrote model identity and metadata into an editor
  the user had already left. Now direct MainActor writes with cancellation honoured. The file also
  had **no logger at all** while writing seven profile fields; it has one now. ⚠️ Its rewrite of an
  uninstalled model is **kept**, unlike A37's: `isInstalled` is a local disk check and an MLX model
  that is not on disk genuinely cannot run — there is no "daemon still starting" or "hand-typed
  name" case to preserve. It is no longer silent, which was the actual defect.

  Covered by 8 new tests in `ModelSelectionPolicyTests.swift`, which now cover **all four pickers at
  once** — the point of the extraction. The load-bearing one sweeps saved × list × candidate and
  fails if any combination produces a `.fill` over a non-empty selection. Regression-checked: 173
  tests across 21 suites — all green.

- **2026-08-07** — **All 7 P3 findings fixed (A70–A76).** Three of them were the same failure as the
  P2 clusters above — a value restated in a second place, then drifting from the first.

  **A70.** Error Recovery and Loop Safety labelled their caps `Auto (3)`, but `Auto` for the parse,
  tool-failure and repetition tiers resolves to the profile's own legacy `retryPolicy.maxRetries` —
  3 only for a profile that never set one. A migrated profile carrying `maxRetries: 5` was told its
  cap was 3 while the run used 5. Both sections now read
  `ResolvedResiliencePolicy.autoDefault(legacy:)`, the same value the resolver reads, threaded from
  the agent config. ⚠️ The denial cap's `Auto (2)` was **correct** — it is deliberately not coupled
  to the legacy knob — but its literal was restated in the UI, so it now reads the named
  `defaultMaxConsecutiveDenials` constant that the resolver uses.

  **A71.** `SimplePromptWindowManager` had no `NSWindowDelegate`, so a red-button close never
  reached `closeWindow()`. With `isReleasedWhenClosed = false`, `window` kept pointing at a dead
  `NSWindow` — which retains its `NSHostingView`, the text binding and the `ThemeManager`. Worse,
  the next open found a non-nil but invisible window, fell through to the create path and abandoned
  the old one: a leak per red-button close. Now an `NSObject` with `windowWillClose` releasing on
  every close path, plus the lifecycle logging the file had none of. The orphan branch is kept as a
  loud `logger.error` — if it ever fires, the delegate has stopped working and the leak is back.

  **A75.** Two halves, one file. The `contextWindow` readout — the thing that tells you a system
  prompt is eating the window — had **no caller passing it**, so it never rendered; the bot editor
  now passes `modelMetadata?.contextWindow`. And ⚠️ **the register's "no callers" framing for the
  title was wrong in an instructive way**: `updateTitle` *does* have a caller — `CreateScheduledTaskView`
  wires it correctly on `.onChange`. `BotConfigDetailView` simply never did. The fix removes the
  call site that can be forgotten: `botName` became a `Binding`, and the hosted view drives the
  title from its own re-render. ⚠️ A plain `String` could not have worked — the editor lives in an
  `NSHostingView` whose root view is built once, so an `.onChange` on a captured `String` can never
  fire. That was caught by reasoning about it, not by the compiler.

  **A72.** `checkChanges`/`saveChanges`/`commitChanges` captured `self`. The view is a struct, so
  that is a value copy — but the copy carries `manager`, a class reference, so the manager owned a
  closure that owned the manager. ⚠️ It has **not** been leaking: `windowWillClose` nils all four
  callbacks. That is a rescue, not a design — and A71, in the sibling manager, is that exact
  assumption already having failed once. Each closure now captures the state BINDINGS it needs
  (which reference the `@State` storage box, never the view) plus a weak manager. ⚠️ `commitChanges`
  had the same defect and is not named in the finding — it was added after the audit.

  **A73** widens the Gemini temperature slider to the API's real `0.0...2.0` (the OpenAI panel
  already used that range for the same parameter) and says so in the caption. **A76** persists
  `trimmedName`: every check around the save — duplicate detection, the disabled state, the
  validator's emptiness and length rules — already worked on the trimmed string, so " Research "
  passed the duplicate check against "Research", saved as a separate row, and the warning never
  fired again for either. **A74** removes the guide's "Parallel Subtasks" row, which instructed the
  user to change a control that no longer exists. ⚠️ Removed rather than reworded — the list
  documents CONTROLS — and the stored field is **still read by `PlanningCapability`**, which is A67
  and is *not* fixed by this; a source comment says to restore the row if A67 restores the toggle.

  Covered by 11 new tests across `AutoDefaultLabelTests.swift` and `ProfileNameTrimmingTests.swift`.
  ⚠️ The load-bearing one asserts the label and the resolver agree for every legacy-backed cap
  across a range of values — a second hardcoded literal is what A70 was. A71/A72/A73/A74/A75 are
  AppKit lifetime and view wiring with no unit-testable seam; verified by inspection.
  Regression-checked: 184 tests across 17 suites — all green.

  ⚠️ **Pre-existing failure found, NOT introduced and NOT fixed here**: `TransportRetrierTests` is
  7-of-10 red at HEAD. `TransportRetrier.swift:91` deliberately nils `drainPenalty` for a cloud 429
  ("avoid the 429 double-drain" — `CloudRequestPipeline` already drained), and the tests still
  assert the old contract. Both files are unmodified; the only change in that directory is the two
  added members on `ResolvedResiliencePolicy`. Stale tests, not a source regression — spun out
  separately.

- **2026-08-07** — **A65 fixed.** The knowledge-source icon was
  `source.exists ? warningColor : errorColor`, so a file that is perfectly FINE was drawn in the
  warning colour and sat one shade from "this file is missing". Both read as alarm states, and on
  the icon the colour was the only thing separating them. A present file now takes `accentColor`
  and a plain `doc.text.fill`; a missing one keeps `errorColor` and gains
  `exclamationmark.triangle.fill`. ⚠️ **The symbol change is the substance of the fix, not polish**:
  it makes the two states distinguishable without perceiving colour at all, which matters here
  beyond taste — the same panel is the subject of A61 (every control unlabeled to VoiceOver), and
  colour-only status is the same defect class. The row also gained a spoken accessibility label,
  since the missing-file case otherwise reached VoiceOver as a filename and a loose "File not found"
  with nothing tying them together.

  ⚠️ Fixed by EXTRACTING `KnowledgeSourceRow` rather than patching both call sites: the agent and
  bot editors held byte-identical copies of this row and had **already drifted** — the bot's used a
  hardcoded `.orange` where the agent's used `theme.warningColor`, so the two panels rendered the
  same state in two different oranges. That is the third instance of this exact duplication in the
  cluster (cf. A28's exits, A60's importer loop, A32's send path).

  Covered by 5 tests in `KnowledgeSourceRowTests.swift`. ⚠️ `iconName(forExistingFile:)` is exposed
  precisely so "the two states differ by more than colour" is an ASSERTION rather than a comment — a
  SwiftUI body is unreachable from a test, and that property regresses silently the moment someone
  tidies two symbol names back into one. Regression-checked: 86 tests across 12 suites — all green.

- **2026-08-07** — **A40, A59 and A60 fixed — the file-import cluster.** All three were the same
  omission: an outcome the code did not model, so the UI could not report it.

  **A60 / A40 (failure handling).** All three `.fileImporter` handlers in the app — skills,
  agent knowledge, bot knowledge — were written `if case .success(let urls) = result` and dropped
  `.failure` on the floor. A permission denial, an ejected volume, or an iCloud placeholder that
  fails to materialise looked *exactly* like pressing Cancel: the sheet closed and nothing happened.

  ⚠️ **The reason this had not been fixed is the trap in the middle: SwiftUI reports user
  cancellation as a `.failure` too.** The naive repair — surface every `.failure` — puts a red
  banner on screen every time somebody backs out of the picker, which is worse than the silence it
  replaces. New `Interfaces/Shared/Components/FileImportOutcome.swift` splits the result into
  `.selected` / `.cancelled` / `.failed`, checked on the underlying `NSError` domain **and** code
  rather than by casting to `CocoaError` — a failed cast there fails OPEN, reporting a cancellation
  as a hard error, which is the exact false alarm being avoided. An empty `.success` is folded into
  `.cancelled` so the `isEmpty` check cannot be forgotten at one of the three sites.

  The two knowledge importers were byte-identical copies of the same loop in two files, so they were
  wrong in the same way twice; they now share `KnowledgeSourceImport.apply`. Both also dropped
  duplicate files silently — not an error (re-picking an attached file is reasonable), but selecting
  three files and watching the list grow by one needs a word, so the skipped names are reported.

  **A40 (duplicate skills).** `handleSkillFolderSelection` filtered out manifests whose name was
  already loaded, silently. Skills are addressed by name, so two folders offering `code-review` is
  ordinary — and the user got no indication which copy won, or that a choice had been made; the
  import simply appeared to load fewer skills than the folder contained. Added
  `SkipReason.duplicateName(keptFrom:)` so rejections ride the **existing** `skipped` list, which
  the UI already renders in its disclosure group and counts in its "N skipped" label — no new
  surface needed. Duplicate *folders* (previously a bare `continue`) are counted and reported too.

  **A59.** "Remove All" nil'd `skillConfig` on the first click, discarding every folder *and* every
  per-skill enable/disable decision, with the profile-wide Revert — which also throws away every
  other unsaved edit — as the only recovery. Now behind a confirmation that states what is actually
  lost: the folder count, the skill count, and specifically the enable/disable choices, since that
  is the part users do not expect to lose. It also says the folders are not deleted from disk, and
  the action logs what it dropped.

  Covered by 15 new tests in `FileImportOutcomeTests.swift`. ⚠️ Most of them exist to pin the
  cancellation boundary, because getting it wrong is invisible in review and obvious to a user:
  `CocoaError(.userCancelled)`, the same thing as a raw `NSError`, an empty success, a permission
  denial, a non-Cocoa `URLError`, and the near-miss that would break it — code 3072 in a *different*
  domain, which must still be a failure. Regression-checked: 121 tests across 18 suites — all green.

- **2026-08-07** — **A28, A29 and A64 fixed — the unsaved-work cluster.** All three were the same
  shape: an exit that ran without asking, so work the user had typed disappeared with no prompt and
  nothing to return to.

  **A28.** The three detail views are each hosted two ways — routed, and as a sheet inside the
  workflow canvas — and were wired `onBack: onCancel ?? handleBackTap`. In the sheet that put the
  xmark straight through to `dismiss()`, so it never consulted `editBuffer.isDirty` while the
  identical view, routed, prompted correctly. ⚠️ The root cause was in the guard, not the views:
  `UnsavedChangesBackGuardModifier` hardcoded `router.goBack()` as its Discard action, which is
  meaningless in a sheet — so the guard *could not* have dismissed it, and wiring around it was the
  only way to make the sheet close at all. Parameterising the exit (`onLeave:`) lets both hosts
  share one guard. Each view now has a single `leaveEditor()` called by both the button and the
  guard. ⚠️ A sheet also has exits the view does not own — Esc, click-away, drag-dismiss — each of
  which destroyed the local buffer; `interactiveDismissDisabled(localBuffer.isDirty)` closes them,
  leaving exactly one way out of a dirty editor and it is the one that prompts.

  **A29.** `applicationShouldTerminate` went straight into async teardown, so ⌘Q with a dirty editor
  discarded the work silently and — against the project logging standard — left no line to find it
  by afterwards. It now prompts Save / Discard / Cancel *before* any teardown, since after
  `.terminateLater` the app is going away. ⚠️ Gated on `hasUnsavedEditorChanges`, never
  `editBuffer?.isDirty` — a workflow canvas keeps its dirt in `WorkflowCanvasState`, so the buffer
  check alone reports "clean" for a canvas full of unsaved nodes. ⚠️ **A failed save CANCELS the
  quit** rather than proceeding: quitting after the user explicitly asked to keep the work would
  destroy it anyway, with only a toast that no longer has a window to appear in. That arm is
  reachable in ordinary use — `ProfileValidator` rejects an over-length name, and the agent
  editor's "system instructions are required" pre-flight lives in the VIEW (A35), so a save routed
  from the quit path never runs it. ⚠️ `NSAlert.runModal()` is correct here and wrong in
  `onDisappear`: this is an AppKit delegate callback, not a SwiftUI update pass. AppDelegate reaches
  the editor through a new `configureTerminationGuard(profileService:)`, injected beside the
  QuickAccess graph; until it runs quit is **not** gated, which is logged rather than assumed.

  **A64.** `handleContinue` called `onContinue(newProfile)` and then `dismiss()` unconditionally, so
  a create refused by the validator surfaced as a toast over a sheet that had already gone — taking
  the name and type with it, with nothing to correct and no way back but to retype it and guess.
  `onContinue` is now `throws`, the sheet dismisses only on success, and the reason renders inline
  under the name field (cleared on the next keystroke, since a stale rejection under a field being
  actively fixed reads as "still wrong"). ⚠️ The sidebar's handler deliberately no longer catches:
  swallowing the error into a toast is precisely the behaviour that made the refusal unrecoverable.

  Covered by 6 new tests in `RejectedProfileCreationTests.swift`. ⚠️ These assert the refusal is
  REAL and its message worth showing — the register's own 150-character scenario, the inclusive
  boundary at 100, and that `ProfileStoreError.validationFailed` forwards the validator's message
  instead of flattening it to "Validation failed." A catch arm for an error that never fires, or one
  that renders an empty string, would leave the sheet no better off than the toast it replaced.
  A28's and A29's exits are view/AppKit wiring with no unit-testable seam; `hasUnsavedEditorChanges`
  — the condition A29 turns on — is already covered by `EditBufferRebaseTests`. Regression-checked:
  159 tests across 16 suites — all green.

- **2026-08-07** — **A31 and A32 fixed. Both were one class of bug — a second implementation of
  something that already existed, drifting from the first — so both fixes delete the duplicate
  rather than patching it.**

  **A31.** `DuplicateProfileSheet` built its copy by calling `BackendProfileSnapshot`'s memberwise
  init with four arguments. Every parameter of that init has a default, so omitting the fifth
  compiled cleanly and produced a copy with `fileContextStrategy == nil`. Replaced with
  `BackendProfileSnapshot.duplicated(as:)`, which copies the whole value and re-stamps only
  identity (`id`, `displayName`, `lastSelected`) — so a property added to the struct later is
  carried instead of dropped. ⚠️ `id` had to become `var` for that; it is documented as
  immutable-everywhere-else, since it is the key the store saves and deletes by.

  ⚠️ **The register's failure scenario was backwards and is corrected here.** It read "a
  `.stateless` agent's copy silently attaches file **content** instead". The opposite is true:
  `FileContextStrategy.defaultStrategy(for: .agent)` **is** `.stateless` (changed 2026-07-25), so a
  dropped override resolves back to `.stateless` and a `.stateless` agent's copy behaves
  identically. The profile that actually changed behaviour is an agent explicitly set to
  **`.directInjection`**, whose copy silently switched to handing the model file PATHS where the
  original handed it file CONTENT. Narrower than filed, and the impact is agent-only: every other
  profile type has a single entry in `availableStrategies`, so `resolve` returns the same answer
  whether the override survived or not — the stored value was still being lost, it just could not
  be observed at send time.

  **A32.** Enter and the send button each implemented the send action, and had drifted. Enter
  intercepted an unselected or deleted profile by opening the backend picker; the button's
  `guard let config = … else { logger.error(…); return }` did nothing a user could see. Since
  `sendButtonDisabled` only checks `selectedProfileID != nil`, deleting the selected profile from
  the sidebar left the button **enabled** over a dangling id — so clicking send read as a dead
  button, while the composer went on displaying the deleted profile's name from a stale
  `selectedProfile` snapshot. Both entry points now route through one `attemptSend`. ⚠️ The file
  already carried this exact lesson at `isVoiceBusy` ("two independently-computed gates and they
  had drifted... One property so they can't diverge again") — that was applied to the GATE and not
  to the ACTION.

  Making the button behave meant knowing *why* resolution failed, so `BackendConfiguration` gained
  `resolveRequestConfig() -> Result<_, BackendConfigUnavailability>`. ⚠️ The old `try?` collapsed
  three conditions into one nil and one log line reading "Profile ID is nil or profile not found in
  store" — but a store THROW and a missing row are opposites: one means the profile is gone, the
  other means we could not look. Acting on the wrong one discards a valid selection over a
  transient fault. Only `.profileDeleted` clears the composer's selection (and says so in a toast);
  `.storeUnavailable` keeps it and invites a retry. Every arm leaves the typed message in the
  composer. `getRequestConfig()` survives as a thin wrapper so the five other callers that only
  need "config or nothing" are untouched.

  Covered by 14 new tests — `ProfileDuplicationTests.swift` (8) and `SendRefusalTests.swift` (6,
  one an explicit `XCTSkip` documenting that the `.storeUnavailable` arm is unreachable while
  `BackendProfileStore.shared` is container-backed in the test process). ⚠️ The duplication suite's
  last test reflects over every stored property and asserts a duplicate differs from its source in
  the three identity fields and nothing else, so a future property dropped the same way fails and
  is named — the guard outlives the file. **Verified failing-first**: reverting `duplicated(as:)`
  to the pre-fix field list turns 4 of the 8 red, including the reflection guard. Regression-checked:
  202 tests across 20 suites — all green.

- **2026-08-07** — **The log-visibility cluster fixed: A45–A50 and A68 — plus one behavioural P1 the
  sweep turned up (MP-01).** Every fix follows the project standard: bracket tag, correlating
  identifier, and the CONSEQUENCE spelled out, so the failure is diagnosable from the log alone.

  `BackendProfileStore`'s four fail-open paths (A45) are do/catch instead of `guard let … else
  { return [] }` / `try?`, and each names what the silence costs: `unreadableProfiles()` answering
  `[]` on a fetch failure means the corruption banner disappears while the corruption remains.
  `loadProfiles()` (A47) records `lastLoadError`, and the sidebar branches on it — a fetch failure
  at launch now renders "Couldn't Load Profiles" with a Retry button and the explicit reassurance
  that nothing was deleted, instead of the first-run empty state whose primary action was *create a
  new profile*. ⚠️ The two cases are genuinely different and the log line distinguishes them by
  count: at `init` there is no prior list to keep, so the sidebar empties; a later failure keeps
  what is in memory, which may now be stale. `decodeConfig` (A48) takes a `context:` and logs the
  profile, the target type, the keys actually stored, and that the whole panel falls back to
  defaults over the user's saved settings.

  A49 was closed by **deleting** `getAdvancedConfig`, not by fixing it. It had zero callers and its
  `switch` used `default:` rather than exhaustive cases, so `.mlx` silently returned an **Ollama**
  parameter set — a bug the compiler could never flag. Reviving a second source of truth for
  advanced config is exactly how the panel and the executor drifted apart in A24/A25; the live path
  is `ProviderAdvancedConfigManager.load(from:using:defaultProfile:)`. Its 70-line sibling
  `logProfileSelection` (A50) was the opposite call — it answers precisely the questions support
  asks, so it was given a caller (`activateEditBuffer`, once per profile activation) rather than
  deleted. ⚠️ Deliberately NOT on the send path: it is a multi-line dump and a send happens per
  message. Its body was split into `profileSelectionSummary(profileID:)` so the content is
  assertable — nothing had ever looked at what it produced, which is how it stayed dead.

  A46 finishes the model-picker arm started with Ollama: the three cloud pickers and the
  OpenAI-compatible picker log the endpoint, the underlying error, and the consequence (the user
  must type the model id by hand). `CloudModelPickerView` needed an explicit `endpointDescription`
  because the wrappers bake `baseURL` into the `fetchClosure` — the view cannot otherwise say
  *which* endpoint failed. A68 gives all three detail views a logger and a
  `[PROFILE] Save FAILED for '<name>' (<id>, <kind>)` line before the toast, naming the
  consequence: the edit buffer stays dirty and the persisted profile is unchanged.

  **MP-01 — found while fixing A46, and it is a behavioural defect, not a logging one.** The
  success path of `CloudModelPickerView.fetchModels` silently reassigned `selectedModel` to
  `fetchedModels.first` whenever the saved id was absent from the fetched list. This is the same
  G95 silent-model-rewrite that OpenRouter had already been fixed for **in this very file** — and
  Anthropic and OpenAI pass `fetchOnAppear: true`, so it fired on plain profile open: reading a
  profile could change which model it used. Now only a genuinely EMPTY selection is filled in; an
  unrecognised id is left exactly as set and logged, because it may be newly released,
  region-limited, or hand-entered. (The OpenAI-compatible picker was checked in the same pass and
  already preserved the saved value.)

  Covered by 10 new tests in `DevgenticTests/Core/Persistence/ProfileLoadDiagnosticsTests.swift`:
  four proving a failed load is distinguishable from an empty store (and that a later failure does
  not empty the sidebar), six on the dump's content — including that the API key is **masked**,
  since this dump lands in every support bundle the user sends. Regression-checked: 189 further
  tests across `BackendProfileServiceTests`, `BackendProfileServiceRebaseTests`,
  `BackendProfileStoreTests`, `ProfileBlobHardeningTests`, `UnreadableStateSurfacingTests`,
  `ProviderKeyStorageTests`, `ProfileEditBufferTests`, `ProfileEditBufferRebaseTests`,
  `AdvancedConfigCodableTests`, `AdvancedConfigLoadGuardTests`, `GeminiSafetySettingsTests`,
  `UnconfiguredAdvancedDefaultsTests`, `DiscardUnreadableRefusalTests`, `ProfileDeleteFailureTests`,
  `ProfileDetailsKeyAccessorTests`, `OllamaStoreFailureSurfacingTests`, plus the Anthropic and
  skills suites — all green.

- **2026-08-07** — **A56 fixed.** The ImageGen Quality picker is now gated on
  `provider == .openAI || provider == .mlx`, matching how Steps/Guidance are already gated on
  `.mlx`. ⚠️ Verified by CONSUMPTION, not intent: those two are the only services that reference
  `options.quality` (`OpenAIImageGenService` sends it as the `quality` body parameter,
  `MLXImageGenService` selects a different Flux2 pipeline from it). `GeminiImageGenService` and
  `OllamaImageGenService` accept `options` and read no field of it at all.
  ⚠️ Gated rather than MAPPED, deliberately. The register offered mapping quality onto Gemini or
  Ollama as an alternative, but neither API documents an equivalent knob and Ollama image-gen is
  aspirational in this codebase — a control that does the WRONG thing is not an improvement on one
  that does nothing.
  ⚠️ Hidden rather than disabled: a greyed-out control still implies the value is stored and
  honoured somewhere, and here it is neither. Replaced with a one-line note.
  Two tests added to `AdvancedConfigCodableTests.swift` (17 total): one asserting a stored `.hd`
  still decodes for a provider that ignores it (hiding the control does not remove the value from
  existing blobs), and one **consumption guard** that greps the four provider sources and fails if
  a non-reader starts reading `options.quality` without being added to `providerHonoursQuality` —
  so the UI gate cannot silently drift from the services it describes.
  Regression-checked: 109 tests across the ImageGen and blob suites — all green.

- **2026-08-07** — **A69 fixed, and it was not just a missing suite.** Added
  `DevgenticTests/Core/Persistence/AdvancedConfigCodableTests.swift` (15 tests) covering all six
  persisted `AdvanceConfig` structs: round-trip identity, empty-object decode, partial blobs,
  unknown keys, legacy wrong-typed values, per-field fidelity, and encoding through
  `AdvancedConfigEncoder`. ⚠️ **Written to assert the desired behaviour first, so it failed before
  it passed** — 6 failures across 4 distinct defects, all in the two structs that had no tolerant
  decoder:
  1. `MLXAdvancedConfig` hard-`decode`d four of its five fields → any blob missing one threw.
  2. `ImageGenAdvancedConfig` had NO custom decoder → a blob missing `quality` threw.
  3. `ImageGenAdvancedConfig` threw on an unrecognised `ImageQuality` raw value (a blob from a
     newer build that added a tier).
  4. Both therefore threw on a blob carrying only unknown keys.
  ⚠️ Each of those costs the user their ENTIRE advanced panel, not one field: a throw becomes nil
  in `decodeConfig` and then `?? .default()` in the load path, and the panel then presents those
  defaults as the user's own settings. Both decoders now fall back per field via `try?`.
  ⚠️ Deliberately did NOT copy the sibling structs' `bool ? 1.0 : 0.0` coercion into
  `MLXAdvancedConfig` — a temperature of 1.0 invented from a `true` is a worse answer than the
  tuned default and just as silent; the per-field `try?` absorbs a wrong type either way.
  ⚠️ The hazard was not hypothetical: `repetitionContextSize` was already grandfathered into that
  decoder, which is proof the struct gains fields over time — the next one added would have
  reintroduced the same total-loss failure.
  Regression-checked: 163 tests across the blob and advanced-config surface (2 skipped) — all green.

- **2026-08-07** — **A16, A17, A18 fixed — the credential-at-rest cluster, and the last of the P1s.**
  **A16:** cloud API keys move to the Keychain via a new `Core/Persistence/ProviderKeyStore.swift`,
  keyed on profile id. ⚠️ The strip/inject pair lives at the `BackendProfileSD` seam, NOT in
  `ProviderConfig.encode(to:)` — `ProviderConfig` is a value type with no idea which profile owns
  it, so a Keychain round-trip inside its `Codable` conformance has nothing to key on; the SD model
  does know the id. `ProviderConfig` therefore stays fully round-trippable, which matters because
  it is also encoded into in-memory snapshots that legitimately carry the key.
  ⚠️ The key is written to the Keychain BEFORE it is stripped, and stripped only if that write
  succeeded — the reverse order would destroy the credential on a Keychain failure. ⚠️ Injection
  happens in `primeDecodeState()` so the Keychain is read once per decode and cached; `details` is
  read on nearly every render. ⚠️ Fixing the write path alone would leave every existing key in the
  blob forever (a profile the user never edits again is never rewritten), so
  `migrateAPIKeysToKeychain()` runs at `configureContainer` — deliberately NOT via `saveProfile`,
  which stamps `lastSelected` and would reorder the whole "recently used" sidebar as a side effect
  of a security fix. Keys are deleted with their profile.
  **A17:** the key moves to the `x-goog-api-key` header in `GeminiService` and both
  `GeminiImageGenService` sites, with `cachePolicy = .reloadIgnoringLocalCacheData` on the
  authenticated listing call. ⚠️ A **fourth** site outside the audited scope —
  `WebSearchService.swift:35` — has the same defect; its key stays in the query string (Custom
  Search's documented auth) but the cache policy now stops the URL reaching disk. Flagged rather
  than changed unverified.
  **A18:** `baseURL` threaded through all four cloud services (defaulted, never hardcoded) and
  their pickers, plus `OpenRouterService.verifyKey` so the key check and the catalog fetch cannot
  hit different hosts. `configuredBaseURL` returns nil rather than a fallback so each service
  applies its own `ProviderDefaults` value.
  Covered by 12 new tests in `DevgenticTests/Core/Persistence/ProviderKeyStorageTests.swift`,
  including the legacy-blob path and Keychain-wins-over-stale-inline. Regression-checked: 167 tests
  across the persistence seam (2 skipped) and 93 across all seven clusters — all green.

- **2026-08-07** — **A10, A13, A14, A15 fixed** (the silent-failure cluster — each failed by looking
  like nothing had happened).
  **A10:** `OllamaModelPickerView` now holds a `fetchTask`, cancels before starting, debounces the
  `baseURL` path by 500 ms, cancels on `.onDisappear`, and carries a monotonic `fetchGeneration`.
  ⚠️ Cancellation ALONE is insufficient — a task can be cancelled after its network call returns but
  before it hops to the main actor, so a superseded response is discarded by generation check, not
  by `Task.isCancelled`. Matches the three sibling pickers in the same file, which already did all
  of this. The catch also now logs the underlying error (partially closing A46's Ollama arm): a TLS
  failure, a proxy 403, a decode error and a down daemon used to be indistinguishable to the user
  AND absent from the log.
  **A13:** the view model tracks `service.isRemovingModel` / `modelRemoveError` and the store view
  renders a dismissible banner. ⚠️ `modelRemoveError` had **zero readers app-wide** while
  `removeModel` wrote a reason into it on five guard arms, and `downloadErrorMessage` had exactly
  two references — its declaration and its assignment. Confirming "Delete Model?" on the active
  model did nothing, silently. `deleteModel` now reads the outcome back and logs it with
  `[DOWNLOAD]`.
  **A14:** `try?` → `do/catch` with a toast, and `returnToChat()` is now conditional on success —
  a failed delete previously left the row in place AND yanked the user out of the profile.
  **A15:** all refusal arms in `discardUnreadableConfiguration` log with `[PERSISTENCE]` + the
  consequence, and the caller shows a toast. ⚠️ The benign arm (the blob became readable between
  the alert and the tap) is logged at `notice`, not `error`, and the toast is deliberately worded
  "could not" rather than naming a cause — the caller cannot distinguish the arms from a `Bool`,
  and the log carries the distinction.
  Covered by 10 new tests in `DevgenticTests/Core/Persistence/FailureSurfacingTests.swift`.
  ⚠️ One test assumption was wrong and corrected: `BackendProfileStore.shared` IS container-backed
  in the test process, so the unconfigured-container arm is not reachable from a test that does not
  un-configure a singleton other suites depend on; it is covered by inspection instead.
  Regression-checked: 78 tests across the picker/store/profile suites and 77 across all six
  clusters — all green.

- **2026-08-07** — **A7, A8, A26, A27 fixed** (silently-dropped limits + two dead controls).
  **A7:** the executor handoff now matches `.agent` and `.code` in one exhaustive `switch`.
  ⚠️ The original was `if case .agent … else`, and that catch-all silently absorbed `.code` when the
  case was added — so `CodeSessionManager`'s persisted 300 s bound was discarded and a Code run had
  no wall-clock limit at all. The resolved timeout (or its absence) is now logged with
  `[EXEC_LIMITS]` + the conversation id.
  **A8:** both cap sites (`PlanningCapability`, `PlanGeneratorStrategy`) log a `[PLANNING]` warning
  naming generated-vs-kept-vs-dropped counts. An 8-step task at the default cap of 5 no longer
  reports completion on three steps it never attempted without a trace.
  **A26:** the `.alert` was simply never attached — `showingDeleteAlert` had two references in the
  file, its declaration and the assignment. Added, mirroring `BotConfigDetailView`.
  **A27:** `AdvancedPromptWindowManager` gains `closeWindowCommittingChanges()`, used by the
  navigation teardown. ⚠️ `NSWindow.close()` does not consult `windowShouldClose(_:)`, so the
  Unsaved Changes prompt never ran and a 3,000-character prompt died on a back-chevron click.
  Committing rather than prompting is deliberate: `onDisappear` runs inside a SwiftUI update, where
  `NSAlert.runModal()` would spin a nested modal loop. The footer's "Changes sync automatically"
  claim was false for this editor and is now accurate.
  ⚠️ **Scope note:** `BotConfigDetailView` was deliberately NOT changed — its editor is
  `SimplePromptWindowManager`, which pushes every keystroke back to the binding, so it has nothing
  pending to lose. An initial edit there was reverted once that was verified.
  **A58 (adjacent, P2):** all three detail views now `router.returnToChat()` after a successful
  delete, so the Delete button being *made to work* does not land the user on "Profile Not Found".
  Covered by 10 new tests in `DevgenticTests/Core/Backends/ExecutionLimitDeliveryTests.swift`,
  including a case-coverage assertion that fails if a new `ProfileDetails` case is added without a
  timeout decision. Regression-checked: 139 tests across the planning/executor/profile suites and
  95 across all five clusters — all green.

- **2026-08-07** — **A9, A19, A24, A25 fixed** (the "panel says X, request does Y" cluster).
  **A9:** `ProviderAdvancedConfigManager.isLoading` replaced with a per-provider `loadedBaselines`
  value comparison. ⚠️ The boolean could never work — `load` set and cleared it inside one MainActor
  turn while SwiftUI runs `.onChange` on the *next* pass, so the write-back it existed to suppress
  fired on every profile open (phantom Save pill), and switching from a custom profile to one whose
  blob failed to decode overwrote the second profile's config with `.default()`. A baseline is
  compared, not raced, so it survives the deferral.
  **A19:** Gemini `safetySettings` now reach the request. ⚠️ They are a TOP-LEVEL sibling of
  `generationConfig`, not a field inside it — which is why the omission looked like completeness.
  All five builders route through one `applyGenerationSettings(to:)`; the app's "Default" option
  (`HARM_BLOCK_THRESHOLD_UNSPECIFIED`) is omitted rather than pinned.
  **A24/A25:** an unconfigured profile now runs the preset its panel displays, resolved at the
  `AgentConnect.initializeModel` seam — the same shape as the existing `[num_ctx auto-default]`
  block, and chosen over seeding on panel-open precisely because that would re-create A9's phantom
  dirty state. ⚠️ `isBotFlow` picks the ladder: `OllamaAdvancedConfig.default()` is the AGENT preset
  (temperature 0.1, **fixed seed 42**), so a Bot given it returns a byte-identical reply to every
  repeated prompt. `defaultProfile` is also now threaded into `ProviderAdvancedConfigManager.load`
  (6 call sites) so the panel shows the right ladder too.
  New `Core/Backends/AdvancedConfigEncoder.swift` is the single struct→options encoder shared by the
  panel and the executor — duplicating it would have put two drifting encoders on either side of the
  contract that drifted in the first place. Gemini's builders were extracted behind shared
  body-builders + a no-logic test seam, matching `ClaudeLLMProvider`.
  Covered by 17 new tests in `DevgenticTests/Core/Backends/AdvancedConfigDeliveryTests.swift`.
  Regression-checked: 97 tests across the provider/profile suites and 120 across all four clusters —
  all green.

- **2026-08-07** — **F3 shipped: A11, A12 fixed.** ⚠️ Both defects were PERMANENT from the user's
  side, so a corrected write site was not sufficient on its own.
  **A11:** `rescanSkillFolders` now RETAINS a folder whose scan throws and carries its last-known
  manifests forward (attributed via `SkillManifest.folderPath`, prefix-matched with a trailing
  separator so `/skills` cannot claim `/skills_backup`), surfacing the failure in the existing
  banner and logging it with `[SKILLS]` + the retained count. A transient failure — unmounted
  volume, renamed directory, lapsed permission — is no longer a delete that the next Save makes
  permanent.
  **A12:** the auto-added `execute_shell` now uses `ToolSource.builtInSourceID`. ⚠️ The old literal
  `"00000000-SKIL-AUTO-SHEL-000000000000"` is not valid hex, so `?? UUID()` fired on 100% of calls
  — never write `X ?? UUID()` for a compile-time-constant identity. Because affected profiles carry
  an entry no UI can remove, **`ProfileSchemaVersion.v7` + `migrateToV7`** repairs stored blobs:
  it rewrites orphaned `execute_shell` sourceIds and COLLAPSES the duplicate that a user-ticked row
  would otherwise collide with, letting the built-in-sourced record's `requiresConfirmation` /
  `isEnabled` win (that one records a deliberate Tool Library choice; the auto-added copy records
  only that an import ran), and defaulting a missing confirmation flag to `true`. This is the
  ladder's only DATA-repair step, deliberately — noted at the step so the "shape changes only"
  invariant is not read as having been broken by accident.
  Covered by 12 new tests in `DevgenticTests/Core/Persistence/SkillFolderResilienceTests.swift`.
  Regression-checked: 128 tests across the blob and skills layers, plus 60 across the F1/F2 suites —
  all green. ⚠️ Also fixed one PRE-EXISTING red test found by that gate:
  `SkillsIntegrationTests.testDecode_agentConfigWithoutSkillConfig_nilSkills` hard-coded
  `"apiProvider": "ollama"`, but `ApiProvider` is a display-string enum whose rawValue is
  `"Ollama (Local)"` — the fixture now derives it. Unrelated to this cluster; it had been failing
  since that enum gained display rawValues.

- **2026-08-07** — **F1 shipped: A1–A6 fixed as one change.** Root cause was one missing operation:
  several surfaces persist ONE facet of a profile while a detail editor is open on it, and none
  re-baselined the buffer. Added `ProfileEditBuffer.rebase(onto:)` — re-points `original` at what
  was actually written while leaving `draft` untouched — plus `BackendProfileService`
  `rebaseEditBuffer(to:)`, called after every out-of-band save (Tool Library ×2, workflow canvas).
  ⚠️ `markSaved()` would have been WRONG at those sites: it declares the whole draft saved and
  would swallow the user's other pending edits; `load()` would destroy them outright. `Revert` now
  restores what is on disk instead of a superseded snapshot.
  `activateEditBuffer` reads through to the store (A2) so an auto-healed thinking flag or a
  backfilled context window is not reverted by the next unrelated save, and clears the buffer on an
  unknown id instead of leaving the previous one live. The capability chips re-read the row and
  apply only the capability delta (A3), refusing to write when the profile was deleted rather than
  resurrecting it. `BackendProfileService` now owns a `canvasEditGuard` and exposes
  `hasUnsavedEditorChanges`; the profile editor passes that guard into its `WorkflowCanvasView` and
  the sidebar consults it (A4), so a dirty canvas prompts — with Discard actually invoking the
  canvas's discard hook, and a Save option when a canvas is what is dirty. `WorkflowDedicatedView`'s
  profile binding is keyed on ID, resolved per access (A6). Covered by 12 new tests in
  `DevgenticTests/Core/Persistence/EditBufferRebaseTests.swift`. Regression-checked: 95 tests across
  `BackendProfileServiceTests`, `ProfileEditBufferTests`, `BlobWriteRefusalTests`,
  `ProfileBlobDowngradeTests`, `ProfileBlobHardeningTests`, `BackendProfileStoreTests` — all green,
  plus the 22 Anthropic tests from F2.

- **2026-08-07** — **F2 shipped: A20–A23 fixed as one change.** New `Core/Backends/AnthropicModelGeneration.swift`
  classifies a model id into the request contract it accepts (`adaptive` / `adaptiveWithSampling` /
  `legacyBudget`), and `ClaudeLLMProvider` now emits per-generation shapes:
  `anthropic-version` pinned to `2023-06-01`; `{"type":"adaptive"}` + `output_config.effort` where
  `budget_tokens` was removed, `budget_tokens` retained where it still works; sampling parameters
  gated on the model, on thinking, and on the temperature/top_p mutual exclusion; thinking applied
  by **all five** request builders instead of only the cognitive step. `AnthropicAdvancedConfig`
  gains `thinkingEffort` (tolerantly decoded — pre-existing profiles have no such key), and the
  Advanced panel swaps the budget stepper for an effort picker and hides sampling controls the
  selected model rejects. Covered by 22 new offline tests in
  `DevgenticTests/Core/Backends/AnthropicRequestShapeTests.swift`, asserting against the *shipped*
  body builders via a no-logic test seam. Two adjacent corrections made in the same change:
  the streaming decoder no longer emits `thinking_delta` into the visible reply (that branch was
  unreachable until thinking reached the streaming builder, and would have spliced reasoning into
  bot answers), and the cognitive-step builders opt into `display: "summarized"` so the agent's
  `thought` field is not blank on adaptive models. Regression-checked: 98 tests across
  `BackendProfileStoreTests`, `ProfileBlobHardeningTests`, `ProviderConfigSwitchProviderTests`,
  `ProfileValidatorTests`, `ProfileValidationSeverityTests`, `SynthesisOptInTests` — all green.

- **2026-08-07** — Created. Eight-dimension audit, 89 raw → 74 merged findings, 6 adversarially
  verified (2 confirmed, 2 narrowed, 1 refuted, 1 narrowed-and-confirmed). Anthropic API claims
  (A20/A21/A23) verified against the current Anthropic API reference, not from memory.

---

## Part D — Follow-up audit of the fixes (2026-08-08)

**Scope.** The 69 rows marked ✅ in Part A. The 7 open P2s (A39, A42, A43, A51, A53, A54, A63) were
out of scope and are not re-reported. Method: eight independent read-only reviews across the axes
Part C nominated (provider request shapes, credentials, signature reach, product halves,
concurrency/lifetime, tests, deliberate narrowings, wrong premises), then hand-verification of the
highest-severity findings against source. `xcodebuild build -scheme devgentic` is **green** at the
time of writing. Rows carry a **Verdict**: **WRONG** (the fix does the wrong thing), **INCOMPLETE**
(right idea, missed a case), **UNTESTED** (behaviour is correct, nothing pins it), **WEAK** (a test
passes without proving its claim).

**Verdict on the pass as a whole: the work largely holds, and the failures cluster.** The
persistence layer, the edit-buffer rebase family (A1–A6), the file-import cluster (A40/A59/A60), the
advanced-config baseline rewrite (A9/A57), `ModelSelectionPolicy` (A37) and the two register
*corrections* (A31, A75 — both re-derived independently, A75 against git history) are sound. Three
failure shapes account for nearly everything below:

1. **A model taxonomy written from memory, twice.** `AnthropicModelGeneration` and
   `OpenAIModelFamily` were the fix for exactly this defect class (A20 was a plausible-looking value
   that does not exist), and both reintroduce it — Anthropic by emitting a thinking shape two named
   models reject, OpenAI by matching a naming convention its vendor has since moved past.
2. **The fix stops at the register row's boundary rather than the defect's.** A74 removed one stale
   guide row and left the subsection below it documenting the capability A66 withdrew in the same
   pass; A37's extraction closed four pickers and left a fifth; A71 fixed one window manager and
   left its sibling; A75 fixed the bot editor and left the agent one; A30's confirmation landed on
   the one delete path out of four the user is least likely to use.
3. **A guard that reads one source of truth when there are three.** A29 gates quit on
   `editBuffer.isDirty || canvas` and misses the floating prompt editor's `@State`; A16's write path
   is careful about failure and its read path has no failure mode at all.

### P1 (7)

| # | Finding | File:line | Failure scenario | Undermines | Verdict |
|---|---|---|---|---|---|
| B1 ✅ | ~~**Claude Fable 5 and Mythos 5 are sent `thinking: {"type":"disabled"}`, which those models reject with a 400 — at any effort.**~~ **FIXED 2026-08-08** `classify` maps `fable`/`mythos` to `.adaptive` by name; `applyThinking` emits an explicit disable for that whole tier when Extended Thinking is off. Verified against the current Anthropic contract: on Fable 5 / Mythos 5 thinking is **always on** and the parameter must be **omitted**; `{"type":"disabled"}` is accepted only on Opus 4.8/4.7/5 and Sonnet 5. The comment at :177-181 reasons correctly about Opus 5 and Sonnet 5 and never considers the two models the classifier singles out one file over | `Core/Backends/AnthropicModelGeneration.swift:108`; `Core/Backends/ClaudeLLMProvider.swift:176-183` | `extendedThinking` defaults to **false** (`ClaudeLLMProvider.swift:62-65`) and A24's own fix leaves `advancedConfiguration` nil until the user edits something — so a Fable 5 profile 400s on **every** request from **all five** builders, before the user touches a setting. Model ids come from the live `/v1/models` fetch, so no hardcoded list gates reachability. This is A20's defect class (a plausible value the API rejects) reintroduced by A20's fix | A20–A23 | **WRONG** |
| B2 | **A Keychain *read* failure is indistinguishable from "no key stored", and the next save destroys the credential.** `retrieve` returns nil for every non-success `OSStatus` — it distinguishes `errSecItemNotFound` only for the log line. `primeDecodeState`'s `ProviderKeyStore.load(for:) ?? outcome.details.providerAPIKey` is nil for any migrated row, so `details` decodes keyless; the store then assigns `existing.details = snapshot.details` unconditionally → the setter calls `save(nil)` → `delete(for:)`. The write path's careful write-before-strip has no counterpart on read | `Interfaces/Shared/ChatInput/SecureKeyStorage.swift:80-85`; `Core/Persistence/SwiftData/BackendProfileSD.swift:135-137`; `Interfaces/Main/Views/BackendProfile/BackendProfileStore.swift:479` | Locked keychain, or a denied ACL prompt after a re-sign / Sparkle update → `errSecAuthFailed` → nil. **No user action is required to trigger the save**: `MLXContextWindowHealer.swift:70`, `CapabilityToolbarButtons.swift:112` and `ToolLibraryContainerView.swift:366,461` all re-save opportunistically. One transient read failure becomes permanent credential destruction, and the user sees an empty API Key field that reads as "never configured" | A16 | **WRONG** |
| B3 ✅ | ~~**The quit guard cannot see the floating Advanced prompt editor.**~~ **FIXED 2026-08-08** `hasUnsavedEditorChanges` is `editBuffer?.isDirty \|\| canvasEditGuard.hasUnsavedChanges` — two sources. `AdvancedPromptEditorView` holds typing in `@State localText` and writes back only via an explicit commit, making it a third. The guard exits at `guard … else { return .proceed }` with **no log**. The comment immediately above shows the author reasoning explicitly about the canvas being a second source and missing the third | `Interfaces/Main/Views/BackendProfile/BackendProfileService.swift:46-48`; `AppDelegate.swift:264`; `.../AdvancedPromptEditor.swift:283` | Open an Agent → Expand → type a 2,000-character system prompt → ⌘Q. Buffer is clean, canvas is clean, quit proceeds silently and the text is gone. This is verbatim the loss A29's own doc comment says it exists to prevent, and the same session fixed A27 — a 3,000-character prompt dying on a back-chevron click — in that exact editor. The bot's Simple editor is safe only because it pushes every keystroke back | A29 (and A27) | **INCOMPLETE** |
| B4 | **Anthropic thinking blocks are never replayed on the native tool loop.** `generateCognitiveStep` captures thinking as text only and never reads `signature`; `ModernCognitiveStep` has no field for it; `ClaudeToolTurnAdapter.assistantTurn` emits only `text` + `tool_use` blocks. The replayed assistant turn is structurally incapable of carrying a thinking block back, and Anthropic requires them returned unchanged when thinking is on and the turn contains `tool_use` | `Core/Backends/ClaudeLLMProvider.swift:472-473, 560-561`; `.../TextGen/AgentModel.swift:127`; `.../ReAct/Generation/Adapters/ClaudeToolTurnAdapter.swift:15-39` | Anthropic Agent profile, Extended Thinking ON, model calls a tool. Iteration 1 succeeds; iteration 2 sends the assistant turn with the thinking block missing and the agent dies on its first tool call. Pre-existing, but A22 **widened it onto the critical path**: thinking now reaches all five builders and actually functions on current models for the first time, so the whole agent path is exposed rather than one dead branch | A22 | **INCOMPLETE** |
| B5 | **The streaming path has no truncation detection at all.** `stop_reason` is inspected at four sites in `ClaudeLLMProvider`, all in non-streaming builders; there are **zero** occurrences after line 590. The SSE decode handles `message_start` / `message_delta` / `content_block_delta` / `message_stop` / `error` and never reads `stop_reason` | `Core/Backends/ClaudeLLMProvider.swift:611-666`; `SSEStreamParser.swift` (no hits) | Bot profile, Opus 5, thinking ON, `maxTokens` at its 4096 default. On the adaptive tier `max_tokens` caps thinking **and** text together, and `thinking_delta` is deliberately not emitted (:643-651) — so no `text_delta` ever arrives. The user gets a **completely empty reply**: no error, no toast, and nothing in the log. Not field-debuggable, against the project standard | A22 | **INCOMPLETE** |
| B6 | **Every GPT-5 point release classifies `.standard`.** `id == "gpt-5" \|\| id.hasPrefix("gpt-5-")` cannot match a dotted id — `gpt-5.1`, `gpt-5.2`, `gpt-5.6`, `gpt-5.1-codex` and siblings all fall through. The code fact is certain; the claim that these are OpenAI's current frontier ids was verified by the auditing pass against vendor documentation and is **sourced, not first-hand** — confirm before acting | `Core/Backends/OpenAIModelFamily.swift:50` | A profile on such a model sends `max_tokens` (reasoning models require `max_completion_tokens`) and a non-default `temperature` → 400 on every send, and the Reasoning Effort picker is hidden on exactly the models that need it. Reachable: the picker filter is `contains("gpt")`, so these ids are offered. The deliberate unknown→`.standard` inversion is defensible for third-party endpoints but is doing double duty as the fallback for **first-party** ids the matcher does not know, and there it is the wrong default | A55 | **WRONG** |
| B7 | **`AdvancedPromptWindowManager` still carries the A71 defect, and the consequence is worse than in the sibling that was fixed.** Its window-reuse test is `isVisible` (false when miniaturized), the fall-through has **no orphan branch and no log** — it simply overwrites `self.window` — every window it creates gets `delegate = self`, and `windowWillClose` ignores `notification.object` | `Interfaces/Main/Views/BackendProfile/AdvancedPromptEditor.swift:43, 69, 82-84, 152-161` | Minimize the floating Advanced editor (`.miniaturizable` is in the styleMask) → click Expand → the old window is abandoned while still holding the manager as delegate. Closing the orphan nils `window` **and all four callbacks belonging to the live window**: the live window's Save prompt goes dead, and `closeWindowCommittingChanges()` calls a nil `commitChanges` — **the typed prompt is silently discarded**, with one `NSWindow` + `NSHostingView` stranded per cycle, unbounded | A71 / A72 | **WRONG** |

### P2 (18)

| # | Finding | File:line | Failure scenario | Undermines | Verdict |
|---|---|---|---|---|---|
| B8 | `gpt-5-chat-*` (the non-reasoning chat variants) classify `.reasoning` — the inverse of B6 | `Core/Backends/OpenAIModelFamily.swift:50` | Picker is shown; setting Reasoning Effort → 400 for a non-reasoning model, and temperature/top_p are silently dropped on a model that accepts them. Sourced claim, same caveat as B6 | A55 | **WRONG** |
| B9 | `o1-mini` / `o1-preview` classify `.reasoning`, but reject `reasoning_effort`. The enum conflates three independent capabilities behind one bit — those models need `max_completion_tokens` (right) but not the effort parameter (wrong), and the test pins the wrong answer | `Core/Backends/OpenAIModelFamily.swift:46`; `EndpointAndReasoningGatingTests.swift:150` | The picker lists `o1-mini`; setting Reasoning Effort 400s every send | A55 | **WRONG** |
| B10 | **A30's "the confirmation now names the cost" reached one of four delete entry points.** `ProfileReferenceIndex` is called only from the sidebar alert; the three detail-view trash buttons still present the pre-fix sentence | `ProfileSidebarListView.swift:216-222` vs `AgentConfigDetailView.swift:815`, `BotConfigDetailView.swift:333`, `ImageGenConfigDetailView.swift:289` | User has the agent open, clicks the trash in the island bar, reads "This action cannot be undone", deletes — the nightly scheduled task bound to it is never mentioned. A26's own register note observes that the sidebar hover-trash "is not discoverable from the screen they are on", so the fix landed on the least-used path | A30 | **INCOMPLETE** |
| B11 | **The scheduler half of A30 makes the mistake A32 was fixed to stop making, in the same pass.** `(try? BackendProfileStore.shared.fetchProfiles())?.first(where:)` collapses "the store threw" and "the row is gone" into one nil — A32's changelog calls those "opposites… Acting on the wrong one discards a valid selection over a transient fault." The comment on `disableTaskWithMissingProfile` acknowledges the conflation and calls it deliberate; the user-visible string does not hedge | `Core/Service/Scheduler/SchedulerService.swift:328-331`, message at `:165-166` | A transient read failure permanently disables the task — `isEnabled = false`, `status = .failed`, `nextRunAt = nil`, timer cancelled — and writes "Stopped: the backend profile this task used was **deleted**." The sentence is false and sends the user looking for a deletion that never happened | A30 | **WRONG** |
| B12 | **Two Esc presses still destroy a dirty editor, and the comment claiming otherwise is false.** The Revert pill carries `keyboardShortcut: .cancelAction` and calls `editBuffer.revert()` with no confirmation. Esc #1 reverts silently, clearing `isDirty`; Esc #2 then passes `interactiveDismissDisabled(false)` and closes the sheet | `AgentConfigDetailView.swift:882-891` (twins at `BotConfigDetailView.swift:399`, `ImageGenConfigDetailView.swift:455`); comment at `WorkflowProfileEditorView.swift:57-60` | The comment reads "Closing those leaves exactly one way out of a dirty editor, and it is the one that prompts." `interactiveDismissDisabled` closes click-away and drag-dismiss; it does not close Esc, because Esc was never the sheet's dismissal here — it was already bound to Revert | A28 | **WRONG** |
| B13 | **A44's premise — that `isInstalled` cannot be transiently false — is contradicted by the repo's own log messages two files away.** `isInstalled` is a pure disk check, but the picker's only protection is an **all-empty** guard, and three in-source paths make a model absent from a **non-empty** list: `MLXModelsLocation:83` falls back to the default directory when the bookmark is "on an unmounted volume"; `:94` does the same on a TCC failure (and `setModelsDirectory` explicitly does not move models, so the default tree stays populated); `scanDisk:402` deliberately hides a model with incomplete shards mid-re-download, `:411` hides a duplicate id | `MLXModelPickerView.swift:137, 143, 174`; `MLXModelService.swift:207-209, 402, 411`; `MLXModelsLocation.swift:83, 94` | Identical to A37's scenario: the binding is `$providerConfig.modelName`, i.e. the edit-buffer draft, so the rewrite persists on the next save — including A29's quit-time Save prompt. "Unmounted volume" is the exact analogue of "daemon still starting" that A37's rule exists to preserve | A44 | **WRONG** |
| B14 | **A35's own filed scenario is still literally true, and the advisory has no reachable surface.** `requirePresence: true` is passed from exactly two arms (bot-strict, agent-strict) and `strict = isUpdate` — so **creation takes the lenient arm and produces no finding at all**. Meanwhile the two editors that could generate the advisory hard-block before calling save, and every out-of-band writer discards the returned array | `ProfileValidator.swift:110, 115, 305-312`; `ProfileSidebarListView.swift:190`; `AgentConfigDetailView.swift:906-909`; `BotConfigDetailView.swift:418-421` | "An Agent created from the + button persists with `instructions == nil` and is never caught" — A35's filed scenario — still holds. The stated *reason* for advisory-not-blocking is sound (`disableThinkingOnProfile` really does route through `saveProfile` on an existing row and would have been refused), but "recorded and surfaced by A34's banner" is true about recording and false about surfacing | A35 | **INCOMPLETE** |
| B15 | **A74 removed one stale guide row and left the subsection below it documenting the capability A66 withdrew in the same pass.** Thirty lines under the removed row, the guide still teaches "Agent Delegation" as an enableable capability with "sub-agents **that you define**" and "Multiple delegations in one turn run in parallel" | `AgentConfigGuideView.swift:106-115` (the surviving comment is at `:76-85`) | A66 removed that toggle, `AgentDelegationConfig` has no sub-agent list to define, and the parallel claim directly contradicts A66's own row text ("sub-agents share one model, so they queue rather than run in parallel"). A74's exact defect, unfixed, in the same file. The `:76-85` comment is also now stale — it asserts A67 "is NOT fixed by this", and A67 closed the next day | A74 / A66 | **INCOMPLETE** |
| B16 | **The advisory is dropped precisely where it is most relevant.** `ProfileValidator` emits "Selected model does not support tool calling" for local providers, and the two surfaces that *edit tools* discard the returned array with no banner of their own | `ProfileValidator.swift:136-142`; discarded at `ToolLibraryContainerView.swift:366, 461` and `CapabilityToolbarButtons.swift:112` | User opens the Tool Library on an Ollama/MLX agent whose model has no tool capability and enables ten tools. Every save recomputes the advisory saying those tools will not work, and every save throws it away. The banner A34 built is on the screen the user is not on | A34 | **INCOMPLETE** |
| B17 | **The banner can render and still be invisible, and it lies after a failed save.** It is the first child of a long `ScrollView` with no `ScrollViewReader`, while Save is pinned in the island bar; and `saveAdvisories` is assigned only in the `do` branch — never cleared in `catch`, on `revert()`, or on the instructions pre-flight bail-out | `AgentConfigDetailView.swift:329` vs `:911-937`; twins at `BotConfigDetailView.swift:164/428`, `ImageGenConfigDetailView.swift:144/473` | Editing Advanced Configuration at the bottom of an 800-line form, ⌘↩ → a green "Profile saved" toast that mentions nothing, advisory several screens above. Then edit the name to 200 chars → Save throws → error toast fires while the banner still reads "Saved — one thing worth knowing" about a write that did not happen | A34 | **INCOMPLETE** |
| B18 | **A75's defect is still live on the agent side.** `showEditor(agentName:)` still takes a plain `String`, and no view calls `AdvancedPromptWindowManager.updateTitle(agentName:)` — its only caller is the scheduler | `AgentConfigDetailView.swift:498-500`; `AdvancedPromptEditor.swift:35-39, 118` | Open the agent's Expand editor, rename the agent in the main window: the floating window keeps advertising the old name. Byte-for-byte the bug A75 fixed for bots, in the sibling file | A75 | **INCOMPLETE** |
| B19 | **`ProviderKeyStore.save(nil)` can never report failure.** The nil branch calls the `Void`-returning `delete(for:)` and hardcodes `return true`; `delete` swallows its `OSStatus`. The one log line that fires states the *deleteProfile* consequence ("an orphaned credential remains after the profile was removed") for a call path whose real consequence is resurrection | `Core/Persistence/ProviderKeyStore.swift:46-49` vs `:71-80` | User clears a revoked key, saves, sees it gone. The delete failed; `primeDecodeState` re-injects the revoked key on the next read and it is sent on every request. One message serving two callers with opposite meanings | A16 | **WRONG** |
| B20 | **A second cloud credential is still written to `UserDefaults` in cleartext** — the web-search key, distinct from A53's `gemini_api_key`, untouched by the A16 sweep | `SettingsCoordinator.swift:119`, read back `:69` | `defaults read <bundle-id> webSearchAPIKey` returns the live key from `~/Library/Preferences/`; swept into every backup and outliving every profile. Same exposure class A16 was raised to close | A16 | **INCOMPLETE** |
| B21 | **A18 was not closed for image generation.** Both `GeminiImageGenService` request builders hardcode `ProviderDefaults.geminiBaseURL`. The A17 fix edited these exact two methods (adding the header) and left the host | `GeminiImageGenService.swift:36, 99`; contrast `OpenAIImageGenService.swift:22-31` | An imageGen profile with API Endpoint set to a corporate gateway sends its gateway-scoped key to `generativelanguage.googleapis.com` on every generation — the precise A18 harm, in the one cloud path the fix skipped | A18 | **INCOMPLETE** |
| B22 | **The cloud picker transmits the key before the user reaches the endpoint field.** `CloudModelPickerView` refetches only `.onChange(of: apiKey)` — `baseURL` is baked into a non-`Equatable` `fetchClosure`, so changing the endpoint never retriggers — and `remoteFields` renders the API Key field **above** the endpoint field | `ModelPickerView.swift:52-62`; field order `ProviderConfigSection.swift:218-241` | Natural top-to-bottom configuration: paste gateway key → debounce fires with `configuredBaseURL == nil` → falls back to `ProviderDefaults` → the gateway-scoped key is sent to `api.anthropic.com`. The "Rule 5 blocks it" reasoning is about *save*; this fetch runs pre-save | A18 | **INCOMPLETE** |
| B23 | **A47's error state is unreachable once a first load has succeeded.** The branch is nested inside `if profileService.profiles.isEmpty`, but `loadProfiles()` deliberately keeps the in-memory list on failure | `ProfileSidebarListView.swift:113-136`; `BackendProfileService.swift:74-86` | Store goes unreadable mid-session: `lastLoadError` is set and rendered nowhere, the sidebar shows a stale list as if current, and the user edits and deletes against it. Not sticky (Retry works, success clears) — invisible. `ProfileLoadDiagnosticsTests.swift:92` pins exactly this state and asserts only the service fields | A47 | **INCOMPLETE** |
| B24 | **The reference index cannot tell "no scheduled tasks" from "tasks not loaded".** `scheduledTaskReferences` filters `SchedulerService.shared.scheduledTasks` with no check of `hasLoadedTasks`, which exists and is consulted everywhere else in that class | `ProfileReferenceIndex.swift:57-61`; `SchedulerService.swift:40, 288, 86-92` | `loadAllTasks()` throws at launch, or the delete happens before the bootstrap task completes → every delete confirmation for the session silently reports zero references and falls back to the old wording. The defect A30 was filed for, re-created by the fix's own data source — and the exact "you have none must not render as I couldn't read them" lesson A47 encodes | A30 | **INCOMPLETE** |
| B25 | **The migration sweep's success log counts attempts, not successes.** `migrated += 1` fires unconditionally after the assignment, which succeeds even when `ProviderKeyStore.save` returned `false` and left the key inline | `BackendProfileStore.swift:132-135` vs `:141-145` | Keychain unavailable during a login-item launch → every row keeps its inline key, yet the log asserts "Migrated N key(s) … no longer readable from DevgenticSD.store". The security claim is stated as achieved when it was not. The sweep does correctly retry next launch; the log denies the need | A16 | **WRONG** |

### P3 (11)

| # | Finding | File:line | Failure scenario | Undermines | Verdict |
|---|---|---|---|---|---|
| B26 | **A cross-fix regression neither register row owns.** `logFullConfiguration` decodes *every* provider's `advancedConfiguration` as `MLXAdvancedConfig`. A69 made that decoder fully tolerant, so an Ollama or Gemini blob now always decodes and returns `MLXAdvancedConfig.default()` | `AgentConnect.swift:1517-1522`; `MLXAdvancedConfig.swift:42-50` | The dump prints fabricated MLX defaults labelled "User Override (temp: 0.1, …)" for a profile whose real settings differ. `0.1` is coincidentally the Ollama **agent** preset temperature, so an engineer debugging "is my Bot pinned at 0.1 with seed 42?" reads a confirmation of the exact bug A25 fixed. Before A69, this path threw and printed "None" | A69 × A50 | **WRONG** |
| B27 | **A72's retain cycle was not eliminated; the fix moved the cycle's edge.** The comment asserts each closure captures state bindings, "never the view struct". True for `$localText`/`$initialText`/`$localTools`/`$initialTools`; **false for `$text` and `$configuredTools`**, which are hand-rolled `Binding(get:set:)` values whose escaping closures capture a copy of `AgentConfigDetailView` — including its `@State` manager | `AdvancedPromptEditor.swift:405-407, 413-426`; `AgentConfigDetailView.swift:62, 247-290` | Cycle routes manager → closure → binding → view copy → `State<Manager>` → `StoredLocation` → manager, so `[weak manager]` does not break it. Practically still rescued by `windowWillClose` — which is exactly what A72's row calls "a rescue, not a design" — and under B7's orphan path the rescue does not run and it leaks for real | A72 | **WRONG** |
| B28 | **`output_config.effort` is lost on Opus 4.5, and the comment justifying it is false.** `acceptsEffort` returns false for the whole `.legacyBudget` tier; effort works on Opus 4.5 (`low`/`medium`/`high`) and errors only on Sonnet 4.5 / Haiku 4.5 | `Core/Backends/AnthropicModelGeneration.swift:45-47, 70-77` | The comment reads "the legacy tier spans exactly the models where that is a risk" — it also spans Opus 4.5, where it is not. Lost capability, not a 400: the panel shows the budget stepper instead of the effort picker and the provider never sends effort | A20–A23 | **INCOMPLETE** |
| B29 | **Top P is a permanently inert control once the Anthropic panel is saved.** `default()` sets `temperature: 1.0` (non-nil), the panel's `toNonOptional` can never write nil back, and `applyGenerationParams` sends `top_p` only in the `else` of `if let temp` | `AnthropicAdvancedConfig.swift:60`; `HelperExtension.swift:11-16`; `ClaudeLLMProvider.swift:138-149` | On any sampling-capable model, opening and saving the panel persists `temperature: 1.0`, after which `top_p` can never be sent and there is no affordance to clear temperature. The caption discloses the mutual exclusion but offers no escape | A23 | **INCOMPLETE** |
| B30 | **`parseVersion` breaks on dot-separated version aliases.** `part.count <= 2` rejects `"4.1"`, the scan aborts, and classification falls through to `.adaptive` | `Core/Backends/AnthropicModelGeneration.swift:157` | `claude-opus-4.1`, `claude-sonnet-4.5` and the OpenRouter dot form → `.adaptive`: thinking ON sends `{"type":"adaptive"}` + effort, both rejected by 4.5/4.1 → 400; thinking OFF silently strips sampling from a model that accepts it. Gateway-reachable only — the dashed OpenRouter form classifies correctly | A20–A23 | **INCOMPLETE** |
| B31 | **A third, unanchored copy of the OpenAI taxonomy — and it is the bare-prefix bug the classifier's own header warns about.** The picker filter is `contains("gpt") \|\| hasPrefix("o1") \|\| hasPrefix("o3")`: no `o4`, no boundary | `Core/Service/OpenAIService.swift:65` | `o4-mini` and `codex-mini-latest` never reach the OpenAI picker, making the classifier's `o4` branch dead code for that provider. A saved `o4-mini` survives (`ModelSelectionPolicy` preserves it) but cannot be re-chosen | A55 | **INCOMPLETE** |
| B32 | **A load-bearing comment names an example the code does not exclude.** The header claims the anchored matcher means "a local fine-tune called `o1-distill-qwen-lookalike` do[es] not get swept in" — but `"o1-distill-qwen-lookalike".hasPrefix("o1-")` is `true`. The lookalike test uses `o1llama-fun` (no hyphen), a different case | `Core/Backends/OpenAIModelFamily.swift:44-45`; test at `EndpointAndReasoningGatingTests.swift:176` | An LM Studio fine-tune named `o1-*` gets `max_completion_tokens`, which those servers ignore → the user's output cap silently stops applying. Exactly the false positive the file claims to have closed | A55 | **WRONG** |
| B33 | **The "hide, don't disable" rule (A56) was applied to one OpenAI control out of three.** Temperature and Top P sliders stay live and persist for `.reasoning` models, then are dropped at request time | `AdvanceConfigurationView.swift:818-853` vs the Anthropic panel at `:626`, `:704` | On `o3-mini` the user drags Temperature to 0.2, it persists, the UI shows 0.20, and every request runs at the model default — the decorative knob the file's own comment says it exists to prevent | A55 / A56 | **INCOMPLETE** |
| B34 | **`ModelSelectionPolicy` closed four pickers and left a fifth.** `Flux2ModelPickerView.onAppear` overwrites a **non-empty** selection with `klein4B`, and the same rule is duplicated at `snapToValidFlux2Model`. Both are silent — no logger at all, unlike the MLX exception | `ImageGenConfigDetailView.swift:409-417, 532-536` | Because `modelName` is shared across providers in one ImageGen profile, switching `.openAI → .mlx` silently overwrites a saved `dall-e-3`, with no snap-back on the reverse switch. Lower hazard than A37 (static enum, not a fetch) but the same rule, the fifth copy | A37 | **INCOMPLETE** |
| B35 | **Duplication is copy-by-default only within the snapshot; a workflow's canvas is left behind.** `WorkflowLayoutStore` is keyed by profile id and has `load`/`save`/`delete(for:)` and no copy API | `BackendProfileSD.swift:496-501`; `WorkflowLayoutStore.swift:78, 105, 229`; duplicate offered on every row at `BackendProfileDetailView.swift:284-289` | Duplicate a workflow profile → the copy carries `agentProfileIDs` but opens an **empty** canvas. The first canvas save recomputes `agentProfileIDs` from zero nodes, strict validation then refuses it ("must reference at least one agent profile"), and the catch only logs. The doc's "any property added is carried for free" is true of the struct and false of the profile | A31 | **INCOMPLETE** |
| B36 | **A30's "cosmetic" justification is false, though the decision it supports is right.** `agentProfileIDs` has three readers, not one: the popover count, the **support dump** (which enumerates each dead UUID as if live — the dump A50 gave a caller in this same pass), and `ProfileValidator:157`, a `.blocking` rule gating every profile save | `ProfileValidator.swift:157`; `BackendProfileService.swift:330-333`; `ProfileSelectorPopover.swift:214` | Leaving the field stale is still correct — and better-founded than stated, because *pruning* it would refuse every later save of the emptied workflow. But the reason as written would walk the next fixer straight into that trap | A30 | **PREMISE-FALSE** |

### Test findings (6)

263 cases were added. The persistence and config-blob suites are strong and test shipped code.
Roughly 20 cases prove nothing about shipped behaviour, in three recurring shapes.

| # | Finding | File:line | Failure scenario | Verdict |
|---|---|---|---|---|
| B37 | **`ExecutionTimeoutExtractionTests` is a parallel implementation.** `executionTimeout(for:)` is a private copy of the switch that ships at `AgentConnect.swift:513-519`; its own comment says "Mirrors the extraction" | `ExecutionLimitDeliveryTests.swift:24-31` | Revert `AgentConnect.swift:515` to `if case .agent … else` — re-introduce **A7 exactly** — and all 5 tests stay green. The claimed case-coverage guarantee is true only of the test's own switch. A 3-line `extension ProfileDetails { var executionTimeout }` was the obvious seam | **WEAK** |
| B38 | **`PlanTruncationTests` asserts a third copy of the cap**, mirroring both production sites | `ExecutionLimitDeliveryTests.swift:91-94, 123-129` | Five tests exercise `Array.prefix`; one is a stdlib tautology. Deleting the cap from both production sites leaves the suite green | **WEAK** |
| B39 | **`BackendConfigUnavailability.isTransient` has zero production callers** — the shipped decision switches on cases directly | `SendRefusalTests.swift:58-62`; decl `BackendConfiguration.swift:32-35`; real logic `ChatInputAreaView.swift:730-757` | The test's own claim ("Getting this backwards discards a valid choice over a hiccup") is unguarded: change the `.storeUnavailable` arm to clear the selection and `isTransient` stays correct, the test stays green, and A32's core distinction is dead. A dead diagnostic needs a caller — the lesson A49/A50 already recorded | **WEAK** |
| B40 | **The `.storeUnavailable` `XCTSkip` is convenience, not impossibility.** `BackendProfileStoreProtocol` already exists and is injected by four sibling suites; `resolveRequestConfig` hardcodes `BackendProfileStore.shared` | `SendRefusalTests.swift:80-86`; `BackendConfiguration.swift:62` | A defaulted `store: BackendProfileStoreProtocol = .shared` parameter is a one-line change with zero call-site churn and makes the arm reachable. Combined with B39, neither half of A32's user-visible distinction is guarded | **UNTESTED** |
| B41 | **The reflection guard is weaker than its docstring.** It compares `String(describing:)` per stored property against a fixture that leaves future properties at their memberwise defaults | `ProfileDuplicationTests.swift:106-136`, fixture `:22-31` | It fails correctly today. But "a property added later is covered automatically" is false: a new property left at its default produces the same default in a field-list copy, so the strings match and the guard passes — precisely A31's shape. Fix: non-default value per property, or assert a `Mirror`-derived field count | **WEAK** |
| B42 | **`testTheResultIsDiscardableWithoutCeremony` does not test `@discardableResult`;** `testUnreadableQueriesFailSafelyWithoutAContainer` runs *with* a container | `AdvisorySurfacingTests.swift:88-91`; `FailureSurfacingTests.swift:154-158` | `XCTAssertNoThrow` takes an `@autoclosure`, so the call is an expression, not a statement — it compiles identically with the attribute removed, though ~23 callers depend on it. The second asserts `unreadableProfiles().isEmpty` against the developer's **real** Application Support store, proving nothing about the fail-open path it is named for | **WRONG** |

### What holds up

Reported explicitly so the negatives are on record — each was checked, not assumed.

- **`anthropic-version`.** Exactly two `URLRequest` sites exist for Anthropic (`ClaudeLLMProvider.swift:248-266`, `AnthropicService.swift:34-37`); both set `2023-06-01` unconditionally. A20's header fix is complete.
- **All five Anthropic builders call both helpers**, and the `requestSummary` split is right — only the two builders that parse thinking into `thought` opt in. A22's "all five" claim is accurate.
- **No second, drifting copy of the Anthropic generation rule.** The Advanced panel calls `AnthropicModelGeneration.classify` directly and drives sampling visibility, the stepper/picker swap and the effort ladder from it. The picker does **not** offer `xhigh` to a 4.6 model.
- **Every OpenAI request path was converted.** `chat/completions` is built in one place and all five body builders call `applyGenerationParams`. UI and transport classify the same live `modelName` string, so they cannot disagree with each other.
- **A16's write path is correct**: write-before-strip is real on both sites, a Keychain failure keeps the key inline rather than losing it, and it is logged with the consequence. The seam choice (SD model, not `ProviderConfig.encode`) is right, and no second on-disk writer exists. Delete ordering is correct; a duplicate gets its own working Keychain item; a provider switch orphans nothing; sweep interruption is safe and idempotent; A50's key masking is real and total.
- **A17 is complete** — no `URLQueryItem(name:"key")` remains on any provider path — and **A18 is complete for the four listing services and their pickers** (`verifyKey` and the catalog fetch cannot diverge).
- **A9 / A57 are genuinely well done.** `encode`'s baseline side effect is intentional, the provider check precedes it, `sync(_:)` is `encode`'s only production caller, and baseline staleness is closed on all three axes — `.task`, provider change, and Revert. Profile A cannot suppress profile B's edit, and a test pins it.
- **A34's store/service layer is clean end-to-end and the G92 invariant holds on the new return path** — all three consumers assign to `@State`, none branch. The banner is attached in all three editors, cannot stack, and resets on profile switch.
- **A31's mutable `id` is not exploited**: one write repo-wide, inside `duplicated(as:)`. **A28's `onLeave` is right at every host**, and `interactiveDismissDisabled` is not a one-of-three gap.
- **A67 is right** — two reads of `parallelSubtasks` exist, the gate short-circuits on the constant first, and the single `withTaskGroup` sits inside the dead branch. **A66 is right** — the presence-only gate is confirmed, the change is draft-scoped and Revert-recoverable, and nothing user-authored is destroyed.
- **A30's register correction is fully verified**: `validateProfileNode` emits a blocking `.error`, `WorkflowExecutor` runs it pre-flight and throws before the DAG loop, and every entry point funnels through it.
- **A31's and A75's corrections both re-derive independently** — A75's against git history (`3e8be0a`, two months before the fix), which rules out self-serving revision.
- **A24/A25's load-bearing half is structurally airtight.** `isBotFlow` is not a caller flag but a `let` bound inside `switch profile.details` at both entry points, so a host cannot mis-set it. No host misreports.
- **A44's concurrency fix is correct.** No isolation escape (the view is `@MainActor`, `.task` inherits it), and `Task.isCancelled` is checked after the last await and before every write. **A10's three claims verify**, including the generation guard being compared after the main-actor hop. **A41's token is per-instance and cannot collide** with a model the user was already on. **A29's `configureTerminationGuard` gap is logged, not assumed**, and every branch returns a defensible `TerminateReply`.
- **A52 holds**: the inline warning is in the hierarchy on all three provider arms, recomputed per keystroke, correct for `localhost`/`127.0.0.1`/`[::1]`/uppercase/userinfo, and `.local` is correctly *not* loopback. **A26/A58 hold** in all three detail views. **A64 holds fully.**
- **`AnthropicRequestShapeTests`' "no-logic test seam" is real** — the `debug*` entry points are genuine pass-throughs, not a parallel implementation. The `options.quality` consumption grep resolves via `#filePath` and fails loudly rather than silently. The three fixtures that were given instructions kept their point.
- **Genuinely strong suites**: `AdvancedConfigCodableTests`, `EditBufferRebaseTests`/`BackendProfileServiceRebaseTests`, `FileImportOutcomeTests`, `ModelSelectionPolicyTests`, `AutoDefaultLabelTests`, `AnthropicModelGenerationTests`, `ProfileLoadDiagnosticsTests`, `EndpointTransportSecurityTests`.

### Confidence notes

- **B1, B28, B30** were verified against the current Anthropic API contract via the `claude-api`
  skill, as Part C required — not from memory.
- **B6, B8, B9** rest on OpenAI's *current* model roster, which the auditing pass verified against
  vendor documentation but which is **not** first-hand here. The code facts are certain
  (`hasPrefix("gpt-5-")` cannot match a dotted id; `o1-mini` is classified `.reasoning`); the
  roster claims should be confirmed before the fix is written.
- **B7, B27** are AppKit lifetime findings reached by reading, not by running. Both are reproducible
  by hand in under a minute (minimize the floating editor, re-open it) and should be reproduced
  before being acted on.
- `TransportRetrierTests` remains 7-of-10 red at HEAD and pre-existing; it was excluded throughout
  and is not counted anywhere above.

### Part D changelog

- **2026-08-08 — B1 and B3 fixed.** Both are the shapes Part D names above: a taxonomy tested
  through its most permissive member, and a guard reading fewer sources of truth than exist.

  **B1.** New `AnthropicModelGeneration.adaptiveAlwaysOn` for Fable 5 / Mythos 5, plus an
  `acceptsDisabledThinking` capability. `ClaudeLLMProvider.applyThinking` now only emits
  `{"type": "disabled"}` where the model accepts it and otherwise falls through to adaptive —
  which the API documents as equivalent to omitting the key.

  ⚠️ **A fourth case rather than a special-case in the provider.** The two models differ from the
  rest of the 5 tier in exactly one bit, and that bit is the difference between a working request
  and a 400 on every send. Encoding it in the enum keeps the contract decision in the one file
  whose job is contract decisions, and makes the divergence visible to the panel, which needs the
  same answer.

  ⚠️ **Effort is still sent with the toggle off** — unlike the `disabled` path, which suppresses
  `output_config` because `xhigh`/`max` are rejected alongside it. On an always-on model effort is
  the *only* depth control, so suppressing it would leave the user no way to steer thinking at all.

  ⚠️ **The panel HIDES the Enable Thinking switch for these models** rather than disabling it
  (register A56's rule), replacing it with a note that thinking is always on and pointing at
  Thinking Effort. The provider keeps a `[ANTHROPIC]` log for the case the UI cannot cover: a
  profile configured on another model and then re-pointed, where the stored `false` survives.

  ⚠️ **The test gap was the cause, not a side note.** Every body assertion in
  `AnthropicRequestShapeTests` ran against `claude-opus-5` — the tier member for which `disabled`
  IS legal — so the suite was green on the exact body that 400s. Body tests now run against a
  Fable id specifically, and `testThinkingOffIsSentExplicitlyOnAdaptiveModels` was given a real
  effort value: with `effort: nil` its `XCTAssertNil(body["output_config"])` passed whether or not
  the suppression it claims to pin existed.

  **B3.** `BackendProfileService` gains `commitPendingPromptEdits` + `flushPendingEditorText()`,
  registered by `AgentConfigDetailView` while it is on screen; `applicationShouldTerminate` flushes
  before reading `hasUnsavedEditorChanges`, so the floating editor's text lands in the draft and the
  existing Save / Discard / Cancel prompt fires on it.

  ⚠️ **Flush is a separate call, not a side effect of `hasUnsavedEditorChanges`.** That property is
  read from view bodies; mutating the draft on read would fire inside a SwiftUI update pass.

  ⚠️ **The hook captures `[weak promptWindowManager]`, never `self`.** Capturing the view would
  route a closure the service owns back into the view's `@State` — the retain shape register A72 is
  about, and which B27 finds is still live there. `commitChanges` is nil while no window is open,
  so the hook is a safe no-op and needs no additional guard.

  ⚠️ **Agent editor only, deliberately.** `SimplePromptWindowManager` (bot, scheduler) pushes every
  keystroke back to its binding and has nothing pending to flush. `CreateScheduledTaskView` also
  owns an `AdvancedPromptWindowManager`, but a scheduled task's prompt is not profile-editor work
  and is outside what `hasUnsavedEditorChanges` speaks for.

  Covered by 5 new tests (3 in `AnthropicRequestShapeTests`, 2 in `EditBufferRebaseTests`) plus a
  strengthened existing one. Regression-checked: 96 tests across 15 suites — all green; app and
  test bundle both build clean. `TransportRetrierTests` still 7-of-10 red at HEAD, untouched and
  excluded.

  **Not fixed here:** B2 (Keychain read failure destroying the credential) and B19 are the same
  read-path gap and should ship together; B4/B5 are the remaining Anthropic P1s.

---

## Part E — Re-derivation of the 7 still-open P2s (2026-08-08)

These seven were excluded from Part D and had never been re-derived since filing. Three read-only
streams, then hand-verification of the decision-relevant claims. No source file carries a
`register A39/A42/A43/A51/A53/A54/A63` marker, so none was touched even incidentally by the
remediation pass — the code is as filed.

⚠️ **Six of the seven rows needed correcting. Only A53 held verbatim.** That is the headline: this
register's text has now been found wrong nine times in total, and the pattern is consistent —
the *mechanism* is usually real and the *trigger*, *scope* or *impact* around it is not. Re-derive
before fixing, every time.

| # | What the register says | What the source shows | Severity | Verdict |
|---|---|---|---|---|
| **A39** | MLX panel silently clamps `maxTokens`/`repetitionContextSize`; triggered by "re-pointing a profile at a smaller-context model" | Mechanism real, **trigger misfiled**. `.onChange(of: config.maxTokens)` watches the VALUE, not the cap, so re-pointing the model clamps nothing. It fires on the **next editor open**, when `load()` assigns the stored value against the now-smaller cap. It **discards the value and writes it back to the blob** (`ProviderAdvancedConfigManager.swift:197`), leaving the buffer dirty on mere open; there is no use-time bound to fall back on (`AgentConnect.swift:1229`) | **P2** (confirmed) | **FIX** (small) |
| **A42** | Ollama pull re-filters per NDJSON chunk; "a multi-GB pull degrades the whole app" | Mechanism real, **impact overstated**. 8 `@Observable` writes per fire, not 6. Cost is one filter+sort of the user's *installed* models (typically <30) and is invisible off screen. **The better finding is that the tracked progress fields have zero live readers** — `downloadBanner` is declared and never called, and live progress comes from `DownloadManager` | **P3** (down from P2) | **FIX-NARROWED** — dead-code removal, ~15 lines. Not a throttling exercise |
| **A43** | "Forced, **uncoalescable** recursive disk walk" per keystroke pause | "Forced" true, **"uncoalescable" false** — `searchDebounceTask?.cancel()` + a fresh 500 ms sleep coalesces a burst into one call. Each pause costs one ~25 ms walk that runs **detached, off the MainActor**, and whose result changes nothing on screen (the filtering is client-side either way). The parenthetical about the dead guard is **stale**: the filter branch was fixed. ⚠️ Partly owned by `MLX_Model_Manager_Production_Readiness.md` **A20**, which violates Part A's own "items that doc does not contain" rule | **P3** (down from P2) | **FIX-NARROWED** — one line: skip the scan on a filter-driven refresh. Leave the debounce and `force:` semantics alone; hand the dead flag back to MLX-A20 |
| **A51** | `HFRequest.perform` defeats the documented HF-token injection seam; "a test still hits the real login Keychain" | Code fact true, **framing wrong on two counts**. The direct read is the documented G4 design (one Bearer header for all raw calls). The doc comment it "contradicts" is explicitly scoped to `hub` and is accurate. **No production impact** (both paths read the same store) and **no existing test reaches it** — nothing in `DevgenticTests/` calls any HF fetch method. The one genuine artefact is an over-broad sentence in an `architecture_readme.md` changelog line | **P3** (down from P2) | **DON'T FIX as filed** — correct the two doc claims. Real injection is only worth it when a test needs the transport stubbed anyway |
| **A53** | `GeminiService` writes the raw key to `UserDefaults` on every successful model-list fetch; never read, never cleared | **Correct verbatim — the only row that was.** The write survived the A17 edit *in the same function*. `saveApiKey`/`getApiKey`/`clearApiKey`/`gemini_api_key` have **zero references outside that file**, so it is a pure write with no reader. Profile delete clears only the Keychain. ✅ Not in the diagnostic-bundle allowlist, so the narrowing holds | **P2** (confirmed) | **FIX** (~10 lines) — ⚠️ **deleting the write is not enough**: a one-time launch purge is what actually closes it, or the plaintext key survives on every machine that already validated one |
| **A54** | Gemini's default `topK: 1` forces greedy decoding, silencing temperature and Top P | True, and **worse than filed**. `topK` is live on the wire (`GeminiLLMProvider.swift:82`), and **A24's fix propagated it further**: `AgentConnect.swift:1200` now encodes `GeminiAdvancedConfig.default()` for *unconfigured* profiles, which previously escaped it by accident. ⚠️ A24 is not at fault — it made the request match the panel, exactly as intended; the panel's value is what is wrong. Gemini's own default is 64, and this is the only provider defaulting to 1 | **P2** (top of band) | **FIX** (~10 lines + migration) — default → `nil`, migrate a stored `topK == 1` in the decoder, raise the stepper floor off 1 |
| **A63** | Execution-policy and Conversation-Memory labels are `String` `displayName`s, so "the whole Execution card ships untranslated" | Real but **scope overstated and severity too high**. Verified against the String Catalog: `Conversation Memory` and `Error Recovery` ARE keys; `Abort`, `Skip & Continue`, `Fallback Prompt`, `Best-effort Response`, `Fail Hard`, `Full`, `On-Demand`, `Smart` are all **absent** — 13 strings at 4 sites, not the whole card. ⚠️ **The app ships English only** (`developmentRegion = en`; all 1,910 catalog keys have exactly one localization), so no user can see a mixed-language screen today | **P3** (down from P2) | **FIX, low urgency** (~1h) — and **widen it**: `ExhaustionPolicy`, `FileContextStrategy.displayName`/`.description` and `AddBackendProfileView`'s type descriptions are the same defect, ~14 more strings, same seam, same hour |

### What actually needs fixing

- **Fix properly (3):** **A53** and **A54** are the two with real user consequence — a plaintext
  credential with no clear path, and every Gemini profile running greedy. **A39** is the third: a
  user setting silently overwritten and persisted, with the correct implementation already sitting
  in the Ollama panel 100 lines away.
- **Cheap cleanups (2):** **A42** and **A43** are each a handful of lines and both are really dead
  code, not performance work. Do them opportunistically; neither is worth scheduling.
- **Doc correction (1):** **A51** — two sentences. There is no defect to fix.
- **Latent (1):** **A63** — nothing to see until a second language ships, but it is an hour and it
  gets cheaper to do before the catalog grows.

⚠️ **Both A53 and A54 need a data step, not just a code change** — a `UserDefaults` purge and a
decoder migration respectively. Shipping the code half alone leaves every existing install in the
broken state, which is the same "a corrected write site does not fix data already on disk" lesson
A11/A12 recorded.

### Part E changelog

- **2026-08-08 — A53 and A54 fixed, and fixing A54 uncovered a larger defect (B43).**

  **A53.** `GeminiService` no longer holds `UserDefaults` at all: the write, the `gemini_api_key`
  constant, and the three accessors that had zero callers are gone. New
  `ProviderKeyStore.purgeLegacyPlaintextKeys()` runs at `configureContainer`, beside the blob sweep.

  ⚠️ **The purge is the half that closes the finding.** Deleting the write protects only future
  fetches; every install that ever validated a Gemini key already has the plaintext value in
  `~/Library/Preferences/`, unreachable from any UI and surviving profile deletion. Same lesson as
  the v7 blob repair (A11/A12): a corrected write site does not fix data already on disk.

  ⚠️ **Membership in the purge list is "has no reader", not "looks like a secret".**
  `webSearchAPIKey` is also a cleartext credential in `UserDefaults` and is deliberately NOT
  purged — it has a live reader in `SettingsCoordinator`, so removing it would silently disable web
  search. That distinction is pinned by a test, because it is exactly the kind of thing a later
  addition to the list would get wrong.

  ⚠️ Idempotent and flag-free: it logs only when something was actually removed, so it is safe on
  every launch and does not need a `UserDefaults` migration flag of its own — which would have been
  an odd way to clean up `UserDefaults`.

  **A54.** `GeminiAdvancedConfig.default()` omits `topK`; the decoder repairs a stored `1` to nil;
  the panel's nil-fallback moves from 1 to 40 and shows "Default" when unset; and a warning row
  appears when the user deliberately selects 1.

  ⚠️ **The floor stays at 1 — warn, don't clamp.** Greedy decoding is legitimate if you actually
  want it; what was wrong was arriving there by accident and silently losing two other controls.
  This is the same choice the Ollama panel makes for `num_ctx`, and the opposite of what the MLX
  panel does (register A39, still open).

  ⚠️ **Blind repair of a stored `1` is safe** because the old stepper's floor was 1, so a stored 1
  is indistinguishable from "never touched" — and greedy-by-accident is overwhelmingly likelier
  than greedy-on-purpose. Stated in the decoder rather than left implicit.

  ⚠️ **A24 was not at fault and is not being reverted.** It made the request match the panel, which
  is what it was for; it simply carried a bad default onto the wire for unconfigured profiles that
  had been escaping it by accident. The value was the defect, not the plumbing.

  **B43 (new, P1-class) — `JSONValue.init` classified 0 and 1 as booleans, so provider options
  holding those values were silently dropped from every request.** `JSONSerialization` returns
  `NSNumber` for booleans *and* numerics, and an `NSNumber` holding 0 or 1 bridges to Swift `Bool` —
  so the `as? Bool` branch caught them before the `CFGetTypeID` check written specifically to tell
  the two apart could run. Every provider reads its options with
  `if case .number(let val) = config.options?[...]`, so a `1.0` that arrived as `.bool(true)` failed
  the pattern match and never reached the wire. **Gemini's shipped `topP: 1.0` and Anthropic's
  shipped `temperature: 1.0` were both affected.** Fixed by testing `NSNumber` first.

  ⚠️ **Found by a test written to prove A54's benefit, not by looking for it.** The assertion was
  "the controls topK was silencing must still be sent" — and `topP` came back `.bool(true)`. Without
  this, un-silencing `topK` would have restored nothing, which is worth recording: a fix whose
  stated value depends on a neighbouring value reaching the wire should assert that it does.

  Covered by 9 new tests (3 purge, 3 decode-repair, 3 encoder/JSONValue) plus one existing
  assertion corrected: `AdvancedConfigCodableTests` pinned `gemini.topK == 1` from a legacy Bool and
  now pins the repair. Regression-checked: **203 tests across ~24 suites — all green**, including
  every suite that touches `JSONValue` (tool arguments, MCP, workflow data passing, chat blobs),
  since that type is shared far beyond provider options. App and test bundle both build clean.
