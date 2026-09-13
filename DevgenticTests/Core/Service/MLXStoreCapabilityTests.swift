// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXStoreCapabilityTests.swift
//  DevgenticTests
//
//  Five MLX store capabilities added 2026-09-13:
//    2  the installed revision is shown (it was computed, stored, and rendered nowhere)
//    3  "Update available" became a button that names both revisions and clears when done
//    4  the quantization choice goes into the HuggingFace QUERY, not a client-side sieve
//    5  the sort choice drives the SERVER ranking, and pagination follows it
//    6  an opt-in "Fits my Mac" filter over the existing RAM advisory
//
//  ⚠️ Every rule under test is a `nonisolated static` on purpose. `MLXModelStoreViewModel.init`
//  scans the disk and fetches from huggingface.co, so the view model cannot be built in a test.
//  The wiring that connects these rules to the UI is covered by the source tests at the bottom.
//

import XCTest
@testable import devgentic

// MARK: - 5: the sort choice drives the server ranking

final class MLXStoreServerSortTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel

    /// Mutation that must turn this red: drop the `sort:` parameter and restore the literal.
    func testTheListingURLCarriesTheRequestedSort() throws {
        let url = try XCTUnwrap(MLXModelService.listingURL(
            search: nil, tags: nil, limit: 30, offset: 0, sort: "lastModified"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "lastModified")
        XCTAssertEqual(items.first { $0.name == "direction" }?.value, "-1",
                       "every field sent is ranked more/newer-first; an ascending sort would have to vary this")
    }

    /// The default must survive, or every existing caller silently re-ranks.
    func testOmittingTheSortKeepsTodaysRanking() throws {
        let url = try XCTUnwrap(MLXModelService.listingURL(search: nil, tags: nil, limit: 30, offset: 0))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, MLXModelService.defaultSortField)
    }

    /// ⚠️ Iterates `allCases` rather than a hand-written list, so a fifth SortOption cannot be
    /// added with a mapping nobody checked.
    func testEverySortOptionMapsToAFieldTheAPIKnowsOrToNothing() {
        let known = ["downloads", "lastModified", "likes", "createdAt", "trendingScore"]
        for option in VM.SortOption.allCases {
            if let field = option.hfSort {
                XCTAssertTrue(known.contains(field), "\(option.rawValue) maps to unknown field \(field)")
            }
        }
        XCTAssertEqual(VM.SortOption.popularity.hfSort, MLXModelService.defaultSortField,
                       "the default option and the default field must agree, or the first render re-fetches")
    }

    func testChangingToAServerRankableSortRefetches() {
        XCTAssertEqual(
            VM.serverSortRefetch(from: .popularity, to: .recent, category: .all, lastFetchedSort: "downloads"),
            "lastModified"
        )
    }

    /// ⚠️ THE ONE THAT MATTERS: a size sort must NOT re-query. The API cannot rank by repo
    /// bytes, so re-fetching would throw away every page the user loaded to change nothing.
    func testASizeSortNeverThrowsAwayLoadedPages() {
        XCTAssertNil(VM.serverSortRefetch(from: .popularity, to: .sizeSmallest, category: .all, lastFetchedSort: "downloads"))
        XCTAssertNil(VM.serverSortRefetch(from: .popularity, to: .sizeLargest, category: .all, lastFetchedSort: "downloads"))
    }

    /// Neither tab has a server behind it — one is a disk scan, the other a local catalogue.
    func testLocalTabsNeverRefetch() {
        for category: VM.StoreCategory in [.installed, .recommended] {
            XCTAssertNil(
                VM.serverSortRefetch(from: .popularity, to: .recent, category: category, lastFetchedSort: "downloads"),
                "\(category.rawValue) has no server behind it"
            )
        }
    }

    func testAlreadyRankedThatWayDoesNotSpendARequest() {
        XCTAssertNil(VM.serverSortRefetch(from: .sizeLargest, to: .popularity, category: .all, lastFetchedSort: "downloads"))
        XCTAssertNil(VM.serverSortRefetch(from: .recent, to: .recent, category: .all, lastFetchedSort: "lastModified"))
    }
}

// MARK: - 4: the quantization goes into the query

final class MLXStoreQuantizationQueryTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel

    /// ⚠️ bf16, not "16bit" — the popular MLX uploads are named `…-bf16`, and `parse` reads
    /// that back as 16-bit so the client-side check still agrees.
    func testSixteenBitQueriesForBf16ButStillAdvisesIn16bit() {
        XCTAssertEqual(MLXQuantization.sixteenBit.searchToken, "bf16")
        XCTAssertEqual(MLXQuantization.sixteenBit.advisorToken, "16bit",
                       "advisorToken feeds ModelFitAdvisor.parseQuantizationBits and must not change")
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "org/Model-bf16"), .sixteenBit)
    }

    func testEveryOtherWidthQueriesForItsOwnSuffix() {
        for quant in MLXQuantization.allCases where quant != .sixteenBit {
            XCTAssertEqual(quant.searchToken, "\(quant.rawValue)bit")
        }
    }

    func testNoQuantizationLeavesTheQueryAlone() {
        XCTAssertEqual(VM.remoteQuery(search: "qwen", quantization: nil), "qwen")
        XCTAssertNil(VM.remoteQuery(search: "   ", quantization: nil))
    }

    func testTheWidthIsAppendedToTheTypedSearch() {
        XCTAssertEqual(VM.remoteQuery(search: "qwen", quantization: .fourBit), "qwen 4bit")
    }

    /// An empty box plus a picked width still queries — this is the whole point of the change.
    func testPickingAWidthWithNoSearchTextStillQueries() {
        XCTAssertEqual(VM.remoteQuery(search: "", quantization: .fourBit), "4bit")
    }

    /// ⚠️ HuggingFace ANDs its search tokens, so "gemma 8bit" plus a 4-bit selection returns
    /// literally zero rows — the empty grid this capability exists to remove.
    func testAContradictoryTypedWidthIsDroppedInFavourOfThePicker() {
        XCTAssertEqual(VM.remoteQuery(search: "gemma 8bit", quantization: .fourBit), "gemma 4bit")
        XCTAssertEqual(VM.remoteQuery(search: "gemma bf16", quantization: .fourBit), "gemma 4bit")
    }

    /// ⚠️ Only a token that is NOTHING BUT a width is dropped. Deleting "Qwen3-8bit" would throw
    /// away the family name and search for a width alone.
    func testAWidthInsideAModelNameSurvives() {
        XCTAssertEqual(VM.remoteQuery(search: "Qwen3-8bit", quantization: .fourBit), "Qwen3-8bit 4bit")
    }

    /// ⚠️ THIS TEST USED TO DEFEND THE DEFECT. It asserted `"qwen 4bit 4bit"` — pinning the one
    /// spelling where duplication happens to be harmless — while its NAME claimed a property it
    /// never checked. The general case was broken: a typed "4-bit" plus a 4-bit picker composed
    /// "qwen 4-bit 4bit", and HuggingFace ANDs the terms against `filter=mlx`, so the query is
    /// unsatisfiable. Verified live: `search=qwen 4bit` returns 30 rows, `search=qwen 4-bit 4bit`
    /// returns 0. It now checks the property its name asserts.
    func testAMatchingTypedWidthIsNotDuplicatedIntoNonsense() {
        XCTAssertEqual(VM.remoteQuery(search: "qwen 4bit", quantization: .fourBit), "qwen 4bit")
    }

    /// The general form of the above: whatever the user typed, the composed query must never
    /// carry two width tokens — the picker supplies exactly one canonical spelling.
    func testNoComposedQueryEverCarriesTwoWidthTokens() {
        let spellings: [(String, MLXQuantization)] = [
            ("4bit", .fourBit), ("4-bit", .fourBit), ("4_bit", .fourBit),
            ("8bit", .eightBit), ("8-bit", .eightBit),
            ("16bit", .sixteenBit), ("bf16", .sixteenBit), ("fp16", .sixteenBit), ("float16", .sixteenBit),
        ]
        for (typed, picked) in spellings {
            let query = VM.remoteQuery(search: "qwen \(typed)", quantization: picked) ?? ""
            let widthTokens = query.split(separator: " ").filter { token in
                let lower = token.lowercased()
                return MLXQuantization.allCases.contains { q in
                    ["\(q.rawValue)bit", "\(q.rawValue)-bit", "\(q.rawValue)_bit"].contains(lower)
                } || ["bf16", "fp16", "float16"].contains(lower)
            }
            XCTAssertEqual(widthTokens.count, 1,
                           "typed \"\(typed)\" + picker \(picked.rawValue)-bit composed \"\(query)\" — HuggingFace ANDs these, so two widths return zero rows")
            XCTAssertEqual(String(widthTokens[0]), picked.searchToken,
                           "the surviving width must be the picker's canonical spelling")
        }
    }

    /// ⚠️ The 16-bit case was self-refuting before the fix: `searchToken` exists precisely because
    /// "16bit" matches almost nothing on HuggingFace, and the filter then put the user's literal
    /// "16bit" straight back into the same query.
    func testATyped16bitDoesNotSurviveAlongsideBf16() {
        XCTAssertEqual(VM.remoteQuery(search: "qwen 16bit", quantization: .sixteenBit), "qwen bf16")
        XCTAssertEqual(VM.remoteQuery(search: "qwen fp16", quantization: .sixteenBit), "qwen bf16")
    }
}

