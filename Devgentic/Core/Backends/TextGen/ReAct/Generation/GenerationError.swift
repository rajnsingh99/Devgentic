// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GenerationError.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A failure raised by a cognitive generator BEFORE any parsing is attempted.
enum GenerationError: Error, Equatable, Sendable {

    /// The provider returned successfully but yielded no text and no tool call.
    ///
    /// NOT a parse failure: there is no output to parse, nothing to correct, and no honest
    /// corrective instruction to give the model. `generator` names the strategy for the log, since
    /// the six generators produce this for different dialects and knowing which one matters when
    /// reading a field bundle.
    case emptyResponse(generator: String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse(let generator):
            return "Empty response from model (\(generator))."
        }
    }
}
