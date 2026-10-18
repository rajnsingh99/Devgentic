// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingCatalog.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "OnboardingCatalog")

// MARK: - Starter models

/// One model the Setup Assistant offers.
struct OnboardingStarterModel: Identifiable, Hashable, Sendable {
    /// HuggingFace repo id (MLX) or Ollama `name:tag`. This is exactly what the profile stores.
    let id: String
    let displayName: String
    /// Where it sits on the ladder: "Tiny", "Small", …
    let sizeClass: String
    let summary: String
    /// Exact download size in bytes: every file in the HF repo (MLX) or every layer in the Ollama manifest.
    /// Hardcoded so onboarding can show it before anything is fetched; re-read it whenever an id changes.
    let downloadBytes: Int64
    /// The smallest Mac (unified memory, GB) this is a sensible choice for. Describes, never gates:
    /// a bigger model on a smaller Mac is shown with a warning, not hidden.
    let recommendedMinimumRAMGB: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

enum OnboardingStarterCatalog {

    /// The ceiling for anything offered here (24 GB).
    static let maxDownloadBytes: Int64 = 24_000_000_000

    static let mlxModels: [OnboardingStarterModel] = [
        OnboardingStarterModel(
            id: "lmstudio-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen3.5 2B",
            sizeClass: String(localized: "Tiny"),
            summary: String(localized: "Fastest. Fine for quick questions and simple tool calls."),
            downloadBytes: 1_749_091_164,
            recommendedMinimumRAMGB: 8
        ),
        OnboardingStarterModel(
            id: "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5 4B",
            sizeClass: String(localized: "Small"),
            summary: String(localized: "Quick and noticeably smarter. A good default on any Apple silicon Mac."),
            downloadBytes: 3_061_140_963,
            recommendedMinimumRAMGB: 8
        ),
        OnboardingStarterModel(
            id: "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen3.5 9B",
            sizeClass: String(localized: "Balanced"),
            summary: String(localized: "Reliable multi-step tool use at a comfortable speed."),
            downloadBytes: 5_977_082_681,
            recommendedMinimumRAMGB: 16
        ),
        OnboardingStarterModel(
            id: "lmstudio-community/gemma-4-12B-it-MLX-4bit",
            displayName: "Gemma 4 12B",
            sizeClass: String(localized: "Capable"),
            summary: String(localized: "Google's Gemma 4. Strong writing and reasoning with native function calling."),
            downloadBytes: 6_773_394_640,
            recommendedMinimumRAMGB: 24
        ),
        OnboardingStarterModel(
            id: "lmstudio-community/Qwen3.6-27B-MLX-4bit",
            displayName: "Qwen3.6 27B",
            sizeClass: String(localized: "Medium"),
            summary: String(localized: "The most capable here. Slower, and wants plenty of memory."),
            downloadBytes: 16_081_499_536,
            recommendedMinimumRAMGB: 32
        ),
    ]

    static let ollamaModels: [OnboardingStarterModel] = [
        OnboardingStarterModel(
            id: "qwen3.5:2b",
            displayName: "Qwen3.5 2B",
            sizeClass: String(localized: "Tiny"),
            summary: String(localized: "Fastest. Fine for quick questions and simple tool calls."),
            downloadBytes: 2_683_396_637,
            recommendedMinimumRAMGB: 8
        ),
        OnboardingStarterModel(
            id: "qwen3.5:4b",
            displayName: "Qwen3.5 4B",
            sizeClass: String(localized: "Small"),
            summary: String(localized: "Quick and noticeably smarter. A good default on most Macs."),
            downloadBytes: 3_324_173_757,
            recommendedMinimumRAMGB: 8
        ),
        OnboardingStarterModel(
            id: "qwen3.5:9b",
            displayName: "Qwen3.5 9B",
            sizeClass: String(localized: "Balanced"),
            summary: String(localized: "Reliable multi-step tool use at a comfortable speed."),
            downloadBytes: 6_550_825_373,
            recommendedMinimumRAMGB: 16
        ),
        OnboardingStarterModel(
            id: "gemma4:12b",
            displayName: "Gemma 4 12B",
            sizeClass: String(localized: "Capable"),
            summary: String(localized: "Google's Gemma 4. Strong writing and reasoning with native function calling."),
            downloadBytes: 8_021_618_699,
            recommendedMinimumRAMGB: 24
        ),
        OnboardingStarterModel(
            id: "qwen3.6:27b",
            displayName: "Qwen3.6 27B",
            sizeClass: String(localized: "Medium"),
            summary: String(localized: "The most capable here. Slower, and wants plenty of memory."),
            downloadBytes: 17_769_076_719,
            recommendedMinimumRAMGB: 32
        ),
    ]

