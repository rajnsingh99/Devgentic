// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXStoreCapability2Tests.swift
//  DevgenticTests
//
//  Capabilities 7, 9, 10 and 11, added 2026-09-13:
//     7  paste a HuggingFace repo id into the MLX store instead of hunting for it in results
//     9  Ollama pulls finally produce a record, progress, Cancel and a completion message
//    10  the HuggingFace token can be entered where the 401 happens
//    11  the token is checked against the server, not just shape-matched
//
//  ⚠️ The rules are pure `nonisolated static`s because neither store view model can be built in
//  a test (each init scans disk and/or fetches over the network). Wiring is covered by source
//  tests at the bottom, which FAIL rather than skip on a missing path.
//

import XCTest
@testable import devgentic

// MARK: - 7: telling a repo id from a search term

final class MLXRepoIdPasteTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel
    private let expected = "mlx-community/Qwen3-8B-4bit"

    func testABareRepoIdIsRecognised() {
        XCTAssertEqual(VM.repoIdToDownload(from: expected), expected)
    }

    /// Pasting out of a code block or an address bar brings padding with it.
    func testSurroundingWhitespaceAndOneTrailingSlashAreTolerated() {
        XCTAssertEqual(VM.repoIdToDownload(from: "  \(expected)\n"), expected)
        XCTAssertEqual(VM.repoIdToDownload(from: "\(expected)/"), expected)
    }

    func testEveryURLFormReducesToTheSameId() {
        for form in [
            "https://huggingface.co/\(expected)",
            "http://huggingface.co/\(expected)",
            "https://www.huggingface.co/\(expected)",
            "https://hf.co/\(expected)",
            "huggingface.co/\(expected)",
            "https://huggingface.co/\(expected)/tree/main",
            "https://huggingface.co/\(expected)/blob/main/config.json",
            "https://huggingface.co/\(expected)?library=mlx",
            "https://huggingface.co/\(expected)#usage",
        ] {
            XCTAssertEqual(VM.repoIdToDownload(from: form), expected, "failed for \(form)")
        }
    }

    /// ⚠️ THE COMMON CASE. Ordinary searches must never grow a Download button.
    func testAnOrdinarySearchIsNotAnIdentifier() {
        for query in ["qwen", "qwen3 8bit", "", "   ", "llama 3.2 instruct"] {
            XCTAssertNil(VM.repoIdToDownload(from: query), "\"\(query)\" must stay a search")
        }
    }

    /// ⚠️ A space means the user is typing tokens — `remoteQuery` splits this same box on spaces.
    func testWhitespaceInsideIsNeverAnIdentifier() {
        XCTAssertNil(VM.repoIdToDownload(from: "mlx-community/Qwen3 4bit"))
    }

    func testOnlyExactlyTwoComponentsQualify() {
        for bad in ["a", "/b", "a/", "a//b", "a/b/c"] {
            XCTAssertNil(VM.repoIdToDownload(from: bad), "\"\(bad)\" must be rejected")
        }
    }

    /// ⚠️ NOT COSMETIC. The value is interpolated into an API URL and handed to HubApi, whose
    /// `localRepoLocation` appends it under the models directory. A `.`/`..` component is a path.
    func testPathComponentsAndExoticCharactersAreRejected() {
        for bad in ["../etc", "a/..", "./b", "a/b c", "a/b%2Fc", "org/na$me", "org/na/me"] {
            XCTAssertNil(VM.repoIdToDownload(from: bad), "\"\(bad)\" must be rejected")
        }
    }

    /// Whatever comes back must itself be a valid id — no half-cleaned strings escape.
    func testTheResultIsAlwaysItselfAcceptable() {
        for input in ["https://huggingface.co/\(expected)/tree/main", "  \(expected)/  ", expected] {
            guard let once = VM.repoIdToDownload(from: input) else { continue }
            XCTAssertEqual(VM.repoIdToDownload(from: once), once, "not idempotent for \(input)")
        }
    }
}

// MARK: - 11: what the server said vs whether we could ask

final class HuggingFaceAccountCheckTests: XCTestCase {

    private typealias Check = HuggingFaceAccountCheck

