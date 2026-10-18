// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HuggingFaceAccountCheck.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "HuggingFaceToken")

// Why: only `name` is declared on purpose: any other decoded field could be picked up by a log line, crash report or
// state dump.
/// The one field of `GET /api/whoami-v2` this app reads.
/// The rest of the response (email, avatar, org list) is discarded by `JSONDecoder` and never held by this process.
struct HFWhoAmI: Decodable {
    let name: String
}

// Why: keep the network out of the secrets store: a `URLSession` dependency would make it also the thing that talks to
// the network, and a `SecureKeyStorage` prompt can hang a headless test run.
/// Asks HuggingFace whether the saved token is one it actually accepts.
/// Kept apart from `HuggingFaceTokenStore` (one Keychain item) and `MLXModelService` (whoami is not a model operation).
enum HuggingFaceAccountCheck {

    /// Three outcomes, not two: the server said no, and we could not ask, are different facts.
    /// Telling an offline user their token is invalid would send them off to regenerate a working credential.
    enum Verdict: Equatable {
        /// 200 — the token authenticates, as this account.
        case valid(account: String)
        /// 401/403 — the server rejected the credential itself.
        case rejected
        /// Anything else. The token has NOT been shown to be wrong.
        case inconclusive(HFRequestError)
    }

    // MARK: - Pure rules (the part tests can reach)

    /// Maps a classified transport failure onto a verdict.
    /// `nonisolated` and pure so the decision is testable without a network call (the project has no `URLProtocol` stub).
    nonisolated static func verdict(forFailure error: HFRequestError) -> Verdict {
        switch error {
        case .unauthorized:
            return .rejected
        case .rateLimited, .notFound, .serverError, .offline, .malformedResponse, .invalidURL:
            return .inconclusive(error)
        }
    }

    /// The sentence shown under the token field.
    /// Only `.rejected` may say anything about the token; every other verdict reports that the check failed,
    /// and states that the token was still saved.
    nonisolated static func message(for verdict: Verdict) -> String {
        switch verdict {
        case .valid(let account):
            return "Verified — signed in to HuggingFace as \(account)."
        case .rejected:
            return "HuggingFace did not accept this token. It has been saved, but gated downloads will fail until it is replaced — check on huggingface.co that it hasn't been revoked."
        case .inconclusive(.offline):
            return "Couldn't reach HuggingFace to check this token. It has been saved and will be used as-is."
        case .inconclusive(let error):
            return "Couldn't check this token right now (\(error.errorDescription ?? "unknown error")). It has been saved and will be used as-is."
        }
    }

    // MARK: - The thin network call

    // Why: `reloadIgnoringLocalCacheData` is load-bearing: `URLCache` ignores the `Authorization` header, so a cached 200
    // from an earlier token could confirm a revoked one.
    /// Asks HuggingFace who the saved token belongs to.
    /// Verifies the token the app will actually use, read by `HFRequest.perform` from `HuggingFaceTokenStore`.
    /// Call it only after `store(_:)` has returned true.
    static func verify() async -> Verdict {
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return .inconclusive(.invalidURL)
        }
        do {
            let who = try await HFRequest.get(
                HFWhoAmI.self,
                from: url,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            // The account name is returned for display and is never logged.
            logger.notice("[MLXSTORE] HuggingFace token verified against /api/whoami-v2. CONSEQUENCE: gated and private repos are reachable and requests use the authenticated rate limit.")
            return .valid(account: who.name)
        } catch let error as HFRequestError {
            let outcome = verdict(forFailure: error)
            if outcome == .rejected {
                logger.error("[MLXSTORE] HuggingFace rejected the saved token (\(error.logLabel)). CONSEQUENCE: the token stays in the Keychain and is still sent, but every gated download will fail and rate limits stay at the anonymous tier until the user replaces it.")
            } else {
                logger.warning("[MLXSTORE] HuggingFace token check inconclusive: \(error.logLabel). CONSEQUENCE: the token is saved and used as-is; it has NOT been shown to be wrong, so the UI must not tell the user to replace it.")
            }
            return outcome
        } catch {
            // `HFRequest.perform` rethrows `CancellationError` for `URLError.cancelled`.
            logger.warning("[MLXSTORE] HuggingFace token check did not complete (\(error.localizedDescription)). CONSEQUENCE: the token is saved and used as-is; nothing is asserted about it.")
            return .inconclusive(.malformedResponse(error.localizedDescription))
        }
    }
}
