// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  GenerationError.swift
//  Devgentic
//
//  Typed failures a cognitive generator can raise, so `LLMRetryStrategy` can tell them apart from
//  "the model produced output we could not parse".
//
//  ⚠️ WHY THIS EXISTS. Six generators each threw an untyped `NSError(domain: <their own string>,
//  code: 422)` for an empty response — six different domains, no shared type — so the retry
//  strategy could not match any of them and every one fell through to the UNCLASSIFIED arm, which
//  is reserved for the MODEL'S OUTPUT BEING UNPROCESSABLE. Three things then happened that were all
//  wrong for a model that emitted nothing:
//
//    1. it burned the PARSE-failure budget, so five empties aborted a run on a cap meant for five
//       malformed-JSON responses;
//    2. it injected "Your last output failed validation … You MUST output valid JSON … no markdown
//       fences" into the model's own context — a false statement, ~205 chars, EVERY attempt, telling
//       a silent model to stop doing something it never did;
//    3. telemetry recorded `.parseExhausted`, and the user was told "the model is returning
//       responses I can't interpret. Try rephrasing or switching models" — advice that points away
//       from the actual lever, which is usually sampling config.
//
//  The precedent for the fix is `consecutiveModelSlotFailures` in `LLMRetryStrategy`, whose own
//  comment already draws this exact distinction: it is not a parse failure "since the model
//  produced nothing to parse". Empty output is the same category of thing.
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