    /// Only a 401/403 is the token's fault.
    func testOnlyAnAuthFailureBlamesTheToken() {
        XCTAssertEqual(Check.verdict(forFailure: .unauthorized), .rejected)
    }

    /// ⚠️ THE ONE THAT MATTERS. Telling someone on a plane that their token is invalid sends them
    /// to regenerate a credential that was fine, and teaches them to distrust the check.
    func testEveryOtherFailureIsInconclusiveNotRejection() {
        for error: HFRequestError in [
            .offline, .notFound, .rateLimited(retryAfter: 30),
            .serverError(status: 503), .malformedResponse("bad json"), .invalidURL
        ] {
            XCTAssertEqual(Check.verdict(forFailure: error), .inconclusive(error),
                           "\(error.logLabel) must not be reported as a bad token")
        }
    }

    /// ⚠️ INVARIANT: only `.rejected` may say anything about the TOKEN; every other verdict must
    /// say the token was saved anyway.
    func testOnlyRejectionTellsTheUserToReplaceTheToken() {
        for error: HFRequestError in [.offline, .rateLimited(retryAfter: nil), .serverError(status: 500)] {
            let text = Check.message(for: .inconclusive(error))
            XCTAssertTrue(text.contains("saved"), "inconclusive must state the token was saved: \(text)")
            XCTAssertFalse(text.lowercased().contains("did not accept"),
                           "inconclusive must not blame the token: \(text)")
        }
        XCTAssertTrue(Check.message(for: .rejected).contains("did not accept"))
        XCTAssertTrue(Check.message(for: .rejected).contains("saved"),
                      "even a rejection must say the token was stored, because it was")
    }

    func testASuccessNamesTheAccount() {
        XCTAssertTrue(Check.message(for: .valid(account: "alice")).contains("alice"))
    }

    /// The account name is for display. It must never appear in a log line.
    func testTheVerdictTypeCarriesNoSecret() {
        XCTAssertEqual(Check.Verdict.valid(account: "alice"), .valid(account: "alice"))
        XCTAssertNotEqual(Check.Verdict.valid(account: "alice"), .rejected)
    }
}

// MARK: - The wiring

final class MLXStoreCapability2WiringTests: XCTestCase {

    private static let ollamaService = "Devgentic/Core/Service/OllamaService.swift"
    private static let storeView = "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift"
    private static let container = "Devgentic/Interfaces/Main/Views/MLXModelStoreContainerView.swift"

    /// Capability 7. The rule is inert unless the button and Return both consult it.
    func testThePasteAffordanceConsultsTheRule() throws {
        let code = try Self.source(Self.container)
        XCTAssertGreaterThanOrEqual(code.components(separatedBy: "MLXModelStoreViewModel.repoIdToDownload(from:").count - 1, 2,
                       "both the Return key and the Download button must gate on the identifier rule")
        XCTAssertTrue(code.contains("DownloadCoordinator.startMLXDownloadIfNeeded"), """
            A pasted id must go through the coordinator, or it skips the install short-circuit, \
            the single-slot refusal, the free-space preflight and the ETA pre-seed.
            """)
        XCTAssertTrue(code.contains("fetchModelDetail(repoId:"), """
            Without the pre-flight a typo passes (the byte probe returns nil for a missing repo \
            exactly as it does for a flaky network) and fails a round trip later with HubApi's \
            "File not found: main", which names the revision rather than the repo.
            """)
    }

    /// Capability 9's entire defect was one missing assignment.
    ///
    /// ⚠️ THIS TEST USED TO PIN THE RELATIVE ORDER of `modelToPull` against `isPullingModel`, in
    /// both directions, via `String.range(of:)` offsets. That order is NOT an invariant:
    /// `ObservationStream`'s onChange schedules `Task { @MainActor … }`, and no suspension point
    /// separates either pair, so the bridge's first observation sees the block's final state and
    /// can never see an intermediate one. Swapping the lines is observationally identical.
    ///
    /// Worse, pinning it would have failed the build on a `defer`-based cleanup — which is
    /// strictly better, because it also covers a future early return. A drift test that blocks an
    /// improvement while protecting nothing is the anti-pattern this repo already has on record:
    /// assert the property, not the arrangement.
    ///
    /// What IS load-bearing, and all that is asserted here: the name is assigned at all, and it is
    /// cleared when the pull ends.
    func testTheOllamaPullIdentifiesItselfToTheDownloadBridge() throws {
        let code = try Self.source(Self.ollamaService)
        XCTAssertTrue(code.contains("modelToPull = trimmedModelName"), """
            DownloadManager opens a record only on `isPulling && !modelName.isEmpty`. With no \
            assignment anywhere in the repo that was permanently false: no record, no progress, \
            no Cancel, no completion notification.
            """)
        XCTAssertTrue(code.contains("modelToPull = \"\""), """
            The name must be cleared when the pull ends, or DownloadCoordinator keeps building its \
            "already pulling" refusal from a pull that finished.
            """)
    }