// MARK: - 3: the update badge clears when the work lands

final class MLXUpdateStatusClearingTests: XCTestCase {

    func testLandingOnThePublishedRevisionMarksItUpToDate() {
        let status = MLXModelService.statusAfterDownload(
            previous: .updateAvailable(installed: "aaaaaaa1", latest: "bbbbbbb2"),
            resolved: "bbbbbbb2"
        )
        guard case .upToDate(let revision)? = status else {
            return XCTFail("expected .upToDate, got \(String(describing: status))")
        }
        XCTAssertEqual(revision, "bbbbbbb2")
    }

    /// ⚠️ The publisher can push again between the check and the download. Landing on some THIRD
    /// commit must drop the entry, not assert a currency nothing verified.
    func testLandingOnADifferentRevisionDropsTheEntryRatherThanClaimingCurrency() {
        XCTAssertNil(MLXModelService.statusAfterDownload(
            previous: .updateAvailable(installed: "aaaaaaa1", latest: "bbbbbbb2"),
            resolved: "ccccccc3"
        ), "dropping re-derives on the next sweep; claiming .upToDate would be a badge that lies")
    }

    func testNoResolvedRevisionDropsTheEntry() {
        XCTAssertNil(MLXModelService.statusAfterDownload(
            previous: .updateAvailable(installed: "aaaaaaa1", latest: "bbbbbbb2"), resolved: nil))
    }

    /// A first install has no cached entry; never invent one.
    func testNoPreviousStatusStaysAbsent() {
        XCTAssertNil(MLXModelService.statusAfterDownload(previous: nil, resolved: "bbbbbbb2"))
    }
}

// MARK: - 6: the fit filter

final class MLXStoreFitFilterTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel

    /// ⚠️ THE regression guard. Remote cards carry a nil `sizeBytes` until the size pass lands,
    /// and `fetchRemoteModels` clears `isLoading` BEFORE awaiting it — so hiding `.unknown`
    /// paints "No models found" over a page that loaded fine, and permanently so under a 429
    /// where the size batch is abandoned and there is deliberately no retry button.
    func testAModelWhoseSizeIsNotKnownYetIsNeverHidden() {
        XCTAssertTrue(VM.passesFitFilter(.unknown))
    }

    /// Paired with the above so "return true for everything" also fails.
    func testAModelThatCannotFitIsHidden() {
        XCTAssertFalse(VM.passesFitFilter(.incompatible))
        XCTAssertFalse(VM.passesFitFilter(.risky))
        XCTAssertTrue(VM.passesFitFilter(.comfortable))
        XCTAssertTrue(VM.passesFitFilter(.tight))
    }

    /// ⚠️ Asserts the PROPERTY — that the filter's quiet path and the badge's logging path agree
    /// — not any particular verdict, so it holds on any Mac. If they diverge, a card gets hidden
    /// while its own badge says it fits.
    func testTheQuietVerdictAgreesWithTheOneTheBadgeShows() {
        let fixtures: [(ModelMetadata?, String?, Int64?)] = [
            (MLXQuantization.fitMetadata(forRepoId: "mlx-community/Qwen2.5-3B-Instruct-4bit"), nil, 1_700_000_000),
            (MLXQuantization.fitMetadata(forRepoId: "mlx-community/Llama-3.1-405B-Instruct-4bit"), nil, nil),
            (nil, nil, 8_000_000_000),
            (nil, nil, nil),
            (nil, nil, 0),
        ]
        for (metadata, sizeString, sizeBytes) in fixtures {
            XCTAssertEqual(
                ModelFitAdvisor.verdict(metadata: metadata, diskSizeString: sizeString, diskSizeBytes: sizeBytes),
                ModelFitAdvisor.assess(metadata: metadata, diskSizeString: sizeString, diskSizeBytes: sizeBytes).verdict,
                "the filter and the badge must never disagree about the same model"
            )
        }
    }

    /// An absent estimate must never read as a fit.
    func testNoEstimateIsUnknownRatherThanComfortable() {
        XCTAssertEqual(ModelFitAdvisor.verdict(metadata: nil, diskSizeString: nil, diskSizeBytes: nil), .unknown)
    }

    /// ⚠️ Raw bytes must be preferred over the formatted string: round-tripping a
    /// `ByteCountFormatter` string through `parseDiskSize` is lossy in comma-decimal locales.
    func testRawBytesOutrankTheFormattedString() {
        let fromBytes = ModelFitAdvisor.estimateRuntimeRAM(metadata: nil, diskSizeString: "1 GB", diskSizeBytes: 40_000_000_000)
        let fromString = ModelFitAdvisor.estimateRuntimeRAM(metadata: nil, diskSizeString: "1 GB", diskSizeBytes: nil)
        XCTAssertGreaterThan(fromBytes, fromString, "diskSizeBytes must win when both are supplied")
    }
}

