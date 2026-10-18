// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAIModelFamily.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Which request contract an OpenAI-style model accepts: reasoning models take `max_completion_tokens`, standard ones
/// `max_tokens`.
/// An unrecognised id falls back to `.standard`, the shape arbitrary OpenAI-compatible endpoints universally accept.
enum OpenAIModelFamily: Equatable {
    /// o-series and GPT-5 style reasoning models: `max_completion_tokens`, no sampling overrides,
    /// `reasoning_effort` accepted.
    case reasoning
    /// Everything else, including every unrecognised id: `max_tokens`, sampling accepted,
    /// `reasoning_effort` NOT sent.
    case standard

    // Why: strips a vendor prefix first: OpenRouter ids arrive as `openai/o3-mini` and would otherwise classify as
    // standard.
    /// Classifies a model id.
    static func classify(modelName: String) -> OpenAIModelFamily {
        let id = modelName
            .lowercased()
            .split(separator: "/").last
            .map(String.init) ?? modelName.lowercased()

        // Anchored to the start of the id with a boundary, so `o1`, `o1-mini` and `o3-mini-2025` match but `orca-2` and
        // `olmo-7b` do not.
        for series in ["o1", "o3", "o4"] where id == series || id.hasPrefix("\(series)-") {
            return .reasoning
        }

        if let major = gptMajorVersion(of: id), major >= 5 { return .reasoning }

        return .standard
    }

    /// The major version of a `gpt-N` / `gpt-N.M` id, or nil when it is not one; every GPT from 5 on is a reasoning model.
    /// Anchored and boundary-checked: `gpt-4o`, `gpt-4.1` and `gpt-5x-local` give 4, 4 and nil; a major of 50 or more is not
    /// a GPT version.
    static func gptMajorVersion(of id: String) -> Int? {
        guard id.hasPrefix("gpt-") else { return nil }
        let rest = id.dropFirst(4)
        let version = rest.prefix { $0 != "-" }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), major < 50 else { return nil }
        return major
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
