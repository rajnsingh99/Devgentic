# MLX Model Manager — production readiness

**Scope:** `Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/` (store, picker, card,
scanner, tokenizer analyzer, fit badge), `Core/Service/MLXService.swift`,
`Core/Service/DownloadManager.swift`, `Core/Service/DownloadCoordinator.swift`,
`Core/Persistence/SwiftData/DownloadHistoryStore.swift` + `DownloadRecordSD.swift`,
`Interfaces/Shared/Components/ModelDownloadStatusView.swift`, and the seams into
`MLXTokenizerAnalyzer`, `ModelFitAdvisor`, `IntelligenceCoreService`, `HistoryCompactionService`
and the vendored `swift-transformers` `HubApi`.

**Audit:** 2026-08-03. Six independent source reviews across six dimensions
(download-lifecycle, networking/HF, persistence, UI/UX, runtime-integration, feature-gaps),
then an adversarial verification pass over the three highest-severity findings.

**How to use this doc.** Part A is defects — things that are wrong in shipped code. Part B is
feature gaps — things that were never built. Both are ranked by severity then user impact.
§Refuted is the register of claims that did not survive verification or were narrowed; do not
re-report them. §Recommended sequencing is the work order.

**Discipline for edits:** state only what you verified in source in that session; give every
constant its reason; update this doc in the same change as the behaviour.

---

## Executive summary

**Verdict: not production-ready.** The subsystem's browse-and-load path works, but its
*lifecycle* path — cancel, re-download, concurrent download, delete, failure surfacing — is
broken in ways that lose user data, leak multi-gigabyte files with no in-app reclaim, and
report the wrong terminal state in download history. Three defects around
`removePartialDownload` / `downloadTask` / concurrent starts are **coupled**: each masks the
others, and fixing any one in isolation makes a different one destructive. On the network
side every HuggingFace call discards its HTTP status, so a 429 (which the unthrottled 30-request
fan-out provokes routinely) is indistinguishable from an empty result, and the RAM-fit advisory
fails *open* on that same error. Zero tests exist for `MLXService`, `MLXModelService`,
`DownloadManager`, `DownloadCoordinator`, `DownloadHistoryStore` or `ModelFitAdvisor`.

Genuinely well-built, in one line: `MLXTokenizerAnalyzer`'s capability/dialect classification is
fixture-driven and covered by 25 tests, `ICReleasePolicy` is the correct extraction pattern for
this subsystem's untested state machines, and `DownloadHistoryStore.reconcileOrphans` is wired
correctly at launch.

| Severity | Part A — Defects | Part B — Feature gaps | Total |
|---|---|---|---|
| **P0** | 0 | 0 | **0** |
| **P1** | 23 | 3 | **26** |
| **P2** | 19 | 7 | **26** |
| **P3** | 2 | 5 | **7** |
| **Total** | **44** | **15** | **59** |

Both findings originally filed P0 were downgraded on verification — see §Refuted. Nothing here
crashes, corrupts a database, or exposes a secret; the ceiling is P1.

### Fix this first

**A1 + A6 + A4 must ship as one change.** `partialDownloadFolder` resolves a path that never
exists (A1), so the cancel-cleanup delete has never fired. That broken delete is the *only*
thing preventing A6 — `downloadTask` and `currentDownloadName` are never cleared on success, so
starting model B right after model A completes calls `removePartialDownload(repoId: "A")`
against the **successfully installed** model A. Fix the path first and you ship a defect that
deletes a completed multi-gigabyte model. A4 (a second download silently cancels the first) is
the trigger that makes the A6 sequence common rather than rare. Land all three together, with
the terminal-branch cleanup (A5) in the same change, and add tests before touching anything else.

---

# Part A — Defects

## P1

### A1. `partialDownloadFolder` builds a path one component short of where HubApi writes — cancel cleanup is a permanent silent no-op

**P1** · ✅ adversarially verified (filed P0 ×2, corrected to P1) · reported by 3 of 6 auditors
· [MLXModelService.swift:425](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:425)

```swift
private func partialDownloadFolder(for repoId: String) -> URL? {
    let components = repoId.components(separatedBy: "/")
    ...
    return modelsDirectory
        .appendingPathComponent(components[0])
        .appendingPathComponent(components[1])
}

func removePartialDownload(repoId: String) {
    guard let folder = partialDownloadFolder(for: repoId) else { return }
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder.path) else { return }
```

**What's wrong.** `hub` is `HubApi(downloadBase: modelsDirectory)`
([MLXModelService.swift:98](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:98))
and swift-transformers resolves the destination as
`downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)`
(`HubApi.swift:378-380`, `RepoType.models.rawValue == "models"`). The real path is therefore
`<modelsDirectory>/models/<author>/<name>`; this function returns
`<modelsDirectory>/<author>/<name>`. Verified on disk: `~/Library/Application
Support/huggingface/models/models/{mlx-community,lmstudio-community,NexVeridian,…}` exists;
`~/Library/Application Support/huggingface/models/mlx-community` does not. `fm.fileExists` is
unconditionally false, so the function has never deleted anything — and the guard logs nothing,
so the log shows no trace of the skipped cleanup. The function's own doc comment asserts the
wrong layout, which is how this survived.

**Impact.** Every MLX download cancel is a no-op on disk. Measured on this machine: 2.4 GB
stranded across three repos — `Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2` (2.1 GB, dated
2026-04-22), `NexVeridian/Qwen3-Coder-Next-8bit` (270 MB),
`mlx-community/granite-3.3-2b-instruct-4bit` (30 MB), all still present on 2026-08-03. Because
those folders carry no completed weights file, `refreshInstalledModels`' `hasWeights` guard
skips them entirely: they are invisible in the store, have no Delete button, and can only be
reclaimed by hand in Finder. The "Cleaning up…" spinner
([ModelDownloadStatusView.swift:146](Devgentic/Interfaces/Shared/Components/ModelDownloadStatusView.swift:146),
[MLXModelStoreView.swift:519](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:519))
and the confirmation copy "any partial files removed from disk"
([MLXModelStoreView.swift:588](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:588))
are both false. For a **multi-shard** repo cancelled after shard 1 completes, the leftover
`config.json` + complete `.safetensors` also satisfies `hasWeights`, so the truncated repo is
listed as Installed forever and fails at load — see A2.

