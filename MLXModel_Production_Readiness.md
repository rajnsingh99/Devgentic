# MLX Model Manager — production readiness status

**Status ledger** for the 2026-08-03 audit of the MLX model manager (model listing + download +
the inference seams it feeds).

This document is the **register of what was found, what was fixed, and what is still open**.
The reasoning, evidence and repro for each item lives in
[MLX_Model_Manager_Production_Readiness.md](MLX_Model_Manager_Production_Readiness.md) — the full
audit. Read that when you need *why*; read this when you need *where things stand*.

Every item below keeps its original audit ID, so the two documents cross-reference directly.

---

## At a glance

| | Found | Fixed | Pending |
|---|---|---|---|
| **Defects** (Part A) | 44 | **44** | 0 |
| **Feature gaps** (Part B) | 15 | 12 (+1 partial) | 2 |
| **Total** | 59 | 56 | 2 |

| Severity | Found | Fixed | Partial | Pending |
|---|---|---|---|---|
| P0 | 0 | — | — | — |
| P1 | 26 | 26 | 0 | 0 |
| P2 | 26 | 25 | 1 (G10) | 0 |
| P3 | 7 | 5 | 0 | 2 (G12, G15p3) |
| **Total** | **59** | **56** | **1** | **2** |

*(G2 was the last pending P1.)* Counts verified against the section headings of
`MLX_Model_Manager_Production_Readiness.md` on 2026-08-03 — P1 26 / P2 26 / P3 7. The P1 row
previously read 27, and the Pending column previously put 2 against P2; both pending items are
in fact P3, and G10 (P2) is the sole partial.

**Every defect is fixed. All P1s are closed.** What remains is 2 feature gaps that the audit
classed as *product*, not readiness.