// MARK: - The wiring
//
// ⚠️ The rules above are inert unless something calls them, and capability 2 is pure plumbing
// with no rule at all. These read the source, because the view model cannot be constructed.
// ⚠️ A missing file FAILS here; it does not skip.

final class MLXStoreCapabilityWiringTests: XCTestCase {

    private static let viewModel = "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift"
    private static let storeView = "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift"
    private static let service = "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift"

    /// Capability 2. The revision was already computed and stored; only the render was missing.
    ///
    /// ⚠️ THIS USED TO ASSERT `revision: item.revision` ON THE CARD. Carrying it there was the
    /// defect: only the INSTALLED-tab mapping populated it, so opening the sheet for the same
    /// installed model from All or Recommended showed no row — which reads as "this copy predates
    /// revision tracking" and is false. The sheet now resolves it from the service, which is right
    /// on every tab, so the assertion is that the LOOKUP happens, not that a field is threaded.
    func testTheInstalledRevisionIsResolvedFromTheAuthoritativeSource() throws {
        let sheet = try Self.source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelDetailSheet.swift")
        XCTAssertTrue(sheet.contains("MLXModelService.shared.installedModel(named: model.id)?.revision"), """
            Resolve at the render site. A revision carried on the card is correct only on the tab \
            whose mapping set it.
            """)
        XCTAssertTrue(sheet.contains("MLXModelRevision.shortForm(revision)"),
                      "the detail sheet must render the revision it resolved")
        XCTAssertFalse(try Self.source(Self.viewModel).contains("revision: item.revision"),
                       "the card must not carry a tab-dependent copy of it any more")
    }

    /// Capability 3. The badge has to be the control, and it has to clear itself.
    func testTheUpdateBadgeActsAndClears() throws {
        let view = try Self.source(Self.storeView)
        XCTAssertTrue(view.contains("case .updateAvailable(let installed, let latest) = status"),
                      "both revisions are carried by the enum and must both be shown")
        XCTAssertTrue(view.contains("await startUpdate()"), "the badge must be a button, not a label")
        XCTAssertTrue(view.contains("force: true"), """
            Without `force` the re-pull is a guaranteed no-op: the coordinator's install check \
            reads the filesystem, and the model is by definition already there.
            """)
        XCTAssertTrue(try Self.source(Self.service).contains("self.noteRevisionAfterDownload(repoId: repoId, resolved: resolved)"),
                      "updateStatus was written in one place and cleared nowhere; the badge must go out when the work lands")
    }

    /// Capability 4 + 5. Both remote call sites must send the SAME query and page the SAME rank.
    func testBothRemoteCallSitesAgree() throws {
        let vm = try Self.source(Self.viewModel)
        XCTAssertEqual(vm.components(separatedBy: "let search = remoteSearchQuery").count - 1, 2, """
            refreshCategoryData and loadMore must both use the combined query. If loadMore sends \
            the bare searchText, page 2 is unfiltered and appended under a filtered page 1.
            """)
        XCTAssertTrue(vm.contains("sort = lastFetchedSort"), """
            loadMore must page the ranking it STARTED on, not the current sortOption — a skip \
            offset is only meaningful within the ranking that produced the earlier pages.
            """)
        XCTAssertFalse(vm.contains("let search = searchText.isEmpty ? nil : searchText"),
                       "a remote fetch that bypasses remoteSearchQuery drops the quantization narrowing")
    }