    static func models(for backend: ApiProvider) -> [OnboardingStarterModel] {
        switch backend {
        case .mlx: return mlxModels
        case .ollama: return ollamaModels
        default:
            logger.error("[ONBOARDING] No starter models for \(backend.rawValue). CONSEQUENCE: the model step shows an empty list.")
            return []
        }
    }

    /// The largest model this Mac is a sensible fit for, falling back to the smallest.
    static func recommended(for backend: ApiProvider, physicalMemoryBytes: UInt64) -> OnboardingStarterModel? {
        let ramGB = Int(physicalMemoryBytes / 1_073_741_824)
        let list = models(for: backend)
        return list.last { $0.recommendedMinimumRAMGB <= ramGB } ?? list.first
    }
}

// MARK: - Starter tools

/// One tool the Setup Assistant offers, with the copy the onboarding card shows.
struct OnboardingStarterTool: Identifiable, Hashable, Sendable {
    /// `NativeToolCatalog` name.
    let id: String
    let title: String
    let purpose: String
    let iconName: String
}

enum OnboardingToolPreset {

    /// Ten everyday tools for a general Mac assistant. Every one is enabled and set to ASK by
    /// default, so the first agent can act but changes nothing without the user's approval.
    static let tools: [OnboardingStarterTool] = [
        OnboardingStarterTool(id: "read_file", title: String(localized: "Read files"),
                              purpose: String(localized: "Text, code, PDF, Word, Excel and more"), iconName: "doc.text"),
        OnboardingStarterTool(id: "list_directory", title: String(localized: "Browse folders"),
                              purpose: String(localized: "List what is inside a folder"), iconName: "folder"),
        OnboardingStarterTool(id: "spotlight_search", title: String(localized: "Spotlight search"),
                              purpose: String(localized: "Find files anywhere on your Mac"), iconName: "magnifyingglass"),
        OnboardingStarterTool(id: "create_new_file", title: String(localized: "Create files"),
                              purpose: String(localized: "Write a new file, never overwrites"), iconName: "doc.badge.plus"),
        OnboardingStarterTool(id: "run_command", title: String(localized: "Run commands"),
                              purpose: String(localized: "Run a shell command"), iconName: "terminal"),
        OnboardingStarterTool(id: "http_request", title: String(localized: "Web requests"),
                              purpose: String(localized: "Fetch a web page or call an API"), iconName: "globe"),
        OnboardingStarterTool(id: "manage_calendar", title: String(localized: "Calendar"),
                              purpose: String(localized: "Read and add calendar events"), iconName: "calendar"),
        OnboardingStarterTool(id: "manage_reminders", title: String(localized: "Reminders"),
                              purpose: String(localized: "Read and add reminders"), iconName: "checklist"),
        OnboardingStarterTool(id: "manage_apple_notes", title: String(localized: "Notes"),
                              purpose: String(localized: "Read and write Apple Notes"), iconName: "note.text"),
        OnboardingStarterTool(id: "manage_clipboard", title: String(localized: "Clipboard"),
                              purpose: String(localized: "Read or set the clipboard"), iconName: "doc.on.clipboard"),
    ]

    /// Builds the profile's tool list; description and schema come from `NativeToolCatalog`, never restated here.
    /// A name the catalogue does not know asserts in debug and is logged and omitted in release.
    static func makeTools(enabled enabledNames: Set<String>, autoApproved: Set<String>) -> [Tool] {
        tools.compactMap { starter in
            guard let entry = NativeToolCatalog.entry(named: starter.id) else {
                assertionFailure("OnboardingToolPreset names '\(starter.id)', which is not in NativeToolCatalog")
                logger.error("[ONBOARDING] Starter tool '\(starter.id)' is not in NativeToolCatalog. CONSEQUENCE: the new agent is created without it.")
                return nil
            }
            let tool = entry.executable()
            return Tool(
                name: tool.name,
                description: tool.description,
                isEnabled: enabledNames.contains(starter.id),
                requiresConfirmation: !autoApproved.contains(starter.id),
                sourceId: ToolSource.builtInSourceID,
                parameters: tool.parameters
            )
        }
    }
}

// MARK: - Default system prompts

enum OnboardingPromptDefaults {

    static let agent = """
    You are a helpful assistant running locally on the user's Mac.
    - Answer directly when you can. Use a tool only when the task needs information from this Mac or an action on it.
    - Before you change anything (files, commands, calendar, reminders, notes), say what you are about to do. The user approves each tool call.
    - If a tool fails, explain what happened and suggest a next step instead of repeating the same call.
    - Keep answers concise and use Markdown for structure.
    """

    static let bot = """
    You are a helpful assistant running locally on the user's Mac.
    Answer clearly and concisely, use Markdown for structure, and say when you are unsure instead of guessing.
    """

    static func prompt(for type: ProfileType) -> String {
        type == .agent ? agent : bot
    }
}
