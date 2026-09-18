// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAIModelFamily.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  Which request contract an OpenAI-style model accepts.
//
//  ⚠️ Register A55. `applyGenerationParams` sent one shape to everything: `max_tokens`,
//  `temperature`, `top_p` and — whenever the user had touched the picker — `reasoning_effort`.
//  Reasoning models reject that combination (they take `max_completion_tokens`, and only the
//  default temperature), and non-reasoning models reject `reasoning_effort` outright. So a profile
//  with Reasoning Effort set failed on a normal model, and a reasoning model failed on the
//  parameters the panel sends by default.
//
//  Modelled on `AnthropicModelGeneration`, with **one rule deliberately inverted**: an unrecognised
//  id here classifies as `.standard`, not as the newest family. Anthropic ids come from a
//  first-party `/v1/models` list, so unknown means newer. This provider also serves arbitrary
//  OpenAI-compatible endpoints — LM Studio, vLLM, llama.cpp, Groq, DeepSeek — where an id can be
//  anything at all, and `.standard` is the shape those universally accept.
//

import Foundation

enum OpenAIModelFamily: Equatable {
    /// o-series and GPT-5 style reasoning models: `max_completion_tokens`, no sampling overrides,
    /// `reasoning_effort` accepted.
    case reasoning
    /// Everything else, including every unrecognised id: `max_tokens`, sampling accepted,
    /// `reasoning_effort` NOT sent.
    case standard

    /// Classifies a model id.
    ///
    /// ⚠️ Strips a vendor prefix first: OpenRouter ids arrive as `openai/o3-mini`, and matching the
    /// raw string would classify every OpenRouter reasoning model as standard.
    static func classify(modelName: String) -> OpenAIModelFamily {
        let id = modelName
            .lowercased()
            .split(separator: "/").last
            .map(String.init) ?? modelName.lowercased()

        // ⚠️ Anchored to the START of the id and requiring a boundary, so `o1`, `o1-mini` and
        // `o3-mini-2025-01-31` match while `orca-2`, `olmo-7b` and a local fine-tune called
        // `o1-distill-qwen-lookalike` do not get swept in by a bare prefix test.
        for series in ["o1", "o3", "o4"] where id == series || id.hasPrefix("\(series)-") {
            return .reasoning
        }

        if id == "gpt-5" || id.hasPrefix("gpt-5-") { return .reasoning }

        return .standard
    }

    /// The parameter name this family uses for an output-token cap.
    var maxTokensParameterName: String {
        self == .reasoning ? "max_completion_tokens" : "max_tokens"
    }

    /// Whether `temperature` / `top_p` may be sent. Reasoning models accept only the default and
    /// reject anything else.
    var acceptsSamplingParameters: Bool { self == .standard }

    /// Whether `reasoning_effort` may be sent.
    var acceptsReasoningEffort: Bool { self == .reasoning }
}