    /// Capability 6. The control that clears the filter must never be hidden by the filter.
    func testTheFitFilterAlwaysOffersItsOwnEscape() throws {
        let view = try Self.source(Self.storeView)
        // ⚠️ ASSERT THE INVARIANT, NOT THE CONTROL. This used to pin
        // `Toggle("Fits my Mac", isOn: $viewModel.fitsMyMacOnly)` and went red when the control
        // was restyled into a Button chip that behaves identically — a drift test defending an
        // implementation detail against a legitimate change. What must hold is that SOME control
        // flips the filter and that the hidden count is shown beside it.
        XCTAssertTrue(view.contains("viewModel.fitsMyMacOnly.toggle()")
                      || view.contains("$viewModel.fitsMyMacOnly"),
                      "some control must flip the fit filter, or it can never be cleared")
        XCTAssertTrue(view.contains("Fits my Mac"), "the control must be labelled")
        XCTAssertTrue(view.contains("viewModel.hiddenByFitFilter > 0"),
                      "an empty grid must say how many the filter hid, or it reads as 'nothing exists'")
        // The control must not be gated on its own effect — that is how a filter becomes
        // unclearable. It may only be gated on the tab it does not apply to.
        XCTAssertTrue(view.contains("if viewModel.selectedCategory != .installed"),
                      "the fit control is gated on the tab only, never on its own result count")
        XCTAssertTrue(try Self.source(Self.viewModel).contains("var fitsMyMacOnly: Bool = false"), """
            Default OFF. This hides models on a hardware verdict nobody asked about; the project \
            directive is that classification describes and never gates.
            """)
    }

    // MARK: - Helper

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Core/Service/<this>
            .deletingLastPathComponent()                 // …/Core/Service
            .deletingLastPathComponent()                 // …/Core
            .deletingLastPathComponent()                 // …/DevgenticTests
            .deletingLastPathComponent()                 // repo root
        guard FileManager.default.fileExists(atPath: repoRoot.path) else {
            throw XCTSkip("repo root not reachable from \(#filePath) — running outside a checkout")
        }
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) no longer exists. A drift test guards this file by path; if the code moved, repoint this test rather than letting the guard go silent.")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Audit fixes (2026-09-13)

final class MLXStoreAuditFixTests: XCTestCase {

    /// P1. The regex is now compiled once. This asserts the BEHAVIOUR still holds after hoisting —
    /// a cached regex that stopped matching would be a silent fit-advisor regression.
    func testParameterCountStillParsesAfterTheRegexWasCached() {
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "mlx-community/Qwen3-8B-4bit"), "8B")
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "org/Llama-3.3-70B-Instruct-8bit"), "70B")
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "org/Qwen2.5-1.5B-Instruct-4bit"), "1.5B")
        // ⚠️ The negative lookarounds are the whole point of the pattern: a width glued to a
        // preceding run is part of another token, not a parameter count.
        XCTAssertNil(MLXQuantization.parameterCount(fromRepoId: "org/model-4bit"))
        XCTAssertNil(MLXQuantization.parameterCount(fromRepoId: "org/plain-model"))
    }

    /// Repeated calls must agree — a stale or non-reentrant cached regex would show up here.
    func testTheCachedRegexIsStableAcrossCalls() {
        let ids = ["mlx-community/Qwen3-8B-4bit", "org/Llama-3.3-70B-Instruct-8bit", "org/nothing"]
        let first = ids.map { MLXQuantization.parameterCount(fromRepoId: $0) }
        for _ in 0..<50 {
            XCTAssertEqual(ids.map { MLXQuantization.parameterCount(fromRepoId: $0) }, first)
        }
    }

    /// P2b + P3: source-level, because neither view model can be constructed in a test.
    func testTheAuditFixesAreWiredIn() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            let url = repoRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(rel) no longer exists — repoint this test rather than letting it go silent.")
                return ""
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        // P1: compiled once, not per call.
        let quant = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXQuantization.swift")
        XCTAssertTrue(quant.contains("private static let parameterCountRegex"), """
            NSRegularExpression(pattern:) is ~23 µs of ICU compilation. Building it per call cost \
            ~158 ms of main-actor time per page load once the fit filter began calling it per card \
            per observer tick.
            """)
        // ⚠️ Strip comments first. The doc comment above the cached property NAMES
        // `NSRegularExpression(pattern:)` to explain the cost, and counting raw text scored that
        // as a second construction site — this assertion failed on its own explanation.
        let quantCode = quant.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertEqual(quantCode.components(separatedBy: "NSRegularExpression(pattern:").count - 1, 1,
                       "exactly one construction site — the cached one")

        // P2b: the observer must not track a property written per NDJSON line.
        let ollamaVM = try source("Devgentic/Interfaces/Main/Views/BackendProfile/OllamaLLM/OllamaModelStoreViewModel.swift")
        // ⚠️ Assert the PROPERTY, not the property NAME. This pinned `pullTerminalMessage` and
        // went red when that value was replaced by a richer `pullTerminalState` — the same
        // assert-the-implementation trap that has now caught me four times in this file's history.
        // What must hold is only that the per-NDJSON-line value is not the one being tracked.
        XCTAssertFalse(ollamaVM.contains("_ = self.service.pullStatusMessage"), """
            pullStatusMessage is rewritten once per progress line, and this observer's onChange \
            runs a full re-filter and re-sort — the regression the note above it forbids.
            """)
        XCTAssertTrue(ollamaVM.contains("_ = self.service.pullTerminal"),
                      "the observer must still track SOME terminal-only pull value, or the banner never updates")

        // P3: the hidden count must not outlive the grid it describes.
        let mlxVM = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift")
        XCTAssertTrue(mlxVM.contains("hiddenByFitFilter = 0\n                return []"), """
            The category-mismatch early return sits above the fit block, so without this the \
            previous tab's count renders over an empty, loading grid.
            """)
    }
}

