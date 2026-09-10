# Devgentic

[![Licence: AGPL v3](https://img.shields.io/badge/Licence-AGPL_v3-blue.svg)](LICENSE)
[![Platform: macOS 26.1+](https://img.shields.io/badge/Platform-macOS%2026.1%2B-lightgrey.svg)](#requirements)

A native macOS app for building and running AI agents — locally where you want it, in the cloud where you need it.

You create **backend profiles**. Each one binds a model to a set of capabilities, and the app gives it somewhere to run: a chat window, a node-graph workflow canvas, a project-scoped coding interface, a global-hotkey panel, or a floating voice orb.

> **Status: pre-release.** Free software under the GNU AGPL v3 — see [Licence](#licence) — and please [read this first](#before-you-use-this).

## What it does

**Five profile types**, each a different shape of work:

| Profile | What it is |
|---|---|
| **Bot** | Plain LLM chat — a model, instructions, and optional knowledge sources. No tools. |
| **Agent** | A ReAct loop with tools, resilience settings, a history strategy, and optional Planning and Self-Reflection layers. |
| **Workflow** | A node graph — profile nodes, routers, code transforms, human-in-the-loop gates, triggers and actions — with per-node timeouts and context budgets. |
| **Image Generator** | Text-to-image, with a negative prompt and aspect ratio. |
| **Code** | A project-scoped agent with a fixed 16-tool preset for reading and editing a codebase. |

**Seven model backends.** `MLX` and `Ollama` run locally; `OpenAI`, `Anthropic`, `Google`, `OpenRouter` and any OpenAI-compatible endpoint run remotely. MLX models are browsed and downloaded in-app from the Hugging Face Hub.

**Tools.** Agent profiles can call 72 native macOS tools — filesystem, shell, git, code search and editing, Calendar/Reminders/Contacts, Safari, UI automation, network — plus anything exposed by a connected MCP server. Every tool call can be gated by a human-in-the-loop approval keyed to its risk tier.

**Surfaces beyond the main window.** A global-hotkey QuickAccess panel; **Jarvis**, a floating voice orb with wake-word or push-to-talk activation that speaks its answers back; a cron scheduler for unattended runs; and remote bridges for Slack, Discord and Telegram.

## Requirements

- **macOS 26.1** or later (the deployment target)
- **Xcode 26.2** — what the project is developed and built against
- **Apple Silicon** for the MLX backend; everything else is architecture-agnostic

No package manager to install: dependencies are Swift Package Manager only, resolved by Xcode from a tracked `Package.resolved` (14 direct packages, 40 pins). Their licences are collected in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Build

```bash
xcodebuild -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS' build
```

Or open `Devgentic.xcodeproj` in Xcode and run the `devgentic` scheme.

> **Note the casing.** The targets and schemes are lowercase-first — `devgentic`, `devgenticTests` — while the source directories are capitalised (`Devgentic/`, `DevgenticTests/`). This matters for `-only-testing:`.

### ObjectBox code generation

There is **no build phase** for it. ObjectBox's generator is an SPM *command* plugin run by hand, and its outputs are committed — so a clean checkout compiles without running it.

You only need to re-run it after changing a property on an ObjectBox entity. Skipping it produces a confusing error at the new property's static query accessor ("instance member cannot be used on type"), not a missing-file error.

## Tests

```bash
# build once, then run what you care about
xcodebuild build-for-testing -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS'
xcodebuild test-without-building -project Devgentic.xcodeproj -scheme devgentic -destination 'platform=macOS' \
  -only-testing:devgenticTests/JarvisSegmentationTests
```

> **Don't run the whole suite casually.** Parts of it load Whisper models and drive real embedding models, so a full run takes many minutes. Find the classes you need and target them — the two-phase `build-for-testing` / `test-without-building` split above lets you iterate on tests without rebuilding the app.

Two shared schemes exist, `devgentic` and `devgenticTests`; both run the `devgenticTests` bundle. `devgenticUITests` is Xcode template scaffolding and is not wired into either scheme.

## Repository layout

```
Devgentic/              the app target
  Core/                 backends, the agent loop, persistence, RAG, shared utilities
    Backends/           per-provider services; TextGen/ReAct is the agent loop itself
    Persistence/        SwiftData schema + the RAG/embedding stack
  Interfaces/           every SwiftUI surface — and the native tool + MCP implementations
    Main/               main window, sidebar, profile editor, workflow canvas, tool library
    Shared/             reusable chat surfaces: history, composer, code viewer
    Code/  QuickAccess/  Onboarding/
  Jarvis/               the voice orb (self-contained)
  ChatOps/              Slack, Discord and Telegram bridges
  Intelligence/         routing and model-capability analysis
  Observaliblity/       tracing and diagnostics — yes, the directory name is misspelled
DevgenticTests/         unit tests
docs/                   engineering notes on specific subsystems
generated/              committed ObjectBox codegen output
```

The repo root also carries a set of `*_Production_Readiness.md` and `*_Design.md` documents. These are **internal working registers** — they enumerate open defects and architectural weaknesses by name, and they are written for whoever is fixing them, not as user documentation.

## Before you use this

This is pre-release software that drives shell commands, edits files and automates the UI on your machine, with your user's privileges. The human-in-the-loop approval system exists for that reason: read what a tool is asking to do before approving it, and be deliberate about turning on autonomous mode. [`SECURITY.md`](SECURITY.md) spells out what is and isn't considered a vulnerability in a tool built on that trust model — and where to report one.

## Privacy

[`PRIVACY.md`](PRIVACY.md) is the full statement. In short: the app is local-first, has no backend of its own, and sends no analytics or telemetry anywhere. Your conversations, files and configuration stay on your Mac.

The exception is the one you choose. A cloud profile sends its requests to whichever provider you configured — that is what a cloud profile *is*. A local `MLX` or `Ollama` profile keeps inference on the machine.

## Contributing

Issues and discussion are welcome. Pull requests are welcome **after** a discussion — open an issue first so the shape of a change is agreed before the work is done. Every contribution requires signing the [Contributor Licence Agreement](CLA.md); [`CONTRIBUTING.md`](CONTRIBUTING.md) has the details, the file-header rule and the conventions that will otherwise fail the build.

## Licence

Devgentic is free software, released under the **GNU Affero General Public License, version 3** (`AGPL-3.0-only`) — the full text is in [`LICENSE`](LICENSE), and every source file carries an SPDX header saying the same.

In practice:

- You can use it, read it, change it and run it — privately or at work, for any purpose.
- If you **distribute a modified version**, or **run a modified version as a service** that other people use over a network, you must make your source available under this same licence. The network clause is the "Affero" part, and it is deliberate: the Slack, Discord and Telegram bridges make "run it as a service" a real way to deploy this app.
- The licence does not forbid commerce; it forbids closing the source. You may charge for it, host it, or sell support, so long as what you ship stays open under AGPL.

If those terms don't work for your organisation, a commercial licence is available on request from the copyright holder — that is what the [CLA](CLA.md) exists to keep possible.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for details.

Third-party components and their licences: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