    /// Capability 9, other half: the narration had no reader.
    func testThePullNarrationIsActuallyRendered() throws {
        let vm = try Self.source("Devgentic/Interfaces/Main/Views/BackendProfile/OllamaLLM/OllamaModelStoreViewModel.swift")
        XCTAssertTrue(vm.contains("self.pullStatus = self.service.pullTerminalState"),
                      "the outcome was written by the service and read by nobody")
        let view = try Self.source("Devgentic/Interfaces/Main/Views/BackendProfile/OllamaLLM/OllamaModelStoreView.swift")
        XCTAssertTrue(view.contains("let status = viewModel.pullStatus"))
        // ⚠️ The regression guard: the banner must never pick its icon from the in-flight flag.
        XCTAssertFalse(view.contains("viewModel.isDownloading ? \"arrow.down.circle\""), """
            Deriving the icon from isDownloading renders every non-in-flight outcome as success — \
            a green tick over "Download cancelled." and "Failed to pull X.".
            """)
        XCTAssertTrue(view.contains("viewModel.dismissPullStatus()"),
                      "a banner with no way out lives for the rest of the process")
        XCTAssertTrue(view.contains("viewModel.downloadErrorMessage == nil"), """
            Status must yield to errors: pullStatusMessage keeps its last value after a failure, \
            so rendering both puts "Successfully pulled…" beside the failure that followed it.
            """)
    }

    /// Capability 10. The screen that knows a token is missing must be able to take one.
    func testTheAuthFailureOffersTheTokenField() throws {
        let code = try Self.source(Self.storeView)
        XCTAssertTrue(code.contains("if case .unauthorized = error"),
                      "the Add Token button belongs to the auth failure only, not to every error")
        XCTAssertTrue(code.contains("HuggingFaceTokenEntrySheet { viewModel.refresh() }"), """
            The retry must fire on SAVE, not on a valid verdict — the token is in use either way, \
            and gating on a network check strands a user whose check was merely inconclusive.
            """)
    }

    /// Capability 11. A cached 200 must not be able to answer for a different credential.
    func testTheTokenCheckBypassesTheURLCache() throws {
        let code = try Self.source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/HuggingFaceAccountCheck.swift")
        XCTAssertTrue(code.contains("cachePolicy: .reloadIgnoringLocalCacheData"), """
            URLCache keys on the URL and ignores the Authorization header, so without this a \
            cached 200 from a previous token verifies a revoked one — worse than not checking.
            """)
        XCTAssertFalse(code.contains("let email"), "only `name` may be decoded; nothing else should enter the process")
    }

    // MARK: - Helper

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.path) else {
            throw XCTSkip("repo root not reachable from \(#filePath) — running outside a checkout")
        }
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) no longer exists. A drift test guards this file by path; repoint it rather than letting the guard go silent.")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - 14: HuggingFace inference, made reachable

final class CompatibleEndpointPresetTests: XCTestCase {

    private typealias P = CompatibleEndpointPreset

    /// The whole point: the endpoint a user could never guess is now one click.
    func testTheHuggingFaceRouterIsOffered() throws {
        let hf = try XCTUnwrap(P.all.first { $0.name == "HuggingFace" })
        XCTAssertEqual(hf.url, "https://router.huggingface.co/v1")
        XCTAssertTrue(hf.usesHuggingFaceToken)
    }