// MARK: - P3 batch (2026-09-13)

final class MLXStoreP3FixTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel

    /// P3 #1. A non-breaking space pasted from a web page used to arrive as ONE token, so a
    /// contradicting width survived the drop and went out ANDed with the picker's — zero rows.
    func testAnyWhitespaceSeparatesTokensNotJustASpace() {
        XCTAssertEqual(VM.remoteQuery(search: "gemma\u{00A0}8bit", quantization: .fourBit), "gemma 4bit")
        XCTAssertEqual(VM.remoteQuery(search: "gemma\t8bit", quantization: .fourBit), "gemma 4bit")
        XCTAssertEqual(VM.remoteQuery(search: "gemma\n8bit", quantization: .fourBit), "gemma 4bit")
    }

    /// ⚠️ The term sent to HuggingFace must not carry a raw U+00A0 either.
    func testTheComposedQueryNeverCarriesExoticWhitespace() {
        let query = VM.remoteQuery(search: "a\u{00A0}b\u{2009}c", quantization: nil) ?? ""
        XCTAssertFalse(query.contains("\u{00A0}"))
    }

    /// P3 #4. Scheme and host are case-insensitive; the PATH is not. Matching on a lowercased
    /// path claimed a broken endpoint was a known-good preset — and offered the token button.
    func testPresetMatchingIsCaseSensitiveOnThePath() {
        XCTAssertNil(CompatibleEndpointPreset.matching("https://router.huggingface.co/V1"),
                     "/V1 is a different path; HTTP paths are case-sensitive")
        XCTAssertEqual(CompatibleEndpointPreset.matching("https://ROUTER.HuggingFace.CO/v1")?.name,
                       "HuggingFace", "host case is insignificant and must still match")
        XCTAssertEqual(CompatibleEndpointPreset.matching("HTTPS://router.huggingface.co/v1")?.name,
                       "HuggingFace", "scheme case is insignificant and must still match")
    }

    /// P3 #7. `HubApi.snapshot` returns normally offline when the repo is complete — no throw, no
    /// bytes. The success path then re-read the OLD commit and the badge was dropped, so the user
    /// saw "Updating…" and the badge vanish on an update that never happened.
    func testAnUpdateThatFetchedNothingKeepsTheBadge() {
        let previous = MLXModelRevision.UpdateStatus.updateAvailable(installed: "aa11bb2", latest: "cc33dd4")
        XCTAssertEqual(MLXModelService.statusAfterDownload(previous: previous, resolved: "aa11bb2"),
                       previous, "unchanged means nothing was fetched — the update is still available")
    }

    /// The other two arms must keep their existing behaviour.
    func testLandingOnThePublishedOrAThirdRevisionIsUnchangedByThatFix() {
        let previous = MLXModelRevision.UpdateStatus.updateAvailable(installed: "aa11bb2", latest: "cc33dd4")
        guard case .upToDate(let rev)? = MLXModelService.statusAfterDownload(previous: previous, resolved: "cc33dd4") else {
            return XCTFail("landing on the published revision must read as up to date")
        }
        XCTAssertEqual(rev, "cc33dd4")
        XCTAssertNil(MLXModelService.statusAfterDownload(previous: previous, resolved: "ee55ff6"),
                     "a third commit means the publisher pushed again — drop and re-derive")
    }

    /// The remaining P3s are wiring, and neither view model can be built in a test.
    func testTheRemainingP3FixesAreWiredIn() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            let url = repoRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(rel) no longer exists — repoint this test rather than letting it go silent.")
                return ""
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        let vm = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift")
        let view = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift")
        let container = try source("Devgentic/Interfaces/Main/Views/MLXModelStoreContainerView.swift")
        let service = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift")

        // #13/#15/#17 — a pending debounce must never duplicate or outlive a newer intent.
        XCTAssertTrue(vm.contains("private func cancelPendingSearch()"))
        XCTAssertGreaterThanOrEqual(vm.components(separatedBy: "cancelPendingSearch()").count - 1, 3,
                                    "declared, plus a call from the category and quantization paths")
        // #16 — an auto-switch must not discard a width the user just chose.
        XCTAssertTrue(vm.contains("if let cleared = quantizationFilter, !isAutoSwitchingCategory {"))
        // #18/#19 — no paging a local tab, and offset from what landed.
        XCTAssertTrue(vm.contains("selectedCategory != .recommended else { return }"))
        XCTAssertTrue(vm.contains("let offset = service.availableModels.count"),
                      "an optimistic page counter leaves a permanent hole after a failed page")
        // #12/#14 — read the expensive computed properties once per body.
        XCTAssertTrue(view.contains("let quantizations = viewModel.availableQuantizations"))
        XCTAssertTrue(view.contains("let fit = fitAssessment"))
        // #9/#10 — the advertised shortcut, and an in-flight guard.
        XCTAssertTrue(container.contains("KeyboardShortcut(.return, modifiers: .command)"))
        XCTAssertTrue(container.contains("guard !isFetchingPastedRepo else { return }"))
        // #5 — an authenticated response must not share a URL-keyed cache.
        XCTAssertTrue(service.contains("token == nil ? cachePolicy : .reloadIgnoringLocalCacheData"))
        // #2/#3 — the token UI says true things.
        XCTAssertTrue(try source("Devgentic/Interfaces/Main/Views/Sidebar/Settings/ModelSettingsSection.swift")
                        .contains("if keychainSaveFailed {"),
                      "the failure row must record an attempt, not infer one from the draft")
        XCTAssertTrue(try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/HuggingFaceTokenEntry.swift")
                        .contains("HuggingFaceTokenStore.looksLikeToken(draft)"),
                      "the sheet's comment promised a shape warning it never performed")
    }
}

