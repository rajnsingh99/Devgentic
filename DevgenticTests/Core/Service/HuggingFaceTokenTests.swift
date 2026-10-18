// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HuggingFaceTokenTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class HuggingFaceTokenShapeTests: XCTestCase {

    /// A shape check, not a verdict. HuggingFace has shipped more than one token format, so
    /// this drives a *warning* — refusing to store a valid token would be worse than letting
    /// the request fail with a clear 401.
    func testRecognisesTheCommonTokenShape() {
        XCTAssertTrue(HuggingFaceTokenStore.looksLikeToken("hf_AbCdEfGhIjKlMnOpQrStUvWxYz012345"))
        XCTAssertTrue(HuggingFaceTokenStore.looksLikeToken("  hf_AbCdEfGhIjKlMnOpQrStUvWxYz012345  "),
                      "surrounding whitespace from a paste must not change the verdict")
    }

    func testFlagsThingsThatAreObviouslyNotTokens() {
        XCTAssertFalse(HuggingFaceTokenStore.looksLikeToken(""))
        XCTAssertFalse(HuggingFaceTokenStore.looksLikeToken("hf_short"))
        XCTAssertFalse(HuggingFaceTokenStore.looksLikeToken("sk-openai-style-key-not-huggingface"))
        XCTAssertFalse(HuggingFaceTokenStore.looksLikeToken("https://huggingface.co/settings/tokens"))
    }
}

final class HuggingFaceGatedDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> HFRawModel {
        try JSONDecoder().decode(HFRawModel.self, from: Data(json.utf8))
    }

    /// ⚠️ `gated` is `false` (Bool) on open repos and a STRING on gated ones. The listing
    /// decoder must survive both or the whole page fails to decode.
    func testListingDecodesBothGatedShapes() throws {
        let open = try decode(#"{ "id": "a/b", "downloads": 1, "likes": 0, "gated": false }"#)
        XCTAssertFalse(open.gated?.isGated ?? false)

        for kind in ["auto", "manual"] {
            let gated = try decode(#"{ "id": "a/b", "downloads": 1, "likes": 0, "gated": "\#(kind)" }"#)
            XCTAssertTrue(gated.gated?.isGated ?? false, "gated:\"\(kind)\" must be recognised")
        }
    }

    /// Most listing entries omit `gated` entirely — absent must mean open, not a decode failure.
    func testAbsentGatedMeansOpen() throws {
        let raw = try decode(#"{ "id": "a/b", "downloads": 1, "likes": 0 }"#)
        XCTAssertNil(raw.gated)
        XCTAssertFalse(raw.gated?.isGated ?? false)
    }

    /// `private` is a Swift keyword and needs backticks in the model — pin that it still
    /// decodes, since a rename would silently drop the flag.
    func testPrivateFlagDecodes() throws {
        let raw = try decode(#"{ "id": "a/b", "downloads": 1, "likes": 0, "private": true }"#)
        XCTAssertEqual(raw.private, true)
    }

    /// A 401 must tell the user what to do. The old copy said a token was required without
    /// the app offering any way to supply one.
    func testUnauthorizedMessagePointsAtTheSetting() {
        let message = HFRequestError.unauthorized.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("settings"),
                      "the message must say where to add a token, not just that one is needed")
    }
}