**Fix.** Derive the folder from the library's own resolver — `hub.localRepoLocation(Hub.Repo(id:
repoId))` — so the two cannot drift again; at minimum insert the missing
`.appendingPathComponent("models")`. Log both early returns (`malformed repoId` /
`no partial folder at <path>`) with the consequence, per the logging standard. Ship a one-time
startup sweep that removes repo dirs containing `.cache/huggingface/download/*.incomplete` and
no top-level weights, to reclaim what has already leaked. **Do not ship this without A6.**

---

### A2. `hasWeights` accepts any single weights file, so a partial sharded repo is reported "Installed"

**P1** · [unverified] · reported by 2 of 6 auditors ·
[MLXModelService.swift:148](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:148)

```swift
let hasWeights = contents.contains { url in
    let ext = url.pathExtension.lowercased()
    return ext == "safetensors" || ext == "npz" || ext == "bin" || ext == "gguf"
}
guard hasWeights else {
    logger.debug("Skipping incomplete download at \(modelDir.lastPathComponent) — no weights file present")
    continue
}
```

**What's wrong.** The completeness check is satisfied by ONE file with a weights extension.
HubApi downloads a repo's files strictly sequentially and moves each completed shard into place
(`HubApi.swift:663-692`), so a pull killed after shard 2 of 4 leaves two complete
`.safetensors` next to `config.json`. Every sharded repo on disk ships a
`model.safetensors.index.json` enumerating the full shard set (verified: Qwen3-Coder-30B expects
4 and has 4; `NexVeridian/Qwen3-Coder-Next-8bit` expects 17), and the scan never consults it.
`mlx-community/Kimi-K2.5` is 199 files.

**Impact.** Cancel or crash mid-pull on any sharded model and it appears under Installed with a
green badge on the next launch. Selecting it and sending a message fails inside
`MLXService.loadModel` with a raw framework shard-lookup error. `refreshInstalledModels` never
re-validates, so the phantom persists across relaunches, and
`DownloadCoordinator.startMLXDownloadIfNeeded` returns `.alreadyInstalled` forever — so the user
cannot resume or re-pull from any surface (A7), despite HubApi holding resumable `.incomplete`
bytes right there.

**Fix.** When `model.safetensors.index.json` is present, parse its `weight_map` values into the
expected shard set and require every one on disk; fall back to the current any-weights check
when absent. Classify the shortfall as `.partial` and render a Resume affordance instead of the
Installed badge. Raise the rejection log from `.debug` to `.info` with model id, expected and
present shard counts — this is the diagnostic for "why did my download vanish from the list".

---

### A3. `displayName` drops the author for every non-`mlx-community` repo, breaking the canonical identity key

**P1** · [unverified] · reported by 3 of 6 auditors ·
[MLXModelService.swift:157](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:157)

```swift
var displayName = modelDir.lastPathComponent

// Reconstruct clean names from nested folders
if parentDir.lastPathComponent == "mlx-community" {
    displayName = "\(parentDir.lastPathComponent)/\(modelDir.lastPathComponent)"
} else if modelDir.lastPathComponent.starts(with: "models--") {
     displayName = modelDir.lastPathComponent
        .replacingOccurrences(of: "models--", with: "")
        .replacingOccurrences(of: "--", with: "/")
}
```

**What's wrong.** The author is re-attached only when the parent directory is literally
`mlx-community`, but HubApi's layout is `<base>/models/<author>/<name>` for *every* author, so
any other publisher yields a bare model name. Measured: 12 of 18 installed models on this
machine are from other orgs (NexVeridian, lmstudio-community, badmadrad, AlfRjw, davehind,
srswti, Jiunsong). The `models--` fallback cannot rescue it — that matches the python
`huggingface_hub` cache, where `config.json` lives in `models--Org--Name/snapshots/<sha>/`, so
`modelDir.lastPathComponent` is the commit SHA and the branch never fires. `MLXModelItem.id` is
set to this same string ([:173](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:173)),
making it the identity key everywhere.

**Impact.** Two-thirds of the user's library fails every exact-match identity check.
(1) [DownloadCoordinator.swift:111](Devgentic/Core/Service/DownloadCoordinator.swift:111)
`installedModels.contains { $0.displayName == trimmed }` never matches, so the "thin idempotent
front-door" its own header claims is defeated: picking Re-download on a history row for an
installed `lmstudio-community` model toasts "Downloading…" and re-pulls the entire multi-GB repo
over the already-present files instead of the "already installed" short-circuit.
(2) [DownloadManager.swift:366](Devgentic/Core/Service/DownloadManager.swift:366) uses the same
test to decide the terminal state, so a successful download falls through to the
`progress >= 0.99` fallback and can be written to history as `.cancelled`.
(3) `MLXModelStoreViewModel.isInstalled` compensates with a *lenient* `contains`, so the two
comparators disagree for exactly this population — see A17.

**Fix.** Compute the display name from the path relative to `modelsDirectory/models` (join the
components after the repo-type segment) so it is always `<author>/<name>`; handle the python
cache by matching `models--` on any ancestor and taking the `snapshots/<sha>` parent. Then route
`DownloadCoordinator` and `MLXModelStoreViewModel.isInstalled` through **one shared comparison
helper** so they cannot drift again.

---

### A4. Starting a second MLX download silently kills the first, and the second gets no record at all

**P1** · [unverified] · reported by 2 of 6 auditors ·
[MLXModelService.swift:378](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:378)
· [DownloadManager.swift:328](Devgentic/Core/Service/DownloadManager.swift:328)

```swift
func downloadModel(repoId: String) {
    cancelDownload()

    isDownloading = true
    currentDownloadName = repoId
```

**What's wrong.** `downloadModel` unconditionally pre-empts any in-flight pull.
`DownloadCoordinator.startMLXDownloadIfNeeded` only short-circuits `.alreadyInProgress` for the
*same* identifier ([:118-123](Devgentic/Core/Service/DownloadCoordinator.swift:118)), so a
different repo sails through. The bridge then corrupts its own bookkeeping: it branches only on
`isDownloading` and never compares `modelName` against the active record's `modelIdentifier`,
and `isDownloading` never returns to false between the two (line 380 re-raises it in the same
MainActor turn). Both siblings refuse instead: `WhisperModelDownloadService.downloadModel:141`
and `OllamaService.pullModel:317` both `guard !isDownloading`.

**Impact.** Model A is downloading; the user clicks Download on model B "to line it up", as they
would in LM Studio. A's HubApi task is cancelled with no toast, no log and no visible state
change — A's multi-GB progress is discarded and (per A1) its partial is never reclaimed. B's
progress ticks are written into **A's** `DownloadRecord`, so the sidebar row keeps ticking under
A's name showing B's bytes. When A's cancelled task throws, the terminal branch closes A's
record and nils `mlxActiveID` while B is still downloading; every subsequent tick is then
dropped by `else if let id = mlxActiveID`. B ends with no record, no `activeRecordIDsByKey`
entry, no sidebar row, no speed/ETA, and **no cancel button anywhere in the UI**. Nothing is
logged at any point.

**Fix.** Short term: make `downloadModel` refuse rather than pre-empt, mirroring Whisper, and
return `.failed("Another model is already downloading")` from `startMLXDownloadIfNeeded` so the
existing toast path surfaces it. Independently, add an identity check at the head of the
bridge's active branch — if `mlxActiveID`'s record `modelIdentifier != modelName`, close the old
record with `markCancelled(reason: "superseded by <new>")`, `clearTransients`, and fall through
to the fresh-start path, logging both identifiers. Apply the same guard to the Ollama and
Whisper bridges. Proper fix in Part B (B-P1c: a real queue).

---

### A5. HubApi never throws `CancellationError` — user cancels are recorded as "failed", or worse as "completed"

**P1** · [unverified] ·
[MLXModelService.swift:403](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:403)

```swift
} catch where error is CancellationError {
    logger.info("Download cancelled by user.")
    self.isDownloading = false
    self.downloadProgress = 0.0
    self.currentDownloadName = ""

} catch {
    logger.fault("Download error: \(error.localizedDescription)")
    self.errorMessage = "Download failed: \(error.localizedDescription)"
```

**What's wrong.** That catch arm is dead. swift-transformers' `Downloader.cancel()` broadcasts
`.failed(URLError(.cancelled))` (`Downloader.swift:379-382`) and `HubFileDownloader` rethrows it
verbatim (`HubApi.swift:595-596`) — a `URLError`, not a `CancellationError`. And when
cancellation lands *between* files, `snapshot` does not throw at all:
`if Task.isCancelled { return repoDestination }` (`HubApi.swift:687-689`) returns normally.

**Impact.** Two wrong terminal states, neither of them "cancelled". Path 1 (cancel mid-file):
the generic catch logs the user's own deliberate cancel at **fault** level and sets
`errorMessage = "Download failed: cancelled."`; `reconcileMLX` sees a non-empty errorMessage and
calls `markFailed`, so Downloads history shows a red "Failed: cancelled" row. Which of failed or
cancelled it lands on is even nondeterministic — `cancelDownload`'s cleanup block clears
`errorMessage` and races the bridge's observation Task. Path 2 (cancel between files): the
success path runs, logs "Download finished successfully.", calls `forceRefreshInstalledModels()`
which picks up the partial repo, so `isInstalledNow` is true and the record is written
**completed** for a download the user cancelled. Ollama gets this right
(`catch is CancellationError { modelPullError = nil }`, `OllamaService.swift:358-360`).

**Fix.** Stop keying off the error type. Check `Task.isCancelled` first on **both** the success
and catch paths — the shape `WhisperModelDownloadService` already uses at :185-188 / :208-211 —
and take the cancel branch before either handler runs. Also treat `URLError.cancelled` as
cancellation. Log the chosen terminal classification with the repo id and the raw error so the
log explains why a record became failed vs cancelled vs completed.

---

### A6. `downloadTask` is never cleared on completion, so the next download's cleanup targets the previous repo

**P1** · [unverified] ·
[MLXModelService.swift:471](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:471)

```swift
let newTaskForSameRepo = self.downloadTask != nil && self.currentDownloadName == modelName

if !modelName.isEmpty && !newTaskForSameRepo {
    self.removePartialDownload(repoId: modelName)
}
```

**What's wrong.** Neither the success path (:399-401) nor the failure path (:409-413) sets
`downloadTask = nil` or clears `currentDownloadName`. After model A finishes successfully,
`downloadTask` is still A's completed task and `currentDownloadName` is still "A". Starting
model B calls `cancelDownload()`, which passes `guard let task = downloadTask`, captures
`modelName = "A"`, logs `"Cancelling download: A"`, sets `isCancellingDownload = true` and
spawns the cleanup Task. `downloadModel` then synchronously sets `currentDownloadName = "B"` and
`downloadTask = <B's task>` before the cleanup block runs, so `newTaskForSameRepo` is false and
`removePartialDownload(repoId: "A")` runs against the **successfully installed** model A.

**Impact.** Today the damage is masked *only* by A1 — the delete silently misses. The moment A1
is fixed, downloading model B immediately after model A in the same session deletes model A's
fully-installed multi-gigabyte folder from disk. Right now it still produces misleading logs
("Cancelling download: A" when nothing is being cancelled) and flips `isCancellingDownload`, so
every MLX card shows a spurious "Cleaning up…" while B starts (C1).

**Fix.** Set `downloadTask = nil` and `currentDownloadName = ""` in every terminal branch
(success, cancel, failure). Guard the cleanup on the task having actually been cancelled —
capture the `Task` identity plus the repo id, and never run `removePartialDownload` for a repo
present in `installedModels`. **Ship with A1.**

---

### A7. "Re-download" of an installed MLX model is a guaranteed no-op — there is no repair path

**P1** · [unverified] ·
[DownloadCoordinator.swift:111](Devgentic/Core/Service/DownloadCoordinator.swift:111)

```swift
let isInstalled = mlx.installedModels.contains { $0.displayName == trimmed }

if isInstalled {
    promoteStaleRecordIfNeeded(backend: .mlx, modelIdentifier: trimmed)
    return .alreadyInstalled
}
```

**What's wrong.** There is no `force` parameter on `startMLXDownloadIfNeeded`, and all three
re-download entry points funnel through it —
[DownloadSidebarView.swift:261](Devgentic/Interfaces/Main/Views/Downloads/DownloadSidebarView.swift:261),
[DownloadManagerContainerView.swift:321](Devgentic/Interfaces/Main/Views/Downloads/DownloadManagerContainerView.swift:321),
[ModelDownloadStatusView.swift:272](Devgentic/Interfaces/Shared/Components/ModelDownloadStatusView.swift:272).
`ModelDownloadStatusView.triggerDownload(force: true)` deletes the *history record*, but the
installed check reads the filesystem, so deleting the record changes nothing.

**Impact.** The confirming alerts promise the opposite — "Existing files will be overwritten"
(DownloadSidebarView.swift:101, ModelDownloadStatusView.swift:107). A user with a truncated or
corrupt model (which is the normal outcome of A1/A2) clicks Re-download, confirms that alert,
and gets a green toast saying "X is already installed". Nothing is re-fetched. The only recovery
is Delete then Download, discarding every completed shard. This wastes a capability already
present: `HubFileDownloader.download` (`HubApi.swift:537-580`) verifies etag/SHA-256 per file and
re-fetches only mismatches, so a forced re-pull would be a cheap, correct repair.

**Fix.** Add `force: Bool = false` to `startMLXDownloadIfNeeded` and skip the `isInstalled`
short-circuit when set; thread it through the three call sites. Since HubApi already
hash-verifies, surface it as "Verify & Repair" alongside "Re-download". Effort S.

---

### A8. A swallowed HF size fetch silently disables the RAM-fit advisory, so oversized models download with no warning

**P1** · [unverified] ·
[MLXModelService.swift:349](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:349)

```swift
} catch {
    return (repoId, nil)
}
```

**What's wrong.** `getSizeForModel` returns `(repoId, nil)` on ANY failure with no log. A nil
size leaves `MLXDisplayModel.size == nil`, which propagates into
`ModelFitAdvisor.assess(metadata: nil, diskSizeString: nil, modelName:)`
([MLXModelStoreView.swift:307](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:307)).
With both inputs nil, `ModelFitAdvisor.swift:104-110` falls through every branch and returns
`.comfortable` with `estimatedRuntimeRAM: 0`. The download gate at
[MLXModelStoreView.swift:403](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:403)
is `if verdict == .risky || verdict == .incompatible`, which `.comfortable` never trips. The
badge is hidden too, because :485 requires `model.size != nil && estimatedRuntimeRAM > 0` — so
there is not even a visual clue the assessment is unknown. **A safety advisory that fails open
on a network error fails in the worst possible direction.**

**Impact.** On a 16 GB Mac, HF returns 429 for the size calls (the common case, not the rare one
— see A9). Every card on the page loses its size, loses its fit badge, and silently reports
`.comfortable`. The user clicks Download on a 40 GB
`mlx-community/Llama-3.3-70B-Instruct-8bit`, gets no advisory sheet, and the pull proceeds to
completion or fills the disk. Sort by Size becomes a no-op too, since `parseSize(nil)` returns 0
for every row.

**Fix.** Distinguish "size unknown" from "size fits": add a `.unknown` verdict so a missing size
renders an explicit "Size unavailable — cannot check RAM fit" state on the card. Log the failure
with tag, repo id and consequence per the project standard.

---

### A9. `fetchSizes` fans out 30 unthrottled HuggingFace requests per page, and the size cache is never read

**P1** · [unverified] ·
[MLXModelService.swift:316](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:316)

```swift
await withTaskGroup(of: (String, String?).self) { group in
    for id in repoIds {
        group.addTask {
            return await self.getSizeForModel(repoId: id)
        }
    }
```

**What's wrong.** No concurrency limit. `repoIds` is the full page (`pageSize = 30`), so every
list fetch immediately issues 30 simultaneous `GET /api/models/{repoId}?blobs=true` — an
expensive blob-enumerating endpoint — from an unauthenticated client. `modelSizes` is declared
as a memoization cache ("Cache for model sizes to avoid re-fetching", :40-41) but is only ever
**written** (:326) and never read: `getSizeForModel` does not consult it. `fetchRemoteModels`
also calls `fetchSizes` on the whole page on the *append* path (:263), not just on new ids.

**Impact.** Each of these costs 1 list request + 30 blob requests: opening the store, every
category tab click, every 500 ms debounce pause while typing, every Load More. Sweeping the tab
bar All→Reasoning→Tool Use→Coding→Vision is 5 × 31 = **155 requests in a few seconds**, all
against the same top-30 models whose sizes were already fetched. HF's anonymous rate limit is
reached quickly; every subsequent request 429s, which A10 discards silently, which disables the
RAM-fit advisory for the whole page (A8).

**Fix.** Bound the group (start 4-6 tasks, `addTask` one more per `next()`), consult and honor
`modelSizes` before issuing a request, and on the append path pass only the ids that are new.

---

### A10. HTTP status codes are discarded on every HuggingFace call — 429/401/500 are indistinguishable from an empty result

**P1** · [unverified] ·
[MLXModelService.swift:226](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:226)

```swift
let (data, _) = try await URLSession.shared.data(from: url)
let rawModels = try JSONDecoder().decode([HFRawModel].self, from: data)
```

**What's wrong.** The `URLResponse` is thrown away with `_` at all three HF call sites (:226
list, :341 size, :365 total-bytes). A 429, 401, 500 or a Cloudflare HTML interstitial all arrive
as a *successful* `data(from:)` with a non-JSON body; the only thing that fails is
`JSONDecoder`, which throws a generic `DataCorrupted`. This is a lone outlier in this codebase —
[CloudRequestPipeline.swift:46](Devgentic/Core/Backends/CloudRequestPipeline.swift:46) already
implements exactly the right pattern (`HTTPURLResponse` cast, status switch, `Retry-After`
extraction at :231) for every cloud provider, and even the vendored `HubApi.httpGet` maps
401/403 → `authorizationRequired` and 404 → `fileNotFound`.

**Impact.** Rate-limited, offline, gated, and genuinely-empty all render the identical dead end:
`availableModels` stays empty and the store shows "No models found" with a "Try Reloading"
button, which fires another 31 requests into the same 429 wall. The log line reads "HF fetch
failed: The data couldn't be read because it isn't in the correct format" — which points a
maintainer at a schema bug rather than at throttling, for the single most likely production
failure. Not field-debuggable from logs alone.

**Fix.** Route the three calls through one helper that casts to `HTTPURLResponse`, switches on
status (429 → "HuggingFace is rate-limiting; retry in N s" from `Retry-After`; 401/403 → "This
repo requires a HuggingFace token"; 5xx → "HuggingFace is unavailable") and logs status + url +
repo id. Reuse `CloudRequestPipeline`'s logic rather than reimplementing it, and surface a
distinct error state instead of the generic empty view.

---

### A11. No request-generation token: a stale in-flight HF response overwrites or corrupts the results of a newer query

**P1** · [unverified] ·
[MLXModelService.swift:257](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:257)

```swift
} else {
    self.availableModels = displayModels
    self.logger.info("HF fetch replace: total=\(self.availableModels.count)")
}
```

**What's wrong.** `fetchRemoteModels` takes no sequence parameter and both terminal writes
(append :249, replace :257) are unconditional — nothing checks whether the query that produced
`displayModels` is still the query on screen. Both callers launch detached, unretained,
uncancelled tasks
([MLXModelStoreViewModel.swift:200](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:200)
and :231), so no handle exists to cancel an older request. The 500 ms `searchDebounceTask` only
coalesces keystrokes *before* dispatch.

**Impact.** Repro A (corrupted list): click Load More on All with search=`qwen` (append,
skip=30), then immediately click the Vision tab — the tab button has no `.disabled` guard,
unlike Load More at :223. The Vision replace lands first, then the stale qwen page-2 *appends*
onto it, so the Vision tab displays 30 non-vision models. Repro B (wrong results): type
`llama`, pause 500 ms, then click the clear-X; if the first request is slower the store shows
llama results with an empty search box, and "Try Reloading" is the only way out.

**Fix.** Add a monotonically increasing generation counter on `MLXModelService`, capture it at
entry, and compare before every write to `availableModels`/`modelSizes`, bailing with an
explicit "discarding stale HF response gen=… current=…" log. Bump it in `refreshCategoryData`.
Retain the fetch `Task` in the view model and cancel it before starting a new one.

---

### A12. A failed MLX download silently reverts the card to a Download button with no error shown anywhere in the store

**P1** · [unverified] ·
[MLXModelService.swift:410](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:410)

```swift
} catch {
    logger.fault("Download error: \(error.localizedDescription)")
    self.errorMessage = "Download failed: \(error.localizedDescription)"
    self.isDownloading = false
}
```

**What's wrong.** `errorMessage` is set here but **no MLX view ever reads it** — the only
consumer in the app is `DownloadManager.bindMLX` (:309/:316). DownloadManager then calls
`markFailed` and `clearTransients`, which removes the key from `activeRecordIDsByKey`, so
`DownloadManager.activeRecord` returns nil and `ModelCardView.body` drops out of
`downloadingCard` back into `standardCard`. The store also never routes through the toast path:
it passes `onDownloadRequested`, so `ModelDownloadStatusView.triggerDownload` returns early at
:259-262 and its `case .failed: toastManager.show(…)` at :292 is unreachable for MLX cards.

**Impact.** On a 403 (gated repo), a mid-download network drop, or disk-full, the progress ring
simply disappears and the card looks exactly as it did before the user pressed Download — no
toast, no banner, no inline error. The reasonable conclusion is that the click did not register,
so the user presses Download again and re-runs the same failing pull. The only place the failure
is visible is the Downloads sidebar, which the user has no reason to open because nothing
signalled a problem. `HubClientError` already produces good `errorDescription` strings that are
computed and then thrown away.

**Fix.** Have `ModelCardView` observe the most-recent record for its model (not just the active
one) and render a red "Failed — <reason>" row with Retry, or toast from the MLX store when a
record transitions to `.failed`. Binding `MLXModelService.errorMessage` to a visible alert in
`MLXModelStoreContent` is the minimum.

---

### A13. Deleting a model is not blocked while it is loaded, does not notify `MLXService`, and a failed delete is silent and unlogged

**P1** · [unverified] · reported by 3 of 6 auditors ·
[MLXModelService.swift:489](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:489)

```swift
func deleteModel(_ item: MLXModelItem) {
    do {
        try FileManager.default.removeItem(at: item.localPath)
        forceRefreshInstalledModels()
    } catch {
        self.errorMessage = "Failed to delete: \(error.localizedDescription)"
    }
}
```

**What's wrong.** Eight lines, four defects. (1) No in-use guard: `MLXService` holds the live
container keyed by `currentModelDirectory` and refuses unload while `activeGenerations > 0`
([MLXService.swift:142](Devgentic/Core/Service/MLXService.swift:142)), yet this removes the
directory unconditionally — no `unloadModel()`, no `activeGenerations` check, no
`IntelligenceCoreService.unloadNow()`. (2) `currentModelDirectory` / `lastModelDirectory` keep
pointing at the removed path. (3) The `.completed` `DownloadRecord` is left claiming the model is
on disk, and no BackendProfile whose `selectedModel` names it is repaired. (4) The catch writes
only to `errorMessage`, which no view observes, and emits no `logger.error` — and there is no
success log either, so a support bundle cannot even show that a model was removed. The empty
author directory is also left behind.

**Impact.** Repro A: start a chat on model X, leave it mid-generation, delete X from the
Installed tab. Files are unlinked under the running container; MLX mmaps the safetensors so
several GB stay resident with no affordance to free them until the 2-minute idle timer fires.
When it does fire and the user resumes, `streamChat`'s lazy reload
([MLXService.swift:271](Devgentic/Core/Service/MLXService.swift:271)) calls `loadModel` on a
directory that no longer exists; it throws and the user gets the generic "No MLX model is
currently loaded. Please load a model first." with nothing in the log connecting it to the
deletion. Repro B: delete a model whose folder is permission-denied — the card stays on screen
(no refresh on the failure branch), the user re-taps Delete, and nothing ever says it failed.
The confirmation alert says only "This will permanently remove the files from your disk"; it
never mentions the model is loaded or selected by a profile.

**Fix.** Before removing: compare `item.localPath` against the loaded model and refuse (or
`await unloadModel()`) when it matches; refuse with a toast when `activeGenerations > 0`; clear
`lastModelDirectory` so the lazy reload cannot resurrect a deleted path. Mark or delete the
matching `DownloadRecord` via `fetchMostRecent(backend:modelIdentifier:)`. Extend the alert to
name affected profiles. Log entry/exit with model id, path and reclaimed bytes, and pair the
catch with a `logger.error` naming the consequence. Remove the parent author directory when
empty. Also log the case where `MLXModelStoreViewModel.deleteModel`'s `first(where:)` lookup
misses and the delete silently no-ops.

---

### A14. `MLXService` has no model identity — a lazy reload can silently run inference on a different model than the profile configured

**P1** · [unverified] ·
[MLXService.swift:271](Devgentic/Core/Service/MLXService.swift:271)

```swift
if modelContainer == nil, lastModelDirectory != nil {
    _ = await reloadCurrentModel()
}
guard let container = modelContainer else {
```

**What's wrong.** `streamChat`/`streamVisionChat` take no model identifier. `MLXLLMProvider`
knows `modelName` but never passes it, and nothing verifies that `currentModelDirectory`
corresponds to the provider that is generating. `lastModelDirectory` is a single global slot
holding whatever model was loaded most recently by ANY caller, and `reloadCurrentModel()`
reloads that slot unconditionally. The load coalescing at :81-89 dedupes only loads of the
*same* directory; concurrent loads of different directories serialize last-writer-wins with no
reference counting.

**Impact.** [WorkflowExecutor.swift:474](Devgentic/Core/Service/WorkflowExecutor.swift:474) runs
independent profile nodes in parallel via `withTaskGroup`. Branch A is an agent node on MLX
model X; branch B is an AI Classifier node on model Y. A runs one ReAct iteration then executes
a tool, so `activeGenerations` is back to 0. B calls `loadModel(from: Y)`, which force-unloads X
and sets `lastModelDirectory = Y`, then `unloadModel()` nils the container. A's next iteration
sees `modelContainer == nil` with `lastModelDirectory == Y` and reloads Y. **Branch A now
produces its answer from the classifier's model.** The only log is the misleading "♻️ Reloading
model from: Y (idle-timer recovery)". No error, no user-visible signal — the workflow output is
simply wrong. The same substitution can happen on the HITL-resume path in
`ReActAgentExecutor.swift:592`.

**Fix.** Thread the expected model directory (or `modelName`) into `streamChat`,
`streamVisionChat` and `reloadCurrentModel(expecting:)`. On mismatch, log
`[MLX] model identity mismatch: request expects <X>, container holds <Y> — refusing to generate`
and either reload the correct model or throw, rather than generating from whatever is resident.

---

### A15. The installed-model rescan does a 76 GB recursive walk plus 9 file reads per model, synchronously on the MainActor, from the request path

**P1** · [unverified] ·
[MLXModelService.swift:70](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:70)

```swift
private func rebuildProfileCache() {
    profileCache.removeAll(keepingCapacity: true)
    for model in installedModels {
        let profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: model.localPath, modelName: model.displayName)
        profileCache[model.displayName] = profile
    }
```

**What's wrong.** `MLXModelService` is `@Observable @MainActor`, so both `refreshInstalledModels()`
and `rebuildProfileCache()` run on the main thread. The former runs a recursive
`FileManager.enumerator` over the whole models directory plus a `contentsOfDirectory` per
`config.json`. The latter runs `detectCognitiveProfile` per model, which performs **nine**
synchronous `Data(contentsOf:)` reads and nine `JSONSerialization` parses each: config.json 3×
(`MLXTokenizerAnalyzer.swift:154`, :77 via `detectContextWindow`, :61 via
`detectVisionModalities`), tokenizer_config.json 2× (:196, :530), special_tokens_map.json 2×
(:168, :501), added_tokens.json 2× (:182, :476). Measured here: 18 models, 410 entries walked,
76 GB directory — **162 blocking reads and 162 JSON parses on the main thread**.

**Impact.** All three runtime consumers invoke this from inside `await MainActor.run { … }` **on
the request path**, all shaped `if installedModels.isEmpty { refreshInstalledModels() }`:
[AgentConnect.swift:1125](Devgentic/Core/Backends/AgentConnect.swift:1125),
[IntelligenceCoreService.swift:67](Devgentic/Core/Service/IntelligenceCoreService.swift:67),
[WorkflowExecutor.swift:1885](Devgentic/Core/Service/WorkflowExecutor.swift:1885). Launch with a
cold page cache and send the first message to an MLX agent profile: the UI freezes for the
duration. It also runs at `init()`, i.e. during app launch. Nothing in the logs attributes the
hang — the only trace is a `.debug` "Profile cache rebuilt for N model(s)." with no elapsed time.

**Fix.** Move the scan and per-model analysis off the MainActor: a `nonisolated` async scan that
hands back a finished `[MLXModelItem]` + profile map to assign on the main actor. Inside
`detectCognitiveProfile`, read each of the four files **once** and pass the parsed JSON down to
`detectCapabilityAndDialect`, `detectContextWindow`, `detectVisionModalities` and
`extractStopSequences` — 9 reads → 4. Log elapsed wall time and file count at `.notice` so a
field hang is attributable.

---

### A16. `DownloadManager.activeRecords` is a computed SwiftData fetch that registers no observation — the Downloads badge never updates

**P1** · [unverified] ·
[DownloadManager.swift:58](Devgentic/Core/Service/DownloadManager.swift:58)

```swift
var activeRecords: [DownloadRecord] {
    DownloadHistoryStore.shared.fetchActive()
}

var hasActiveDownloads: Bool { !activeRecords.isEmpty }
var activeCount: Int { activeRecords.count }
```

**What's wrong.** `DownloadManager` is `@Observable`, but the macro only instruments **stored**
properties. `activeRecords` touches no stored property of `self` — it calls into
`DownloadHistoryStore` (a plain `@MainActor final class`, not `@Observable`) which runs
`context.fetch(descriptor)` and returns an array without reading any property of any
`DownloadRecord`. Inside SwiftUI's `withObservationTracking` around a view body, nothing is
registered, so no invalidation ever fires. `ActivityBarButton` reads exactly this
([ActivityBar.swift:119](Devgentic/Interfaces/Main/Views/ActivityBar.swift:119)) and reads no
other observable state on that path.

**Impact.** Start an MLX/Ollama/Whisper download and the activity-bar badge does not appear. It
flips only when the button's body happens to re-run for an unrelated reason — hovering it
(`@State isHovering`) or switching tabs — then goes stale again. The reverse too: the badge
persists after the last download finishes until the user hovers. `DownloadSidebarView` uses
`@Query` and *is* reactive, so the sidebar list and the badge visibly disagree. Secondary: each
accessor runs an independent predicated main-thread fetch, so reading `hasActiveDownloads` and
`activeCount` together costs two full-table predicate scans per body evaluation.

**Fix.** Store the count: maintain `private(set) var activeCount` / `activeRecordIDs` on
`DownloadManager`, updated from the same bridge points that already write
`activeRecordIDsByKey` (which IS a stored observable property and is used correctly by
`activeRecord(backend:modelIdentifier:)` at :215). Derive `hasActiveDownloads` from
`!activeRecordIDsByKey.isEmpty`, and demote `activeRecords` to an explicit non-observable lookup
*method* so callers cannot mistake it for reactive state.

---

### A17. `isInstalled()` substring match falsely marks un-downloaded models as "Installed", hiding the Download button entirely

**P1** · [unverified] ·
[MLXModelStoreViewModel.swift:364](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:364)

```swift
func isInstalled(_ model: MLXDisplayModel) -> Bool {
    return service.installedModels.contains { installed in
        installed.displayName == model.id || installed.displayName.contains(model.displayName)
    }
}
```

**What's wrong.** `installed.displayName` is the full repo path; `model.displayName` is
`id.components(separatedBy: "/").last`, i.e. the bare name with the org stripped. `contains`
therefore returns true for ANY installed model whose name has the candidate as a substring —
different org, different quantization, any suffixed variant.

**Impact.** User has `mlx-community/Qwen2.5-7B-Instruct-4bit-DWQ` installed. The store lists the
distinct, more common `mlx-community/Qwen2.5-7B-Instruct-4bit`;
`"…-4bit-DWQ".contains("Qwen2.5-7B-Instruct-4bit")` is true, so `isInstalled` is true. In
[MLXModelStoreView.swift:391-420](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:391)
the `ModelDownloadStatusView` — the only Download affordance — renders exclusively in the `else`
branch, so the card shows a green "Installed" capsule and **there is no way to download that
model at all**. Same false positive for `Llama-3.2-3B-Instruct` against an installed
`…-3B-Instruct-4bit`, and cross-org. It also mislabels the Installed tab, where `deleteModel`
uses strict `==` and therefore silently no-ops on the same card.

**Fix.** Compare canonical repo ids:
`installed.displayName.caseInsensitiveCompare(model.id) == .orderedSame`. If a bare-name
fallback is genuinely needed for legacy layouts, require a full path-component match, never
`contains`, and log a warning with both ids whenever the fallback branch is what produced the
match. Share the comparator with `DownloadCoordinator` (A3).

---

### A18. The tool-capability heuristic hard-filters the Agent Model Store — classification enforces instead of describing

**P1** · [unverified] · ⚠️ violates the standing project directive ·
[MLXModelStoreViewModel.swift:297](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:297)

```swift
// Apply hard filter if we only want tool models
if filterForTools {
    sourceModels = sourceModels.filter { $0.capabilities.contains(.toolUse) }
}
```

**What's wrong.** Three enforcement points stack on top of a name-matching heuristic
(`classifyCapabilities`, substring matching over the model id). (a) This filter removes
installed models from the Installed tab. (b) `availableCategories` (:109-115) returns only
`[.installed, .toolUse]` when `filterForTools`, deleting the "All" tab so there is no browse
path to a model the heuristic did not tag. (c)
[MLXModelPickerView.swift:46](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelPickerView.swift:46)
filters the picker itself. This contradicts the standing rule that classification metadata may
label or group but must never gate an action, and it contradicts the picker's own documented
intent at :22 — *"If true, incompatible models will be disabled/dimmed"* — the code deletes them.

**Impact.** A user downloads a genuinely tool-capable MLX model whose id the heuristic misses
(any newly-released family, a re-quantized community upload, a personal fine-tune). In an Agent
profile the model is absent from the picker, absent from the Installed tab of the Agent Model
Store, and there is no All tab to find it in — so it cannot be selected or downloaded through the
UI at all. The only recourse is switching the profile to Bot. **A heuristic false negative
becomes a hard product lockout with no override.**

**Fix.** Keep the classification visual: render non-tool models dimmed with a "May not support
tools" badge and keep them selectable and downloadable — the picker's existing
`showUnsupportedAlert` (:81-85) is the correct describe-and-warn shape. Restore `.all` when
`filterForTools`. If any filtering remains, make it a user-toggleable "Show tool-capable only"
switch defaulting on.

---

### A19. Locale decimal separator corrupts size parsing 10×, producing a spurious "Model Too Large" gate

**P1** · [unverified] ·
[MLXModelStoreViewModel.swift:348](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:348)

```swift
let numberString = normalized.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
let value = Double(numberString) ?? 0
```

**What's wrong.** The size string is produced by `ByteCountFormatter`
([MLXModelService.swift:345](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:345)),
which is locale-aware and emits "," as the decimal separator in de/fr/es/it/pt and most of
Europe. The allowed character set keeps only ASCII digits and "." so the separator is
**stripped, not converted**: "2,4 GB" → "24". `ModelFitAdvisor.parseDiskSize`
([ModelFitAdvisor.swift:339](Devgentic/Core/Utils/ModelFitAdvisor.swift:339)) has the identical
bug, and `Double(_:)` is locale-invariant so it would fail on a comma anyway.

**Impact.** On a German Mac a 2.4 GB model parses as 24 GB. (1) "Size (Smallest)" puts 2.4 GB
models below 9 GB ones. (2) Worse, `ModelCardView.fitAssessment` feeds `model.size` into
`ModelFitAdvisor.assess`; 24 GB × 1.2 blows past `effectiveBudget` on any 16/24 GB Mac, yielding
`.incompatible`, so `onDownloadRequested` diverts the user into the "Model Too Large" advisory
sheet instead of downloading. A perfectly compatible 2.4 GB model is gated behind a scary modal
in every comma-decimal locale — capability metadata blocking an action on a number the code
itself corrupted.

**Fix.** Stop round-tripping a formatted string. Carry the raw `Int64` byte total on
`MLXDisplayModel` alongside the display string (it is already computed at
MLXModelService.swift:343 and already exposed by `getTotalBytesForModel`) and sort/assess on the
number. If a string parse must remain, normalize the locale separator to "." before
`Double(_:)`.

---

### A20. The Installed-tab search field is inert — its filter branch is gated on a flag that is never set false

**P1** · [unverified] ·
[MLXModelStoreViewModel.swift:317](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:317)

```swift
if !query.isEmpty && !isRemoteSearchEnabled {
    sourceModels = sourceModels.filter { model in
        model.displayName.localizedCaseInsensitiveContains(query) ||
```

**What's wrong.** `isRemoteSearchEnabled` is declared `= true` at :38 and a repo-wide grep finds
only reads (:24, :192, :228, :317) plus the declaration — no UI control, no settings key,
nothing assigns it. It is permanently true, so this entire local-filter branch is dead code. The
Installed tab is the casualty: `refreshCategoryData` routes `.installed` to the local path and
`filterAndSortModels` builds `sourceModels` from `local` but then skips the query filter. The
remote path is unaffected because it passes `searchText` to HF — but there is no HF query for
locally-installed models.

**Impact.** The placeholder literally reads "Filter installed models…"
([MLXModelStoreView.swift:97](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:97))
and typing into it changes nothing; a user with 25 downloaded models cannot narrow the list at
all. Each keystroke still runs the full 500 ms debounce and calls `refreshCategoryData`, which
invokes `refreshInstalledModels()` and re-runs `applyFilterAndSort` over every installed model
for a result guaranteed identical to the unfiltered list.

**Fix.** Filter installed models on `query` unconditionally when `category == .installed` — the
remote-vs-local distinction is meaningless there. Then wire `isRemoteSearchEnabled` to a real
toggle or delete it and its three remaining reads.

---

### A21. "Recent" sort scrambles the remote list because every remote `MLXDisplayModel` has `createdAt == nil`

**P1** · [unverified] ·
[MLXModelStoreViewModel.swift:330](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:330)

```swift
case .recent:
    sourceModels.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
```

**What's wrong.** `createdAt` is populated only for locally-scanned models. The remote mapper
(MLXModelService.swift:233-241) never passes it, and `HFRawModel` does not even decode a date
field. For every remote model the comparator degenerates to `.distantPast > .distantPast` ==
false for all pairs, and Swift's `sort` is introsort — **not stable** — so an all-equal-keys
sort permutes the array arbitrarily. The user is put into this state without asking:
`refreshCategoryData` force-switches `if sortOption == .popularity { sortOption = .recent }` when
the Installed tab opens (:183) and never restores it.

**Impact.** Open the store (All + Popularity, correctly ordered because the HF query itself is
`sort=downloads&direction=-1`). Tap Installed — sort silently flips to Recent. Tap All — the 30
HF results come back in arbitrary order with the sort menu confidently reading "Recent", and
reshuffle again on each of the ~30 size-update ticks (B15), so cards visibly jump under the
cursor. "Recent" is a non-functional sort option for the entire remote store.

**Fix.** Decode HF's `lastModified`/`createdAt` into `HFRawModel` and populate it in the remote
mapper. Until then, hide `.recent` from `SortOption.allCases` for non-installed categories, make
the comparator stable (tie-break on `downloads` then `id`), and restore the user's prior sort
when leaving the Installed tab.

---

### A22. An HF fetch failure is invisible, and the grid silently re-renders stale models from the previous category

**P1** · [unverified] ·
[MLXModelService.swift:265](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:265)

```swift
} catch {
    logger.error("HF fetch failed: \(error.localizedDescription) (url=\(url.absoluteString))")
    await MainActor.run { self.isLoadingRemoteModels = false }
}
```

**What's wrong.** The catch neither sets `errorMessage` nor clears `availableModels`. Flipping
`isLoadingRemoteModels` fires the view model's ObservationStream → `applyFilterAndSort()` →
`displayedModels` is rebuilt from the **stale** `availableModels` left over from the previous
category or query.

**Impact.** Browse All (30 models load), pull the network, tap Coding. `refreshCategoryData`
clears `displayedModels`, the fetch throws, and the observer refills `displayedModels` by
filtering the OLD All payload for `.coding` — the user sees a plausible-looking but stale list
with zero indication that the network failed and zero indication these are not Coding results.
If `availableModels` happened to be empty they instead get the generic "No models found" + "Try
Reloading", indistinguishable from a genuinely empty search, whose button re-runs the same
failing request. A pre-release app shipped outside the App Store has no telemetry backstop here;
the user's only signal is a log line they will never see.

**Fix.** Set `errorMessage` in the catch with URL and localized error, surface it in
`MLXModelStoreContent`'s ZStack as a dedicated error state (icon + message + Retry) distinct
from the empty state, and clear it at the top of every `fetchRemoteModels`. Track the category
`availableModels` was fetched for and treat a mismatch as empty rather than repopulating from a
different category's payload.

---

### A23. The Download button is hover-gated with hit-testing disabled — there is no pointer-free path to the store's primary action

**P1** · [unverified] ·
[MLXModelStoreView.swift:494](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:494)

```swift
private var showActionsOverlay: Bool {
    isHovered || isInstalled
}
...
.overlay(alignment: .topTrailing) {
    actionsView
        .opacity(showActionsOverlay ? 1 : 0)
        .allowsHitTesting(showActionsOverlay)
        .animation(.easeOut(duration: 0.15), value: showActionsOverlay)
}
```

**What's wrong.** For a not-yet-installed remote model — the overwhelmingly common case in a
model store — `isInstalled` is false, so the entire `actionsView` (containing the only
`ModelDownloadStatusView` Download button) renders at `opacity(0)` with
`allowsHitTesting(false)` until the pointer physically enters the card. There is no
`.focusable`, no keyboard equivalent, no context menu, and no double-click on the card body.
`.opacity(0)` does not remove the subtree from the accessibility tree, so VoiceOver may announce
a "Download" button that is invisible and, via `allowsHitTesting(false)`, not activatable.

**Impact.** Navigate the MLX Model Library with Full Keyboard Access or VoiceOver and nothing
can be downloaded. Every card looks like a static, non-interactive tile with no visible
affordance indicating a download is even possible. This is the single primary action of the
subsystem, discoverable only by mouse hover.

**Fix.** Keep the Download button permanently visible — it already has a `.help` and
`.accessibilityLabel` at ModelDownloadStatusView.swift:130-131, they are just unreachable — and
reserve hover-reveal for genuinely secondary actions. At minimum drive visibility from
`isHovered || isInstalled || isFocused` with `@FocusState`, and never pair `opacity(0)` with
`allowsHitTesting(false)` on an element still in the AX tree; use conditional rendering so it is
consistently absent or consistently present.

---

## P2

### B1. MLX generation streams have no cancellation propagation — Stop leaves the GPU decoding and blocks unload until the idle timer

**P2** · ✅ adversarially verified (filed P0, corrected to P2) ·
[MLXService.swift:263](Devgentic/Core/Service/MLXService.swift:263)

```swift
return AsyncThrowingStream { continuation in
    Task {
        activeGenerations += 1
        defer { activeGenerations -= 1 }
```

**What's wrong.** Neither `streamChat` (:263) nor `streamVisionChat` (:517) sets
`continuation.onTermination`, and all three producer Tasks (including
`MLXLLMProvider.streamWithUsage:181`) **discard their handle**, so there is no cancellation path
even in principle. `consumeGenerationStream`'s `for await generation in stream` (:408) breaks
only on `stopDetected`, never on `Task.isCancelled`, so a non-throwing `AsyncStream` would not
surface cancellation anyway. This is an asymmetry, not a style choice: 14 `onTermination` sites
exist in this codebase (`ChatExecutor.swift:292`, `AgentConnect.swift:812`,
`ReActAgentExecutor.swift:1422`, `WorkflowExecutor.swift:607`, `PlanningCapability.swift:527`,
`SelfReflectionCapability.swift:439`, `ImageGenExecutor.swift:131`, …) and neither MLX file
appears. The vendored library *would* stop early — `MLXLMCommon/Evaluate.swift:1689-1719` breaks
on `Task.isCancelled` and on a terminated yield — but neither trigger can fire.

**Impact.** Pressing Stop mid-generation unwinds the consumer while the model keeps decoding on
the GPU until EOS, a stop sequence, the circuit breaker, or `maxTokens` (default 2048),
discarding every token. For that window `activeGenerations > 0`, so `unloadModel()` refuses at
[ConversationSwitchCoordinator.swift:146](Devgentic/Core/Service/ConversationSwitchCoordinator.swift:146),
[BackendOrchestrationService.swift:66](Devgentic/Core/Service/BackendOrchestrationService.swift:66)
and [AppDelegate.swift:231](Devgentic/AppDelegate.swift:231), logging only "Refusing model
unload — N generation(s) in flight" with no indication the generation is abandoned. The
practical costs: wasted GPU/battery/thermals for up to one full generation after an explicit
Stop; the user's next message decoding **concurrently with the orphan** on the same GPU at
roughly half token rate; and if a different MLX model is loaded inside that window,
`loadModel`'s forced `performUnload()` swaps the container while the orphan still holds a strong
reference to the old one, briefly making two models resident. **Bounded and self-healing** —
`defer { activeGenerations -= 1 }` always runs and `startIdleTimer()` fires at the end of the
same Task, so the model unloads on the 2-minute idle path.

**Fix.** In both `streamChat` and `streamVisionChat`, capture the producer task and set
`continuation.onTermination = { @Sendable _ in task.cancel() }`, matching the 14 existing sites.
Add `if Task.isCancelled { logger.notice("[MLX] generation cancelled by consumer at N chunks — releasing container"); break }`
inside `consumeGenerationStream`'s loop. Log at `unloadModel`'s refusal which caller holds the
lease so the zombie is traceable.

---

### B2. `DownloadManager` has zero logging — every terminal classification decision is invisible in the field

**P2** · [unverified] ·
[DownloadManager.swift:369](Devgentic/Core/Service/DownloadManager.swift:369)

```swift
if let err = errorMessage, !err.isEmpty {
    _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
} else if isInstalledNow || progress >= 0.99 {
    _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
} else {
    _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
}
```

**What's wrong.** The file contains no `DGLogger`/`logger` reference at all, yet it is where
every download's final status is *decided* from three fuzzy inputs. All four store calls discard
their `Result` with `_ =`, so a `.notFound`/`.saveFailed` is dropped silently.
`cancelDownload(_:)` at :135 (`guard let backend = record.backend else { return }`) and
`preSeedTotalBytes` at :124 are unlogged early returns, as is the nil-`mlxActiveID` progress
drop from A4.

**Impact.** When a user reports "my download shows Failed but it worked" (A5) or "my second
download never appeared" (A4), the log contains only `DownloadHistoryStore`'s "Failed download
record id=<uuid>" with no repo id, no branch inputs, and no indication a tick was dropped. The
subsystem is not field-debuggable from logs alone, which the project standard requires.

**Fix.** Add `DGLogger(category: "DownloadManager")` with a `[DOWNLOAD]` bracket tag and the
record UUID as correlation id. Log record creation (backend, identifier, pre-seeded bytes or
"none"); the terminal branch chosen together with all three inputs; every discarded `Result`
failure with its consequence; and each of the three silent early returns.

---

### B3. `DownloadCoordinator` reports `.startedFresh` when `OllamaService` silently refuses a concurrent pull

**P2** · [unverified] ·
[DownloadCoordinator.swift:93](Devgentic/Core/Service/DownloadCoordinator.swift:93)

```swift
// OllamaService.pullModel is async; fire-and-forget so callers get
// the outcome synchronously. Progress flows via @Observable state.
Task { await ollama.pullModel(name: trimmed, baseURL: ollama.ollamaBaseURL) }
return outcomeForHistory
```

**What's wrong.** `outcomeForHistory` is computed before the pull is attempted and the `Task`
result is never inspected. `OllamaService.pullModel` begins with
`guard !isPullingModel else { return }` (`OllamaService.swift:317`) — an unlogged silent return.
The coordinator's own in-flight check (:77-82) is scoped to the *same* identifier, so pulling B
while A is pulling passes it and then hits the service guard.

**Impact.** The user is pulling A, clicks Download on B, and `triggerDownload` receives
`.startedFresh` and shows "Downloading B…". Nothing happens: no pull, no `DownloadRecord`, no
sidebar row, no error, and no log line explaining the refusal. The same shape applies to the
`isRemovingModel` and `serverStatus == .disconnected` guards, whose `modelPullError` the
coordinator never returns to the caller either.

**Fix.** Make `pullModel` return a discardable success/failure (or check `ollama.isPullingModel`
in the coordinator before dispatching) and map a refusal to
`DownloadStartOutcome.failed("Already pulling <model>")`. Log the refusal naming both the
requested and in-flight model plus the consequence.

---

### B4. The MLX progress closure spawns an unstructured Task per tick with no staleness guard

**P2** · [unverified] ·
[MLXModelService.swift:393](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:393)

```swift
_ = try await hub.snapshot(from: repoId) { progress in
    Task { @MainActor in
        self.downloadProgress = progress.fractionCompleted
    }
}
```

**What's wrong.** Every callback allocates a fresh unstructured `Task`, captures `self` strongly,
and performs no staleness check. These Tasks are not children of `downloadTask`, so cancelling
the download does not cancel them, and there is no ordering guarantee between independently
enqueued MainActor Tasks. `WhisperModelDownloadService.swift:167-169` does it correctly:
`Task { @MainActor [weak self] in guard let self, self.isDownloading else { return }`.

**Impact.** After a cancel, `cancelDownload`'s cleanup sets `downloadProgress = 0.0` but Tasks
queued before the cancel can land afterwards and write a stale non-zero fraction back, leaving
the MLX banner and `ModelDownloadStatusView` showing e.g. "43%" with `isDownloading == false`.
During a large pull it also churns a Task allocation per chunk on the MainActor queue for the
whole download.

**Fix.** Mirror the Whisper shape with a weak capture plus
`guard self.isDownloading, self.currentDownloadName == repoId`. Coalesce with a fraction-delta
check (the same 1% rule `ProgressThrottler` already uses) so the closure only hops when the
displayed value would change.

---

### B5. `isLoadingRemoteModels` is a bare `Bool`, not a counter — concurrent fetches clear it early and it lies during `fetchSizes`

**P2** · [unverified] ·
[MLXModelService.swift:260](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:260)

```swift
self.isLoadingRemoteModels = false
}

await fetchSizes(for: displayModels.map { $0.id })
```

**What's wrong.** Set true at :199 and false at :260/:267 with no reference count, while nothing
prevents concurrent `fetchRemoteModels` calls (A11). It is also cleared **before** the
30-request `fetchSizes` fan-out at :263, so it reports idle while the page is still visibly
filling in sizes.

**Impact.** With two fetches in flight, the first to finish clears the flag: the store's
`isLoading && displayedModels.isEmpty` branch drops its spinner and falls through to "No models
found" for the duration of the second request, then abruptly repopulates. The Load More button's
`.disabled(viewModel.isLoading)` guard re-enables mid-flight, letting the user stack a third
overlapping request that lands out of order. Clearing before `fetchSizes` also hides the real
cost of the fan-out from anyone watching the UI.

**Fix.** Replace with an integer in-flight counter
(`isLoadingRemoteModels = inFlightFetches > 0`) and decrement only after `fetchSizes` returns.

---

### B6. `getSizeForModel` has two silent return paths with zero logging

**P2** · [unverified] ·
[MLXModelService.swift:338](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:338)

```swift
guard let url = URL(string: urlString) else { return (repoId, nil) }

do {
    let (data, _) = try await URLSession.shared.data(from: url)
```

**What's wrong.** Both exits — the URL guard at :338 and the catch at :350 — return
`(repoId, nil)` without emitting anything. The asymmetry is inside this same file: the
near-identical `getTotalBytesForModel` *does* log its failure at :370, so the same failure is
observable when it happens for the ETA denominator and invisible when it happens for the store
card. The URL guard is reachable in practice: `repoId` is interpolated into the path at :337
with no percent-encoding, so ids with spaces or non-ASCII fail `URL(string:)`.

**Impact.** A rate-limited page produces zero log output. The maintainer sees a store with no
sizes, no fit badges and no size sorting, with nothing indicating that 30 requests were issued
and 30 rejected — the exact scenario the logging standard exists to prevent.

**Fix.** Log both paths with a bracket tag, the repo id and the consequence, mirroring the
wording already used at :370. Percent-encode `repoId` into the path while there.

---

### B7. `.urlQueryAllowed` is the wrong character set for a query-parameter value — search text is injected into the URL

**P2** · [unverified] ·
[MLXModelService.swift:213](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:213)

```swift
let encodedSearch = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
urlString += "&search=\(encodedSearch)"
```

**What's wrong.** `.urlQueryAllowed` describes a whole query **string**, not one parameter
**value** — it deliberately leaves `&`, `=`, `+`, `?`, `/`, `:`, `;`, `,` unescaped (verified:
`CharacterSet.urlQueryAllowed.contains("&") == true`, same for `=`, `+`, `?`). The whole URL is
assembled by string concatenation; `URLComponents`/`queryItems` appears nowhere in this file.

**Impact.** Two reproducible breakages. (1) Searching `c++` — an ordinary query for a coder
model — produces `&search=c++`; HF decodes `+` as a space in a form-urlencoded query, so the
backend searches for `c  ` and returns unrelated models. (2) Searching `qwen&limit=1000` yields
a second `limit` parameter that overrides the app's pagination, so `skip`/`limit` no longer
correspond to what `currentPage` believes and Load More silently returns overlapping or empty
pages. Verified: input `qwen & limit=1000#x+y` produces `search=qwen%20&%20limit=1000%23x+y`,
i.e. a real extra query parameter, and `URL(string:)` accepts it without complaint.

**Fix.** Build the request with `URLComponents` + `URLQueryItem(name: "search", value: search)`,
which encodes each value correctly including `+`. If concatenation must stay, use
`CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))`.

---

### B8. No timeout, retry or backoff on any HuggingFace call — the store can hang on the URLSession default

**P2** · [unverified] ·
[MLXModelService.swift:341](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:341)

```swift
let (data, _) = try await URLSession.shared.data(from: url)
let detail = try JSONDecoder().decode(HFModelDetail.self, from: data)
```

**What's wrong.** All three HF calls use `URLSession.shared.data(from:)` with stock
configuration — 60 s request timeout, 7-day resource timeout, no retry, no backoff, no
`Retry-After` handling, and no ETag/If-None-Match even though the list endpoint's top-30
response is highly cacheable. Every other network client here sets an explicit timeout:
`AnthropicService.swift:28` (15 s), `OpenRouterService.swift:74`,
`OpenAICompatibleService.swift:40`, `OllamaConnect.swift:527-529` (a full
`URLSessionConfiguration` with 300 s/1800 s bounds). The MLX store is the outlier.

**Impact.** On captive-portal Wi-Fi or a half-open TCP connection the spinner sits for up to 60 s
per request with no cancel affordance, and because of B5 a second stalled request extends the
dead time. Once HF returns 429 there is no backoff, so "Try Reloading" immediately re-issues 31
requests into the throttle. Re-opening the store re-downloads an identical list payload every
time because no caching validator is sent.

**Fix.** Build the requests as `URLRequest(url:timeoutInterval: 15)`, add one bounded retry with
jittered backoff honoring `Retry-After` on 429/503, and set `.useProtocolCachePolicy` so
URLSession's shared cache can revalidate the list endpoint.

---

### B9. Every `DownloadHistoryStore` read swallows its error and every write `Result` is discarded unlogged

**P2** · [unverified] ·
[DownloadHistoryStore.swift:215](Devgentic/Core/Persistence/SwiftData/DownloadHistoryStore.swift:215)

```swift
func fetchActive() -> [DownloadRecord] {
    guard let context = mainContext else { return [] }
    ...
    return (try? context.fetch(descriptor)) ?? []
}
```

**What's wrong.** All five read paths (:188, :198, :215, :231, :247) collapse both failure modes
— container not configured, and `fetch` throwing — into an empty result with zero log output.
The mutators return `.failure(.notFound(id))` (:115, :129, :141, :152, :163) with no log, and
every call site discards the `Result` with `_ =` (DownloadManager :193, :273, :289-293, :350,
:370-374, :440, :459-463). `configureContainer` is invoked from an async
`Task { @MainActor }` at [DevgenticApp.swift:63](Devgentic/DevgenticApp.swift:63) rather than
synchronously with the other stores, so `.containerUnavailable` is genuinely reachable.

**Impact.** A store that fails to open, or a predicate that throws, produces the exact same
observable behaviour as "the user has never downloaded anything" — the sidebar renders its "No
Downloads" empty state and the log contains not one line explaining why. If a download begins
before the container is wired, `startDownload` fails, the bridge still sets `mlxActiveID`, every
subsequent `updateProgress` and the terminal `markCompleted` return `.notFound` silently, and
the entire download never appears in history — unreproducible from logs alone.

**Fix.** Give every read a `catch` that logs `[DOWNLOAD-HISTORY]` + the descriptor's purpose +
"returning empty; UI will show no history", and log the `mainContext == nil` guard the same way.
Log `.notFound` inside the mutators with the record id and which transition was lost. At the
bridge call sites, replace `_ =` with an `if case .failure(let e)` that logs record id, backend
and model identifier.

---

### B10. The 30 s scan debounce makes the "Refresh Models" button a no-op; the code comment claims the window is <2 s

**P2** · [unverified] ·
[MLXModelService.swift:81](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:81)

```swift
private var lastScanTime: Date? = nil
private let scanDebounceInterval: TimeInterval = 30.0
```

**What's wrong.** `refreshInstalledModels` skips entirely when the previous scan was under 30 s
ago (:118-121), and the skip is reported only at `logger.debug`.
`MLXModelStoreViewModel.refreshCategoryData` documents the behaviour as *"if the last scan was
<2s ago"* (:186-189) — the comment is 15× off, and the workaround it describes
(`applyFilterAndSort()`) only re-filters the already-stale array. The measured cost does not
justify 30 s: on this machine's 76 GB / 18-model store the enumerate + completeness check takes
4.8-6.6 ms and `rebuildProfileCache` 9.5-17.5 ms.

**Impact.** The `arrow.clockwise` Refresh Models button
([MLXModelStoreView.swift:81](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:81)),
the second refresh trigger at :187, and `MLXModelPickerView`'s `.onAppear` scan all do nothing
for up to 30 s after any prior scan. A user who deletes or adds a model folder in Finder presses
Refresh and sees no change, with only a `.debug` line explaining why.

**Fix.** Fix the stale comment, drop the interval to ~2 s (justified by the 5-20 ms measured
cost), route the explicit Refresh button through `forceRefreshInstalledModels()`, and raise the
skip log to `.info` stating the consequence.

---

### B11. An unreadable or corrupt `config.json` is silently swallowed and reported as "no tool logic found" / text-only

**P2** · [unverified] ·
[MLXTokenizerAnalyzer.swift:59](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXTokenizerAnalyzer.swift:59)

```swift
private static func detectVisionModalities(for modelPath: URL) -> SupportedModalities {
    let configURL = modelPath.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modelType = (json["model_type"] as? String)?.lowercased() else {
        return .textOnly
    }
```

**What's wrong.** Both `detectVisionModalities` (:59) and the config read in
`detectCapabilityAndDialect` (:154) use `try?` and fall through with no log. The consolidated log
at :329 then reports `detectionReason` = "No tool logic found in config, tokens, or template"
(:275) — a **positive claim that the files were read and contained nothing**, which is false
when the read itself failed. The sibling `detectContextWindow` logs its miss correctly at :362.

**Impact.** Truncate or chmod-000 a model's config.json (partial download, disk corruption, an
unexpected config shape) and the model is classified `capability = .none`,
`dialect = .heuristicJson`, `modalities = .textOnly`. A genuinely vision-capable model silently
loses `.visionInput`, so the orchestrator's degrade path strips the user's attached images with
no explanation; a tool-capable model silently loses tool calling. And the logs positively assert
the config contained no tool logic, sending the investigation in the wrong direction.

**Fix.** Split the guard and log the read/parse failure distinctly from "file parsed but no
`model_type`", naming the consequence (vision input stripped, tool calling disabled). Change
`detectionReason` at :275 to distinguish "files read, no tool logic" from "files could not be
read".

---

### B12. An IC context-window lookup miss silently degrades the compaction budget to 4096 with no log

**P2** · [unverified] ·
[HistoryCompactionService.swift:357](Devgentic/Core/Service/HistoryCompactionService.swift:357)

```swift
guard let model = MLXModelService.shared.installedModels.first(where: { $0.displayName == selectedModelName }) else {
    return 4096
}
```

**What's wrong.** Of the four `installedModels` lookup sites, three surface the miss
(`AgentConnect.swift:1130` throws a 404, `IntelligenceCoreService.swift:110` logs
`[IC Load] REJECTED — Model '<name>' not found on disk` then throws,
`WorkflowExecutor.swift:1888` throws `nodeExecutionFailed`). This one silently substitutes 4096
with no logger call — a silent early return, which the project standard prohibits. It also does
not call `refreshInstalledModels()` first, unlike the other three, so a stale empty list
produces the same silent fallback. Note this is also reachable via A3: a non-`mlx-community` IC
model never matches by `displayName`.

**Impact.** Select a 131K-context model as the Intelligence Core, then delete it (or rename it
outside the app). Compaction now believes the IC window is 4096 and compacts far more
aggressively — the user sees checkpoints created constantly and history disappearing, with
nothing in the logs tying it to the missing model. `resolveICContextWindow` feeds every
compaction budget decision downstream.

**Fix.** Log the miss with its consequence before returning, and call `refreshInstalledModels()`
first so a stale list is not mistaken for a deleted model.

---

### B13. Nothing checks or logs memory headroom at MLX load time; `ModelFitAdvisor.assessDualModel` has zero callers

**P2** · [unverified] ·
[ModelFitAdvisor.swift:115](Devgentic/Core/Utils/ModelFitAdvisor.swift:115)

```swift
/// Assess whether two models can coexist (e.g. agent model + Intelligence Core).
/// The `primary` model is assumed to be loaded; `secondary` briefly loads alongside it.
static func assessDualModel(
```

**What's wrong.** `assess` is called from five UI surfaces; `assessDualModel` has **no callers
anywhere** — the only grep hit is its own definition. Meanwhile `MLXService` (agent model) and
`IntelligenceCoreService` (IC model,
[IntelligenceCoreService.swift:37](Devgentic/Core/Service/IntelligenceCoreService.swift:37)) hold
completely independent containers with independent idle timers (2 min vs 60 s) and no shared
memory budget. `MLXService.loadModel` logs nothing about available RAM before loading — the only
memory line is `logMemoryStats(label: "Post-Load")` at `.debug`, emitted **after** the
allocation. No `MLX.GPU.set(cacheLimit:)` is configured anywhere.

**Impact.** Pick a 24B 3-bit agent model (~12 GB) on a 16 GB Mac and set an 8B model as the
Intelligence Core. A single turn loads both (RAG rewrite → agent generation → synthesis), the
machine swaps hard, and the only evidence in a support bundle is a `.debug` active/cache pair
after each load. Per the standing directive the advisor must not *gate* the load — but the
absence of any pre-load headroom line means a field report of "the app hangs my Mac" cannot be
diagnosed from logs at all.

**Fix.** Add a non-gating pre-load `.notice` in `MLXService.loadModel` and
`IntelligenceCoreService.load` using `ModelFitAdvisor.estimateRuntimeRAM`
(`estimated <X> vs effective budget <Y>, headroom <Z>, verdict <v>`), and wire `assessDualModel`
into the Core Intelligence picker so choosing an IC model shows the combined verdict against the
selected agent model. Describe, never block.

---

### B14. Duplicate display names silently drop a model from the installed list

**P2** · [unverified] ·
[MLXModelService.swift:172](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:172)

```swift
// Deduplicate
if !foundModels.contains(where: { $0.displayName == displayName }) {
    foundModels.append(MLXModelItem(id: displayName, displayName: displayName, localPath: modelDir, createdAt: createdAt))
}
```

**What's wrong.** A silent drop with no `else` and no logger call. Because the display name for
non-`mlx-community` orgs is only the bare folder name (A3), two different HF orgs shipping the
same model folder name collapse to one entry — and which one survives depends on
`FileManager.enumerator` ordering, which is not guaranteed stable.

**Impact.** Install `orgA/Llama-3.2-3B-Instruct-4bit` and `orgB/Llama-3.2-3B-Instruct-4bit`
(mirror re-uploads are common on HF; this library already contains mirror-style repos). One
becomes permanently invisible in the picker, the Installed tab, and every `installedModels`
lookup, while its multi-GB weights still occupy disk. No log line explains the disappearance, so
from the field this looks like "the download vanished".

**Fix.** Add an `else` logging both paths at `.error`, naming which was kept, which was hidden,
and that the hidden one is invisible in every picker and lookup. Fixing A3 removes most
collisions at the source; key the dedup on the full relative path.

---

### B15. `applyFilterAndSort()` re-runs on every unthrottled progress tick, and the state it maintains is consumed only by dead code

**P2** · [unverified] ·
[MLXModelStoreViewModel.swift:164](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:164)

```swift
onChange: { [weak self] in
    guard let self else { return }
    // Mirror state from service
    self.isLoading = self.service.isLoadingRemoteModels
    self.isDownloading = self.service.isDownloading
    self.downloadProgress = self.service.downloadProgress
    self.currentDownloadName = self.service.currentDownloadName
    self.applyFilterAndSort()
}
```

**What's wrong.** The `track` closure subscribes to `service.downloadProgress`, which is written
on every HubApi callback with no throttling (B4). Every tick triggers a full re-map, re-filter,
re-sort and a whole-array reassignment of `displayedModels`, invalidating the entire
`LazyVGrid`. The same happens ~30× during `fetchSizes`, which does one `await MainActor.run`
mutation per model. Critically, the three mirrored download properties are consumed by exactly
one view — `MLXModelStoreView.downloadBanner` (:240-285) — which is **never referenced
anywhere**; :233-235 documents that the global banner was intentionally removed. The churn
maintains dead state, and it runs app-wide, because `DestinationCoordinator.mlxStore` caches the
view model for the app's lifetime so the observer keeps firing when the store is off screen.

**Impact.** During one page load the grid is fully rebuilt ~30 times as sizes stream in — with
`.sizeSmallest`/`.sizeLargest` selected the cards visibly reorder on each tick, because
`isLoadingRemoteModels` is cleared before `fetchSizes` runs (B5) and the sort menu is re-enabled.
During a multi-GB pull, hundreds of progress callbacks per second each trigger a full
re-filter/re-sort/re-render of up to 30 cards, each card body recomputing
`ModelFitAdvisor.assess` (a `ByteCountFormatter` allocation) and a `DownloadHistoryStore` lookup
— sustained main-thread work for a banner that does not exist. The rest of the app pays it too.

**Fix.** Remove `downloadProgress`/`isDownloading`/`currentDownloadName` from the `track` closure
and delete the mirrored properties along with the dead `downloadBanner` — per-card progress
already comes from `DownloadManager.activeRecord`, throttled to 1% deltas by `ProgressThrottler`.
Track only `availableModels`, `installedModels` and `isLoadingRemoteModels`. Batch `fetchSizes`
into a single MainActor write after the task group drains.

---

### B16. The cancel-download progress circle is not a button: unreachable by VoiceOver/keyboard, and it leaks a pushed `NSCursor`

**P2** · [unverified] ·
[MLXUIComponents.swift:44](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXUIComponents.swift:44)

```swift
.contentShape(Circle())
.onTapGesture {
    onCancelRequested()
}
.onHover { hovering in
    withAnimation(.easeOut(duration: 0.12)) {
        isHovered = hovering
    }
    if hovering {
        NSCursor.pointingHand.push()
    } else {
        NSCursor.pop()
    }
}
```

**What's wrong.** (1) The control is a `ZStack` + `onTapGesture`, not a `Button`: no
`.accessibilityAddTraits(.isButton)`, no `.accessibilityLabel`, no `.accessibilityAction`, no
keyboard focusability. The only text it exposes is a bare "47%". (2) `NSCursor.push()`/`pop()` is
balanced only through the hover-exit callback, but this view is *designed* to be destroyed on a
state change: `ModelCardView.body` swaps `downloadingCard` for `standardCard` the moment
`activeDownloadRecord` goes nil, and `downloadingCard` swaps the circle for a `ProgressView`
when `isCancellingDownload` flips.

**Impact.** A VoiceOver user can hear that a download is at 47% but cannot cancel it from the MLX
card — the `ModelDownloadStatusView` path with its proper "Cancel download of …" label is not
used in the downloading layout. And hovering the circle until the download finishes tears the
view down while hovered, so `onHover(false)` never fires, `NSCursor.pop()` is never called, and
the pointing-hand cursor stays pushed on the cursor stack for the whole window. Every completed
download watched to the end leaks one push.

**Fix.** Wrap the circle in `Button(action: onCancelRequested)` with `.buttonStyle(.plain)`,
`.accessibilityLabel("Cancel download")` and
`.accessibilityValue("\(Int(progress * 100)) percent")`. Replace the manual push/pop with
`.onContinuousHover` plus a guaranteed pop in `.onDisappear`, or the lifecycle-safe
`.pointerStyle(.link)`.

---

### B17. The model-fit verdict is encoded in color alone, next to an unlabeled second GB figure that reads as a duplicate disk size

**P2** · [unverified] ·
[ModelFitBadgeView.swift:38](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/ModelFitBadgeView.swift:38)

```swift
HStack(spacing: 5) {
    Circle()
        .fill(badgeColor)
        .frame(width: 6, height: 6)

    Text(compact ? assessment.verdict.rawValue : assessment.formattedEstimatedRAM)
}
...
.help(assessment.explanation)
```

**What's wrong.** `ModelCardView` instantiates this with the default `compact: false`, so the
badge renders a 6pt colored dot plus an unlabeled byte count. The verdict — Comfortable / Tight
Fit / Risky / Too Large, the entire point of the badge and the thing that gates the download
advisory — is conveyed **only by hue**. There is no `.accessibilityLabel`; `.help()` is a
pointer-only tooltip VoiceOver does not read as a label. The meta row two lines above already
renders a GB figure for disk size.

**Impact.** A card shows "2.4 GB" (disk) and, six points away, "2.9 GB" (estimated RAM) with no
label distinguishing them — users read it as a rendering duplicate. For a red/green colorblind
or VoiceOver user, an `.incompatible` model is indistinguishable from a `.comfortable` one, so
the first indication the model will not fit is the "Model Too Large" sheet appearing after they
commit. `ModelFitInlineView` (:51-75) has the same color-only dot and no `.help` at all.

**Fix.** Show both pieces of text — "Tight Fit · ~2.9 GB RAM" — or add an
`.accessibilityLabel` combining verdict and estimate, plus a per-verdict SF Symbol
(`ModelFitVerdict.systemImage` already exists at ModelFitAdvisor.swift:24-31 and is used only by
the advisory sheet). Prefix the RAM figure with a "RAM" label.

---

### B18. Every category switch flashes "No models found" because `displayedModels` is cleared synchronously while `isLoading` arrives two actor hops later

**P2** · [unverified] ·
[MLXModelStoreViewModel.swift:198](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:198)

```swift
// Clear stale cards from the prior tab so the loading UI shows
// instead of (incorrectly) rendering the previous category's
// models until the remote fetch completes.
displayedModels = []

Task {
    await service.fetchRemoteModels(
```

**What's wrong.** The comment states the intent — clear so the loading UI shows — but the loading
flag is never set here. `isLoading` mirrors `service.isLoadingRemoteModels`, set inside
`fetchRemoteModels` via `await MainActor.run` and reaching the view model one further hop later
through the ObservationStream's `Task { @MainActor … }`. The view's ZStack branches on
`isLoading && displayedModels.isEmpty` first and `displayedModels.isEmpty` second, so for at
least two main-actor turns the state is (false, []) — the second branch.

**Impact.** Every category tab tap renders a magnifying-glass icon, "No models found", and a
"Try Reloading" button for a frame or two before the spinner appears — the app tells the user the
category is empty before it has started asking. Same flash on the debounced search refresh and
on ⌘R. Precisely the failure mode the comment was written to prevent.

**Fix.** Set `isLoading = true` synchronously in `refreshCategoryData` immediately after clearing
`displayedModels`, and let the observer's mirror only ever clear it. Or require a completed
fetch (`hasLoadedOnce`) before the empty branch can render.

---

### B19. Fixed point sizes on download text ignore Dynamic Type; the subsystem honors Reduce Motion nowhere

**P2** · [unverified] ·
[ModelDownloadStatusView.swift:175](Devgentic/Interfaces/Shared/Components/ModelDownloadStatusView.swift:175)

```swift
Text(DownloadSpeedFormatter.compactLine(snapshot: snapshot))
    .font(.system(size: 9, design: .monospaced))
    .foregroundColor(theme.tertiaryText)
    .lineLimit(1)
```

**What's wrong.** (1) Hard-coded point sizes on *text*: this line plus
`DownloadSidebarView.swift:349` (size 10 monospaced) and `:393` (size 10). The codebase marks
intentional fixed sizes with a `// Fixed size: intentional (icon)` comment (MLXModelStoreView
:173, ModelFitBadgeView :94, DownloadManagerContainerView :90) — these three carry no marker, so
they are unintentional, and all three pair with `.lineLimit(1)`. (2) No
`@Environment(\.accessibilityReduceMotion)` anywhere in the subsystem, while the project honors
it in 17+ other sites (JarvisCoreVisual, AgentTimelineView, ContentBlockView, MarkdownTableView,
ChatBubbleView, ChatHistoryView).

**Impact.** At any Dynamic Type setting the speed/ETA line and history subtitle stay at 9-10 pt —
the smallest, most information-dense text in the download UI is the only text that never grows,
and low-vision users cannot read the MB/s and time-remaining readout at all. With Reduce Motion
enabled, cards still run hover scale/shadow/border animations, the actions overlay still
cross-fades, the progress ring still animates its trim, and rows still animate hover fills — a
grid of 30 animating cards during a page load is exactly what the setting exists to suppress.

**Fix.** Replace the three fixed text sizes with semantic styles (`.caption2`/`.footnote` with
`.monospacedDigit()`), or `@ScaledMetric` if the exact size matters. Add
`@Environment(\.accessibilityReduceMotion)` to `ModelCardView`, `MLXDownloadProgressCircle`,
`ActiveDownloadRowView` and `HistoryDownloadRowView` and gate each animation on it, matching
`withAnimation(reduceMotion ? nil : .default)` already used at MarkdownTableView.swift:262.

---

## P3

### C1. `isCancellingDownload` is a service-global flag, so every MLX card shows "Cleaning up…"

**P3** · [unverified] ·
[ModelDownloadStatusView.swift:53](Devgentic/Interfaces/Shared/Components/ModelDownloadStatusView.swift:53)

```swift
backend == .mlx && MLXModelService.shared.isCancellingDownload
```

**What's wrong.** The flag carries no model identity and this predicate does not compare against
`modelIdentifier`, so every `ModelDownloadStatusView` rendered for the MLX backend evaluates
true simultaneously.

**Impact.** Cancel one model and every visible MLX card — including installed ones and unrelated
available ones — flips to "Cleaning up…" for the duration. Because of A6 this also fires
spuriously at the *start* of any download that follows a completed one.

**Fix.** Change the flag to `cancellingRepoId: String?` and gate on
`MLXModelService.shared.cancellingRepoId == modelIdentifier`. Same change at
MLXModelStoreView.swift:506.

---

### C2. Every user-facing string sourced from an enum `rawValue` is invisible to the String Catalog extractor

**P3** · [unverified] ·
[MLXModelStoreView.swift:604](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:604)

```swift
HStack(spacing: 6) {
    Image(systemName: category.icon)
    Text(category.rawValue)
}
```

**What's wrong.** `Text(category.rawValue)` binds to `Text(_ content: some StringProtocol)`, the
non-localizing overload — unlike a string literal, which becomes a `LocalizedStringKey`.
Verified empirically against `Devgentic/Localizable.xcstrings` (1632 keys, en only): every
literal in this subsystem IS extracted ("Download", "No models found", "Load More Models",
"Delete Model?"), while every rawValue-sourced string is MISSING — "Tool Use", "Coding",
"Vision", "All", "Popularity", "Size (Smallest)", "Size (Largest)", "Chat", "Comfortable",
"Tight Fit", "Risky", "Too Large", "MLX", "Ollama", "Whisper". Same for
`Label(option.rawValue, systemImage:)`, `Text(capability.rawValue)`, `Text(cancelAlertMessage)`,
`Text(assessment.explanation)` and `Text(subtitle)`. The date-group headers use a runtime key,
`sectionHeader(LocalizedStringKey(group.title), …)`, which the compiler cannot extract —
"Today"/"Yesterday"/"This Week"/"Earlier" are all absent.

**Impact.** On the first non-English localization the MLX store ships permanently mixed-language:
translated chrome around untranslated English category tabs, sort options, capability badges, fit
verdicts, backend names and date-group headers. `Text("Fetching \(selectedCategory.rawValue)
models...")` is worse — the key extracts but the interpolated category name stays English inside
a translated sentence. Roughly 25 permanently-unlocalizable strings, and they are the *labels*.

**Fix.** Give each enum a `var localizedTitle: LocalizedStringKey` (or `LocalizedStringResource`)
alongside `rawValue`, keeping `rawValue` for persistence and logging only. Replace
`Text(someString)` with `Text(LocalizedStringResource(...))` for `cancelAlertMessage`, the
`ModelFitAdvisor` explanations and the sidebar subtitle. Replace the runtime
`LocalizedStringKey(group.title)` with a `HistoryGroup` enum carrying static keys.

---

# Part B — Feature gaps

## P1

### G1. No disk-space preflight anywhere in the download path — the byte total is already fetched and discarded

**P1** · [unverified] · reported by 2 of 6 auditors ·
[DownloadCoordinator.swift:135](Devgentic/Core/Service/DownloadCoordinator.swift:135)

```swift
let totalBytes = await mlx.getTotalBytesForModel(repoId: trimmed)
DownloadManager.shared.preSeedTotalBytes(
    backend: .mlx,
    modelIdentifier: trimmed,
    bytes: totalBytes
)
```

**What's missing.** The exact download size is fetched here from the HF blobs endpoint and used
**only** as a speed/ETA denominator. Nothing compares it against free space. A repo-wide grep
for `volumeAvailableCapacity` hits only `MacOSUtilityTools.swift:393-399` (the agent's disk-info
tool) and `SystemHealthSource.swift` — the idiom exists and is simply not applied here.
`ModelFitAdvisor` models RAM only; disk is never modelled. Models land on the boot volume.

**Impact.** The store's own top-30 listing (verified live against `filter=mlx&sort=downloads`)
includes `mlx-community/Kimi-K2.5` at **657 GB** across 199 files. On a 512 GB MacBook the fit
advisory fires on RAM, the user clicks "Download Anyway", and the pull silently fills the startup
disk until macOS enters its low-disk failure modes. Even a routine 30 GB model on a nearly-full
disk fails partway with a raw FileManager error surfaced as "Download failed: …" and — because
`removePartialDownload` is called only from the cancel path, not the error path — leaves every
downloaded byte stranded (A1). LM Studio, Ollama, Jan and GPT4All all block or warn here.

**Fix.** Immediately after line 135, read `volumeAvailableCapacityForImportantUsageKey` on
`modelsDirectory` and return `.failed("Needs X GB, only Y GB free")` when `totalBytes` plus
headroom does not fit — the `.failed(String)` outcome already routes to an error toast at all
three call sites. Show remaining free space in `ModelFitAdvisoryView` alongside the RAM verdict.
Also call `removePartialDownload` from the download catch block. **Effort S.**

---

### G2. No pause/resume, and no Resume affordance for an interrupted download — although HubApi supports byte-range resume

**P1** · [unverified] · reported by 2 of 6 auditors ·
[DownloadHistoryStore.swift:265](Devgentic/Core/Persistence/SwiftData/DownloadHistoryStore.swift:265)

```swift
for record in stillActive {
    record.statusRaw = DownloadRecordStatus.interrupted.rawValue
    record.updatedAt = Date()
    record.errorMessage = record.errorMessage ?? "App closed during download"
}
```

**What's missing.** swift-transformers fully supports resume: `Downloader.swift:109` reads
`incompleteFileSize(at:)` and :179-185 set `requestHeaders["Range"] = "bytes=\(resumeSize)-"`.
The `.incomplete` files survive termination — 2.34 GB of them on this machine right now. Yet the
subsystem exposes **zero** resume UI. Startup reconciliation is correctly wired
([DevgenticApp.swift:63](Devgentic/DevgenticApp.swift:63)) and correctly flips crashed-session
records to `.interrupted`, but nothing touches the filesystem and `.interrupted` is not surfaced
as a resumable state — `DownloadSidebarView.swift:423` renders it as a plain "Interrupted" label,
and its context menu offers only "Re-download…" (a no-op, A7) and "Remove from History". There is
no pause control anywhere: `MLXModelService` has only `downloadModel`/`cancelDownload`.

**Impact.** A user on hotel wifi cannot pause a 30 GB pull; the only button is Cancel, which
(once A1 is fixed) discards every downloaded byte. A user who quits during a 20 GB pull gets an
"Interrupted" history row and a 20 GB directory that is never reclaimed, and if any shard
completed the model shows as Installed and fails to load (A2). The bytes are physically on disk
and resumable; the product never offers it. Ollama, LM Studio and Jan all ship pause/resume.

**Fix.** Add `DownloadRecordStatus.paused` and a `pauseDownload` that cancels the task **without**
calling `removePartialDownload`; resume is then just re-entering `hub.snapshot(from:)`, which
picks up the Range header for free. Surface pause/resume in `ActiveDownloadRowView` and
`ActiveDownloadCardView`, and add Resume / Discard to the history context menu for `.interrupted`
records. After `reconcileOrphans`, log each interrupted MLX repo's path and byte size at
`[DOWNLOAD]` info so the leak is visible. **Effort M.**

---

### G3. No storage accounting: installed models show no size, and there is no "space used by models" view at all

**P1** · [unverified] ·
[MLXModelStoreViewModel.swift:286](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift:286)

```swift
return MLXDisplayModel(
    id: item.displayName,
    size: nil,
    capabilities: caps,
    tags: ["Installed"],
```

**What's missing.** Installed models are mapped with `size: nil`, so `standardCard` skips the
`Label(size, systemImage: "internaldrive")` branch and the Installed tab shows no disk figure.
`ModelFitBadgeView` is suppressed for installed models too (gated on `model.size != nil`).
"Size (Smallest/Largest)" on the Installed tab is a silent no-op since `parseSize(nil)` returns
0 for every row. A repo-wide grep for `storageUsed`/`totalModelSize`/`diskUsage` returns nothing.

**Impact.** This machine has 76 GB of MLX models in Application Support and the app cannot tell
the user that, cannot tell them which model is the 16 GB one, and cannot rank them by size so
they can reclaim space. The Delete confirmation says "permanently remove the files from your
disk" without saying how many bytes that recovers. Users discover their disk is full via macOS,
not via the model manager. LM Studio, `ollama list` and Jan all show per-model size and a total.

**Fix.** Sum `.fileSizeKey` during `refreshInstalledModels` — the enumerator at
MLXModelService.swift:130 is already walking these trees — store it on `MLXModelItem`, and
populate `size` in the installed mapping. Add a "Models — 76.2 GB used" summary row to the
Installed tab header and a matching line in settings. **Effort M.**

---

## P2

### G4. No HuggingFace token support anywhere; gated repos are listed as ordinary downloadable cards

**P2** · [unverified] ·
[MLXModelService.swift:98](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:98)

```swift
private var hub: HubApi {
    return HubApi(downloadBase: modelsDirectory)
}
```

**What's missing.** No `hfToken:` argument, so `HubApi` falls back to `hfTokenFromEnv()`, which
reads `HF_TOKEN`/`HUGGING_FACE_HUB_TOKEN`/`HF_TOKEN_PATH`/`HF_HOME` from
`ProcessInfo.processInfo.environment`. **A macOS .app launched from Finder, Spotlight or Sparkle
does not inherit the user's shell environment**, so this is always nil in the shipped product.
Grep confirms no token entry UI, no Keychain entry, and no `hfToken:` call site — yet the app has
full Keychain plumbing for MCP and every cloud provider. `HFRawModel` also drops HF's `gated` and
`private` fields, so a gated repo renders as a normal card with a normal Download button.

**Impact.** The user clicks Download on a gated MLX conversion (any Llama or Gemma derivative
inheriting the upstream license gate). `HubApi.httpHead` maps the 403 to `authorizationRequired`,
which becomes "Download failed: Authentication required. Please provide a valid Hugging Face
token." — an instruction the app provides **no way to follow**. The model is permanently
un-downloadable with no path forward. Anonymous requests are also why the size fan-out (A9) gets
throttled so readily.

**Fix.** Add an optional HuggingFace token in settings, store it in the Keychain alongside the
provider API keys, and pass it to `HubApi(downloadBase:hfToken:)` and the three raw HF calls as
an `Authorization: Bearer` header. Decode `gated` and `private` and mark those cards — label
only, do not disable the button — so the failure is anticipated rather than discovered.
**Effort M.**

---

### G5. The store is quantization-blind: no quant shown, no filter, no recommendation, and parsed quant bits are discarded pre-download

**P2** · [unverified] ·
[MLXModelStoreView.swift:307](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:307)

```swift
private var fitAssessment: ModelFitAssessment {
    ModelFitAdvisor.assess(metadata: nil, diskSizeString: model.size, modelName: model.id)
}
```

**What's missing.** `MLXDisplayModel` has no quantization field, `classifyCapabilities` never
parses one from the repo id or tags, and there is no quant filter among the store's categories or
sort options. The fit advisor is deliberately called with `metadata: nil`, so
`ModelFitAdvisor.parseQuantizationBits` (:320) — which already understands
`4bit`/`8bit`/`bf16`/`mxfp4` — is **dead code on the pre-download path**, and the verdict falls
back to the crude `diskBytes × 1.2` estimate. Quantization is recovered only after download, by
`MLXTokenizerAnalyzer` reading `config.json`.

**Impact.** Choosing a quantization is the single most important decision a local-model user
makes, and the store cannot help. Verified against the live listing: the top 30 include
`gemma-4-E4B-it-MLX-4bit`, `-5bit`, `-6bit` and `-8bit` as four visually identical cards
distinguished only by a suffix buried in the title, plus `Qwen3.6-27B-MLX-4bit/5bit/6bit/8bit`.
No badge, no grouping, no "recommended for your 32 GB machine", and no way to filter to 4-bit.
LM Studio's central UX affordance is exactly this.

**Fix.** Parse the quant suffix in `classifyCapabilities` into a new
`MLXDisplayModel.quantization`, render it as a badge, add a quantization filter/sort, and feed a
synthesized `ModelMetadata(quantization:)` into `ModelFitAdvisor.assess` so the verdict uses real
bits-per-weight instead of a disk-size proxy. Optionally group same-family variants into one card
with a quant picker. **Effort M.**

---

### G6. No model detail view — no README, license, parameter count, or context length before committing to a multi-GB download

**P2** · [unverified] ·
[MLXModelService.swift:240](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:240)

```swift
return MLXDisplayModel(
    id: raw.id,
    size: nil,
    capabilities: caps,
    tags: raw.tags ?? [],
    downloads: raw.downloads,
    likes: raw.likes,
    description: nil
)
```

**What's missing.** `description` is hardcoded nil for every remote model, and `HFRawModel`
decodes only id/downloads/likes/tags/pipeline_tag — never `cardData`, `license`, `config`, or the
README. `ModelCardView` has no tap target, no navigation, and no sheet other than the fit
advisory. Meanwhile the detail endpoint is already hit **twice per model** (`getSizeForModel`
:336 and `getTotalBytesForModel` :361) and its response decoded into `HFModelDetail`, which
throws away everything except sibling sizes.

**Impact.** A user deciding between a 4 GB and a 12 GB model sees only name, org, download count,
size and heuristic capability badges. No license (material for a pre-open-source app whose users
may ship commercial work), no parameter count, no context window, no model card. The context
length in particular is unknowable until after download, when `MLXTokenizerAnalyzer` reads
`config.json` — so users download blind and discover an 8K window afterward, which is what
`MLXContextWindowHealer` exists to patch up. Every competitor shows a model card.

**Fix.** Extend `HFModelDetail` to decode `cardData` (license, base_model), `config` and `tags`;
present a detail sheet on card tap with README excerpt, license, params, context length and file
list. The extra data comes free on the API call already being made. **Effort M.**

---

### G7. First-run store is a raw HF popularity dump: non-LLM ASR models badged "Chat", no curated set

**P2** · [unverified] ·
[MLXModelService.swift:209](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:209)

```swift
var urlString = "https://huggingface.co/api/models?sort=downloads&direction=-1&limit=\(limit)&skip=\(offset)&filter=\(filterString)"
...
// Default to Chat
if caps.isEmpty {
    caps.insert(.textGeneration)
}
```

**What's missing.** The only server-side filter is the `mlx` tag. `pipeline_tag` is read but used
solely for the vision check, never to exclude non-text-generation models, so anything
unrecognized falls through to the `.textGeneration` = "Chat" default. Verified against the live
endpoint this app calls: results **1, 2 and 29** of the first 30 are
`mlx-community/parakeet-tdt-0.6b-v2`, `parakeet-tdt-0.6b-v3` and `parakeet-tdt_ctc-110m` —
automatic-speech-recognition models `MLXService.loadModel` cannot load as LLMs — each rendered
with a "Chat" badge. Result 28 is `mlx-community/Kimi-K2.5` at 657 GB. There is no curated set
for a zero-model first run; the empty state just says "Download models from the All tab."

**Impact.** A brand-new user with zero models opens the store and the first two recommendations
are ASR models labelled "Chat" that download 2.5 GB and then fail at inference with a framework
error. The app's own sibling surface does this right: `WhisperModelCatalog.swift:29-40` ships a
hand-curated 9-entry list with display names and sizes. The MLX store — the primary onboarding
path for local inference — has no equivalent.

**Fix.** Filter out non-text/image-text pipeline tags in `fetchRemoteModels`, logging each
exclusion with the reason. Add a `CuratedMLXCatalog` mirroring `WhisperModelCatalog` — a handful
of known-good, RAM-tiered, tool-capable models — rendered as a "Recommended" category that is the
default tab when `installedModels.isEmpty`. **Effort M.**

---

### G8. No revision pinning and no update detection — installs are not reproducible and go stale silently

**P2** · [unverified] ·
[MLXModelService.swift:393](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:393)

```swift
_ = try await hub.snapshot(from: repoId) { progress in
    Task { @MainActor in
        self.downloadProgress = progress.fractionCompleted
    }
}
```

**What's missing.** No `revision:` argument, so HubApi's default `revision: "main"` applies —
whatever the branch tip happens to be at download time. HubApi *does* record the resolved commit
hash via `writeDownloadMetadata(commitHash:etag:metadataPath:)` (`HubApi.swift:607`) into
`.cache/huggingface/download/*.metadata`, and this subsystem never reads it back.
`DownloadRecord.sourceURL` is a bare repo URL with no commit, and its own doc comment says it is
"not used by the backends at trigger time". Nothing polls HF for a newer revision.

**Impact.** Two users installing the same model id on different days get different weights with
no way to tell — a real problem for an app about to be open-sourced, whose users will file "model
X behaves differently for me" bugs. When a publisher re-quantizes or fixes a broken chat template
(common in mlx-community), the installed copy stays stale forever: no "Update available" badge,
and the only refresh path is the no-op in A7. LM Studio and Ollama both surface an update
indicator.

**Fix.** Read the commit hash back from the `.metadata` files after `snapshot` returns and persist
it on `DownloadRecord` (add `revisionCommitHash: String?`) and on `MLXModelItem`. Add a
lightweight `GET /api/models/<id>` sha comparison on store refresh to drive an "Update available"
badge. Optionally accept a pinned revision in the download call. **Effort M.**

---

### G9. Nothing prevents system sleep during a multi-hour download

**P2** · [unverified] ·
[MLXModelService.swift:387](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:387)

```swift
downloadTask = Task {
    do {
        _ = try await hub.snapshot(from: repoId) { progress in
```

**What's missing.** A repo-wide grep for `beginActivity`, `IOPMAssertion` and `idleSystemSleep`
returns **zero hits** — no power assertion anywhere in the app. `HubApi` is constructed without
`useBackgroundSession`, so the transfer runs on a foreground URLSession inside this Task. No
metered-network check, no bandwidth limit.

**Impact.** A laptop on battery downloading a 30 GB model hits its display-sleep timer and the
transfer stalls. Waking may recover via Range resume, but with no pause/resume UI (G2) and a
broken cleanup path (A1) what the user sees is a progress bar frozen at some percentage with no
explanation and no log line marking the stall.

**Fix.** Wrap the download task in
`ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Downloading MLX model \(repoId)")`
and end the activity in every terminal branch, logging begin/end with the repo id. The same seam
applies to `WhisperModelDownloadService` and `OllamaService`. **Effort S.**

---

### G10. Zero test coverage for model loading, memory lifecycle, fit assessment, and the entire download pipeline

**P2** · [unverified] ·
[MLXService.swift:20](Devgentic/Core/Service/MLXService.swift:20)

```swift
actor MLXService {

    // MARK: - Singleton
    static let shared = MLXService()
```

**What's missing.** Grepping `DevgenticTests/` for this subsystem's types returns hits for exactly
one file: `MLXTokenizerDialectTests.swift`. There is **no test anywhere** referencing
`MLXService`, `MLXModelService`, `ModelFitAdvisor`, `DownloadCoordinator`, `DownloadManager`,
`SpeedSampler`, `ProgressThrottler` or `DownloadHistoryStore`. What *is* covered:
`MLXTokenizerDialectTests` (25 fixture-driven cases), `MLXContextWindowTests` (7),
`MLXWindowHealingTests` (5), `ICReleasePolicyTests` (10 on the pure IC residency decision table),
and `WhisperModelDownloadServiceTests` (9 — the sibling backend, not MLX).
`detectVisionModalities` has zero coverage despite gating whether images reach the model, and
`ModelFitAdvisor`'s parsers are pure, `static` and trivially testable yet untested.

**Impact.** Every defect in Part A sits in untested code. The `ICReleasePolicy` extraction proves
the pattern works — the IC's residency logic was pulled into a pure type and has 10 tests — but
`MLXService`'s equivalent state machine (`activeGenerations`, `loadInFlight`,
`lastModelDirectory`, idle-timer re-arm) never got the same treatment, which is exactly why B1
and A14 went undetected. Refactoring the display-name reconstruction (A3) today has no test that
would catch breaking every profile's stored model name.

**Fix,** highest value first: (1) extract `MLXService`'s residency state into a pure
`MLXResidencyPolicy` mirroring `ICReleasePolicy` and test it — cancel-during-generation must not
pin `activeGenerations`; `unloadModel` refuses under load; a reload for Y while X is expected is
rejected. (2) `refreshInstalledModels` display-name reconstruction against a temp-dir fixture
tree covering `mlx-community/X`, `otherOrg/X`, `models--org--X`, a weights-less partial, and a
duplicate-name collision. (3) `ModelFitAdvisor.parseParameterCount`/`parseQuantizationBits`/
`parseDiskSize` table tests including the malformed inputs `logUnusualInputs` claims to catch,
and the comma-decimal locale case from A19. (4) `detectVisionModalities` fixtures for `gemma3` vs
`gemma3_text` (the trap called out in its own doc comment) and a corrupt config.json.
(5) `startMLXDownloadIfNeeded` idempotency against a fake installed list containing
non-`mlx-community` names. **Effort M.**

---

## P3

### G11. MLX cards never render the shared component's Installed state, so MLX is the only backend without a Re-download affordance

**P3** · [unverified] ·
[MLXModelStoreView.swift:396](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift:396)

```swift
ModelDownloadStatusView(
    backend: .mlx,
    modelIdentifier: model.id,
    displayName: model.displayName,
    isInstalled: false,
```

**What's missing.** `ModelDownloadStatusView` documents itself as the unified per-model component
rendering three states, with `installedView` (:204-241) providing the Installed capsule plus an
overflow menu carrying "Re-download…" and "Delete". `ModelCardView` renders it only inside the
`else` of `if isInstalled` and hard-codes `isInstalled: false`, so that branch is unreachable for
MLX. The card substitutes its own bespoke Installed capsule with no menu and exposes Delete only
when `selectedCategory == .installed`. It also passes no `onDeleteRequested` and no `profileID`.

**Impact.** In the Ollama store and Whisper settings rows the ellipsis menu offers "Re-download…"
in place. In the MLX store, browse tabs show a plain Installed badge with no menu; on the
Installed tab the only action is Delete. To re-pull a model the user must delete it and re-find
it. MLX also produces `DownloadRecord`s with a nil `profileID` while the other two backends
populate it.

**Fix.** Drive `ModelDownloadStatusView` from the real `isInstalled` value, pass
`onDeleteRequested` and `profileID`, and delete the card's duplicate Installed capsule and
standalone trash button so all three backends present installed models identically. Depends on
A7 for the re-download to do anything. **Effort S.**

---

### G12. No architecture or runtime-support check before a multi-GB download; unsupported models fail only at first load

**P3** · [unverified] ·
[MLXModelService.swift:209](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:209)

```swift
var urlString = "https://huggingface.co/api/models?sort=downloads&direction=-1&limit=\(limit)&skip=\(offset)&filter=\(filterString)"
```

**What's missing.** The store lists every `mlx`-tagged repo with no filter on whether the bundled
runtime can execute it. The app already knows this distinction:
`MLXTokenizerAnalyzer.visionModelTypes` (:48-53) is explicitly documented as "the RUNNABLE
subset", naming `mllama`, `llava`, `llava_next`, `phi3_v`, `minicpmv`, `internvl_chat` as VLMs
MLXVLM cannot run — but that knowledge is applied only *after* the model is on disk, and only to
route vision vs text. Nothing checks `model_type` against MLXLLM's registry at any point. There
is also no Apple-Silicon guard in the MLX path (`#if arch(arm64)` appears only in
`MCPBugReportBundler.swift:79`) and the project sets no `ARCHS`/`EXCLUDED_ARCHS`.

**Impact.** Search for `llava` or `Llama-3.2-11B-Vision` — both `mlx`-tagged, both listed. The
user downloads 6-20 GB, sees it appear as Installed, selects it in a profile, and only then does
`MLXLMCommon.loadModelContainer` throw, surfacing as a raw framework error with no indication the
model was never runnable. The download succeeded, so nothing marks it unusable and the user can
repeat the cycle.

**Fix.** Fetch each candidate's `config.json` `model_type` from the HF API before the pull (the
store already fetches per-model detail in `getSizeForModel`) and, when it is outside the runnable
set, show a non-blocking "this architecture is not supported by the bundled runtime" badge —
describe, do not gate, per the standing directive. Post-install, mark such models with the same
badge in the Installed tab. **Effort M.**

---

### G13. No completion notification, despite a working local-notification channel already shipping

**P3** · [unverified] ·
[DownloadManager.swift:371](Devgentic/Core/Service/DownloadManager.swift:371)

```swift
} else if isInstalledNow || progress >= 0.99 {
    _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
} else {
    _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
}
```

**What's missing.** The terminal transition writes a SwiftData row and nothing else.
`LocalNotificationChannel` is a complete, permission-handling `UNUserNotificationCenter` wrapper
and `AppDelegate.swift:89` already installs the notification-center delegate — but no download
path calls into it. Same for the Ollama (:291) and Whisper (:461) terminal branches.

**Impact.** Model downloads are the longest-running operation in the app — tens of minutes to
hours. The user switches away and gets no signal when the model is ready or when it failed, so
they poll the Downloads sidebar. Every competitor notifies on completion.

**Fix.** Emit via `LocalNotificationChannel.send(_:)` from the terminal branches of all three
reconcile methods (success and failure), gated by the existing per-channel preference in
`NotificationSettingsView`. **Effort S.**

---

### G14. The models directory is hardcoded — no custom location, no import of an existing local model folder, no Reveal in Finder

**P3** · [unverified] ·
[MLXModelService.swift:87](Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift:87)

```swift
private var modelsDirectory: URL {
    let fileManager = FileManager.default
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let mlxPath = appSupport.appendingPathComponent("huggingface/models")
```

**What's missing.** A private computed property with no UserDefaults override, referenced only
inside this file. No import flow — grep for `importModel`/`addLocalModel` returns nothing. The
installed card exposes the path only as truncated caption text with no reveal action, even though
`NSWorkspace.shared.activateFileViewerSelecting` is used elsewhere
(`ExplorerViewModel.swift:491`).

**Impact.** 76 GB of models are pinned to the boot volume on a machine that may have a fast
external SSD, with no supported way to relocate them — LM Studio, Ollama (`OLLAMA_MODELS`), Jan
and GPT4All all support a custom directory. A user migrating from `mlx_lm` or LM Studio
re-downloads tens of GB they already have. And when something is wrong with a model they cannot
open its folder from the app to inspect it. Related: `urls(for:).first!` is an unlogged
force-unwrap in a directory-resolution path that a user-configurable location would make
genuinely fallible.

**Fix.** Back `modelsDirectory` with an `@AppStorage` path (security-scoped bookmark for
sandbox-safety), add a directory picker in settings that triggers a rescan, add an "Import Model
Folder…" action that validates `config.json` + weights and symlinks or copies into the store, and
add "Reveal in Finder" to the installed card's actions menu. **Effort M** for the directory
override, **S** for reveal-in-Finder.

---

### G15. `DownloadRecord` has no retention policy, no fetch limit in the sidebar, and no versioned schema/migration plan

**P3** · [unverified] ·
[DownloadRecordSD.swift:49](Devgentic/Core/Persistence/SwiftData/DownloadRecordSD.swift:49)

```swift
@Model
final class DownloadRecord {

    @Attribute(.unique)
    var id: UUID
```

**What's missing.** Nothing prunes `DownloadRecord` rows by age or count — `deleteAllHistory`
exists but is reachable only from the user-driven "Clear History…" menu item, and
`reconcileOrphans` only rewrites status. `fetchHistory` caps at 200 but the sidebar bypasses it
with an unbounded `@Query(sort: \.updatedAt, order: .reverse)` whose three computed properties
each re-filter the whole array on every body pass. No `@Attribute(.index)` on `backendRaw`,
`modelIdentifier` or `statusRaw`, so `fetchMostRecent` and `fetchActive` — called from the
bridges on every reconcile tick — are full-table predicate scans. The container is built with no
`migrationPlan:` and no `VersionedSchema`, relying entirely on implicit lightweight migration.

**Impact.** Growth is slow (one row per download attempt) but strictly monotonic across the life
of the install, and every row is scanned on each bridge reconcile and each sidebar render. The
migration gap is the sharper edge for a Sparkle-distributed app: adding any non-optional property
without a default to `DownloadRecord` — or to any of the 12 entities in the shared schema — makes
lightweight migration fail, and the launch path correctly refuses to continue
([DevgenticApp.swift:99-120](Devgentic/DevgenticApp.swift:99) shows a critical alert and calls
`exit(EXIT_FAILURE)`). That is the right call for data safety, but it leaves the user with a
bricked app and no in-app recovery after an auto-update, and no test exercises the
old-store-opens-with-new-schema path.

**Fix.** Add a retention sweep next to the existing `reconcileOrphans()` launch hook (terminal
records older than 90 days, or beyond the newest 500, whichever is looser) and log the pruned
count. Give the sidebar's `@Query` a `fetchLimit` matching `fetchHistory`'s 200. Add
`@Attribute(.index)` to the predicated columns. Introduce a `VersionedSchema` +
`SchemaMigrationPlan` now, while there is only one shipped version, with a test that opens a
fixture store written by the previous schema. **Effort M.**

---

## Refuted / narrowed — do not re-report these

Nothing was fully refuted; two findings were **downgraded** and three premises were **narrowed**
on adversarial verification. Recorded so a future audit does not re-file them at the original
severity.

| Claim as filed | Verdict |
|---|---|
| `partialDownloadFolder` is **P0** | **P1.** The path bug is real and confirmed three ways (source, dependency source, live filesystem), but the failure mode is orphaned disk usage plus a stale Installed row — no crash, no security exposure, no loss of user-authored data, and recoverable by re-downloading or deleting in Finder. |
| Cancelling any MLX download leaves a phantom "Installed" model | **Narrowed.** Only for **multi-shard** repos cancelled after at least one shard completed. A cancel during the first (or only) shard leaves no weights file, so `hasWeights` (MLXModelService.swift:148-155) already filters it — those repos are invisible orphans, not phantom installs. The doc comment on `cancelDownload` claiming the cleanup exists to stop the scanner misidentifying an orphaned `config.json` is therefore **wrong about its own rationale**: `hasWeights` already covers that. The real justification is the disk leak. |
| MLX Stop **permanently blocks** every model unload | **Narrowed, and downgraded P0 → P2.** `defer { activeGenerations -= 1 }` is unconditional and the producer Task always returns, with `startIdleTimer()` at the end of the same Task — so the counter never leaks and the 2-minute idle unload fires afterward. Unload is *delayed*, not blocked. The orphan also still runs through `consumeGenerationStream`, so the circuit breaker, stop sequences, EOS and `maxTokens` all bound it to one generation length. `AppDelegate.swift:231` is inconsequential (the process is exiting). The double-residency claim additionally requires loading a *different* MLX model inside the orphan's remaining lifetime. |
| MLX Stop's worst symptom is memory pressure | **Corrected.** The most user-visible symptom the auditor missed is that the user's **next** message decodes concurrently with the zombie on the same GPU, roughly halving token rate. |
| The MLX cancel path could stop early via the vendored library | **Refuted as a mitigation.** `MLXLMCommon/Evaluate.swift:1689-1719` *would* break on `Task.isCancelled` or a terminated yield, but neither trigger can fire: MLXService's consumer never exits early and its producer Task handle is discarded, so it is never cancelled. `ModelContainer.perform` serializes only prompt-prep, so the orphan decodes outside any lock. No `cancelGeneration`/`stopGeneration` API exists on `MLXService`. |
| Citation `MLXModelStoreView.swift:527` for the "Cleaning up…" spinner | Minor drift — it is at **:519**. |

---

## Recommended sequencing

### Batch 0 — the coupled download-lifecycle fix (must ship together) — ✅ SHIPPED 2026-08-03

Nothing else should land first. These three defects mask each other and fixing any one alone
makes another destructive.

| # | Item | Effort | Status |
|---|---|---|---|
| A1 | `partialDownloadFolder` → `hub.localRepoLocation`, log both early returns, one-time orphan sweep | S | ✅ |
| A6 | Clear `downloadTask`/`currentDownloadName` in every terminal branch; guard cleanup on the repo not being installed | S | ✅ |
| A4 | `downloadModel` refuses instead of pre-empting; bridge identity check with supersede logging | S | ✅ |
| A5 | `Task.isCancelled` on both success and catch paths; treat `URLError.cancelled` as cancellation; log the terminal classification | S | ✅ |
| G10 (partial) | Tests for exactly these paths **before** the fixes, so the regression is pinned | M | ✅ 14 tests |

**As shipped**, with three deviations from the plan above — all deliberate:

1. **The cleanup guard asks the filesystem, not `installedModels`.** The planned "guard on the
   repo not being installed" reads a list refreshed by a 30s-debounced scan (B10), so it is
   stale exactly when it matters. `removePartialDownload` now refuses any folder containing
   weights via `MLXModelService.containsWeights` — one definition now shared by the installed
   scan, the orphan scan and the guard, so they cannot disagree. The `installedModels` check
   is kept as a secondary guard. A test caught this: the guard passed only because the
   debounce had left the list empty.
2. **The orphan sweep does not delete.** A launch-time sweep of multi-gigabyte user folders is
   not reversible, a second app instance could be writing into one, and a user may have
   hand-placed files there. `findOrphanedPartialDownloads()` is read-only and runs at launch
   **off the MainActor** (adding another synchronous walk there would worsen A15);
   `reclaimOrphanedPartialDownloads()` is the destructive counterpart and is not yet wired to
   any UI. **Follow-up: the reclaim affordance ships with G3 (storage accounting).** Until
   then the stranded bytes are logged but only reclaimable from Finder.
3. **The refusal deliberately does not set `errorMessage`.** The bridge reads that field to
   classify the *active* download's terminal state, so writing a refusal there would mark the
   still-running model as failed when it later completed. The refusal travels back as a
   `Bool` from `downloadModel` and a `.failed` outcome from the coordinator instead; a test
   pins this.

Also folded in, because these files were open and the standing logging rule applies to code
we touch: `DownloadManager` had **zero** logging — it now logs every terminal classification
with the signals that produced it (`[DOWNLOAD]`), and `MLXModelService` logs every start,
refusal, cancel classification and cleanup skip (`[MLXSTORE]`). The identity guard was applied
to the Ollama and Whisper bridges too, not just MLX. `MLXModelStoreView` now surfaces the
coordinator outcome as a toast at both call sites — it previously discarded it with `_ = await`.

Verified: `xcodebuild build-for-testing` clean; `MLXDownloadLifecycleTests` 14/14 green.
Not verified on device — no real download was exercised end to end.

### Batch 1 — P1 correctness — ✅ SHIPPED 2026-08-03 (2 items deferred)

Group by root cause, not by file.

**Shipped:** A3 · A17 · A7 · B14 · B12 (identity) · A2 (completeness) · A8 · A9 · A10 · A11 ·
A22 · B7 (network) · A13 (delete safety) · A16 · A12 (observability) · A18 · A19 · A20 · A21 ·
A23 (UI). 27 new tests across 7 suites; 41/41 green, plus 57/57 in adjacent suites.

Notes on how a few landed, where it differs from the plan above:

- **A3 needed a migration path, not just a fix.** Correcting `displayName` to the canonical
  `author/name` changes the identity key that existing profiles already store — those hold the
  old bare name, so a pure exact-match fix would have orphaned every non-`mlx-community` model
  the user had already configured. `MLXModelIdentity.match` therefore returns a three-state
  `MatchKind`: `.exact`, `.legacyBareName` (tolerated, always logged as ambiguous, and only
  when exactly one side carries an author — otherwise it would resurrect A17's cross-org false
  positive), or `.none`. All 12 comparison sites now route through it.
- **A19 was fixed at the source rather than the parser.** `MLXDisplayModel` carries
  `sizeBytes: Int64?` and sort/fit-assessment use it; `ModelFitAdvisor.assess` gained a
  `diskSizeBytes:` parameter that bypasses string parsing entirely. `parseDiskSize` still
  exists for callers that only have a string, and now normalises "," → "." instead of
  stripping it.
- **A18 went further than "restore `.all`".** Three enforcement points stacked on one name
  heuristic; all three are now descriptive. The store keeps every category, the hard filter
  became a user-facing "Show tool-capable models only" toggle (default on), and the picker
  lists every installed model with a `⚠︎ tools unconfirmed` label instead of deleting the
  rows. The alert copy no longer claims the selection was rejected — nothing rejects it.
- **A9's bound also had to stop early.** Capping concurrency at 5 is not enough on its own:
  once HuggingFace starts returning 429 the remaining requests only deepen it, so the batch
  abandons on the first rate-limit and logs how many it dropped. The store's retry button is
  suppressed for that one error class for the same reason.
- **A16 keeps the computed property.** `activeRecords` still exists for non-view callers; the
  observable `activeCount` is now a stored property maintained from the same bridge
  transitions that write `activeRecordIDsByKey`. The doc comment says which to use and why.

**Deferred, with reasons — these are the only Batch 1 items not shipped:**

| # | Why it was left | What is in place instead |
|---|---|---|
| **A14** — thread model identity into `streamChat` | Deferred from Batch 1; **✅ SHIPPED 2026-08-03**. |
| **A15** — move the scan off the MainActor | Deferred from Batch 1; **✅ SHIPPED 2026-08-03**. |

### A14 + A15 as shipped — 2026-08-03

12 new tests; **122/122** green across the subsystem and its neighbours.

**A14 — model identity.** The blast radius turned out small: three callers of
`streamChat`/`streamVisionChat` (all in `MLXLLMProvider`) and two construction sites
(`AgentConnect`, `WorkflowExecutor`) that already held the resolved directory. `MLXLLMProvider`
now carries `modelDirectory` and passes it as `expectedModelDirectory`.

The important part is *how* the check is done. A naive check-then-use is unsafe here — the
actor is reentrant across every suspension, so a concurrent `loadModel` can swap
`modelContainer` after the check passes. The new `container(expecting:)` loads the requested
model if needed and then **validates identity and captures the container with no `await`
between them**, returning a strong reference to the model it verified. Reentrancy afterwards
cannot substitute it. On an unresolvable mismatch it throws `ServiceError.modelIdentityMismatch`
naming both models, rather than answering from the resident one. A nil identity keeps the old
behaviour and logs a warning — that path is exactly the one that could be served by the wrong
model.

**A15 — off-actor scan.** `scanDisk(root:)` and `computeProfiles(for:)` are now `nonisolated
static`; only the publish step runs on the MainActor. `refreshInstalledModels()` became a
fire-and-forget launcher, `refreshInstalledModelsAsync(force:)` does the work, and
`ensureLoaded()` is the contract for callers that need the result. All four request-path
consumers plus `DownloadCoordinator` now await it.

⚠️ **A test caught a real bug in the first version of this**: `ensureLoaded()` was being
short-circuited by the debounce, so it could return *before any scan had landed* — a caller
would then read an empty list and conclude the model wasn't installed, failing a turn with a
404 for a model that is present. Two fixes: coalescing is now checked **before** the debounce
(joining an in-flight walk is always correct, and cheaper than a second one), and
`ensureLoaded()` keys on `hasCompletedInitialScan` rather than on the list being non-empty, so
a genuinely empty library doesn't re-walk on every request.

Three production call sites also had to change, all previously relying on the synchronous
contract: `deleteModel` and the cancel-cleanup block now await the refresh (both feed terminal
classification), and `MLXModelPickerView` moved from `.onAppear` to `.task { await
ensureLoaded() }` — its `attemptAutoSelect()` ran against an empty list and silently selected
nothing, with nothing re-triggering it once the scan landed.

**Not verified on device:** the wrong-model workflow scenario itself. It needs two MLX models
loaded by parallel workflow branches with a pause between iterations — reproducible in
principle, not exercised here. The identity plumbing and error surface are unit-tested; the
race it prevents is not.

- **Identity** — A3 (org-agnostic display name) + A17 (`isInstalled` exact match) + A7 (`force:`
  re-download) + B14 (log duplicate drops) + B12 (IC lookup logging). One shared comparison
  helper; A3 is the root and unblocks the rest. **M**
- **Completeness** — A2 (`model.safetensors.index.json` shard verification, `.partial` state).
  **M**
- **Network truthfulness** — A10 (HTTP status handling via `CloudRequestPipeline`) + A8
  (`.unknown` fit verdict, fail closed) + A9 (bounded fan-out, honor the cache) + A11
  (generation token) + A22 (error state, no cross-category bleed). **M**
- **Runtime safety** — A14 (thread model identity into `streamChat`) + A13 (delete guards +
  unload + record repair + logging) + A15 (move the scan off the MainActor, 9 reads → 4). **M**
- **Observability** — A16 (observable active count) + A12 (surface terminal failure on the card).
  **S**
- **UI correctness** — A18 (describe, do not filter — standing directive) + A19 (carry raw
  bytes, kill the string parse) + A20 (Installed-tab filter) + A21 (stable sort) + A23
  (always-visible Download button). **M**

### Batch 2 — P2 — ✅ SHIPPED 2026-08-03

- **Logging pass** (project standard): B2, B6, B9, B11, B13. One sweep, `[DOWNLOAD]` /
  `[MLXSTORE]` / `[MLX-LOAD]` tags with correlation ids. **M**
- **Lifecycle**: B1 (`onTermination` + `Task.isCancelled` in the generation loop), B3 (Ollama
  refusal outcome), B4 (weak + staleness guard), B5 (in-flight counter). **S**
- **Networking**: B7 (`URLComponents`), B8 (timeouts + one bounded retry + ETag). **S**
- **Performance / UX**: B15 (stop tracking `downloadProgress`, delete the dead banner), B10 (2 s
  debounce + forced refresh), B18 (synchronous `isLoading`). **S**
- **Accessibility**: B16 (real Button + cursor lifecycle), B17 (verdict text + symbol), B19
  (Dynamic Type + Reduce Motion). **S**

**All 13 remaining P2 items shipped** (B2, B5, B6, B7 had already landed with Batches 0–1).
4 new tests; 45/45 green across the subsystem, 67/67 in adjacent suites.

Worth recording, because a few differ from the plan:

- **B1's fix is a chain, not a site.** Cancelling only `MLXService`'s producer would not have
  helped: `MLXLLMProvider.streamWithUsage` also discarded its handle, so the teardown stopped
  one level above. All three producers now capture their task and cancel it from
  `continuation.onTermination`, and `consumeGenerationStream` breaks on `Task.isCancelled` —
  the vendored evaluator's own check only fires between token batches. `unloadModel`'s
  refusal now names the model holding the lease, so a leaked stream is traceable.
- **B3 was fixed on both sides.** `OllamaService.pullModel`'s silent `guard` now logs, and
  `DownloadCoordinator` pre-checks `isPullingModel` / `isRemovingModel` so the caller gets a
  `.failed` toast instead of a `.startedFresh` that pulls nothing. The coordinator's own
  in-flight check is scoped to the same identifier, which is why pulling B during A slipped
  through.
- **B15 removed the tracking, not just the churn.** `downloadProgress` is no longer observed
  by `MLXModelStoreViewModel` at all — the only consumer was a `downloadBanner` that was
  defined but never referenced (the code's own comment said the global banner was
  intentionally omitted). Banner deleted; the per-row status view and the sidebar already
  own progress display.
- **B10 needed the call site too.** Dropping the interval 30s → 2s is not sufficient while
  the store's refresh path calls the debounced `refreshInstalledModels()`; that path now
  calls `forceRefreshInstalledModels()`, since reaching it is always an explicit user
  request. The skip log moved from `.debug` to `.info` with its consequence.
- **B16's cursor leak was the subtler half.** The manual `NSCursor.push()`/`pop()` pair in
  `onHover` leaks a pushed cursor for the whole app whenever the exit event never arrives —
  which is exactly what happens when the download completes and the view is removed
  mid-hover. Replaced with `.pointerStyle(.link)`, tied to the view's lifetime.
- **B13 logs, and only logs.** Per the standing directive the pre-load headroom line never
  refuses a load; it exists so a "the app hangs my Mac" report has evidence, which a
  `.debug` post-load pair could not provide.

### Batch 3 — P3 polish — ✅ SHIPPED 2026-08-03

C1 (per-repo cancelling flag), C2 (`localizedTitle` on every enum). **S** each.
9 new tests; **131/131** green across the subsystem and its neighbours.

- **C1.** `isCancellingDownload: Bool` became `cancellingRepoId: String?` plus
  `isCancellingDownload(repoId:)`. Both view call sites now pass their own identifier. The
  clear is guarded on still owning the flag, so a newer cancel for a different repo cannot
  have its indicator wiped by an older one finishing.
- **C2.** `localizedTitle: LocalizedStringKey` added to `MLXModelCapability`,
  `StoreCategory`, `SortOption`, `ModelFitVerdict` and `ModelBackendType`, with `rawValue`
  retained for persistence and logging only. Three shapes needed more than a swap:
  - The fit badge composed `"\(verdict) · ~\(ram) RAM"` into one `String`. Now
    `Text(verdict.localizedTitle) + Text(verbatim: " · ~… RAM")` — the verdict is a
    translatable key, the number is appended after it.
  - `Text("Fetching \(category.rawValue) models...")` extracted the key but left the category
    English inside a translated sentence; it now interpolates a nested `Text` of the
    localized title.
  - The sidebar's date headers used `LocalizedStringKey(group.title)` — a **runtime** key the
    compiler cannot extract, so Today/Yesterday/This Week/This Month/Earlier were all absent
    from the catalog. `HistoryGroup` now carries a `HistoryBucket` enum with static keys.

⚠️ `ModelBackendType.rawValue` is a persistence key (`DownloadRecord.backendRaw`, the pre-seed
dictionary key). A test pins the exact strings so a future display tweak cannot silently orphan
every stored download record.

### Feature milestones

| Milestone | Contents | Effort |
|---|---|---|
| **M1 — Don't fill the user's disk** ✅ SHIPPED 2026-08-03 | G1 disk preflight · G3 storage accounting (per-model size + total) · G9 sleep assertion | S + M + S |
| **M2 — Downloads you can control** | ✅ G2 pause/resume + Resume on interrupted records (SHIPPED 2026-08-03) · ✅ G13 completion notifications (SHIPPED 2026-08-03) · ✅ G11 unified Installed state with Re-download (SHIPPED 2026-08-03) | M + S + S |

**M2 is complete.**
| **M3 — Choose a model with information** | ✅ G7 curated catalog + pipeline-tag filtering · ✅ G5 quantization badge/filter/fit input · ✅ G6 model detail sheet (all SHIPPED 2026-08-03) · G12 runnable-architecture badge | M ×3 + M |
| **M4 — Reach the models you can't today** | ✅ G4 HuggingFace token in Keychain + gated/private badges (SHIPPED 2026-08-03) · ✅ G14 custom models directory + import + Reveal in Finder (SHIPPED 2026-08-03) | M + M |

**M4 is complete.**
| **M5 — Durability** | ✅ G8 revision tracking + update detection (SHIPPED 2026-08-03) · ✅ G15 retention sweep + indexes (SHIPPED); `VersionedSchema` split to `SWIFTDATA_MIGRATION_PLAN.md` · G10 the remaining test coverage | M ×3 |

M1 and the Batch 0/1 work are the shipping gate. M2 onward is product, not readiness.

---

### First on-device run — 2026-08-03

The app was launched and its log inspected (screen capture is blocked by TCC on this machine,
so the UI itself was **not** visually verified). What the launch path confirmed against the
real 19-folder library:

| Claim | Evidence from the running app |
|---|---|
| A3 canonical ids | `MLX Analysis [badmadrad/Devstral-Small-2-24B-Instruct-2512-MLX-3bit]`, `[AlfRjw/DeepSeek-R1-Distill-…]`, `[davehind/Kimi-K2.5-vision]` — full `author/name` for every non-`mlx-community` publisher, which is precisely what was bare before |
| A2 shard/weights filtering | `Models ready: 16` — 19 folders on disk minus the 3 weightless ones |
| A1 orphan detection | `Orphan scan: 3 partial download(s) occupying 2.52 GB — NexVeridian/… (283.2 MB), Jiunsong/… (2.2 GB), mlx-community/granite-3.3-2b-instruct-4bit (31.9 MB)` |
| G3 storage accounting | `Sized 16 installed model(s): 79.05 GB total on disk`, published 340 ms after the scan, off the MainActor |
| Context-window resolution | `393216 tokens (config.json)` for a publisher-qualified model — the lookup that A3 previously broke |

**And it found a defect that no test caught.** B9's new store logging fired on every launch:

> `[DOWNLOAD] fetchActive called before the SwiftData container was configured. CONSEQUENCE:
> the operation is skipped and download history is neither read nor written…`

A16 had added `refreshActiveCount()` to `DownloadManager.init`, but that singleton is
constructed during launch **before** `DownloadHistoryStore.configureContainer` runs in
`DevgenticApp`'s async Task. The count was therefore always seeded to 0 regardless of reality.
Masked in practice — `reconcileOrphans()` runs moments later and flips any stale actives to
`.interrupted`, so 0 was accidentally correct — but it is fragile and logged a hard error every
launch. Fixed: `init` no longer fetches, and `DevgenticApp` calls `primeActiveCount()` after
the container is up and orphans are reconciled. Verified gone on relaunch.

This is the argument for running the app: the observability work from Batch 2 paid for itself
on the first launch, catching an ordering bug that 111 passing tests did not.

#### A real download, observed end to end

`mlx-community/parakeet-tdt-0.6b-v2` was pulled through the UI. The full lifecycle, from the
log, in order:

```
[MLXSTORE] HF fetch gen=1 → …?sort=downloads&direction=-1&limit=30&skip=0&filter=mlx
[MLXSTORE] HF fetch gen=1 ← 30 models
[MLXSTORE] HF replace: total=30 category=All
[MLXSTORE] HF fetch gen=2 → …            ← second fetch, generation token increments
[MLXSTORE] HF replace: total=30 category=All
[MLXSTORE] Starting download task for 'mlx-community/parakeet-tdt-0.6b-v2'.
[DOWNLOAD]  Active download count 0 → 1.
[DOWNLOAD]  Holding a power assertion for downloads — Downloading 1 model.
            … 2m26s …
[MLXSTORE] Download of 'mlx-community/parakeet-tdt-0.6b-v2' finished successfully.
[MLXSTORE] Terminal state for '…': completed. Clearing in-flight handles.
[DOWNLOAD]  MLX '…' terminal → completed (record 6CEEECE3…, progress=1.000, installedNow=true, error=nil).
[DOWNLOAD]  Active download count 1 → 0.
[DOWNLOAD]  Released the power assertion for downloads; normal idle sleep resumes.
[MLXSTORE] Sized 17 installed model(s): 81.52 GB total on disk.
```

That single trace confirms, on real traffic: **A16** (the observable count actually transitions
0→1→0), **G9** (the assertion is taken *and released* — no leak), **A6** (handles cleared on the
success path), **B2** (the terminal classification names every signal that produced it),
**A11** (`gen=1` / `gen=2` both complete without clobbering), **A22** (payload tagged with its
category), **B7/A10** (`URLComponents`-built URL, real status handling), **A9** (30 models sized
with no 429 — every card in the screenshot shows a size), and **G3** (re-sized to 17 models /
81.52 GB immediately after the install).

#### Confirmed from the store UI

- **A18** — all six category tabs present, including `All`, which the old code deleted in
  tool-filtering mode.
- **A23** — the Download pill renders on every card without hovering.
- **B17 + A8** — badges read `✓ Comfortable · ~2.76 GB RAM`, `⚠ Tight Fit · ~10.03 GB RAM`,
  `✗ Too Large · ~33 GB RAM`: per-verdict symbol, verdict name, and the RAM figure labelled as
  RAM. Previously a bare colour dot and an unlabelled "2.76 GB" that read as a duplicate disk size.
- **Describe-don't-enforce holds** — a card verdicted `Too Large · ~33 GB RAM` still shows an
  active Download button; the advisory sheet warns, it does not gate.
- **A17** — `parakeet-tdt-0.6b-v2` and `Qwen3.5-9B-MLX-8bit` show `Installed`; both verified
  present on disk. No false positives among the 30 listed.

#### Second pass — Installed tab, filter, and Stop mid-generation

**B1 — Stop actually stops.** A generation on `granite-3.3-8b-instruct-4bit` was cancelled
mid-sentence:

```
11:03:28  [MLX-LOAD] Loading 'granite-3.3-8b-instruct-4bit' — on disk 4.6 GB,
                     est. runtime 5.14 GB, budget 18 GB, verdict Comfortable.     ← B13
11:03:35  User requested to cancel streaming → TRACE_END status: cancelled
11:05:35  MLX Service has been idle for 2 minute(s). Releasing memory.
11:05:35  🔻 [Unload Start] Active: 4.28 GB | Cache: 1.02 GB
11:05:35  ✅ [Unload Done] Freed: 5.3 GB
```

The idle timer started **at the moment of cancel** and there is no `Refusing model unload —
N generation(s) in flight` anywhere after it. Pre-fix, the orphaned producer would have held
`activeGenerations > 0` while decoding to EOS, so the idle window could not have started on
time and any unload in it would have been refused.

⚠️ Note the consumer-side marker (`Generation cancelled by consumer after N chunk(s)`) did
**not** fire. The loop exited because the stream *terminated* — `onTermination` cancelled the
producer and the sequence ended — rather than via the `Task.isCancelled` check. That is the
cleaner path and confirms the `onTermination` wiring; the consumer check is a backstop that was
not reached here, and therefore remains itself unexercised.

**G3 / A8 / A3 / A20 in the Installed tab.** `17 installed · 81.52 GB on disk` renders under
the tabs; every card carries its size (2.47 GB … 17.19 GB … 331.1 MB) where all were blank
before; fit badges appear on installed models for the first time (they were gated on a non-nil
size); publisher labels show `srswti`, `davehind`, `lmstudio-community`, `AlfRjw`; and typing
`granite` filtered 17 → 1 in a field that was previously inert.

**Two defects this pass found — both introduced by this work, both fixed:**

| Defect | Cause |
|---|---|
| Storage row read `1 installed · 81.52 GB on disk` when filtered | Filtered count beside an unfiltered total. Now `1 of 17 shown · 81.52 GB on disk`. |
| Long model names ran under the "Set as IC" / delete overlay | **Regression from A3.** Org labels now render for every model; previously only `mlx-community` had one, so most titles were short and unqualified and never collided. Fixed with single-line truncation, layout priority, and reserved trailing space. |

**Build note.** A stale Xcode-built binary (`~/Library/Developer/Xcode/DerivedData/…`, dated the
previous day) coexists with the one under test. Its log is identifiable at a glance: model names
appear bare (`MLX Analysis [DeepSeek-R1-Distill-Llama-8B-abliterated-Q2-mlx]`) where the current
build emits `[AlfRjw/DeepSeek-R1-Distill-Llama-8B-abliterated-Q2-mlx]`, and it carries no
`[MLXSTORE]` tags at all.

#### Third pass — clean launch on an Xcode-built binary

A rebuild from Xcode (so the stale-binary confusion above is resolved) produced a launch log
confirming the remaining launch-path items:

- **The container-ordering fix holds** — zero occurrences of `fetchActive called before the
  SwiftData container was configured`, the defect the Batch 2 logging surfaced on the first run.
- **Canonical ids throughout** — `[AlfRjw/…]`, `[srswti/bodega-raptor-90m]`,
  `[badmadrad/…]`, `[davehind/…]`, `[lmstudio-community/…]`.
- **17 models** (parakeet included), `Sized 17 installed model(s): 81.52 GB total on disk`,
  `Orphan scan: 3 partial download(s) occupying 2.52 GB`.
- **B10's shortened debounce works as intended** — a second scan moments after the first ran
  rather than being silently swallowed, and correctly reported `Models unchanged (17). Cache
  retained.` At the old 30 s interval it would have returned without looking.
- Hardware context for the fit verdicts: `RAM: 24 GB, Chip: M4 Pro, Budget: 18 GB`.

**Still unverified on device:** the tool-capable toggle (a one-line conditional that renders
only when the store is opened from an Agent profile via *Manage Models* — a few seconds to
eyeball, not worth automating) and G1's disk-full refusal, which needs a genuinely full volume
and is covered by unit tests instead (`MLXDiskCapacityTests`).

Everything else in Batches 0–2 and M1 has now been exercised against real models, real
HuggingFace traffic, a real download and a real cancelled generation.

---

### M1 as shipped — 2026-08-03

9 new tests; 111/111 green across the subsystem and its neighbours.

- **G1 — disk preflight.** `MLXModelService.availableBytes(onVolumeContaining:)` reads
  `volumeAvailableCapacityForImportantUsageKey` (purgeable-aware, unlike the plain key), and
  `hasRoomForDownload(ofBytes:)` requires the download plus a **5 GB headroom** — models land
  on the boot volume, and macOS degrades badly as the startup disk approaches full.
  `DownloadCoordinator` refuses with `.failed("X needs N GB but only M GB is free")`, which
  already routes to an error toast at all three call sites. Applied to Whisper too, using the
  catalog estimate. ⚠️ **Unknown free space proceeds rather than blocks** — a failed stat must
  never stop a legitimate download; `hasRoomForDownload` returns nil and the caller carries on.
  The advisory sheet now shows Free Disk beside the RAM figures, since it modelled RAM only
  while the user was committing gigabytes of disk.
  **Also closed here:** `removePartialDownload` is now called from the download **error**
  path, not just the cancel path. Batch 0 fixed *where* that function looked; a download that
  *failed* mid-pull still stranded every byte it had written — which is precisely what a
  full disk produces.
- **G3 — storage accounting.** Per-model sizes are computed **off the MainActor** after each
  scan and published when they land. Deliberately not folded into the scan itself: that runs
  synchronously on the main thread and already walks the whole tree (A15), and sizing every
  multi-gigabyte model there would have made the exact problem A15 describes worse. The
  Installed tab gains a "N installed · X on disk" row, installed cards carry their real size
  (so the fit badge and size sorting work there for the first time), and the delete
  confirmation names the bytes it reclaims. `totalInstalledBytes` is nil — not 0 — until the
  pass completes, so the UI can distinguish "not known yet" from "nothing installed".
- **G9 — sleep assertion.** `DownloadPowerAssertion` holds an
  `NSProcessInfo` activity with `.idleSystemSleepDisabled`. Hooked to `DownloadManager`'s
  aggregate active count rather than per-download, so it covers all three backends through
  one seam and **cannot leak**: when the count reaches zero every assertion is released
  unconditionally. Display sleep is deliberately still permitted — only idle *system* sleep
  is suppressed, so the screen still dims and closing the lid still sleeps the machine.