// MARK: - The last pre-existing finding (2026-09-13)

final class OllamaPullRefreshTests: XCTestCase {

    /// The pull path must refresh through an UNGUARDED entry point.
    ///
    /// ⚠️ `loadLocalModels()` opens with `guard …, !isPullingModel, … else { return }`, and the
    /// pull's success path runs while `isPullingModel` is still true — so it returned having
    /// fetched nothing. The just-pulled model never appeared in the grid, and `DownloadManager`'s
    /// terminal classification read a stale `localModels` under a comment asserting it was fresh.
    func testThePullPathRefreshesFromInsideItsOwnWindow() throws {
        let service = try Self.source("Devgentic/Core/Service/OllamaService.swift")

        XCTAssertTrue(service.contains("private func performLocalModelRefresh() async {"),
                      "the refresh must exist without the in-flight guard")

        // The guarded entry point still guards, and delegates.
        XCTAssertTrue(service.contains("guard serverStatus == .connected, !isPullingModel, !isRemovingModel else {"),
                      "view appearances must still not race a pull or a delete")

        // ⚠️ The success path calls the UNGUARDED one.
        let successPath = try XCTUnwrap(service.range(of: "pullTerminalState = .succeeded"))
        let afterSuccess = String(service[successPath.upperBound...].prefix(600))
        XCTAssertTrue(afterSuccess.contains("await performLocalModelRefresh()"), """
            The pull's own completion is the one caller that must refresh while isPullingModel is \
            still true. Calling loadLocalModels() there fetches nothing.
            """)
        XCTAssertFalse(afterSuccess.contains("await loadLocalModels()"),
                       "the guarded call in the success path is the defect")
    }