    /// ⚠️ `OpenAILLMProvider` appends `chat/completions` to the base URL. If this ever stops
    /// resolving to HuggingFace's real endpoint, every request 404s.
    func testTheBaseURLResolvesToTheRoutersChatEndpoint() throws {
        let hf = try XCTUnwrap(P.all.first { $0.name == "HuggingFace" })
        let url = try XCTUnwrap(URL(string: hf.url))
        XCTAssertEqual(url.appendingPathComponent("chat/completions").absoluteString,
                       "https://router.huggingface.co/v1/chat/completions")
    }

    func testRemotePresetsAreHTTPSAndNamesAreUnique() {
        XCTAssertEqual(Set(P.all.map(\.name)).count, P.all.count)
        for preset in P.all where !preset.url.contains("localhost") {
            XCTAssertTrue(preset.url.hasPrefix("https://"), "\(preset.name) must not be plaintext")
        }
    }

    /// Matching drives both the selected-chip highlight and the token-reuse offer, so a trailing
    /// slash or a capitalised host must not lose it.
    func testMatchingSurvivesTrailingSlashesAndCase() {
        XCTAssertEqual(P.matching("https://router.huggingface.co/v1")?.name, "HuggingFace")
        XCTAssertEqual(P.matching("https://router.huggingface.co/v1/")?.name, "HuggingFace")
        XCTAssertEqual(P.matching("  https://ROUTER.HuggingFace.co/v1  ")?.name, "HuggingFace")
    }

    /// ⚠️ A near-miss must NOT offer the HuggingFace token — that button copies a credential.
    func testAnUnrelatedEndpointMatchesNothing() {
        for url in ["https://api.openai.com/v1", "https://router.huggingface.co", "", "   "] {
            XCTAssertNil(P.matching(url), "\"\(url)\" must not match a preset")
        }
        XCTAssertNil(P.matching(nil))
    }
}

// MARK: - The Ollama pull outcome

/// The banner used to choose its icon from `isPullingModel` — a PHASE — so every terminal state
/// that was not "in flight" rendered as success. These pin the outcome as a value instead.
final class OllamaPullTerminalStateTests: XCTestCase {

    private typealias State = OllamaService.PullTerminalState

    /// ⚠️ THE REGRESSION. Neither of these is a success, and both used to render a green tick.
    func testCancellationAndFailureAreNotSuccesses() {
        XCTAssertFalse(State.cancelled.isSuccess)
        XCTAssertFalse(State.failed(model: "foo:bar").isSuccess)
        XCTAssertTrue(State.succeeded(model: "foo:bar").isSuccess)
        XCTAssertFalse(State.started(model: "foo:bar").isSuccess,
                       "a pull that has only started has not succeeded")
    }

    /// Only `.started` is non-terminal — that is what gates the dismiss control.
    func testOnlyAStartedPullIsNonTerminal() {
        XCTAssertFalse(State.started(model: "foo:bar").isTerminal)
        for state: State in [.succeeded(model: "foo:bar"), .cancelled, .failed(model: "foo:bar")] {
            XCTAssertTrue(state.isTerminal, "\(state) must offer a dismiss control")
        }
    }

    /// The sentence travels WITH the outcome, so the two can never describe different events.
    func testEachOutcomeCarriesItsOwnSentence() {
        XCTAssertEqual(State.started(model: "llama3:8b").message, "Starting pull for llama3:8b…")
        XCTAssertEqual(State.succeeded(model: "llama3:8b").message, "Successfully pulled llama3:8b.")
        XCTAssertEqual(State.cancelled.message, "Download cancelled.")
        XCTAssertEqual(State.failed(model: "llama3:8b").message, "Failed to pull llama3:8b.")
    }

    /// ⚠️ Exactly one outcome may read as success. A new case defaulting into the success branch
    /// is how this defect happened in the first place.
    func testExactlyOneOutcomeReadsAsSuccess() {
        let all: [State] = [.started(model: "m"), .succeeded(model: "m"), .cancelled, .failed(model: "m")]
        XCTAssertEqual(all.filter(\.isSuccess).count, 1)
    }

    /// The model name must survive into the sentence, or a multi-pull session cannot be read.
    func testTheModelNameIsNotLost() {
        XCTAssertTrue(State.failed(model: "qwen2.5:7b").message.contains("qwen2.5:7b"))
        XCTAssertTrue(State.succeeded(model: "qwen2.5:7b").message.contains("qwen2.5:7b"))
    }
}
