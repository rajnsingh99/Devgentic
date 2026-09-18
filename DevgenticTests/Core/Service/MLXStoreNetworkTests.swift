// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXStoreNetworkTests.swift
//  DevgenticTests
//
//  Batch 1 "Network truthfulness" group of the MLX Model Manager readiness plan.
//
//    A8   A swallowed size fetch made `ModelFitAdvisor` return `.comfortable` with a 0-byte
//         estimate — a RAM safety advisory failing OPEN on the network error that A9 provokes.
//    A10  Every HF call discarded its `URLResponse`, so 429 / 401 / 500 / offline / genuinely
//         empty were indistinguishable, and the log blamed a schema bug.
//    B7   `.urlQueryAllowed` is the wrong character set for a query *value* — it permits
//         `&`, `=` and `#`, so search text could inject extra query parameters.
//

import XCTest
@testable import devgentic

final class HFRequestErrorTests: XCTestCase {

    /// Each class must be distinguishable — that is the whole point of A10. If any two
    /// collapsed to the same user-facing text the store would again present one dead end
    /// for four different causes.
    func testEveryFailureClassHasADistinctMessage() {
        let errors: [HFRequestError] = [
            .rateLimited(retryAfter: nil),
            .unauthorized,
            .notFound,
            .serverError(status: 503),
            .offline,
            .malformedResponse("x"),
            .invalidURL
        ]
        let messages = errors.compactMap(\.errorDescription)
        XCTAssertEqual(messages.count, errors.count, "a failure class has no message")
        XCTAssertEqual(Set(messages).count, errors.count, "two failure classes share a message")
    }

    /// `Retry-After` is the server telling us how long to wait; it must reach the user.
    func testRateLimitMessageCarriesRetryAfterWhenKnown() {
        XCTAssertTrue(
            HFRequestError.rateLimited(retryAfter: 42).errorDescription?.contains("42") == true
        )
        // And degrades gracefully when the header is absent.
        XCTAssertNotNil(HFRequestError.rateLimited(retryAfter: nil).errorDescription)
    }

    /// The UI suppresses its retry button for this case only — retrying is what deepens a 429.
    func testOnlyRateLimitingSuppressesRetry() {
        XCTAssertTrue(HFRequestError.rateLimited(retryAfter: nil).isRateLimited)
        XCTAssertFalse(HFRequestError.offline.isRateLimited)
        XCTAssertFalse(HFRequestError.serverError(status: 500).isRateLimited)
    }

    /// Log labels must name the status, since "couldn't be read" was what sent maintainers
    /// looking for a schema bug during a rate limit.
    func testLogLabelsIdentifyTheStatus() {
        XCTAssertTrue(HFRequestError.rateLimited(retryAfter: 5).logLabel.contains("429"))
        XCTAssertTrue(HFRequestError.unauthorized.logLabel.contains("401"))
        XCTAssertTrue(HFRequestError.serverError(status: 503).logLabel.contains("503"))
    }
}

// MARK: - A8: the fit advisory must not fail open

final class ModelFitUnknownVerdictTests: XCTestCase {

    /// THE A8 regression. With no metadata and no disk size there is nothing to assess, and
    /// the old code answered `.comfortable` — so a 40 GB model on a 16 GB Mac produced no
    /// advisory sheet and no badge.
    func testNoSizeDataYieldsUnknownRatherThanComfortable() {
        let assessment = ModelFitAdvisor.assess(metadata: nil, diskSizeString: nil, modelName: "test/model")

        XCTAssertEqual(assessment.verdict, .unknown,
                       "an unassessable model reported a fit verdict — the advisory is failing open")
        XCTAssertNotEqual(assessment.verdict, .comfortable)
    }

    /// A real size must still assess normally — the `.unknown` case must not swallow the
    /// working path.
    func testARealDiskSizeStillProducesAConcreteVerdict() {
        let assessment = ModelFitAdvisor.assess(metadata: nil, diskSizeString: "4.2 GB", modelName: "test/model")
        XCTAssertNotEqual(assessment.verdict, .unknown)
    }

    /// `.unknown` must read as "we don't know", never as a pass.
    func testUnknownVerdictExplainsItself() {
        let assessment = ModelFitAdvisor.assess(metadata: nil, diskSizeString: nil, modelName: nil)
        XCTAssertTrue(
            assessment.explanation.localizedCaseInsensitiveContains("unavailable")
            || assessment.explanation.localizedCaseInsensitiveContains("can't")
        )
    }
}

// MARK: - B7: query construction

final class HFQueryEncodingTests: XCTestCase {

    /// ⚠️ Rewritten 2026-08-03. These previously built a `URLComponents` in the test body and
    /// asserted that Foundation percent-encodes it — true of Foundation regardless of what the
    /// app does. Reverting B7 to string interpolation left them green. They now drive the real
    /// `MLXModelService.listingURL`.

    private func query(_ url: URL, _ name: String) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == name }
            .compactMap(\.value)
    }

    /// `.urlQueryAllowed` permits `&`, `=` and `#`, so the old string-interpolated URL let a
    /// search term inject extra query parameters.
    func testSearchTextCannotInjectQueryParameters() throws {
        let url = try XCTUnwrap(MLXModelService.listingURL(
            search: "qwen&limit=9999&filter=evil&sort=likes",
            tags: nil, limit: 30, offset: 0
        ))

        XCTAssertEqual(query(url, "limit"), ["30"], "search text injected an extra `limit`")
        XCTAssertEqual(query(url, "filter"), ["mlx"], "search text injected an extra `filter`")
        XCTAssertEqual(query(url, "sort"), ["downloads"], "search text overrode the sort")
        XCTAssertEqual(
            query(url, "search"), ["qwen&limit=9999&filter=evil&sort=likes"],
            "the search term must survive intact as ONE value, not be split into parameters"
        )
    }

    /// Spaces and slashes are the everyday case, not an attack: a user typing a repo id or a
    /// multi-word search must produce a valid URL.
    func testRepoIdsAndSpacesEncodeCorrectly() throws {
        let url = try XCTUnwrap(MLXModelService.listingURL(
            search: "mlx-community/Qwen3 4bit instruct", tags: nil, limit: 30, offset: 0
        ))
        XCTAssertFalse(url.absoluteString.contains(" "), "a raw space makes the URL invalid")
        XCTAssertEqual(query(url, "search"), ["mlx-community/Qwen3 4bit instruct"],
                       "decoding must round-trip to exactly what the user typed")
    }

    /// The pieces the caller actually varies — paging and category tags — must reach the URL.
    func testPagingAndTagsAreCarried() throws {
        let url = try XCTUnwrap(MLXModelService.listingURL(
            search: nil, tags: ["vision"], limit: 50, offset: 90
        ))
        XCTAssertEqual(query(url, "limit"), ["50"])
        XCTAssertEqual(query(url, "skip"), ["90"])
        // ⚠️ `mlx` must always lead — dropping it turns a category page into the whole of
        // HuggingFace, which is what the filter exists to prevent.
        XCTAssertEqual(query(url, "filter"), ["mlx,vision"])
        XCTAssertTrue(query(url, "search").isEmpty, "an absent search must not send an empty one")
    }
}