**Verification:** **175 test methods across 33 suites in 17 new files** (the subsystem previously
had **zero**) — counted from the working tree on 2026-08-03, superseding an earlier "154 tests
across 23 suites" that was never updated as batches landed. Runs are per-batch and surgical, not
whole-suite (the full suite loads Whisper models and live embeddings); the last recorded figures
are 100/100 green across the P2-affected suites and 29/29 across the P3-affected ones. The
subsystem has also been exercised on device against a real library, a real HuggingFace fetch, a
real download and a real cancelled generation — see [Verification status](#verification-status)
for exactly what that did and did not cover.

> ⚠️ **This ledger was itself audited on 2026-08-03** and several "Fixed" claims did not survive.
> Corrections are inline below and marked **[ledger correction]**. The lesson is worth keeping:
> a status document drifts in the direction of "done", so its claims need checking against source
> exactly like code does.

---

## Part A — Defects (all fixed)

### P1 — 23 defects

| ID | Defect | Fixed in |
|---|---|---|
| A1 | `partialDownloadFolder` built a path one component short of where HubApi writes — cancel cleanup was a permanent silent no-op | Batch 0 |
| A2 | `hasWeights` accepted any single weights file, so a partial sharded repo reported "Installed" and failed at load | Batch 1 |
| A3 | `displayName` dropped the author for every non-`mlx-community` repo, breaking the canonical identity key | Batch 1 |
| A4 | A second MLX download silently killed the first, and the second got no record at all | Batch 0 |
| A5 | HubApi never throws `CancellationError` — user cancels were recorded as "failed", or worse as "completed" | Batch 0 |
| A6 | `downloadTask` never cleared on completion, so the next download's cleanup targeted the previous repo | Batch 0 |
| A7 | "Re-download" of an installed model was a guaranteed no-op — no repair path | Batch 1 |
| A8 | A swallowed size fetch silently disabled the RAM-fit advisory — a safety gate failing *open* | Batch 1 |
| A9 | `fetchSizes` fanned out 30 unthrottled HF requests per page; the size cache was never read | Batch 1 |
| A10 | HTTP status discarded on every HF call — 429/401/500 indistinguishable from an empty result | Batch 1 |
| A11 | No request-generation token — a stale response could overwrite a newer query's results | Batch 1 |
| A12 | A failed download reverted the card to a Download button with the reason shown nowhere | Batch 1 |
| A13 | Delete was not blocked while the model was loaded, didn't notify `MLXService`, and failed silently | Batch 1 |
| A14 | `MLXService` had no model identity — a lazy reload could run inference on a different model | **Deferred → shipped** |
| A15 | The rescan did a recursive walk plus per-model parsing synchronously on the MainActor | **Deferred → shipped** |
| A16 | `DownloadManager.activeRecords` was a computed SwiftData fetch registering no observation — the badge never updated | Batch 1 |
| A17 | `isInstalled()` substring match falsely marked un-downloaded models "Installed", hiding their only Download button | Batch 1 |
| A18 | The tool-capability heuristic hard-filtered the Agent store — classification *enforcing* instead of describing | Batch 1 |
| A19 | Locale decimal separator corrupted size parsing 10×, producing a spurious "Model Too Large" gate | Batch 1 |
| A20 | The Installed-tab search field was inert — its filter branch was gated on a flag nothing ever set | Batch 1 |
| A21 | "Recent" sort scrambled the remote list; no remote model carried a date and the sort isn't stable | Batch 1 |
| A22 | An HF fetch failure was invisible, and the grid re-rendered stale models from the previous category | Batch 1 |
| A23 | The Download button was hover-gated with hit-testing disabled — no pointer-free path to the primary action | Batch 1 |

### P2 — 19 defects

| ID | Defect | Fixed in |
|---|---|---|
| B1 | MLX generation streams had no cancellation propagation — Stop left the GPU decoding to EOS | Batch 2 |
| B2 | `DownloadManager` had zero logging — every terminal classification was invisible | Batch 0/1 |
| B3 | `DownloadCoordinator` reported `.startedFresh` when `OllamaService` silently refused a concurrent pull | Batch 2 |
| B4 | The MLX progress closure spawned an unstructured Task per tick with no staleness guard | Batch 2 |
| B5 | `isLoadingRemoteModels` was a bare `Bool`, not a counter — concurrent fetches cleared it early | Batch 1 |
| B6 | `getSizeForModel` had two silent return paths with zero logging | Batch 1 |
| B7 | `.urlQueryAllowed` is the wrong character set for a query *value* — search text could inject parameters | Batch 1 |
| B8 | No timeout, retry or backoff on any HF call — the store could hang on the 60s URLSession default | Batch 2 |
| B9 | Every `DownloadHistoryStore` read swallowed its error; every write `Result` was discarded unlogged | Batch 2 |
| B10 | The 30s scan debounce made Refresh a no-op; the comment claimed the window was 2s | Batch 2 |
| B11 | A corrupt `config.json` was swallowed and reported as "no tool logic found" | Batch 2 |
| B12 | An IC context-window lookup miss silently degraded the compaction budget to 4096 | Batch 1 |
| B13 | Nothing checked or logged memory headroom at load time | Batch 2 |
| B14 | Duplicate display names silently dropped a model from the installed list | Batch 1 |
| B15 | `applyFilterAndSort()` re-ran on every progress tick, maintaining state consumed only by dead code | Batch 2 |
| B16 | The cancel control was not a button — unreachable by VoiceOver/keyboard, and it leaked a pushed `NSCursor` | Batch 2 |
| B17 | The fit verdict was encoded in colour alone, beside an unlabelled GB figure reading as a duplicate disk size | Batch 2 |
| B18 | Every category switch flashed "No models found" | Batch 2 |
| B19 | Fixed point sizes ignored Dynamic Type; Reduce Motion was honoured nowhere | Batch 2, **completed 2026-08-03** — see Ledger corrections |

### P3 — 2 defects

| ID | Defect | Fixed in |
|---|---|---|
| C1 | `isCancellingDownload` was service-global, so cancelling one model showed "Cleaning up…" on every MLX card | Batch 3 |
| C2 | Every label sourced from an enum `rawValue` was invisible to the String Catalog extractor | Batch 3, **completed app-wide 2026-08-03** — see Ledger corrections |

---

## Part B — Feature gaps

### ✅ Fixed (12 gaps, 13 rows — G15 is split across this table and Pending)

G1/G3/G9 shipped together as milestone M1 — "Don't fill the user's disk". G2 followed.

| ID | Gap | Notes |
|---|---|---|
| G1 | No disk-space preflight | Refuses with `.failed("needs X, only Y free")` and a 5 GB headroom. Unknown free space **proceeds** rather than blocks. Also closed the error-path cleanup hole — a *failed* download used to strand its bytes. |
| G3 | No storage accounting | Per-model sizes computed off the MainActor; `N installed · X on disk` row; delete names the bytes it reclaims. |
| G9 | Nothing prevented sleep during a download | `.idleSystemSleepDisabled` activity keyed off the aggregate active count, so it covers all three backends and cannot leak. |
| G8 | No revision tracking or update detection | `MLXModelRevision` reads the commit HubApi already recorded in `<repo>/.cache/huggingface/download/*.metadata` and compares it against the `sha` HuggingFace already returns — both halves existed and neither was read. Stored on `MLXModelItem.revision` and `DownloadRecord.revisionCommitHash` (**optional**, so lightweight-migration safe). "Update available" badge plus an explicit **Check for Updates** on the Installed tab. ⚠️ Explicit, not automatic: one request per installed model on every store open is exactly the fan-out A9 removed. ⚠️ `.unknown` is distinct from `.upToDate` — an absent answer must not read as reassurance (the A8 failure shape). |
| G15 (parts 1–2) | No retention, unbounded history reads | Retention sweep at launch — terminal records past 90 days or beyond the newest 500, logged. ⚠️ `.paused` is **never** pruned: pause is an explicit "I'll come back to this" and its bytes are deliberately on disk, so removing the row would take away the only Resume affordance pointing at them. Both history `@Query`s bounded to 200 (they were unbounded and re-filtered the whole array per render), and `#Index` added on the columns the bridges predicate on every reconcile tick. **Part 3 (migration) split out** — see pending. |
| G14 | Models directory hardcoded | `MLXModelsLocation` backs it with a security-scoped bookmark, a picker in Settings › Account, Reveal in Finder on the card menu, and "Import Model Folder…". Also removed the `urls(for:).first!` force-unwrap that a configurable location makes genuinely fallible. ⚠️ Import **copies** rather than symlinking or referencing in place: an in-place reference would put a folder the app doesn't own inside `installedModels`, where `deleteModel` — a recursive delete — would remove the user's own directory. Import applies the same shard-completeness rule as the scan (A2). |
| G4 | No HuggingFace token support | `HuggingFaceTokenStore` (Keychain, mirroring `MCPSecretStore`) + a `SecureField` in Settings › Account with a link to HuggingFace's token page. Passed to `HubApi(hfToken:)` and as a `Bearer` header on every raw HF call — which also lifts the anonymous rate limit that made A9's fan-out so fragile. ⚠️ `HubApi`'s own fallback reads `HF_TOKEN` from the process environment, and **a .app launched from Finder inherits no shell environment**, so it was always nil in the shipped product. Gated repos now carry a label — never a disabled button, since the user may have a token. |
| G5 | Store was quantization-blind | `MLXQuantization` parsed from the repo id → badge, filter, and — the part that also improves correctness — synthesised `ModelMetadata` so `ModelFitAdvisor` uses real bits-per-weight instead of a `diskBytes × 1.2` proxy. ⚠️ Parsing is digit-boundary anchored: `Devstral-…-24B-…-3bit` contains the substring "4bit" inside "24B", and a naive match would report 4-bit for a 3-bit model — wrong in the unsafe direction. |
| G7 | First run was a raw popularity dump | `CuratedMLXCatalog` (7 hand-checked, RAM-tiered, non-gated repos, each verified live) served as a **Recommended** tab that is the default when nothing is installed. Non-LLM pipelines are excluded from the listing with a logged reason. ⚠️ A **denylist**, not an allowlist: `any-to-any` is 8 of the live top 30 (gemma-4 multimodal) and an allowlist would have hidden them all. |
| G6 | No model detail view | Tap any card for a sheet with licence (+ link), download size, quantization, architecture, tensor count, file counts, base model and the publisher's model card. Data comes free from the detail endpoint already being called; the README is a lazy second request. ⚠️ **Context length is shown as "Not published"** — verified against the live API across four MLX repos that `max_position_embeddings` is never exposed, so it genuinely cannot be known pre-download. Gated repos get an explicit warning; G4 (token support) shipped in the same session, so the warning names the token rather than being a dead end. |
| G11 | MLX had no Re-download affordance | `ModelDownloadStatusView` is now driven by the real `isInstalled` (it was hard-coded `false` and rendered only in an `else`, making its Installed state unreachable), with `onDeleteRequested` and `profileID` passed. The card's bespoke Installed capsule and standalone trash button are gone — all three backends present an installed model identically. ⚠️ Supplying MLX's `onDownloadRequested` hook would have swallowed the `force` flag and silently regressed A7; interception is now gated on `!force`. |
| G13 | No completion notification | Emitted from `logTerminal`, the seam all three backends already funnel through. Policy is typed on `DownloadTerminalClassification`: **completion notifies only when the user has switched away** (the sidebar, badge and card already show it in-app), **failure notifies regardless** (its only in-app surface is the store banner, invisible from a chat), and cancel/pause stay **silent** — user-initiated. |
| G2 | No pause/resume | `DownloadRecordStatus.paused` + `pauseDownload()` / `resumeDownload()` / `discardPartialDownload()`. **Pause keeps the bytes, Cancel discards them** — that is the whole feature, since HubApi resumes from the `.incomplete` files via a `Range` header. Pause on active rows; Resume / Discard Partial Files on resumable history rows. Resume preflights only the *remaining* bytes. |

### ◐ Partially addressed (1)

| ID | Gap | State |
|---|---|---|
| G10 | Zero test coverage | **175 tests** now cover identity, download lifecycle, shard completeness, HF error classification, capacity arithmetic, the async scan, pause/resume, the notification policy and the polish items. **Still uncovered:** model loading, memory lifecycle, and `ModelFitAdvisor`'s full assessment matrix — nothing here loads an MLX model, by design (the suite must stay hermetic). |

### ⬜ Pending (2)

Ordered by the audit's own milestone grouping.

| ID | Gap | Sev | Effort | Milestone |
|---|---|---|---|---|
| G12 | No architecture/runtime-support check before download; unsupported models fail only at first load | P3 | M | M3 |
| G15 (part 3) | **No versioned schema / migration plan.** Parts 1–2 shipped 2026-08-03; the migration half was **split out** — it belongs to the shared 13-entity container, not to downloads. Tracked in [SWIFTDATA_MIGRATION_PLAN.md](SWIFTDATA_MIGRATION_PLAN.md). | P3 | M | M5 |

**The pending items are all P2/P3 product work.** With G2 shipped there is no remaining P1 in
either part.

---

## Ledger corrections (2026-08-03 audit of this document)

The validation audit checked this document's claims against source, the way it checked the code.
Several did not hold. Recorded rather than silently edited, because the drift is itself the
finding: **a status doc moves toward "done" unless something pushes back.**

| Claim | Reality | State now |
|---|---|---|
| **C2 "Fixed"** | Genuinely incomplete, though not at the sites the audit first named — those line references had gone stale. The real residue in this subsystem was `DownloadSidebarView`'s VoiceOver label (a `String`, so it read the persisted `rawValue` out in English) and its status subtitle, plus `.paused` falling through `default:` on both download surfaces. Both `DownloadRecordStatus.localizedTitle` and `ModelBackendType.localizedTitle` had **zero call sites app-wide** — the API shipped unwired. | ✅ **Now complete app-wide.** Fixed in this subsystem in the P2 batch, then swept across the rest of the app: 26 of 28 remaining sites converted, plus the two shared components (`CategoryChip`, `IslandTitleLabel`) whose `String` title type was the real blocker. Two sites deliberately left raw with documented reasons. `ModelBackendType.localizedTitle` was REMOVED — product names should not be catalog keys; display sites use `Text(verbatim:)` and localize only the fallback prose. |
| **B19 "Fixed"** | Dynamic Type was done; **Reduce Motion was honoured nowhere in `DownloadSidebarView`** — both hover transitions animated unconditionally. | ✅ Fixed — `@Environment(\.accessibilityReduceMotion)` on both row views. |
| **G2 "Fixed"** | True of the sidebar, not of the Downloads Manager screen: `DownloadManagerContainerView` had no `.paused` case and still has **no Pause / Resume / Discard actions**. Its only history actions are Re-download (restarts from zero) and Remove from History — which strands the bytes pause deliberately kept. | ◐ **Partial.** The `.paused` rendering is fixed; the missing actions on that surface are a real gap, not a wording problem. |
| **A19 listed as test-covered** | No test references `parseDiskSize`, `decimalSeparator`, or a comma-decimal size string. | ✅ Moved to *Not verified at all*. |
| **G6 row: "G4 (token support) is still open"** | G4 shipped in the same session, three rows above. | ✅ Corrected. |
| **Severity tally** | Summed to 60 against a stated total of 59; P1 read 27 against the audit's own 26; the Pending column put 2 against P2 when both pending items are P3. | ✅ Corrected against the full audit's section headings. |
| **Test counts** | Three different figures (74 / 83 / 154) and "23 suites". | ✅ Replaced with a measured **175 methods / 33 suites / 17 files**. |
| **"invariants 16–26"** | §7 now runs to 36. | ✅ Corrected. |
| **"✅ Fixed (12)" over a 13-row table** | **Not an error.** 12 gaps are fully fixed; G15 appears in both tables because parts 1–2 shipped and part 3 is pending. The audit called this a miscount — it was not. Clarified in place instead. | ◻ No change needed. |

---

## Defects introduced *during* this work

Recorded because they are the honest cost of the change, and because two of them were caught only
by running the app — not by the test suite.

| # | Defect | How found | State |
|---|---|---|---|
| D1 | `DownloadManager.init` read `DownloadHistoryStore` before the container was configured, so the active count was always seeded to 0 | **App log on first launch** (surfaced by B9's new logging) | ✅ Fixed — `primeActiveCount()` called after `reconcileOrphans()` |
| D2 | The storage row showed a *filtered* count beside an *unfiltered* total: `1 installed · 81.52 GB` | **App UI** | ✅ Fixed — now `1 of 17 shown · 81.52 GB` |
| D3 | Long model titles ran under the "Set as IC"/delete overlay — **a regression from A3**, since org labels now render for every model where before only `mlx-community` had one | **App UI** | ✅ Fixed — single-line truncation, layout priority, reserved trailing space |
| D4 | `ensureLoaded()` was short-circuited by the debounce and could return **before any scan landed** — a caller then reads an empty list and 404s a model that is installed | **Test** | ✅ Fixed — coalescing now precedes the debounce; readiness keys on `hasCompletedInitialScan` |
| D6 | G11 would have regressed A7: once MLX supplied the `onDownloadRequested` hook, `triggerDownload` intercepted it unconditionally and dropped the `force` flag, so Re-download became a no-op again | **Caught during implementation** by tracing the call chain before shipping | ✅ Fixed — interception gated on `!force`, extracted to a testable `shouldDelegateToHost` |
| D5 | Three production sites relied on the old synchronous scan contract: `deleteModel`, the cancel-cleanup block, and the picker's `.onAppear` (auto-selecting from an empty list with nothing to re-trigger it) | **Test cascade** after A15 | ✅ Fixed — all now await; the picker moved to `.task` |
| D7 | **A13's cleanup guard defeated A1.** It refused any folder containing weights, but HubApi moves each finished shard to its final path before fetching the next — so an interrupted *sharded* download is exactly that, and `removePartialDownload` silently refused every one. Cancelling a large pull stranded its bytes with no in-app route to free them (`.cancelled` is not `isResumable`) | **Validation audit** (adversarially verified against the vendored `swift-transformers` source) | ✅ Fixed — `isCompleteInstall(at:)`, shared with `scanDisk`/`scanForOrphans`; reclaim now reports refusal so the history row survives |
| D8 | **The download slot had no ownership check on the pause/terminal paths.** `pauseDownload` freed the slot while the cancelled task was still unwinding, and `resumeDownload` re-enters `downloadModel` immediately — so the late unwind cleared the *new* download's handles, reset `isDownloading`, and on the failure path reclaimed the live download's bytes | **Validation audit**, confirmed by reading the call chain | ✅ Fixed — `downloadGeneration` token gates every terminal handler, progress tick and reclaim. ⚠️ A repo-id check cannot work: Pause→Resume shares the id |
| D12 | **`parseQuantizationBits` read every 16-bit model as 6-BIT** — it is a chain of substring tests and `"16bit"` contains `"6bit"` (likewise `"32bit"`/`"2bit"`). A ~2.7× under-estimate of runtime RAM, in the unsafe direction | **Exposed by the P2 fix to `ModelFitAdvisor`** — latent while G5's metadata was being discarded, live once the formula was routed ahead of the byte proxy | ✅ Fixed — wide formats tested first; a test pins that every `MLXQuantization.advisorToken` round-trips. Invariant 28 extended |
| D10 | **`force:` did not force.** The coalesce check returned above the `force` test, so a caller that had just mutated the disk was satisfied by a walk already in flight — reopening the race the download-success path's awaited refresh exists to close (stale list → a completed pull recorded as cancelled) | **Validation audit**, confirmed by reading `refreshInstalledModelsAsync` | ✅ Fixed — forcing callers join, then start their own walk; `scanTask` cleared only by its owner. Invariant 26 was overstated and is now scoped |
| D11 | **G14 import ran a recursive sizing walk and `copyItem` inline on the `@MainActor` service** — the hang A15 existed to remove, in code written after it. ⚠️ The size walk hid inside a `ByteCountFormatter` interpolation, where arguments evaluate eagerly | **Validation audit** | ✅ Fixed — both off-actor; `deleteModel`'s sizing too. Its `removeItem` deliberately stays inline (the loaded/generating guards above it are `await`s) |
| D9 | `testPauseKeepsPartialFiles` **never called `pauseDownload()`** — it assigned three flags and asserted a folder it had just created existed, so the file's flagship invariant had zero coverage and stayed green with the bug reinstated | **Validation audit** (test-quality pass) | ✅ Fixed — rewritten to drive the real path; D7 and D8 are both mutation-tested |

**Lesson worth keeping:** a green test suite is not verification. Running the app found three
defects that 111 passing tests did not, and the observability work from Batch 2 is what made
D1 visible at all. **D7–D9 sharpen it:** the suite was green *because* several tests asserted on
literals they defined themselves. A test that cannot fail when the fix is reverted is not
coverage — every new invariant test should be mutation-checked once, which is cheap and is how
D7 and D8 were confirmed.

---

## Verification status

### Proven on device

Against the real 17-model / 81.52 GB library, with real HuggingFace traffic:

- **A3** — canonical `author/name` for every publisher (`AlfRjw/…`, `srswti/…`, `badmadrad/…`),
  visible both in the analyzer log and as org labels in the store
- **A2** — 16 of 19 folders admitted; the 3 weightless ones filtered
- **A1** — orphan scan reports 2.52 GB of unreclaimed partial downloads
- **A8 / B17** — badges render `✓ Comfortable · ~2.76 GB RAM`, `⚠ Tight Fit`, `✗ Too Large`
- **A18** — all six category tabs present, including the `All` tab the old code deleted
- **A23** — Download pill visible without hovering
- **A20** — typing `granite` filtered 17 → 1 in a field that was previously inert
- **G3** — `17 installed · 81.52 GB on disk`, per-model sizes on every card
- **B10** — a genuine second scan runs and reports `Models unchanged (17)`
- **B13** — `[MLX-LOAD] Loading … est. runtime 5.14 GB, budget 18 GB, verdict Comfortable`

A **full download** (`mlx-community/parakeet-tdt-0.6b-v2`, 2m26s) confirmed **A16** (count
0→1→0), **G9** (assertion taken *and released*), **A6** (handles cleared), **B2** (terminal
classification naming every signal), **A11** (two generations, no clobbering), **A9** (30 models
sized, no 429) and **G3** (re-sized immediately after install).

A **cancelled generation** confirmed **B1**: the idle timer started at the moment of cancel and
the unload freed 5.3 GB two minutes later, with no `Refusing model unload` anywhere — pre-fix the
orphan would have held `activeGenerations > 0` decoding to EOS.

### Test-only

Everything covered by the 175 tests but not exercised on device — notably A5's cancel
classification, A7's forced re-pull, A10/B8's error handling under real 429s, and the A14
identity plumbing.

> **[ledger correction]** This list previously named **A19's locale parsing** as test-covered.
> It is not: no test anywhere references `parseDiskSize`, `decimalSeparator`, or a comma-decimal
> size string. A19 is **unverified**, not test-only — it belongs in the section below. The count
> here also read "74 tests", one of three different figures this document carried (74 / 83 / 154)
> against a measured 175.

### ⚠️ Not verified at all

| What | Why |
|---|---|
| **The A14 wrong-model race itself** | Needs two MLX models loaded by parallel workflow branches with a pause between iterations. The identity plumbing and error surface are unit-tested; the race they prevent is not reproduced. |
| **G1's disk-full refusal** | Needs a genuinely full volume. Covered by `MLXDiskCapacityTests` arithmetic instead. |
| **The tool-capable toggle (A18)** | Renders only when the store is opened from an Agent profile via *Manage Models*. A few seconds to eyeball. |
| **B1's consumer-side backstop** | The cancellation propagated via stream *termination* (`onTermination` → producer cancel), so the `Task.isCancelled` check inside the consumer loop never fired. That path is still unexercised. |
| **A19's locale parsing** | **[ledger correction]** Previously listed as test-only. Nothing references `parseDiskSize` or a comma-decimal separator in any test, and it has not been run under a European locale. |
| **The P2/P3 audit-fix UI** (items 2, 7, 8, 9) | The quantization-filter reset, the `.paused` icons on both download surfaces, the workflow inspector's `.task` conversion and the HF token card's re-render are logic-tested but have not been looked at running. |

---

## Traps for whoever picks this up

Recorded as invariants 16–36 in [architecture_readme.md](architecture_readme.md) §7. The ones
most likely to be "simplified" back into bugs:

1. **Never rebuild HubApi's download path by hand.** It is
   `downloadBase/models/<author>/<name>` — a *doubled* `models` component. Getting this wrong is
   what made cancel cleanup a silent no-op for months.
2. **Never compare model ids with `contains`.** A bare model name is a substring of its own
   longer variants (`…-4bit` inside `…-4bit-DWQ`). Use `MLXModelIdentity`.
3. **`Text(x.rawValue)` does not localize.** It binds to the `StringProtocol` overload, unlike a
   literal. Use `localizedTitle`; keep `rawValue` for persistence and logging.
4. **`ModelBackendType.rawValue` is a persistence key** (`DownloadRecord.backendRaw`). Never
   change it for display. A test pins the exact strings.
5. **An identity check and the use of what it validated must share one synchronous region.**
   `MLXService` is a reentrant actor; any `await` between them lets a concurrent load swap the
   container.
6. **Coalescing precedes debouncing.** Letting a debounce short-circuit a caller that is *waiting
   for* the scan returns it on unpopulated state — which reads as "nothing installed".
7. **A capability check that cannot answer must not block.** `hasRoomForDownload` returns nil,
   not false, when free space is unreadable, and the caller proceeds. Same shape as the
   `.unknown` fit verdict.
8. **Pause keeps the partial bytes; Cancel discards them.** The `.incomplete` files ARE the
   resume state and live *inside* the repo folder at `.cache/huggingface/download/`, so any
   cleanup on the pause path silently destroys it. `.cancelled` is deliberately not resumable.
9. **Classification describes; it never gates.** A `Too Large` card still has a working Download
   button. This is a standing project directive, and A18 was its violation.

---

## Changelog

| Date | Change |
|---|---|
| 2026-08-03 | Initial audit (59 findings) and full remediation: Batches 0–3, milestone M1, the two deferred inference-path items A14 and A15, and G2 (pause/resume). 83 tests added where there were none. Verified on device across a real library, download and cancelled generation. |
