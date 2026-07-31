# Devgentic — Architecture Reference

> **Living document.** Written incrementally, one subsystem at a time, as work touches it —
> not generated in one pass at the end. A doc assembled retroactively records what someone
> *remembered*; this one records what was *verified in code* at the time of writing.
>
> **Rules for extending it** (please follow, including future AI sessions):
> 1. Document only behaviour you have **read in the source** during that session. If you did
>    not verify it, leave it in the coverage map as `not documented` rather than writing
>    plausible prose. A confident wrong description is worse than an admitted gap.
> 2. Every non-obvious constant, cap or fork gets **the reason it exists**, not just its
>    value. Values are recoverable from the code; reasons are not.
> 3. When you change behaviour the doc describes, update the doc **in the same change**.
> 4. Record **invariants** (§7) with the failure they prevent. Those are the lines a future
>    reader is most likely to "simplify" into a bug.
> 5. Add a dated line to the changelog (§9 — §8 is Observability).

---

## Coverage map

| Area | Status | Section |
|---|---|---|
| Agent memory & context budgeting | **documented** (2026-07-29, audited 2026-07-30) | §1–§6 |
| Tool execution & output handling | **documented** (2026-07-29, audited 2026-07-30) | §3 |
| Tool argument → subprocess safety | partial — the three fixed criticals only (2026-07-31) | §3.5 |
| Tool confirmation & approval scope | **documented** (2026-07-31) | §3.6 |
| Tool catalogue (what exists, where it's offered) | **documented** (2026-07-31) | §3.7 |
| History compaction / checkpoints | partial — the render side only | §2.4 |
| Backends & dialect routing | not documented | — |
| Capability decorators (Plan&Execute, Reflexion) | not documented | — |
| Workflow engine (DAG) | not documented | — |
| RAG / knowledge base / file context | not documented | — |
| Persistence (SwiftData + ObjectBox) | not documented | — |
| HITL / InteractionCenter | not documented | — |
| UI / theming / Code interface | not documented | — |
| Vision & multimodal | not documented | — |

Existing design docs live at the repo root and in `Docs/`; they are point-in-time design
notes, not maintained references. Prefer this file when they disagree, and say so here.

---

## 1. Agent memory: the problem

An LLM has no memory between requests. Everything the agent "remembers" is re-sent on every
turn. So the entire design question is: **what is worth re-sending, and what can be
re-derived?**

Devgentic's answer:

- **Repeatable** → don't carry it. A file can be read again.
- **Not repeatable** → carry it. A file you overwrote cannot be un-overwritten from nothing;
  a build that failed cannot be un-failed.

Almost every rule below follows from that one distinction.

---

## 2. The two history channels

A request carries conversation history on **two independent channels**. They are separate on
purpose.

| Channel | Content | Where it lands | Who gets it |
|---|---|---|---|
| **Episodic XML** | structured record of turns and tool actions | system prompt, Layer 7 | everyone |
| **Native turn pairs** | plain user/assistant prose | real message turns | native providers only |

Kept apart because merging them caused a mimicry loop: when tool summaries were baked into
assistant turns (`[Used: tool(...) → result]`), models imitated the *format* instead of
calling tools. Prose teaches conversation flow; XML teaches tool-execution context.

MLX (non-native) gets the episodic channel only.

`PromptLayerConfig` gates it: `agent`, `bot` and `code` all set `includeEpisodicMemory`;
`workflow` does not.

### 2.1 History strategies

Four, selected per agent profile (`HistoryStrategy`). Non-agent profiles resolve to
`recentHistory`.

| Strategy | UI name | Renders |
|---|---|---|
| `recentHistory` (default) | Recent | last **10** turns, full |
| `fullHistory` | Full | every turn, full |
| `pointer` | On-Demand | every turn as a skeleton + a retrieval tool |
| `hybrid` | Smart | last **3** full, older as skeletons |

`EpisodicHistoryFormatter.build(strategy:from:…)` is the **single** dispatch. `AgentConnect`
builds the prompt through it and the fit gauges size the prompt through it, so the number the
gauge shows is by construction the payload that ships.

⚠️ **The Code interface hardcodes `.pointer`** (`CodeSessionManager`), with `maxIterations: 20`.

### 2.2 Turn rendering

Exactly **two** renderers exist — `renderInlineTurn` and `renderPointerTurn`. Every strategy
composes them; none re-implements them. This is load-bearing: the three strategies previously
hand-rolled their own copies and drifted, silently losing `<effect>` on one path, emitting
non-deterministic attribute order on another, and discarding compaction summaries on two.

```xml
<episodic_memory>
  <compacted_context checkpoint_turns="12">…summary of turns folded away…</compacted_context>
  <recent>
    <turn status="completed|failed|partial|cancelled" goal="…" recency="2 turns ago">
      <attached_images>chart.png</attached_images>          <!-- vision profiles only -->
      <outcome>…agent's reply, 200 chars…</outcome>
      <termination>…why the run stopped early…</termination>
      <action tool="write_file" status="success">
        <params path="…" content="…"/>                       <!-- sorted; 200 chars/value -->
        <error>…failure text, 1024 chars…</error>
        <effect file="Shape.java" path="/abs/path" added="14" removed="5">
+    public abstract double calculateArea();
-    public double area();
        </effect>
      </action>
      <user_correction>User denied: delete_file</user_correction>
    </turn>
  </recent>
</episodic_memory>
```

### 2.3 Turn status

`terminalOutcome` from the executor is authoritative, overriding action-derived status. This
catches the case where every tool call technically succeeded but the run was force-terminated
by the circuit breaker or iteration exhaustion — without the override those turns read as
`completed` and taught the model that a looping pattern was acceptable.
`completedWithWarnings` renders as `partial`.

### 2.4 Compaction & checkpoints

When history grows past a threshold, a background pass summarises old turns into a
`.checkpoint` message. From then on the formatters render only turns *after* it, prefixed by
`<compacted_context>`. The compaction runs off the request path; the checkpoint pays off from
the next turn.

⚠️ An empty post-checkpoint history renders `<recent/>` **plus** the summary — never an empty
string. Returning "" discards the summary that was just computed to stand in for the turns it
replaced, and (because tool registration is gated on the rendered text) the means to fetch it
back.

---

## 3. Tools — output, safety, confirmation, catalogue

This surprises people, so it is stated plainly.

| | Reaches the model on later turns? | Cap |
|---|---|---|
| **Successful** tool output | **No. Not at all.** | — |
| **Failed** tool output | Yes, as `<error>` | **1,024 chars** + loss marker |
| Timeline display / resume | Yes | **32,768 chars** + loss marker |

### 3.1 Why successful output is dropped

A successful read is repeatable. Carrying an 8 KB `read_file` result forward on *every*
subsequent prompt costs the same 8 KB every turn, forever, to save one re-read. The model is
told the call happened, with what arguments, and that it succeeded — enough to decide whether
to look again.

**Known limitation.** This reasoning holds for reads and breaks for non-repeatable output:
`execute_shell` output, HTTP responses, timestamps, random samples. Re-running is impossible,
expensive, or returns something different. For those the agent has genuine amnesia. See §6.

### 3.2 Why failed output is kept

A failure is *why the agent must do something different*, and it usually cannot be re-derived
— the state that caused it may be gone. It was capped at 150 chars, which is shorter than
most compiler errors and nearly every stack trace, so the model routinely adapted to a cause
it could not read. Now 1,024 with an explicit `[truncated N characters of error output]`
marker, because a silently clipped trace hides the real frame.

`truncate()` (bare `"..."`) is still used for goals, outcomes and params — nobody acts on
those. `cappedError()` is used where the text is a decision input.

### 3.2.1 What retrieval brings back

`get_conversation_history(N)` returns the user query, the agent's response **in full**, and
every tool execution with its arguments, status, error and file diff. It does **not** return
tool results — a call is reproducible from its name and arguments, both of which it does
return, so storing results would spend context on something the agent can simply ask for
again. What a write *changed* is not reproducible, so that rides `<effect>` and is served in
full.

⚠️ The agent response is the one field where the split is real: the prompt carries 200 chars
(`<outcome>`), retrieval carries the whole thing. Until 2026-07-29 the tool handed back the
same 200-char clip, so a `pointer` agent could never recover more than 200 characters of any
answer it had given, and the retrieval its own skeleton instructed it to make returned nothing
it did not already have.

### 3.3 Two independent output caps

`ToolExecutionData.cappedOutput` clips at **32,768** when persisting to the timeline. Not
cosmetic: `TimelineTurnReconstructor` rebuilds a *resumed* run's tool observations from
`output`, so the marker is what tells the model its view is incomplete. The full text reached
the model on the original run; a resumed run sees the marker. Both truncation points log
`[TOOL_OUTPUT]` with the original size.

### 3.4 Failure classification

`classify()` keys on the typed `ToolFailureCategory`, never on output text. String-matching
the phrasing was the old scheme and is deliberately gone.

| Category | Action status | Bans the tool? |
|---|---|---|
| `userDenied` | `denied` | ✅ (also emits `<user_correction>`) |
| `permissionRejected` | `permission_denied` | ✅ |
| `notFound` | `not_found` | ✅ |
| `executionThrew` / `timeout` / `invalidArgs` / `cancelled` | 1:1 | ❌ soft, may retry |

Bans go into `negativeConstraints` ("Ghost Protocol") and are injected as `FAILED PATHS` in
the system prompt.

⚠️ A failed row with **no** category is legacy persisted data. It falls back to a generic
`.failed` and deliberately does **not** ban the tool — banning on unclassified data would ban
timeouts too.

### 3.5 Tool arguments reaching a subprocess

Tool arguments are **model-supplied**, so anything that can steer the model — a web page, a
file it was asked to read, a RAG chunk, a poisoned dependency — can choose them. The value
being protected is a profile that deliberately withholds `execute_shell` but enables ordinary
tools; every hole below let such a profile reach code execution anyway.

There are **two** interpreters to get past, and closing the first does not close the second.

**1. The shell.** Closed structurally by argv: `Process.arguments` never carries a command
string a shell will re-parse. Audited across `Tooling/` on 2026-07-31; the last offender was
`disk_usage largest_files`, which built `["-c", "find \"\(searchPath)\" … | head -\(topN)"]`
and so was invisible to a guard keyed on variable NAMES (`cmd`, `command`, …) because it named
nothing. `ShellInterpolationGuardTests` now also matches the sink — `"-c"` followed by an
interpolated literal — which is the shape an author cannot avoid. That guard is line-based and
therefore blind to multi-line (`"""`) command strings; the one such site clamps a `Double` to
`0.0...1.0` before interpolating, so it is safe by validation, not by the guard.

**2. The invoked program's own option parser.** Argv gives it the same attacker-controlled
words, and a read-only query tool can carry write, read and mutate primitives with no shell in
sight. Confirmed against `/usr/bin/git` and fixed in `GitCommandBuilder`:

| Option | Primitive it gives the caller |
|---|---|
| `--output=<path>` | creates or **truncates** any file, with git's output as content |
| `--no-index <a> <b>` | diffs two arbitrary paths; **`-C <repo>` is not honoured** |
| `--contents <file>` (blame) | reads an arbitrary file into the output |
| `branch -a -M <new>` | renames the checked-out branch (`-a` blocks `-d`/`-D`, not this) |

Two layers, in this order, because they fail differently:

- **Config neutralisation** (`GitCommandBuilder.hardening`) — `-c core.fsmonitor=`,
  `-c diff.external=`, `-c core.hooksPath=/dev/null`, `-c core.pager=cat` on *every*
  invocation. A repository is data, but git executes what `diff.external` and `core.fsmonitor`
  name, and both live in `<repo>/.git/config`. **The trigger call needs no arguments at all** —
  a bare `diff` runs `diff.external`, a bare `status` runs `core.fsmonitor` — so argument
  filtering structurally cannot see it. These are `-c` globals, not the equivalent flags,
  because `args` is appended *after* the subcommand and a flag loses to a later one:
  `-c diff.external=` wins over a subsequent `--ext-diff`, whereas `--no-ext-diff --ext-diff`
  re-enables the program.
- **An option denylist** (`deniedAnywhere`, plus `deniedForBranch`) — the table above. Matched
  on the option NAME, taken from before any `=`, and applied *after* tokenising, because a
  leading `\` or quote reconstructs a dash (`\--output=x` → `--output=x`) and would slip any
  guard written against the raw string. Exact names suffice: git rejects abbreviated long
  options here (`--outp` is an error). `-c`/`-C`/`-t` are denied for `branch` only — they mean
  "copy branch" there and something harmless elsewhere (`git log -c` is a combined diff).

`--no-textconv` is passed per-action rather than set as config, because a `.gitattributes`
textconv driver's config key is named by the *repository*, so there is no key to empty; the
`--textconv` that would countermand it is on the denylist.

A denylist is knowingly incomplete — a future git option could open a new primitive. It is the
second layer; the config neutralisation is what makes code execution unreachable.

The same lens applies to every search tool. `code_search`, `find_definition`, the three
`code_search_*` splits and `grep_files` all pass a model-supplied pattern to ripgrep or grep,
and each argv now carries `--` before it. Without that separator a pattern beginning with `-`
is read as a flag: confirmed against `/usr/bin/grep`, where `-f <path>` makes grep take its
pattern **list** from an arbitrary file, and ripgrep's `--pre` names a preprocessor **command**
it executes — so on any machine with ripgrep installed the same hole is code execution rather
than an unconfined read. Each tool has two argv branches (ripgrep, then a grep fallback), and
adding the separator to one and not the other is the obvious way to half-fix it, so a test
counts the separators per file.

`GitCommandBuilder.tokenize` splits on the POSIX `IFS` set — space, tab, newline, CR — and
deliberately not `Character.isWhitespace`, which is the *Unicode* whitespace set. They differ on
U+00A0, U+2000–200A, U+3000 and more, and the difference was reachable: `HEAD~1<NBSP>--output=…`
reads to an operator as one innocuous revision name, but `isWhitespace` split it and promoted
`--output=` to its own argv element, where neither a shell nor git would have split at all. The
scalar-wise test matters because a Swift `Character` is a grapheme *cluster*, so `\r\n` is one
Character and matches neither `"\r"` nor `"\n"` in a `Set<Character>`.

**AppleScript is the third interpreter**, and argv does not apply to it: a tool cannot hand
`NSAppleScript` an argument vector, only source text, and AppleScript reaches a shell itself via
`do shell script`. The mitigation is escaping, and it lives in ONE place —
`AppleScriptEscaping.escapeStringLiteral` — because the observed failure mode is a tool that
escapes *most* of its interpolations: `apple_notes` escaped its title, body and search term and
missed the `list` folder, while `manage_safari_tabs` escaped nothing, so a `"` in its `url`
closed the literal **and** the enclosing `tell` block and the rest ran as script. Backslash is
escaped first (or the later escapes would be escaped in turn), then the quote, then `\n`/`\r` —
a literal cannot span lines, so a raw newline ends the statement.

That escaper is only for values landing **inside** a quoted literal. A value interpolated into
a script *position* — an identifier, a count, a whole clause — has no quoting to escape into and
must be constrained by type instead; the clamped `Int` tab index in `manage_safari_tabs` and the
`0.0...1.0` brightness in `MacOSUtilityTools` are the correct pattern for that case.

**Two tools are shells by design**, and no amount of the above changes that. `execute_shell` and
`batch_command` both run `/bin/zsh -c <caller's command>`. They now share `ShellCommandGuard`
(interactive programs, bare REPLs, interactive sudo) — previously those refusals lived inside
`ShellSessionManager` and so applied to `execute_shell` only, meaning `batch_command` bypassed
every one of them by being a different tool. **A guard attached to one tool is a guard on a
name, not on a capability.** `BatchCommandTool.destructivePatterns` is a footgun speed-bump, not
a boundary: `rm  -rf /` with two spaces, `find / -delete` and `python3 -c '…os.system(…)'` all
pass it, and no addition changes that — the argument to `zsh -c` is a complete language.
`run_applescript` is the third member of this set. The only real boundary for all three is
whether the profile grants them.

That set has a name — `ToolCapability.arbitraryCodeExecution` — and it is the single answer to
"does this tool run whatever the model wrote?". The line it draws is *the argument is a
program*, not *this could cause damage*: `delete_file` is destructive and deliberately outside
it, because it does one bounded thing to a named path and its arguments can be validated. These
three cannot be bounded by argument validation at all.

Before it existed, each consumer kept its own list of names and they disagreed:
`HITLRiskTier.classify` named `execute_shell` and `run_applescript` but not `batch_command`, so
the same `/bin/zsh -c` was badged **"Destructive"** or **"Modifies"** depending on which tool the
model picked. Lists of names go stale silently — `disk_usage` belonged in this set until
2026-07-31 and appeared in none of them — so the set is not trusted: `ToolCapabilityTests` reads
the tool sources, finds every tool that hands its own `arguments.` to an interpreter (three
shapes: `zsh -c`, `NSAppleScript(source:)`, `ShellSessionManager.execute`), and fails the build
if such a tool is missing from the set **or** if a name in the set no longer executes anything.
Both directions matter; a stale entry over-warns forever just as quietly as a missing one
under-warns. The guard was verified by removing `batch_command` and confirming four tests fail
naming it.

⚠️ **The capability deliberately does not gate anything.** Per-tool `requiresConfirmation`
remains the only thing deciding whether the user is asked, exactly as the profile configured it:
a tool set to run automatically still runs automatically. What the capability changes is the
*labelling* of a confirmation that was going to happen anyway. One consequence was accepted
knowingly (2026-07-31): the banner hides **"Allow for this chat"** for `.destructive` tools, so
`batch_command` can no longer be pre-authorised for a conversation — it now behaves exactly like
`execute_shell`, which was the point of unifying them.

### 3.6 Who gets asked, and what an answer covers

Whether the user is asked before a tool runs is decided **per tool, by the profile** —
`requiresConfirmation`, nothing else. No capability class forces it (§3.5, invariant 14) and
nothing warns when related tools are configured differently: a configured preference is the
answer, not an input to one.

Two things were not honouring that.

**Action nodes never asked.** They bypass `ToolExecutionMediator`, which is what raises HITL for
the agent path — so a tool the user had set to ASK ran silently inside a workflow. The
`requiresConfirmation: false` in `resolveWorkflowTool` was not even the mechanism; nothing on
that path read the flag at all. The Action branch now performs its own check against the node's
own tool configuration, suspending through the same `ExecutionSuspensionService.suspend` the
agent path and Gate nodes use.

The original rationale — *"workflow actions are pre-approved at design time; gate risky ones
behind a Gate node"* — holds for the **shape** of the call: the author picked the tool and wrote
the argument templates. It does not hold for the **values**, which resolve from upstream, and
therefore from model output, at run time. So the banner shows the RESOLVED arguments, unlike the
timeline event beside it which stays argument-names-only because it is exportable; approving
`args: [command]` without seeing the command is not consent. Argument edits made in the banner
are re-encoded and used — offering an editor and then running the original arguments would be
worse than offering no editor.

**"Allow for this chat" leaked across nodes.** `SessionToolApprovals` was keyed by conversation,
and every node of a run shares one conversationID — so approving a tool in one node silently
auto-approved it in every other node, including nodes deliberately configured to ask. The scope
is now `(conversationID, nodeID?)`, with `nodeID` nil outside workflows so ordinary chat is
unchanged. There is deliberately **no fall-back in either direction**: a node grant does not
answer a conversation-scoped check, and a conversation grant does not blanket-approve every node
— falling back is precisely the leak. `clear(conversationID:)` still drops the whole run,
node scopes included.

The `nodeID` reaches the check through `WorkflowExecutionContext`, which `ReActAgentExecutor`
already receives, then one parameter into `executeToolCalls`/`executeSingleTool`. The persisted
store key was deliberately **not** version-bumped: the old format (a bare conversation UUID) is a
strict subset of the new one (`conversation|node`), so grants users already gave still hydrate.

---

### 3.7 The tool catalogue

Written 2026-07-31 because the surface had grown past the point where anyone could say what was in
it. Every count below was derived from source that day, not from a registry's own opinion of
itself; where a reader agent and the source disagreed, the source won.

#### What is actually there

| | Count |
|---|---|
| Tool structs in source | **77** |
| Reachable via `AgentConnect.resolveNativeTool` | **72** |
| Injected directly, not via dispatch (`ask_user`, `final_answer`, `get_conversation_history`, `load_skill`, `update_project_context`) | 5 |
| **Unreachable — no construction site anywhere** | **0** |
| Offered in the Tool Library (Chat / agent / workflow profiles) | 63 |
| In `CodeToolPreset` | 16 (9 of them Code-only) |
| **Dispatchable but surfaced in no UI** | **0** |

Both numbers that mattered are closed. **Every tool in source is reachable**, down from 11 orphans
at the start of 2026-07-31, and **every reachable tool is offered in the Tool Library**, down from
25 invisible. The two registries that decide those questions now agree exactly — which they had
never done before.

The tool COUNT also understates the decision the model faces. 21 tools multiplex on an `action`
argument, hiding **81 distinct operations** between them — `manage_windows` alone has 9. The real
menu is closer to 130 operations than to 74 tools.

#### Reading the table

`R` read · `W` write/delete · `RW` both · `X` executes arbitrary code.

**Where** is availability, and the three values are not degrees of the same thing:
- **Chat** — registered in `LocalToolManager`, so it appears in the Tool Library and a user can
  enable it on any agent/bot/workflow profile.
- **Code** — in `CodeToolPreset.defaultTools`. Code profiles get these whether or not they are in
  the library, and `hiddenToolNames` stops the user disabling them.
- **_profile-only_** — a dispatch case with no registration: it runs, but is offered nowhere.
  **No tool is in this state today**, and the legend is kept because nothing prevents it
  recurring. Such a tool reaches a profile only through a stored tool list that already names it
  (an imported profile, or one saved while it was still registered) — not through the workflow
  Action-node picker either, which reads the same `UnifiedToolStore` as the Tool Library. And
  `ProfileValidator` never checks tool names against any catalog, so that import is accepted
  silently.
- **dead** — no construction site. Present in source, callable by nothing.

⚠️ `hiddenToolNames` is a **UI filter, not an execution guard**. A profile whose stored tool list
already names a hidden tool still dispatches it fine — the user simply cannot see it to turn it
off. That is how a Code profile can end up holding `edit_code` *and* `edit_code_single` *and*
`edit_code_batch`: three shapes for one intent, which is the exact confusion the split was
introduced to prevent.

#### Dead code — cleared 2026-07-31

At the start of the day 11 tools were unreachable: no dispatch case, no injection site, no
construction site anywhere. **All are now deleted** — 6 files and one struct, ~770 lines, 11 tools.
**Every tool remaining in source is reachable.**

| Removed | Tools | Note |
|---|---|---|
| `DeviceControlTools.swift` | `toggle_system_settings`, `manage_displays`, `manage_media_playback` | each duplicated a live tool (`toggle_dark_mode`, `display_management`, `media_control` + `manage_audio`) |
| `AdvancedFinderTools.swift` | `manage_finder_tags`, `trigger_quicklook`, `empty_trash` | `manage_finder_tags` was a read-only subset of the live `finder_tags` |
| `CommunicationTools.swift` | `manage_apple_mail`, `send_imessage` | both built AppleScript from unescaped String arguments (§3.5) |
| `VectorSearchTool.swift` | `recall_conversation_history` | dispatch was removed earlier as redundant with the RAG pipeline; the struct outlived it |
| `UpdateSessionTool.swift` | `update_session_context` | referenced by nothing but itself |
| `ScratchpadTool.swift` | `scratchpad_tool` | see below — it was never a tool |
| `XcodeOrchestratorTool` (struct only) | `xcode_orchestrator` | a 6-action `xcodebuild` wrapper; its file's other three tools are live |

`CommunicationTools` was the one that mattered beyond tidiness: the injection could not fire
because nothing could call it — but adding a dispatch case would have armed it. Deleting removes
that permanently.

**`scratchpad_tool` was never a tool.** It was a struct of static constants whose own doc comment
claimed it was "intercepted natively by the ReActAgentExecutor". No such interception exists —
nothing in Swift referenced `ScratchpadTool` at all. It defined a resolver for pointers of the form
`[ scratchpad_tool $X ]`, and nothing ever emitted that format: the working-memory strategy that
DOES elide repeated observations writes `"IDENTICAL TO Step M"` markers, which are read by the
model directly and need no resolver. A design that was replaced, with the definition left behind.
Note it was never advertised either — no prompt or listing carried its name — so the model could
not have called it even if a resolver had existed.

**Two removals deliberately left something behind.** `recall_conversation_history` keeps its label,
icon and argument-summary case in `AgentTimelineView`: stored conversations from before the removal
still contain calls to it, and that view renders history — deleting the mappings would make old
turns fall back to a generic label for no gain. A tool's display metadata outlives the tool. And
`xcode_orchestrator` was the only tool setting `outputMayContainErrorText`, so the test pinning
"an opted-out tool must THROW its operational failures rather than return an `Error:` string" was
re-pointed at `execute_shell` rather than deleted with it — that invariant belongs to the opt-out,
not to the tool that happened to carry it.

⚠️ **What was given up with `xcode_orchestrator`**: build, test, list-schemes, read-build-errors,
open-file and clear-derived-data, for a macOS development tool. It had never been reachable, so
nothing regressed — but this is a decision to drop the capability rather than wire it up and fix
its option-injection exposure (§3.5). Rebuilding it is a bigger job than restoring the file.

#### One implementation, two names — fixed 2026-07-31

`ManageContactsTool` was dispatched under **both** `manage_contacts` and `read_contacts`: not two
similar tools but the same struct, offered twice, so the model had to reason about a choice that
did not exist. The `read_contacts` case was removed. `manage_contacts` survives because it is the
one registered in the Tool Library; `read_contacts` was profile-only, reachable solely by naming it
in a profile's tool list.

Worth checking for again — nothing prevents a second `case` pointing at an existing struct, and
nothing would flag it. A dispatch-table test asserting each struct appears at most once would.

#### Deliberate splits — sound design, thin containment

`CodeToolPreset` deliberately exposes three capabilities as narrower tools so a small model cannot
silently mis-set a behaviour-changing boolean:

| Original (in the Tool Library) | Splits (Code preset only) |
|---|---|
| `edit_code` | `edit_code_single`, `edit_code_batch` |
| `code_search` | `code_search_text`, `code_search_symbol`, `code_search_files` |
| `create_file` | `create_new_file`, `overwrite_file` |

The reasoning is right and worth keeping: `overwrite_file` makes the destructive path a tool
CHOICE rather than an `overwrite: true` the model may set by accident. But the two families are
separate implementations in `CodingAssistantTools.swift` and `CodingAssistantSplitTools.swift`, so
every fix to matching, whitespace handling or multi-edit atomicity has to land twice. Given this
repo's history with silent content-rewriting transforms (see the path-normalisation class), that
is the cost that will actually bite. Making the originals shims over the split code paths would
keep two prompt surfaces over one implementation.

#### Multiplexers — the count is not the problem

21 tools switch on an `action` argument. That is usually fine: `git_tool`'s seven subcommands share
one noun and one output shape, and seven separate tools would bloat every prompt for no gain.

What hurt was **mixing side-effect classes inside one multiplexer**, and four did:

| Was | Split out 2026-07-31 | Why |
|---|---|---|
| `manage_calendar` (read/search/create/**delete**) | `delete_calendar_event` | removes a real calendar event |
| `manage_reminders` (read/create/complete/**delete**) | `delete_reminder` | `complete` is reversible, `delete` is not — and they shared one code branch |
| `manage_processes` (list_top/**kill**) | `kill_process` | `SIGKILL` cannot be caught: no cleanup, no save |
| `finder_tags` (read/add/remove/search/**set**) | `replace_finder_tags` | `add`/`remove` preserve what they do not name; `set` discards everything |

A tool carries exactly one `requiresConfirmation`, so before the split that single setting had to
cover both halves, and neither option it left was acceptable. Prompt on every calendar read and the
user learns to approve without looking — which is precisely how the delete gets approved. Prompt on
none and the delete lands silently. "Ask before destroying, not before looking" was not expressible.

Splitting makes it expressible without enforcing anything (invariant 14): each half now carries its
own setting, and what the user sets still decides. It also lets the destructive half be classified
`.destructive` rather than inheriting `.moderate`, so a `kill -9` no longer reaches the banner with
the same pencil icon as a rename — and it makes the destructive path a tool the model must NAME,
rather than one word changed in an `action` string. Same reasoning, same shape as
`create_file` → `create_new_file`/`overwrite_file`.

The moved actions return an explicit error that names the new tool rather than "unknown action": a
model working from an older schema or its own priors needs to be told where the action went, or it
retries the same call. Both PIM refusals are checked BEFORE requesting EventKit access, so a moved
action never triggers a permission prompt.

⚠️ Migration: a stored profile enabling `manage_calendar` keeps read/search/create but loses
`delete` until the new tool is enabled too. That is a behaviour change on existing profiles, not a
pure refactor — arguably the safe direction for a destructive action, but it is not silent.
All four splits are registered in the Tool Library, including `kill_process` — even though its
former host `manage_processes` is not. A tool absent from `LocalToolManager` appears in NEITHER the
Tool Library nor the workflow Action-node picker (both read `UnifiedToolStore`, built from that
registry), so leaving the split half out would have made the capability unselectable rather than
separately controllable — the opposite of the point. Both halves of a split must be registered TOGETHER: registering only `kill_process` briefly left
the destructive half selectable while the harmless listing it was split FROM was not — splitting a
tool to make its dangerous action controllable, and thereby hiding the safe one, is worse than not
splitting it. `manage_processes` was registered 2026-07-31 to close that inversion.

#### Overlaps worth a decision

- `grep_files` vs `code_search`/`code_search_text` — same question, different engines. `code_search`
  is ripgrep-backed and respects `.gitignore`, which is right for a repo and **wrong** for "search
  my Documents". Keeping both is defensible only if that distinction is the reason.
- `glob_files` vs `fs_smart_search` — both find files by pattern.
- `codebase_map` (recursive tree) vs `list_directory` (one level) vs `glob_files` (filtered).
- `batch_command` vs `execute_shell` — neither is a superset: `batch_command` has timeout,
  backgrounding and traceback-preserving truncation; `execute_shell` has per-conversation working
  directory memory. Both are `/bin/zsh -c` (§3.5).
- `get_wifi_info` vs `check_network_status` — overlap on SSID, the field usually wanted.

A large group of tools are thin wrappers over one shell or AppleScript command (`get_power_state`
→ `pmset -g batt`, `disk_usage` → `du`/`df`, `dns_lookup` → `nslookup`, and ~30 more). Subsumption
is **not** on its own a reason to delete them: a wrapper can carry its own confirmation policy,
returns capped structured output, and a small local model calls `get_power_state` far more
reliably than it writes and parses `pmset -g batt`. Collapsing them into `execute_shell` would
trade many tool definitions for one all-or-nothing gate on arbitrary code execution.

#### Not confined to a folder — decided, not overlooked

About 35 of these tools take a filesystem path from the model, spanning read, write, delete and
execute. **None is confined to a root**, and the only checks anywhere in the tool layer are
`expandingTildeInPath` and `fileExists` — *does it exist*, never *is it allowed*. There is no
workspace-root concept for agent profiles (`projectPath` exists only on Code profiles).

This was considered and **declined on 2026-07-31**. The app is a general macOS assistant that
grants shell access by design; the boundary is which profile you run, not which folder it sees.
The tool descriptions ask the model to pass a project root, and in normal use it does — so the
wide access is latent rather than routine. Recording it here so the next reader knows it is a
decision, not an oversight.

Note for anyone revisiting it: `normalizePathArguments` (`ToolExecutionLoop`) is the one place
every path argument already passes through, so a check would go there rather than in ~35 tools.
Its `pathArgumentKeys` list is name-based and currently misses `working_directory`, `output_path`,
`image_path`, `file_a`, `file_b` and `destinationFolder`; workflow Action nodes bypass it entirely.
Both gaps would have to close first, or the boundary would have holes exactly where it matters.

#### One catalogue, two projections

`NativeToolCatalog.entries` is the single declaration of which native tools exist. Both consumers
derive from it: `AgentConnect.resolveNativeTool` is a name lookup, and `LocalToolManager` registers
the entries marked `.library`. **Adding a tool is one line, in one place.**

Until 2026-07-31 it was two hand-maintained lists — a ~100-line `switch` deciding what RUNS and
~90 lines of `registerNative(…)` deciding what is OFFERED — with 63 tools constructed identically
in both and nothing checking they agreed. The failure modes are asymmetric, which is why the drift
only ever ran one way:

- Forget the **registration** → a working, invisible tool. Nobody notices, because it works.
- Forget the **dispatch case** → a visible tool that fails to resolve. Loud, so it never happened.

Every tool bug in the 2026-07-31 audit was that gap: 11 unreachable tools, 25 dispatchable tools in
no picker, one struct dispatched under two names, a split whose destructive half was selectable
while its harmless half was not.

Three shape decisions worth knowing:

- **Entries store a closure, not an instance.** `AgentToolFactory.wrap` is generic over the
  concrete `T` so it can decode `T.Arguments`; a heterogeneous `[any DevgenticTool]` would erase
  exactly the type it needs. `make` captures `T` at each call site, which is what lets one list
  hold 72 tool types.
- **The closure takes a `UUID?`.** Exactly one tool — `execute_shell` — needs the conversation, to
  persist its working directory across calls. `nil` yields the same tool without directory memory,
  which is what the Library needs for metadata. The other 71 ignore it. One uniform signature beat
  a special case.
- **Availability is data on the entry**, not a second list:
  `.library` (everywhere) · `.libraryExceptCode(supersededBy:)` (in the Library, hidden for Code
  profiles because the preset replaces it) · `.codeOnly` (Code preset only) ·
  `.hidden(reason:)` (runs, offered nowhere — nothing is `.hidden` today; the case exists so that
  state has a name and a reason attached rather than being an unexplained absence).

`CodeToolPreset.hiddenToolNames` derives from that. It is the preset's own tools (hidden so the
user cannot disable what the preset guarantees) **union** `NativeToolCatalog.hiddenFromCodeLibrary`.
Until 2026-07-31 the second group was a five-name `Set` literal in `CodeToolPreset` —
`edit_code`, `code_search`, `create_file`, `write_file`, `execute_shell` — with the reason for each
in a comment above the list rather than beside the tool. Now the entry names its replacement:
`edit_code` says `supersededBy: "edit_code_single / edit_code_batch"`. Being superseded is a fact
about the **Code interface**, not about the tool, so Chat and Workflow profiles still see all five.

`CodeToolVisibilityTests` pins the derivation against the exact set the old literal produced — a
refactor that quietly changes which tools a Code profile sees would be worse than the duplication
it removed. Verified by demoting one entry back to plain `.library`: four tests failed, each
naming `execute_shell`.

`defaultTools` derives too. Each entry is now just a name plus, where it differs from the default,
whether the tool asks first — its **description and argument schema come from the catalogue**.
Both were previously spelled out per entry and both were wrong in different ways: the descriptions
were dead text, because resolution reads the tool's own via `AgentToolFactory` and never the
profile's copy; and every schema was an empty `ToolParameters`. The empty schema was harmless for
Code profiles, which never read it — but `Tool.parameters` is exactly what a workflow Action node
binds its arguments from, so the shape was one reuse away from producing a tool with no arguments.
Per-tool settings (`requiresConfirmation`, `isEnabled`) stay in the preset: those are the thing a
preset is actually for.

An unknown name trips an assertion in debug and is logged-and-skipped in release, rather than
crashing a launch over one misconfigured tool; `CodeToolPresetTests` pins the 16-tool membership
so the release path should never run.

`AgentToolFactory` exists because the wrapping logic was `AgentConnect.wrapTool`, private — so the
only way to obtain an `AgentTool` was to be inside `AgentConnect`, which is *why* the list had to
be a switch there and a second list had to exist for the UI. Lifting it out is what made one
source of truth possible.

**Five tools are deliberately outside the catalogue**: `ask_user`, `final_answer`,
`get_conversation_history`, `load_skill` and `update_project_context` are injected by
`AgentConnect` with run-scoped data (chat history, skill manifests, a project folder) that a
startup catalogue cannot supply. `ToolRegistryDriftTests` asserts they stay out of it.

`ToolRegistryDriftTests` changed job with this refactor rather than being deleted: it no longer
reconciles two lists, it asserts the catalogue is still the only source — no dispatch `switch`
reintroduced, no `registerNative` calls, the Library exactly equals the `.library` entries, names
unique, and the catalogue non-empty so none of it can pass vacuously.

#### The catalogue

**Coding Assistant**

| Tool | Purpose | | Where |
|---|---|---|---|
| `batch_command` | Runs a shell command with timeout, working dir, and optional backgrounding | X | Chat+Code |
| `code_search` | Regex search across files, returning matching lines with context | R | Chat |
| `code_search_files` | Lists which files contain a pattern, without showing the lines | R | Code |
| `code_search_symbol` | Finds exact whole-word occurrences of an identifier | R | Code |
| `code_search_text` | Case-insensitive content search returning matching lines plus context | R | Code |
| `codebase_map` | Prints the whole directory tree of a repo, skipping build/vendor folders | R | Chat+Code |
| `create_file` | Writes a new file, creating parent folders; can overwrite on request | W | Chat |
| `create_new_file` | Creates a file, failing outright if the path already exists | W | Code |
| `edit_code` | Replaces exact code blocks in a file; one or many edits per call | W | Chat |
| `edit_code_batch` | Applies several search-and-replace edits to one file at once | W | Code |
| `edit_code_single` | Replaces one unique code block in a file | W | Code |
| `file_overview` | Summarizes a source file: language, line count, and symbols with line numbers | R | Chat+Code |
| `find_definition` | Locates where a function, class, or variable is declared | R | Chat+Code |
| `glob_files` | Finds files by name/glob pattern under a directory | R | Chat+Code |
| `overwrite_file` | Replaces an existing file's entire contents, discarding what was there | W | Code |

**File System**

| Tool | Purpose | | Where |
|---|---|---|---|
| `copy_file` | Duplicates a file or folder to a new path; refuses to overwrite | W | Chat |
| `create_folder` | Creates a directory, including any missing parent directories | W | Chat |
| `delete_file` | Permanently deletes a file or folder, blocking root and home paths | W | Chat |
| `diff_files` | Shows a unified diff between two files, truncated at 6000 chars | R | Code |
| `fs_organize_batch` | Moves many files into one destination folder, optionally simulated | W | Chat |
| `fs_read_metadata` | Reports a file's size, type, dates, tags and download origin URL | R | Chat |
| `fs_smart_search` | Finds files by name or content via Spotlight, with disk-scan fallback | R | Chat |
| `fs_watch_folder` | Starts, stops, or lists background monitors on folder changes _(3 actions)_ | RW | Chat |
| `get_file_hash` | Computes a file's SHA256 or MD5 checksum | R | Chat |
| `grep_files` | Regex-searches file contents in a folder, returning file:line matches | R | Chat |
| `list_directory` | Lists files and folders in a directory with type markers and sizes | R | Chat+Code |
| `move_file` | Moves or renames one file or folder; refuses to overwrite | W | Chat |
| `preview_file` | Shows the first or last N lines of a file without reading it all _(2 actions)_ | R | Chat |
| `read_file` | Reads a file's text, including PDF/DOCX/XLSX/CSV/PPTX/RTF extraction | R | Chat+Code |
| `write_file` | Writes or appends text to a file, creating parent folders as needed | W | Chat |

**macOS Utilities**

| Tool | Purpose | | Where |
|---|---|---|---|
| `apple_notes` | Lists, reads, creates, or searches notes in Apple Notes _(5 actions)_ | RW | Chat |
| `disk_usage` | Reports free disk space, folder size, or the biggest files _(3 actions)_ | R | Chat |
| `display_management` | Lists displays with resolution/position and gets or sets brightness _(3 actions)_ | RW | Chat |
| `external_devices` | Lists connected USB devices, mounted volumes, or all peripherals _(3 actions)_ | R | Chat |
| `finder_tags` | Read, add, remove, replace or search Finder tags on files _(5 actions)_ | RW | Chat |
| `login_items` | Lists startup apps or opens the Login Items settings pane _(2 actions)_ | RW | Chat |
| `open_system_settings` | Opens System Settings at a named pane so the user can configure it | W | Chat |
| `replace_finder_tags` | Replaces every Finder tag on a file, discarding the rest | W | Chat |
| `screen_capture` | Takes a screenshot of the whole screen, a region, or an app window _(3 actions)_ | W | Chat |

**Vision & UI**

| Tool | Purpose | | Where |
|---|---|---|---|
| `click_ui_element` | Clicks a button or control in the front app by its accessibility label | W | Chat |
| `read_screen_state` | Screenshots the main display and returns OCR'd text with bounding boxes | R | Chat |
| `read_ui_element_tree` | Dumps an app's accessibility element hierarchy so the agent can find controls | R | Chat |
| `scroll_ui` | Scrolls the screen up/down/left/right at a screen coordinate _(4 actions)_ | W | Chat |

**Developer & Diagnostics**

| Tool | Purpose | | Where |
|---|---|---|---|
| `get_power_state` | Reports battery percentage and whether the Mac is charging | R | Chat |
| `git_tool` | Read-only git inspection of a repo: status, log, diff, branches, stash, blame _(7 actions)_ | R | Code |
| `kill_process` | Force-terminates a process by pid or name (SIGKILL) | W | Chat |
| `manage_processes` | Lists the top processes by CPU and memory (killing is `kill_process`) | R | Chat |

**System & Shell**

| Tool | Purpose | | Where |
|---|---|---|---|
| `execute_shell` | Runs a zsh command, remembering the working directory per conversation | X | Chat |
| `get_system_stats` | Returns OS version, user name, and free memory | R | Chat |
| `open_application` | Launches and activates a Mac app by bundle identifier | W | Chat |
| `run_applescript` | Runs arbitrary AppleScript to automate apps or the system | X | Chat |

**System Toggles**

| Tool | Purpose | | Where |
|---|---|---|---|
| `get_wifi_info` | Reports current Wi-Fi SSID, signal, channel and security | R | Chat |
| `manage_bluetooth` | Shows Bluetooth power state and paired devices _(2 actions)_ | R | Chat |
| `toggle_dark_mode` | Switches macOS appearance to dark or light, or reports it _(4 actions)_ | RW | Chat |
| `toggle_do_not_disturb` | Turns Focus / Do Not Disturb on or off via Control Center clicks _(3 actions)_ | W | Chat |


**Audio & Media**

| Tool | Purpose | | Where |
|---|---|---|---|
| `manage_audio` | Reads or sets system output volume and mutes/unmutes audio _(4 actions)_ | RW | Chat |
| `media_control` | Sends play/pause, next and previous track keys to whatever app is playing _(3 actions)_ | W | Chat |


**Native Browser Automation**

| Tool | Purpose | | Where |
|---|---|---|---|
| `extract_safari_reader_view` | Returns the visible text of Safari's current tab in paginated chunks | R | Chat |
| `manage_safari_tabs` | Opens, closes, lists or switches Safari tabs and returns the active URL or HTML _(6 actions)_ | RW | Chat |
| `read_safari_bookmarks` | Lists saved Safari bookmarks as title plus URL, capped by limit | R | Chat |

**Network & Connectivity**

| Tool | Purpose | | Where |
|---|---|---|---|
| `check_network_status` | Reports whether the internet is reachable, plus Wi-Fi SSID and local IP | R | Chat |
| `dns_lookup` | Resolves a hostname to IP addresses via nslookup | R | Chat |
| `http_request` | Fetches or posts to a URL and returns status plus first 5000 chars of body | RW | Chat |

**Personal Information**

| Tool | Purpose | | Where |
|---|---|---|---|
| `delete_calendar_event` | Deletes one calendar event by id — irreversible | W | Chat |
| `delete_reminder` | Deletes one reminder by title — irreversible | W | Chat |
| `manage_calendar` | Reads, creates, deletes or keyword-searches Calendar events _(4 actions)_ | RW | Chat |
| `manage_contacts` | Searches, lists or creates entries in the macOS Contacts address book _(3 actions)_ | RW | Chat |
| `manage_reminders` | Lists incomplete reminders, or creates, completes and deletes them by title _(4 actions)_ | RW | Chat |


**System State**

| Tool | Purpose | | Where |
|---|---|---|---|
| `manage_clipboard` | Reads or writes clipboard text and images, or lists its types _(5 actions)_ | RW | Chat |
| `push_local_notification` | Shows a macOS notification with a title and body | W | Chat |


**System Automation**

| Tool | Purpose | | Where |
|---|---|---|---|
| `run_mac_shortcut` | Runs a named macOS Shortcut, optionally piping text into it | X | Chat |

**Workspace Management**

| Tool | Purpose | | Where |
|---|---|---|---|
| `manage_windows` | Tiles, resizes, minimizes, closes, moves or lists application windows _(10 actions)_ | RW | Chat |

**Internal** (injected by `AgentConnect`, never in the Library)

| Tool | Purpose | | Where |
|---|---|---|---|
| `ask_user` | Pauses the agent and asks the user a question, waiting for their reply | R | injected |
| `final_answer` | Ends the agent loop and delivers the finished answer verbatim to the user | W | injected |
| `get_conversation_history` | Returns earlier turns in full — query, agent response, tool recipes | R | injected |
| `load_skill` | Loads a named skill's full instructions, optionally with its bundled resources | R | injected |
| `update_project_context` | Saves durable project notes to .devgentic/context.md for future system prompts | W | injected |

_77 tools._

---

## 4. `<effect>` — what a write actually did

Before this existed, a successful write left the agent knowing it called `write_file` and
nothing about the result. Asked to undo one, the model answered *"I do not have access to a
version control system… restoring the file perfectly is impossible"* — while the app was
holding the pre-write snapshot the whole time (field-observed 2026-07-25). Reverting was never
a tooling problem; it was a memory problem.

### 4.1 Lifecycle

| Stage | Where |
|---|---|
| Derived **once** at tool completion | `ActionEffect.from(toolExecution:)` |
| Persisted on the row | `ToolExecutionData.effect` |
| Copied into memory | `pairTurns` / `buildGraph` → `MemoryAction.effect` |
| Rendered | `renderEffect` → `<effect>` |
| Injected | system prompt Layer 7, **every** request |

Derived once because deriving per prompt-build re-ran an O(n²) LCS for every historical write
on every request — ~6 s for a 4,000-line diff.

It also drives UI: the timeline diff row, the inline diff, and tappable file references.

### 4.2 What is and isn't stored

| Artifact | Holds | Lifetime |
|---|---|---|
| `preWriteContent` / `postWriteContent` | the **full** file, before/after | RAM only — dropped from `encode` |
| `ActionEffect.diff` | changed lines + 2 lines of context | **persisted** |

Neither the original nor the final file content is ever in memory or in the prompt. The effect
is the change, never the file. A snapshot is skipped when the file exceeds
`preWriteSnapshotByteLimit` (**512,000 bytes**) or isn't UTF-8.

### 4.3 The four markers — mutually exclusive, do not merge

| Marker | Counts | Body | What the model can do |
|---|---|---|---|
| *(none)* | real | present | — |
| `truncated="true"` | real | clipped at the per-action cap | nothing; full diff on the timeline row |
| `diff="elided"` | real | dropped for budget | nothing; full diff on the timeline row |
| `diff="on_demand"` | real | not inlined by `pointer` | **`get_conversation_history(N)`** |
| `baseline="none"` | **placeholder** | never existed | nothing — must not offer to undo |

`baseline="none"` is the important one: with no pre-image, `removed="0"` is a placeholder, not
a measurement. Without the marker a destructive overwrite of an 800 KB file reads as a clean
create and the model offers an undo it cannot perform.

`elided` and `on_demand` both mean "no body" but differ on the only question that matters —
whether the model can go and get it. Bodyless effects render self-closing.

### 4.4 A deliberate fork

`TimelineFileViewerAction.resolve(data:missingBaseline:)` answers **differently** for the two
consumers, on one case: an append with no snapshot.

- **Timeline chip** (`.skipAction`, the default) → no affordance. The post-write file is
  snapshot + fragment; opening the fragment as though it were the file would lie.
- **Memory** (`.recordFragment`) → record it. Memory's failure mode is the reverse: silence
  reads as "nothing happened", which is the exact amnesia `<effect>` exists to cure.

---

## 5. Budgets and the chars↔tokens ratio

### 5.1 One ratio

`PromptFitCheck.charsPerToken = 3.0`, both directions. Conservative because code burns tokens
fast.

It used to be two — the gauge priced chars→tokens at 3.0 while budgets were built
tokens→chars at 4.0. A history filled to exactly its 60%-of-window allowance therefore priced
back as **0.6 × 4 ÷ 3 = 80%**, above the 75% overflow threshold. That posted an advisory the
user could not clear, because the cost came from history the composer cannot edit.
`ImageTokenHeuristic.budgetCharsPerToken` now *tracks* the constant instead of restating it,
so the mismatch is unrepresentable rather than documented.

⚠️ **Unification is not complete** (audited 2026-07-30). The main agent request path is
consistent; these still convert by hand and are NOT covered by the invariant below:

| Site | Expression | Problem |
|---|---|---|
| `WorkingMemoryStrategy:95` | `tokenBudget * 4` | token budget → chars at 4.0 |
| `HistoryCompactionService:246` | `Int(Double(icContextWindow) * 0.70) * 4` | window → chars at 4.0 |
| `RAGRetrievalBudget` (`BackendOrchestrationService:1070`) | `Int(Double(tokens) * 3.0 * 0.15)` | right *value*, hard-coded literal — sizes `ragContextString`, which the fit check then charges back |

`TokenUsage.estimated` (`/4`) is a deliberate exception, not a stray: it reports cost, it does
not build a budget. Same for the display-only estimators in the UI.

### 5.2 The budgets

| Budget | Value | Spent on |
|---|---|---|
| `historyCharBudget` | 60% of window, floor 4K | both history channels |
| `nativePayloadCharBudget` | 75% of window, floor 8K | native payload compaction |
| `ActionEffect.diffBudget` | ¼ of `historyCharBudget`, floor 4,608 | **all** effect diffs in one blob |
| `layerOverheadChars` | flat 2,000 | instructions + environment ONLY |
| `responseHeadroom` | 25% of window | reserved for the model's reply |

Both channels ride the same prompt, so the effect budget is a **split** of the history budget,
never a second allocation.

Tool schemas came **out** of `layerOverheadChars` (2026-07-30). They ride every request and
scale with how many tools the profile enables, so folding them into a flat constant charged a
2-tool profile the same as a 30-tool one. They are now measured per-tool. Nothing variable
should go back into that constant.

⚠️ `nativePayloadCharBudget` is also what a spawned sub-agent gets. `CallAgentTool` used to
hand-roll `Int(Double(8192) * 0.75) * 4` — which reads as "75% of the window" but is 24,576
chars, i.e. the *whole* 8,192-token window at 3.0. A cap meant to reserve room for the reply
only engaged after history had taken the room. Fixed 2026-07-30 by deriving it.

### 5.3 Every cap, by what it costs

Classified by **cost model**, because the value matters far less than whether it recurs.

**Class 1 — recurring.** Rides every subsequent request; cost = value × actions × turns ×
every future prompt. This is why these are small.

| What | Cap | Marker on loss? |
|---|---|---|
| Tool output → timeline / resume | 32,768 | ✅ counts characters |
| Tool failure text → `<error>` | 1,024 | ✅ counts characters |
| Effect diff, per action | 4,096 | ✅ `truncated="true"` |
| Effect diffs, aggregate per blob | ¼ history budget | ✅ `diff="elided"` + log |
| Agent reply → `<outcome>` | 200 | `...` |
| Param value → `<params>` | 200 | `...` |
| User query → `goal` | 80 | `...` |
| Pre-write snapshot | 512,000 bytes | ✅ `baseline="none"` |

**Class 2 — one-time.** Paid once, in the turn that asks.

| What | Cap | Marker on loss? |
|---|---|---|
| Tool output → timeline / resume | 32,768 | ✅ counts characters |
| `get_conversation_history` diffs | 8,192 per response | ✅ names the omitted files |
| `get_conversation_history` agent response | 16,384 (½ the persistence cap) | ✅ counts characters |
| `batch_command` output | 1,000 lines / 8,000 chars, head+tail preserved for tracebacks | ✅ both |
| `git_tool` output | 6,000 | ✅ `...[Truncated]` |
| Direct file injection | 50,000 per file / 200,000 total | not verified |
| RAG retrieval | 15% of window, clamped [1,200 … 24,000] | not verified |

**Class 3 — counts, not characters.** `recentTurnLimit` 10 · `hybridInlineCount` 3 ·
`maxIterations` 15 (Code 20) · `maxTimelineEvents` 500 (evicts oldest non-card event, logged) ·
`historyImageLookback` 20.

**Class 4 — capture-time.** `preWriteSnapshotByteLimit` 512,000 bytes. The most consequential
cap in the system: exceed it and no pre-image exists, so the diff can never be built. This is
the whole reason `baseline="none"` exists.

**Class 5 — no model cost.** Display (`collapsedLineLimit` 3, `expandThresholdChars` 220,
`codeBlockLineLimit` 50, table `initialRowLimit` 50), compute guards (`DiffUtility.lcsLineLimit`
5,000, `intraLineCoreLimit` 400, `intraLineMaxPairs` 300, `maxRegexRecoveryLength` 200,000),
storage (`searchCorpusLimit` 1,000, `persistedTabLimit` 20, `transcodeMaxDimension` 2,048).
Found by sweep, not traced in depth.

**The rule worth carrying into new code:** a cap on a *decision input* must state what it
dropped. Bare `...` is fine for a goal or an outcome — nobody acts on those. It was wrong
exactly once, on `<error>` at 150 chars, where the model adapted to causes it could not read.

Elision spends **newest-first, stop on overflow** — "undo that" refers to the most recent
write, and stopping (rather than greedily skipping) keeps the carried set a contiguous recent
window the model can reason about.

### 5.4 The fit gauges

Two surfaces estimate prompt size: the composer ring (`ContextWindowGauge`) and the send-time
check (`BackendOrchestrationService`). Both **render the real episodic blob and count it**
rather than estimating from a parallel copy of the render rules. Affordable because the ring
recomputes on turn boundaries, not keystrokes.

Both read history through **`BackendHistoryResolver`** (2026-07-30), which merges the stored
conversation with the in-memory window and returns it **ascending** — the same source and the
same order the request uses. Previously each gauge read `currentChatMessages`, the view's
**descending** pagination window, and had to reverse it by hand. Two bugs in one: `pairTurns`
walks forward, so a descending array pairs every reply with the wrong question and silently
halves the turn count (a plain character sum is order-independent, which is why it hid for so
long); and the render window is not the conversation, so a long chat was measured on whatever
happened to be paged in.

Reversal at the call site is therefore **gone, not merely correct** — see invariant 8. Do not
reintroduce a `.reversed()` here; if history arrives descending, the resolver is the bug.

Guiding principle throughout: **never charge for payload that will not ship.** A banner the
user cannot clear is worse than no banner — hence images are only counted when the model is
vision-capable and the strategy actually carries them.

---

## 6. Known gaps

Honest list. Each is a decision, not an oversight.

- ~~**11 tools are unreachable and still compiled.**~~ **Fully closed 2026-07-31** — all 11 deleted
  across 6 files plus one struct (~770 lines); every tool in source is now reachable (§3.7). That
  included the `CommunicationTools` pair whose unescaped AppleScript would have become a live
  injection the moment anyone added a dispatch case. Accepted cost: `xcode_orchestrator`'s six
  `xcodebuild` actions are gone rather than wired up.
- ~~**25 dispatchable tools are offered in no UI.**~~ **Closed 2026-07-31** — 20 registered in the
  Tool Library, 4 deleted (`type_text`, `press_key_combo`, `text_to_speech`, `get_focus_context`),
  and 1 (`read_session_history`) left out for a structural reason documented in §3.7. A capability
  nobody can find is a capability nobody can audit; that is no longer true of any tool.
  ✅ The DRIFT that produced it is now guarded — `ToolRegistryDriftTests` asserts the two
  registries agree in both directions, and that no struct is dispatched under two names. Verified
  to fire by removing a registration and adding a duplicate alias; both failed, each naming the
  offender.
- ~~**Multiplexers mix read and irreversible actions under one name.**~~ **Closed 2026-07-31** for
  the four that did — `delete_calendar_event`, `delete_reminder`, `kill_process` and
  `replace_finder_tags` are now separate tools with their own `requiresConfirmation` and a
  `.destructive` label (§3.7). Remaining multiplexers mix only reads with additive writes, which
  one setting can reasonably cover. Migration caveat: existing profiles keep the safe actions and
  lose the destructive one until the new tool is enabled.
- **The split tool families are two implementations, not one** (§3.7). `CodingAssistantTools`
  and `CodingAssistantSplitTools` both implement search-and-replace, so a matching or
  whitespace fix has to land twice. Making the originals shims over the split paths would keep
  two prompt surfaces over one code path.

- **Tool results are never retained — DECIDED, not an oversight** (2026-07-29). Not in the
  prompt, not in retrieval. The recipe to re-run a call (name + exact arguments + status) is
  carried, and that is enough to obtain the result again. Accepted cost: output that is
  genuinely not repeatable — `execute_shell`, HTTP responses, timestamps — cannot be
  recovered, only re-attempted. Revisit only with evidence of a concrete failure this causes;
  the alternative spends context on every prompt to save an occasional re-run.
- **Appends under-claim.** With no snapshot an append records `baseline="none"`, though
  `removed="0"` is genuinely true for an append and undoing it means truncating N lines. The
  XML has no append marker, so the model cannot tell it from an overwrite; under-claiming is
  the safe direction.
- **No cross-turn effect dedup, deliberately.** Ten writes to one file carry ten diffs and
  nine describe dead states — but collapsing them breaks multi-step revert (keeping only turn
  3's diff gets you C→B and loses B→A). Intra-turn dedup is the safe variant, not yet done.
- **Shell failures are classified by prose prefix.** `ToolExecutionMediator.isSemanticFailure`
  decides "did this tool fail?" by testing whether the output starts with the word `error`
  followed by `:` or whitespace, with the length bound applied to the FIRST LINE (so a short
  header with a long body still classifies). The predicate is sound; the problem was that three
  tool authors each picked a different reasonable prefix.

  | Tool | Sniffed? | Reads exit code | Visible this turn | Visible later turns |
  |---|---|---|---|---|
  | `batch_command` | ✅ | ✅ in output | ✅ `Exit code: N` | ✅ `exit="N"` **2026-07-30** |
  | `git_tool` | ✅ | ✅ branches on it | ✅ | ✅ **fixed 2026-07-29** |
  | `execute_shell` | ❌ opted out | ✅ **fixed 2026-07-29** | ✅ `Exit code: N` | ✅ `exit="N"` **2026-07-30** |

  Fixed: `git_tool` returned `"Git error:"` — missing `hasPrefix("error")` by one word, so a
  correctly-detected failure was recorded as a success; it also required non-empty stderr, so a
  silent non-zero exit fell through. `execute_shell` never read `terminationStatus` at all,
  caught every throw into `"Command failed: …"` (which matches nothing), and returned refusals
  for blocked commands as ordinary strings — from a tool whose sniffing is switched off, so all
  three were recorded as successful calls. Blocked commands and launch failures now THROW,
  which is the only channel an opted-out tool has.

  ✅ **The later-turn half is fixed** (2026-07-30). `ShellExitStatus` now owns both the
  `Exit code: N` emission and its parse, `ActiveStreamManager` reads it into
  `ToolExecutionData.exitCode` at the same seam that derives `<effect>`, and
  `EpisodicHistoryFormatter` emits ` exit="N"` on later turns. An agent can no longer read its
  own record of a failed `swift build` and conclude the build passed. Carried because a verdict
  is **not repeatable** — re-running the command after editing answers a different question,
  the same argument that justifies keeping `<effect>` for writes.

  ⚠️ **Still open: reclassification.** A non-zero exit is *recorded* but still classifies the
  tool call as success. That is a real decision, not an oversight: `grep` exits 1 for "no
  match" and `diff` for "files differ", and marking those failed would count them against the
  circuit breaker. `exit` is deliberately a **separate attribute from `status`** — the tool
  succeeded (it ran the command), the command did not. The clean fix remains structured failure
  returns instead of prose sniffing — what `XcodeOrchestratorTool`'s "must THROW" comment is
  groping toward.

- **✅ Pipe-drain deadlock — CLEARED.** A `Process` pipe holds ~64 KB. Draining it only AFTER
  `waitUntilExit()` deadlocks on any command whose output passes that: the child blocks in
  `write()`, the parent in `wait()`, and Phase 10 removed the hard kill that used to break the
  tie. Confirmed empirically — `seq 1 50000` (288 KB) hangs indefinitely wait-then-read,
  returns in 0.027 s read-then-wait.

  **`ProcessRunner`** (`Tooling/Local/Utils/`) is now the ONE way to run a subprocess: it
  drains stdout and stderr concurrently and returns both plus the exit code. 27 sites migrated
  across 11 files, plus `ShellSessionManager.runZshProcess` fixed in place.

  ⚠️ **"Zero wait-then-read sites remain" was written here on 2026-07-29 and was false.**
  `batch_command` still waited then read two pipes. It was missed because a timeout wrapped it:
  a command past 64 KB blocked, the timeout fired, and it reported *"timed out after 30s"* —
  a plausible-looking lie about a command that had actually finished. **A bug wearing a
  believable error message survives a sweep that a hang would not.** Fixed 2026-07-30 with
  `ProcessRunner.run(_:timeout:)` (watchdog on the process, SIGTERM→SIGKILL, partial output
  kept). Verified mechanically afterwards across all 11 remaining `waitUntilExit()` call sites,
  with comment text excluded — the first re-check reported two false positives because the
  phrase appears in the comments that document the fix.

  ⚠️ The dangerous shape was NOT "reads both pipes" — only one site did that. **Ten sites wrote
  `process.standardError = Pipe()` and never read it.** That reads as "discard stderr" and is
  actually "buffer stderr into 64 KB, then hang". `grep -rn` over a home directory emits one
  "Permission denied" line per unreadable directory and passes 64 KB easily, so the search
  tools were the exposed ones — not the tools that looked riskiest.

  Three lessons from the sweep, all learned the hard way:
  0. **A mechanical migration can silently narrow behaviour.** Five sites had set
     `process.standardError = outPipe`, so their ONE read returned *both* streams. Converting
     them to `ProcessRunner.run(process).standardOutput` compiled, passed every test, and
     **dropped stderr** — `xcode_orchestrator` returned builds with the compiler errors
     removed, `dns_lookup` returned blank for every failed lookup. Caught 2026-07-30 by
     diffing what each site did *before* the migration, not by reading what it does now. When
     replacing an idiom, the question is not "is the new call correct?" but "did the old one
     do something this one doesn't?"
  1. **Heuristic site-counting is unreliable here.** Variable names (`process`, `outPipe`)
     repeat across sequential blocks in one file, so a sliding-window classifier produces both
     false positives and false negatives. Three successive counts (28 → 13 → 27) were each
     wrong. The reliable predicate is simply: *any* `waitUntilExit()` with a
     `readDataToEndOfFile()` after it.
  2. **Scripted range-replacement is unsafe on this shape.** `run` / `wait` / `read` are not
     always contiguous — a `} catch { }` frequently sits between them, and a naive range
     splice swallows it. Unbalanced braces at least fail loudly; the silent hazard is
     semantic: one site used `try?` for graceful degradation across several probes, and
     mechanically promoting it to `try` would have made a missing `airport` binary (removed in
     recent macOS) abort the whole network report.

- **`PreSendFitHint` passes `historyChars: 0`** by design — no `messages` parameter, and its
  copy is scoped to "Attached content is…".
- **✅ Prose over-counting — CLEARED** (2026-07-30). Both halves are fixed. `carriesHistoryProse`
  gates the term off for MLX / non-native providers, which get no native turn pairs and receive
  prose only as the 200-char `<outcome>` — it was pricing an 8K window at 248% occupancy. And
  the term no longer sums every message: it builds the real `NativeHistoryConverter` turns under
  the actual strategy and char budget, so the trimmed recent window is what gets counted.

---

## 7. Invariants

Lines a reader is likely to "simplify" into a bug. Each names the failure it prevents.

1. **The four `<effect>` markers never merge.** Each answers a different "what can I do about
   it?". Collapsing any two re-creates the ambiguity `baseline="none"` exists to remove.
2. **Only two turn renderers exist.** A third copy is how `<effect>`, sorted params and
   compaction summaries were lost the first time.
3. **The gauge measures the shipped blob, not an estimate of it.** A parallel estimator is a
   fourth copy of the render rules.
4. **Logging must not alter the payload.** The gauge renders with `correlation: nil` (silent),
   the request with one (logs); the output must be byte-identical.
5. **One chars↔tokens ratio, both directions.** Two ratios means one budget is wrong. Holds on
   the main request path; §5.1 lists the sites that still convert by hand.
6. **Effects are derived once, at tool completion.** Deriving per prompt-build is O(n²) per
   historical write, per request.
7. **`resolve`'s two policies stay two policies.** The chip must refuse an append with no
   baseline; memory must record it.
8. **Ascending history only, from `BackendHistoryResolver`.** `pairTurns` walks forward, so a
   descending array pairs every reply with the wrong question and halves the turn count —
   invisibly, because a character sum is order-independent. Never re-add a `.reversed()` at a
   call site; if history arrives descending, the resolver is the bug. Never substitute the
   view's `currentChatMessages`: that is a pagination window, not the conversation.
9. **Every silent drop is logged with its consequence.** An elision, a trim, a skipped
   snapshot, a rejected retrieval.
10. **`GitCommandBuilder.hardening` goes on every action, ahead of the subcommand.** It is not
    redundant with the option denylist and cannot be folded into it: the RCE it closes is
    triggered by a call carrying **no arguments** (`status`), which argument filtering never
    sees. Ahead of the subcommand because `-c` is a git global and `args` is appended after it.
11. **Model-supplied values never become a shell command string, and never become an
    AppleScript literal unescaped.** Two interpreters, two mitigations — argv for the first,
    escaping for the second. Neither substitutes for the other. §3.5.
12. **A model-supplied value that leads an argv position gets a `--` before it.** Argv ends the
    shell's involvement, not the callee's option parser; `grep -f` and `rg --pre` are the proof.
    Both branches of a tool (the ripgrep path and the grep fallback) need it, not just one.
13. **A guard belongs to a capability, not to a tool name.** The interactive/REPL/sudo refusals
    protected `execute_shell` and nothing else, so `batch_command` — the same `zsh -c` — walked
    past all of them. New shell-running or AppleScript-running tools call the shared guard and
    the shared escaper; they do not grow private copies.
14. **`NativeToolCatalog` is the only place a native tool is declared.** `resolveNativeTool` is a
    lookup and `LocalToolManager` is a projection; neither may grow its own list. A second list
    is what produced every tool bug in the 2026-07-31 audit, and the asymmetry hides it — a
    missing registration is silent because the tool still works. §3.7.
15. **`ToolCapability.arbitraryCodeExecution` describes what a tool DOES; it decides nothing.**
    Per-tool `requiresConfirmation` stays the sole gate, so a profile that set a tool to run
    automatically still does. Anything that starts *enforcing* off this set has changed the
    user's configured behaviour behind their back — which is the one thing it must not do.
    It is also never hand-edited on its own: `ToolCapabilityTests` checks it against the source
    in both directions, and it is meant to fail when the code and the set disagree.

---

## 8. Observability

The app must be debuggable from logs alone. Every line carries a bracket tag and, on the
request path, a `conv:… trace:…` correlation.

| Tag | Reports |
|---|---|
| `[EPISODIC]` | blob size, turns rendered, effects carried/elided and why |
| `[HISTORY]` | native turn trimming, intentionally omitted images |
| `[HISTORY_TOOL]` | retrievals, omitted diffs, out-of-range asks |
| `[EFFECT]` | missing snapshots, truncated diffs, no-op writes |
| `[TOOL_OUTPUT]` | output truncated for persistence |
| `[CTXGAUGE]` | ring occupancy + per-term breakdown |
| `[FIT]` | send-time overflow with a full breakdown |
| `[CodeViewer]` | why a timeline row got no viewer chip |

A render with no correlation is a **measurement** (a gauge sizing the prompt) and logs
nothing — otherwise the log fills with elision warnings for prompts that were never sent.

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-07-31 | **§3.5 added — tool arguments reaching a subprocess.** Adversarial audit of the 2026-07-30 shell→argv sweep. The five converted tools were argv-correct, but the sweep's own top prediction landed: argv does not close the invoked program's option parser. Three reachable code-execution paths fixed — `disk_usage largest_files` (a `zsh -c` string the sweep missed entirely), `apple_notes` list-folder (the one unescaped AppleScript interpolation in that tool), and `git_tool`'s config-write→trigger chain. Fixing the third also closed `git_tool`'s arbitrary file write (`--output`), whole-disk read (`--no-index`, `blame --contents`) and branch rename (`-a -M`). Invariants 10 and 11 added. |
| 2026-07-31 | **Logging hardened across everything touched this session**, per the standing production-logging directive (tag + correlation ID + the CONSEQUENCE stated). `[TOOLRESOLVE]` — an unresolved profile tool was one `warning` with a bare name; it is now an `.error` naming the profile, the conversation and the effect ("the agent will run WITHOUT this capability"), plus a per-run summary line, and `resolveExecutableTools` gained a `profileID:` parameter purely to carry that correlation. `[TOOLCATALOG]` — the startup line now reports the full projection (58 library + 5 library-except-code, 9 code-only withheld) and errors if the registered count disagrees, since a bare count cannot distinguish a shrunken catalogue from a mis-filtered projection. Catalogue duplicate-name collapse now logs before its `assertionFailure`, because `assert` is compiled out of exactly the builds users run. `[GIT_DENY]` and `[KILLPROC]` — security refusals were visible only to the model; an operator asking "why did the agent say it couldn't?" had nothing. `[WF_HITL]` — loop-body HITL forwarding logs that the run is now WAITING, which is the only thing distinguishing that state from a hang. 193 tests pass. |
| 2026-07-31 | **Audit follow-ups cleared.** (1) `extract_safari_reader_view` TRAPPED — a hard crash — on a negative `offset` or `limit`: both reach `String.index(_:offsetBy:)`, and the existing `startOffset < totalLen` guard passes happily for -1. Rejected rather than clamped, so a miscalculated offset is reported instead of silently paginating from the wrong place. (2) **Loop-body HITL events were swallowed.** The loop's `default: break` caught `.requestConfirmation` / `.requestGate` / `.requestClarification` alongside the orchestration events it meant to suppress. Each carries an `operationID` the inner run is already suspended on, so dropping it meant no banner, nobody to answer, and a workflow hung forever with no error or timeout — and Action-node confirmations, added the same day, widened the reachable surface. All three now forward, preserving the operationID and the inner node's id (the approval scope is keyed on it). (3) `ExplorerViewModel.openInTerminal` interpolated a filesystem path raw into `do script "cd \"…\""` — two nested interpreters, AppleScript and the shell, from a path on disk: a crafted filename in any cloned repo sufficed. Now POSIX-single-quoted then AppleScript-escaped. (4) `finder_tags` search interpolated `search_tag` into an `mdfind` QUERY — a fourth interpreter — where a `'` ends the literal and widens the search. (5) `ToolRegistryDriftTests` read `Local/Utils/` while git tracks `Local/utils/`: on a case-sensitive checkout it `XCTSkip`ped, silently disabling the only guard against a reintroduced registration list. Both source scans now assert they read the intended file. 193 tests pass. |
| 2026-07-31 | **Adversarial audit of this session's changes — 3 real defects found and fixed, 2 of them introduced BY the session.** (1) `kill_process` accepted a non-positive pid: `target: "-1"` became `kill -9 -- -1`, a SIGKILL to every process the user owns. The `--` added for option-injection safety is precisely what makes `-1` parse as a target rather than a malformed signal — the separator armed it. Now rejects pid ≤ 0. (2) The Action-node confirmation gate added earlier this session was **unreachable dead code**: `ActionNodeInspectorView.selectTool` hardcoded `requiresConfirmation: false`, so `toolRef.requiresConfirmation` could never be true. The gate was written, documented and reviewed without tracing the value to its producer. Nodes now inherit `def.requiresConfirmation`. (3) git_tool's hardening did NOT close the diff-driver RCE: `-c diff.external=` empties the global hook, but a repo naming its own driver (`.gitattributes` `diff=evil` + `[diff "evil"] command = …`) has a repo-chosen config key no fixed `-c` can empty — reproduced executing with full hardening applied. All content-rendering actions now pass `--no-ext-diff --no-textconv`. Also: the denylist matched option names exactly while **git accepts unambiguous abbreviations** — `git blame --cont <file>` leaked a file past it; long options now match by prefix. The comment claiming abbreviation-immunity was "verified" was false. |
| 2026-07-31 | **`CodeToolPreset.defaultTools` derives its descriptions and schemas.** Each of the 16 entries carried a hand-written description and an EMPTY `ToolParameters`. The descriptions were dead text — resolution reads the tool's own via `AgentToolFactory`, never the profile's copy — and the empty schemas were a latent trap: unread by Code profiles, but `Tool.parameters` is what a workflow Action node binds arguments from, so the shape was one reuse away from a tool with no arguments. Entries are now `preset("name", confirms:)`, with description and schema from `NativeToolCatalog`; per-tool settings stay, since that is what a preset is for. Unknown names assert in debug, log-and-skip in release. `CodeToolPresetTests` pins membership, real schemas, description-equals-catalogue, and the confirm/no-confirm split. 174 tests pass. |
| 2026-07-31 | **Phase 2 — "who sees this tool" is answered once.** `CodeToolPreset.hiddenToolNames` no longer carries a five-name `Set` literal; it derives from `NativeToolCatalog.hiddenFromCodeLibrary`, backed by a new `.libraryExceptCode(supersededBy:)` visibility case that records WHY each is hidden next to the tool rather than in a comment above a list. `libraryTools`/`codeOnlyTools`/`hiddenFromCodeLibrary` are now all projections of one `visibility` field. `CodeToolVisibilityTests` pins the derived set against the literal's exact contents and asserts every superseded tool names its replacement; verified to fire by demoting an entry (4 failures naming `execute_shell`). 180 tests pass. |
| 2026-07-31 | **Phase 1 — `NativeToolCatalog` replaces the two hand-maintained tool lists.** The ~100-line dispatch `switch` in `AgentConnect.resolveNativeTool` and the ~90 lines of `registerNative(…)` in `LocalToolManager` are both gone (−147 and −146 lines); each is now derived from one 72-entry catalogue. `AgentConnect.wrapTool` was lifted out to `AgentToolFactory` — being private was the structural reason a second list had to exist at all. Availability moved onto the entry as data (`.library` / `.codeOnly` / `.hidden(reason:)`), absorbing most of the planned Phase 2. Entries store a closure rather than an instance because `wrap` is generic over `T.Arguments`, and take a `UUID?` because exactly one tool (`execute_shell`) needs the conversation. Parity verified: 63 library + 9 code-only = 72, identical to before. `ToolRegistryDriftTests` rewritten from "do the two lists agree" to "is the catalogue still the only source". 174 tests pass. |
| 2026-07-31 | **Phase 0 of the registry unification — `category` is now a `DevgenticTool` requirement.** Completes a migration abandoned at "Step 3": `NativeToolWrapper` had been reading `category` by `Mirror` reflection, so a tool that omitted it silently became "System Automation" and nothing could say so. Verified first that no registered tool relied on that fallback. The internal injected tools and the two test mocks now declare one; `DynamicMCPTool` derives it from the server's own `ToolDefinition`. Dead `LocalToolManager.execute` deleted — called by nothing, and its presence made a catalogue read as a second execution engine. **Correction it forced:** the compiler immediately found `ConversationHistoryTool`, whose `var name: String { … }` is computed and had therefore been invisible to every `let name = "…"` grep this session — including the one that built §3.7. `get_conversation_history` is a real, documented tool (§3.2.1, §5.3) that was missing from the catalogue and wrongly recorded as a reader hallucination. Native tool types 76 → **77**; injected 4 → **5**. 158 tests pass. |
| 2026-07-31 | **`ToolRegistryDriftTests` added — the drift that caused this whole cleanup is now guarded.** Asserts both directions between `AgentConnect.resolveNativeTool` and `LocalToolManager`: every dispatchable tool is offered somewhere (Library, Code preset, or an `intentionallyUnlisted` entry carrying its reason — currently EMPTY), and every offered tool can actually run. Also asserts no struct is dispatched under two names (the `read_contacts` bug). The registered side is read from the live registry so it reflects real behaviour; the dispatch side is source-scanned because `resolveNativeTool` needs a full `AgentConnect`. Includes a non-vacuity check, because a source scan that finds nothing passes every other assertion while checking nothing. Verified by injecting both bugs — a dropped `registerNative` and a duplicate alias — and confirming each test failed naming the offender. |
| 2026-07-31 | **`read_session_history` removed — the two registries now agree exactly.** Investigated on the hypothesis that it mattered for long sessions. That was its intent — its own comment says it recovers "deep logs from completed episodes stripped by Semantic Compression" — but it could not deliver: `MemoryAction` has no tool-output field (results are deliberately never retained), its `logs: [String]` was **never populated by either construction site**, and `SessionGraph` is now ephemeral computed state with no compression step to recover from. It was also **not** profile-only as previously recorded here: `ToolAugmentedMemory` injected it into every non-tiny/small model's tool list, so it spent a real tool slot advertising a `[SYSTEM: UNCOMPRESSED SESSION GRAPH]` retrieval that returned metadata with empty logs. Every tier now uses `StaticGroundingMemory`; `ToolAugmentedMemory` is kept as the seam for a future deep-memory tool. Source tools 77 → 76, dispatch 73 → 72, **profile-only 1 → 0**. 182 tests pass. |
| 2026-07-31 | **Tool visibility reconciled — every tool but one is now in the Tool Library.** Deleted 4 UI-automation / accessibility tools the owner judged unwanted: `type_text`, `press_key_combo` (plus the private `CGEvent.keyboardSetUnicodeString` helper that served only `type_text`), `text_to_speech`, and `get_focus_context` (whole file `ContextAwarenessTools.swift`). Registered the remaining 14 profile-only tools. `read_session_history` is the sole exception and cannot simply be registered — it requires a non-optional `conversationID` and is built per-call, while the registry builds one instance at startup; surfacing it is a semantic change to the tool, not a registration fix (§3.7). Source tools 81 → 77, dispatch 77 → 73, Library 49 → 63, invisible 19 → 1. 161 tests pass. |
| 2026-07-31 | **`manage_processes` registered — split-inversion closed.** Registering only `kill_process` after the split left the destructive half selectable in the Tool Library while the harmless listing it was split FROM was not, because a tool absent from `LocalToolManager` appears in neither the Library nor the Action-node picker. Both halves of a split must be registered together; splitting a tool to make its dangerous action controllable and thereby hiding the safe one is worse than not splitting it. Library 48 → 49, profile-only 20 → 19. 150 tests pass. |
| 2026-07-31 | **Last two orphans deleted — zero unreachable tools remain.** `XcodeOrchestratorTool` (struct only; the other three tools in its file are live) and `ScratchpadTool`. The latter was never a tool: a struct of static constants whose doc comment claimed native interception by `ReActAgentExecutor` that does not exist, defining a resolver for `[ scratchpad_tool $X ]` pointers nothing ever emitted — the live working-memory path writes `"IDENTICAL TO Step M"` markers the model reads directly. Its name was never advertised in any prompt either. `xcode_orchestrator` was the only tool setting `outputMayContainErrorText`, so the test pinning "an opted-out tool must THROW rather than return an `Error:` string" was re-pointed at `execute_shell` — the invariant belongs to the opt-out, not that tool. Accepted cost: six `xcodebuild` actions dropped rather than wired up. Source tools 83 → 81, unreachable 2 → **0**. 178 tests pass. |
| 2026-07-31 | **Two more orphan tools deleted**: `VectorSearchTool` (`recall_conversation_history`) and `UpdateSessionTool` (`update_session_context`), 195 lines. The first had already been dropped from dispatch as redundant with the RAG pipeline — the struct simply outlived the decision; the second was referenced by nothing but itself. Its timeline label/icon/summary entries in `AgentTimelineView` were deliberately KEPT: stored conversations still contain calls to it and that view renders history. Source tools 85 → 83, unreachable 4 → 2 (`xcode_orchestrator`, `scratchpad_tool`). 180 tests pass. |
| 2026-07-31 | **Four hidden utilities surfaced in the Tool Library**: `preview_file`, `dns_lookup`, `get_wifi_info`, `get_power_state`. All read-only reporters that were dispatchable but registered nowhere, so they appeared in neither the Library nor the Action-node picker — registration drift between the hand-maintained `LocalToolManager` and `resolveNativeTool`, not a policy. Library 44 → 48, invisible 24 → 20. |
| 2026-07-31 | **Destructive actions split out of four multiplexers.** `manage_calendar delete` → `delete_calendar_event`; `manage_reminders delete` → `delete_reminder` (it shared a code branch with the reversible `complete`); `manage_processes kill` → `kill_process`; `finder_tags set` → `replace_finder_tags`. Each bundled frequent harmless reads with an irreversible action under one `requiresConfirmation`, so the user could not express "ask before destroying, not before looking" — and prompting on every read is what teaches the reflex that approves the delete. The new tools are `.destructive` in `HITLRiskTier`; the survivors are not. No enforcement added (invariant 14): each half carries its own setting and the user's choice still decides. All four are registered in the Tool Library — including `kill_process`, whose former host `manage_processes` is not, because a split absent from the registry appears in neither the Library nor the Action-node picker and would have been unselectable rather than controllable. Moved actions return an error NAMING the new tool, checked before EventKit access so they never trigger a permission prompt. Source tools 81 → 85, dispatch 73 → 77, Library 40 → 44. 10 new tests, 133 pass. |
| 2026-07-31 | **`read_contacts` alias removed.** `ManageContactsTool` was dispatched under two names, so the model saw two tools that were one implementation. Kept `manage_contacts` (the Tool Library name); dropped `read_contacts` (profile-only). Dispatch cases 74 → 73. Build green, 123 tests pass. Nothing structurally prevents this recurring — a test asserting each struct appears at most once in the dispatch table would. |
| 2026-07-31 | **Three dead files deleted** (393 lines, 8 tools): `DeviceControlTools.swift`, `AdvancedFinderTools.swift`, `CommunicationTools.swift`. Every tool in them was unreachable — no dispatch case, no construction site, no reference outside the files themselves. `CommunicationTools` was the load-bearing one: `send_imessage`/`manage_apple_mail` built AppleScript from unescaped String arguments, inert only because nothing could call them. Source tools 89 → 81, unreachable 11 → 4. Build green, 123 tests pass. Backups in the session scratchpad. Deliberately dropped with them: `trigger_quicklook` and `empty_trash`, which had no live equivalent and did not work. |
| 2026-07-31 | **§3.7 added — the tool catalogue.** All 89 tool structs documented with purpose, read/write/execute class and where each is offered (Tool Library / Code preset / profile-only / dead). Counts derived from source, not from any registry's self-report. Findings: **11 tools are unreachable** — including three files dead in their entirety (`DeviceControlTools`, `AdvancedFinderTools`, `CommunicationTools`, the last carrying live AppleScript-injection bugs that cannot fire only because nothing calls them); **25 dispatchable tools appear in no UI**; `ManageContactsTool` is dispatched under two names (`manage_contacts`, `read_contacts`); 21 multiplexers hide 81 operations, and the ones mixing reads with irreversible actions cannot carry a single sensible `requiresConfirmation`. §3 retitled from "Tool output" — 3.5/3.6/3.7 are not about output. Also records the **declined** workspace-confinement decision and where a check would go if it is ever revisited. |
| 2026-07-31 | **§3.6 added — workflow confirmations and per-node approval scope.** Two gaps, both against the rule that a configured per-tool preference is the answer. (a) Action nodes never asked at all — they bypass `ToolExecutionMediator`, and the `requiresConfirmation: false` in `resolveWorkflowTool` was not the mechanism (nothing on that path read it); the Action branch now checks the node's own tool config and suspends through `ExecutionSuspensionService`, showing RESOLVED arguments and honouring banner edits. (b) `SessionToolApprovals` was keyed by conversation, and workflow nodes share one — so "Allow for this chat" in one node auto-approved every other node; scope is now `(conversationID, nodeID?)` with no fall-back in either direction. Store key deliberately not version-bumped (old format is a strict subset), so existing grants survive. Retraction: the earlier claim that workflow tools "never ask" was wrong — PROFILE nodes always honoured `requiresConfirmation`; only Action nodes did not. |
| 2026-07-31 | **Shell-equivalent gating unified — labelling only, no gating change.** `ToolCapability.arbitraryCodeExecution` is now the one answer to "does this tool run whatever the model wrote?" (`execute_shell`, `batch_command`, `run_applescript`); `HITLRiskTier.classify` derives from it instead of keeping a second, disagreeing list, and `DevgenticTool.executesArbitraryCode` exposes the same fact tool-side. `ToolCapabilityTests` checks the set against the tool sources in BOTH directions and fails the build on drift — verified by removing `batch_command` and confirming four tests fail naming it. User decisions recorded: per-tool `requiresConfirmation` stays the sole gate (no forced confirmation for the class), and no warning is shown when one of the three is disabled and others are not. Accepted consequence: `batch_command` is now `.destructive`, so the banner no longer offers "Allow for this chat" for it — identical to `execute_shell`, which was the point. Invariant 14 added. |
| 2026-07-31 | **Remaining HIGH findings fixed.** (a) `manage_safari_tabs` open interpolated `url` raw into AppleScript — a `"` closed the literal and the `tell` block and the rest ran as script; escaped, and the escaper extracted to `AppleScriptEscaping` so `apple_notes` and Safari share one rule. (b) `--` end-of-options added to all six search argv branches (`code_search`, `find_definition`, the `code_search_*` shared runner, `grep_files`) — `grep -f <path>` reads an arbitrary file as its pattern list, and `rg --pre` runs a command, so this was a latent RCE on any machine with ripgrep. (c) `ShellCommandGuard` extracted: `batch_command` bypassed every refusal `execute_shell` enforced. (d) `tokenize` now splits on POSIX IFS, not Unicode whitespace. Invariants 12 and 13 added. |
| 2026-07-31 | Retraction: the guard test's recorded justification for excluding `script` — "no AppleScript is built from a String argument anywhere under Tooling" (2026-07-30) — was **false**. `run_applescript` takes an entire script as its argument by design, and `apple_notes`/`send_imessage`/`manage_apple_mail`/`manage_safari_tabs` interpolate String arguments into AppleScript source. The exclusion itself stands (escaping, not argv, is the mitigation there) but the reason is corrected in place; do not read it as "AppleScript is clean". |
| 2026-07-31 | `ShellInterpolationGuardTests` strengthened: matches the `["-c", "…\(…)"]` SINK as well as variable names (the shape that hid `disk_usage`), and asserts a non-zero scanned-file count — a source-scan that reaches zero files passed vacuously before. Known limit recorded: it is line-based and cannot see multi-line command strings. |
| 2026-07-30 | **Audit of the 2026-07-29 work.** Corrected this document's false statements (listed below), which is why several entries here retract earlier ones. |
| 2026-07-30 | Retraction: "zero wait-then-read sites remain" (2026-07-29) was **false** — `batch_command` survived, hidden behind a timeout that misreported the deadlock as a slow command. Fixed with `ProcessRunner.run(_:timeout:)`; the claim is now mechanically verified across all 11 `waitUntilExit()` sites. §6. |
| 2026-07-30 | Regression from that migration: five sites had merged stderr into stdout before it and silently lost stderr afterwards (`xcode_orchestrator` shipped builds with the compiler errors stripped). Fixed via `combinedOutput`; §6 lesson 0. |
| 2026-07-30 | Shell exit codes now survive to later turns as ` exit="N"`, separate from `status`. The §6 table's "❌ classifies success" for `batch_command` / `execute_shell` no longer holds for the later-turn column; reclassification remains open. |
| 2026-07-30 | Gauge alignment: history now read through `BackendHistoryResolver` (store-authoritative, ascending) by both gauges — §5.4's "callers must reverse" warning removed as it contradicted invariant 8. Prose over-counting cleared. Tool schemas measured per-tool and taken OUT of `layerOverheadChars`. |
| 2026-07-30 | `CallAgentTool` sub-agent payload budget derived from `nativePayloadCharBudget` instead of a hand-rolled `* 4` that reserved 100% of the window where 75% was intended. §5.2. |
| 2026-07-30 | Stateless knowledge manifest given one owner (`StatelessKnowledgeManifest`): the emitter and the estimator had disagreed on both the preamble and whether `read_file` gates the manifest, and the sentence now varies when no file-reading tool exists rather than naming one the profile lacks. |
| 2026-07-29 | `ProcessRunner` added (concurrent stdout/stderr drain); 27 wait-then-read sites migrated across 11 files. ⚠️ The "zero remain" claim in this entry was wrong — see 2026-07-30. Earlier counts (28/13) were also both wrong; see §6 on why heuristic counting fails on this shape. |
| 2026-07-29 | Pipe-drain deadlock fixed in `runZshProcess` (drain before wait), reproduced and pinned at 288 KB; 28 further sites audited and catalogued by fix shape. |
| 2026-07-29 | Shell failure classification traced across all three shell-family tools; `git_tool` prefix corrected and its empty-stderr hole closed; `execute_shell` now reads `terminationStatus` and throws on refusals/launch failures. §5.3 reorganised by cost model with the classes it was missing. |
| 2026-07-29 | `get_conversation_history` now serves the agent's response in full (was re-serving the prompt's 200-char clip); tool results confirmed as a deliberate non-feature; `<error>` cap raised 150 → 1,024 with a loss marker. |
| 2026-07-29 | Initial document. §1–§8 written from a session covering episodic memory, `<effect>` consistency, aggregate budgets, gauge alignment, the chars↔tokens unification, and the tool-output caps. All statements verified against source in that session. |
