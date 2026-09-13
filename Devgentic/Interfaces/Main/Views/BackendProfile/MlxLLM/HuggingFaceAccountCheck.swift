// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HuggingFaceAccountCheck.swift
//  Devgentic
//
//  `looksLikeToken` is a SHAPE check, so a wrong or revoked token saved cleanly and only
//  failed later, inside a download — at the moment the user was least able to act on it.
//

import Foundation

private let logger = DGLogger(category: "HuggingFaceToken")

/// The one field of `GET /api/whoami-v2` this app reads.
///
/// ⚠️ DELIBERATELY ONE FIELD. The real response also carries `email`, `emailVerified`,
/// `avatarUrl`, `isPro` and the org list. Declaring only `name` means `JSONDecoder` discards the
/// rest: the address never becomes a value this process holds, so there is nothing for a future
/// log line, crash report or state dump to pick up by accident.
struct HFWhoAmI: Decodable {
    let name: String
}

/// Asks HuggingFace whether the saved token is one it actually accepts.
///
/// ⚠️ NOT part of `HuggingFaceTokenStore`: that type's whole job is one Keychain item, and giving
/// a secrets store a `URLSession` dependency makes the thing that must never leak also the thing
/// that talks to the network. It is also structurally untestable — `SecureKeyStorage` can raise a
/// modal prompt that hangs a headless run. Not part of `MLXModelService` either: whoami is not a
/// model operation, and Settings should not reach through the model manager to check a credential.
enum HuggingFaceAccountCheck {

    /// ⚠️ THREE OUTCOMES, NOT TWO. "the server said no" and "we could not ask" are different
    /// facts, and collapsing them is the exact failure this check exists to avoid: telling a user
    /// on a plane that their token is invalid sends them off to regenerate a credential that was
    /// fine, and teaches them to distrust the check.
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
    ///
    /// `nonisolated` and pure for the same reason `MLXModelStoreViewModel.searchDestination` is:
    /// there is no `URLProtocol` stub or injected `URLSession` anywhere in this project, so the
    /// only honest way to test the decision is to keep it out of the network call.
    nonisolated static func verdict(forFailure error: HFRequestError) -> Verdict {
        switch error {
        case .unauthorized:
            return .rejected
        case .rateLimited, .notFound, .serverError, .offline, .malformedResponse, .invalidURL:
            return .inconclusive(error)
        }
    }

    /// The sentence shown under the token field.
    ///
    /// ⚠️ INVARIANT: only `.rejected` may say anything about the TOKEN. Every other verdict
    /// reports that the CHECK failed, and every one of them states the token was still saved.
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

    /// Asks HuggingFace who the SAVED token belongs to.
    ///
    /// ⚠️ Verifies the token the app will actually USE, not the string the user typed:
    /// `HFRequest.perform` reads `HuggingFaceTokenStore.shared.token` itself, so this exercises
    /// the Keychain round-trip too. Call it only after `store(_:)` has returned true.
    ///
    /// ⚠️ `reloadIgnoringLocalCacheData` is load-bearing, not tidiness. `URLCache` keys on the
    /// URL and ignores the `Authorization` header, so without it a cached 200 from a previous
    /// token can answer the check for a revoked one — confirming a credential that does not work,
    /// which is worse than today's silence.
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
            // ⚠️ The account name is returned for DISPLAY and is never logged.
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
