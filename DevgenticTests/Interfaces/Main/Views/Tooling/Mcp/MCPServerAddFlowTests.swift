// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPServerAddFlowTests.swift
//  DevgenticTests
//
//  Register KC-5: a completed OAuth sign-in must never be discarded by a `try?`.
//
//  ⚠️ THE ORDERING IS THE FIX. The bundle is persisted BEFORE the row exists, under the id the row
//  will get, so the one step that can fail happens before anything irreversible — and its failure
//  reaches the form as an outcome instead of vanishing.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPServerAddFlowTests: XCTestCase {

    private var events: [String] = []

    private func bundle(accessToken: String = "AT") -> MCPOAuthCredentialBundle {
        MCPOAuthCredentialBundle(
            issuer: URL(string: "https://as.example.com")!,
            clientId: "client-1",
            grantedScopes: ["mcp"],
            redirectURI: URL(string: "http://127.0.0.1:1/cb")!,
            accessToken: accessToken,
            refreshToken: "RT",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            registrationAccessToken: nil,
            registrationClientUri: nil
        )
    }

    private struct Refused: Error {}

    // MARK: - add

    func testTheBundleIsPersistedBeforeTheRowAndUnderTheRowsID() {
        var persistedUnder: UUID?
        var insertedAs: UUID?

        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: bundle(),
            isDuplicate: { _ in events.append("duplicate?"); return false },
            persistBundle: { _, id in events.append("persist"); persistedUnder = id },
            addTool: { id in events.append("insert"); insertedAs = id; return id },
            discardBundle: { _ in events.append("discard") }
        )

        guard case .added = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(events, ["duplicate?", "persist", "insert"], "the write that can fail runs first")
        XCTAssertNotNil(persistedUnder)
        XCTAssertEqual(persistedUnder, insertedAs, "the bundle must be keyed on the row's final identity")
    }

    /// ⚠️ THE KC-5 REGRESSION. A refused write must refuse the add — the row is never created and
    /// the form is told why.
    func testAFailedPersistRefusesTheAddAndNeverInsertsTheRow() {
        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: bundle(),
            isDuplicate: { _ in false },
            persistBundle: { _, _ in events.append("persist"); throw Refused() },
            addTool: { id in events.append("insert"); return id },
            discardBundle: { _ in events.append("discard") }
        )

        guard case .failed(let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error.title, "Sign-in could not be saved")
        XCTAssertEqual(events, ["persist"], "no row, and nothing to discard")
    }

    func testAFailedInsertDiscardsTheBundleWrittenAheadOfIt() {
        var persistedUnder: UUID?
        var discarded: UUID?

        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: bundle(),
            isDuplicate: { _ in false },
            persistBundle: { _, id in events.append("persist"); persistedUnder = id },
            addTool: { _ in events.append("insert"); return nil },
            discardBundle: { id in events.append("discard"); discarded = id }
        )

        guard case .failed(let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error.title, "Server could not be saved")
        XCTAssertEqual(events, ["persist", "insert", "discard"])
        XCTAssertEqual(discarded, persistedUnder, "an orphaned grant must not stay in the Keychain under an id nothing references")
    }

    func testAFailedInsertWithoutABundleDiscardsNothing() {
        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: nil,
            isDuplicate: { _ in false },
            persistBundle: { _, _ in events.append("persist") },
            addTool: { _ in events.append("insert"); return nil },
            discardBundle: { _ in events.append("discard") }
        )

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(events, ["insert"])
    }

    func testADuplicateShortCircuitsBeforeAnythingIsWritten() {
        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: bundle(),
            isDuplicate: { _ in true },
            persistBundle: { _, _ in events.append("persist") },
            addTool: { id in events.append("insert"); return id },
            discardBundle: { _ in events.append("discard") }
        )

        guard case .duplicate = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(events, [])
    }

    func testNoBundleMeansNoPersistAndAPlainInsert() {
        let outcome = MCPServerAddFlow.add(
            serverName: "srv", oauthBundle: nil,
            isDuplicate: { _ in false },
            persistBundle: { _, _ in events.append("persist") },
            addTool: { id in events.append("insert"); return id },
            discardBundle: { _ in events.append("discard") }
        )

        guard case .added = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(events, ["insert"])
    }

    // MARK: - persistIfChanged (edit path)

    func testAnUnchangedBundleIsNotRewritten() throws {
        let stored = bundle()
        let wrote = try MCPServerAddFlow.persistIfChanged(
            stored, stored: stored, sourceID: UUID(),
            persist: { _, _ in self.events.append("persist") }
        )
        XCTAssertFalse(wrote, "a plain rename must not be refused over a write it does not need")
        XCTAssertEqual(events, [])
    }

    func testAChangedBundleIsWrittenUnderTheSourceID() throws {
        let id = UUID()
        var persistedUnder: UUID?
        let wrote = try MCPServerAddFlow.persistIfChanged(
            bundle(accessToken: "AT-new"), stored: bundle(accessToken: "AT-old"), sourceID: id,
            persist: { _, under in persistedUnder = under }
        )
        XCTAssertTrue(wrote)
        XCTAssertEqual(persistedUnder, id)
    }

    /// When the stored bundle cannot be read, the comparison fails CLOSED: the write is attempted,
    /// so a Keychain refusal surfaces instead of an edit being applied over an unconfirmed sign-in.
    func testAnUnreadableStoredBundleForcesTheWrite() throws {
        let wrote = try MCPServerAddFlow.persistIfChanged(
            bundle(), stored: nil, sourceID: UUID(),
            persist: { _, _ in self.events.append("persist") }
        )
        XCTAssertTrue(wrote)
        XCTAssertEqual(events, ["persist"])
    }

    func testNoBundleWritesNothing() throws {
        let wrote = try MCPServerAddFlow.persistIfChanged(
            nil, stored: bundle(), sourceID: UUID(),
            persist: { _, _ in self.events.append("persist") }
        )
        XCTAssertFalse(wrote)
        XCTAssertEqual(events, [])
    }

    func testAFailedWriteIsRethrownNotSwallowed() {
        XCTAssertThrowsError(try MCPServerAddFlow.persistIfChanged(
            bundle(accessToken: "new"), stored: bundle(accessToken: "old"), sourceID: UUID(),
            persist: { _, _ in throw Refused() }
        ))
    }

    // MARK: - Wiring

    /// ⚠️ THE DEFECT, STATED AS AN ABSENCE. Neither view may `try?` the persist any more, and both
    /// must route through the flow.
    func testTheContainerAndTheFormNoLongerSwallowAPersistFailure() throws {
        let container = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/Tooling/Mcp/AddMCPServerContainerView.swift")
        XCTAssertFalse(container.contains("try? MCPOAuthCoordinator.persist"))
        XCTAssertTrue(container.contains("MCPServerAddFlow.add("))
        XCTAssertTrue(container.contains("MCPToolStore.shared.addTool(\n                    id: newID,"), "the row must be inserted under the id the bundle was written for")

        let form = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/Tooling/Mcp/AddMCPServerView.swift")
        XCTAssertFalse(form.contains("try? MCPOAuthCoordinator.persist"))
        XCTAssertTrue(form.contains("MCPServerAddFlow.persistIfChanged("))
        XCTAssertTrue(form.contains("case .failed(let error):\n                // Register KC-5"), "a failed add must reach the form's error state")
    }
}