    /// ⚠️ The alternative fix — clearing the flag early to get past the guard — is the same race
    /// from the other side: the bridge would observe the pull finishing before the list was
    /// refreshed. Assert the refresh still precedes the flag clear.
    func testTheRefreshStillPrecedesTheFlagClear() throws {
        let service = try Self.source("Devgentic/Core/Service/OllamaService.swift")
        let refresh = try XCTUnwrap(service.range(of: "await performLocalModelRefresh()"))
        let clear = try XCTUnwrap(service.range(of: "isPullingModel = false"))
        XCTAssertLessThan(refresh.lowerBound, clear.lowerBound, """
            DownloadManager reads localModels on the isPullingModel transition. Clearing the flag \
            before the refresh would make its "localModels is fresh" comment false again.
            """)
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.path) else {
            throw XCTSkip("repo root not reachable from \(#filePath) — running outside a checkout")
        }
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) no longer exists — repoint this test rather than letting it go silent.")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Cross-instance payload sharing (2026-09-13)

final class MLXStoreSharedPayloadTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel

    /// The happy case: the payload is ours.
    func testAMatchingPayloadIsNotForeign() {
        XCTAssertFalse(VM.payloadIsForeign(
            category: .all, payloadCategory: "All", payloadSort: "downloads", payloadSearch: "qwen",
            expectedSort: "downloads", expectedSearch: "qwen"))
    }

    /// ⚠️ THE DEFECT. The agent store fetches `.all` by downloads while the general store is on
    /// `.all` by date. The category matches, so the old guard passed and the general store both
    /// rendered and paged the other instance's rows.
    func testTheSameCategoryWithADifferentRankingIsForeign() {
        XCTAssertTrue(VM.payloadIsForeign(
            category: .all, payloadCategory: "All", payloadSort: "downloads", payloadSearch: nil,
            expectedSort: "lastModified", expectedSearch: nil))
    }

    /// The search term varies the query just as the sort does.
    func testADifferentSearchTermIsForeign() {
        XCTAssertTrue(VM.payloadIsForeign(
            category: .all, payloadCategory: "All", payloadSort: "downloads", payloadSearch: "gemma",
            expectedSort: "downloads", expectedSearch: "qwen"))
        XCTAssertTrue(VM.payloadIsForeign(
            category: .all, payloadCategory: "All", payloadSort: "downloads", payloadSearch: nil,
            expectedSort: "downloads", expectedSearch: "qwen"))
    }

    func testADifferentCategoryIsStillForeign() {
        XCTAssertTrue(VM.payloadIsForeign(
            category: .vision, payloadCategory: "All", payloadSort: "downloads", payloadSearch: nil,
            expectedSort: "downloads", expectedSearch: nil))
    }

    /// ⚠️ A cold store must NOT refetch on first appearance — `init` already issued one.
    func testNothingFetchedYetIsNotForeign() {
        XCTAssertFalse(VM.payloadIsForeign(
            category: .all, payloadCategory: nil, payloadSort: nil, payloadSearch: nil,
            expectedSort: "downloads", expectedSearch: nil))
    }

    /// Local tabs never read the shared array, so they can never disagree with it.
    func testLocalTabsAreExempt() {
        for category: VM.StoreCategory in [.installed, .recommended] {
            XCTAssertFalse(VM.payloadIsForeign(
                category: category, payloadCategory: "All", payloadSort: "downloads", payloadSearch: "x",
                expectedSort: "lastModified", expectedSearch: nil),
                "\(category.rawValue) is served locally and must never trigger a refetch")
        }
    }

    /// All three seams must consult it, and the service must stamp the identity on BOTH write paths.
    func testEverySeamConsultsThePayloadIdentity() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            let url = repoRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(rel) no longer exists — repoint this test rather than letting it go silent.")
                return ""
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        let vm = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift")
        let service = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift")
        let container = try source("Devgentic/Interfaces/Main/Views/MLXModelStoreContainerView.swift")

        XCTAssertTrue(vm.contains("guard !sharedPayloadIsForeign else {"),
                      "loadMore must never append onto another instance's ranking")
        XCTAssertTrue(vm.contains("&& service.availableModelsSort == lastFetchedSort"),
                      "the grid must not RENDER a foreign payload either — category alone was the bug")
        XCTAssertTrue(container.contains("viewModel.refreshIfSharedPayloadIsForeign()"),
                      "re-entry is the only moment a swap made while away is detectable")

        // ⚠️ Both write paths. A failure that clears the payload but leaves a stale identity makes
        // the next loadMore believe the empty array is its own.
        XCTAssertEqual(service.components(separatedBy: "availableModelsSort =").count - 1, 2,
                       "the replace path and the failure path must both stamp the sort")
        XCTAssertEqual(service.components(separatedBy: "availableModelsSearch =").count - 1, 2,
                       "and the search term")
    }
}
