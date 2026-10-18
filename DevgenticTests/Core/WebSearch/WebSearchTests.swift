// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WebSearchTests: XCTestCase {

    private var defaults: UserDefaults!
    private var config: WebSearchConfig!
    private let suite = "WebSearchTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        config = WebSearchConfig(defaults: defaults)
        WebSearchKeyStore.setStorageForTesting(ProgrammableKeychain())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        WebSearchKeyStore.setStorageForTesting(nil)
        super.tearDown()
    }

    private func transport(status: Int = 200, body: String, capture: ((URLRequest) -> Void)? = nil) -> WebSearchClient.Transport {
        { request in capture?(request); return (Data(body.utf8), status) }
    }

    // MARK: Parsing

    func testBraveParsesResultsAndStripsMarkup() throws {
        let body = #"{"web":{"results":[{"title":"Swift","url":"https://swift.org","description":"The <strong>Swift</strong> &amp; more"}]}}"#
        let client = WebSearchClient(provider: .brave, apiKey: "k", transport: transport(body: body))
        let r = try client.parse(Data(body.utf8))
        XCTAssertEqual(r, [WebSearchResult(title: "Swift", url: "https://swift.org", snippet: "The Swift & more")])
    }

    func testTavilyGoogleSearxngParse() throws {
        let tavily = #"{"results":[{"title":"T","url":"https://t.io","content":"c"}]}"#
        XCTAssertEqual(try WebSearchClient(provider: .tavily).parse(Data(tavily.utf8)).first?.snippet, "c")
        let google = #"{"items":[{"title":"G","link":"https://g.io","snippet":"s"}]}"#
        XCTAssertEqual(try WebSearchClient(provider: .google).parse(Data(google.utf8)).first?.url, "https://g.io")
        let searx = #"{"results":[{"title":"S","url":"https://s.io","content":"x"}]}"#
        XCTAssertEqual(try WebSearchClient(provider: .searxng).parse(Data(searx.utf8)).first?.title, "S")
    }

    func testGoogleWithoutItemsIsZeroHitsButNonJSONIsMalformed() {
        XCTAssertEqual(try WebSearchClient(provider: .google).parse(Data("{}".utf8)), [])
        XCTAssertThrowsError(try WebSearchClient(provider: .brave).parse(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? WebSearchError, .malformedResponse)
        }
        // A SearXNG instance with JSON off often answers HTML/other JSON with no `results`.
        XCTAssertThrowsError(try WebSearchClient(provider: .searxng).parse(Data("{}".utf8)))
    }

    func testRowsWithoutAURLAreDropped() throws {
        let body = #"{"results":[{"title":"no url"},{"title":"ok","url":"https://ok.io","content":""}]}"#
        XCTAssertEqual(try WebSearchClient(provider: .tavily).parse(Data(body.utf8)).map(\.url), ["https://ok.io"])
    }

    // MARK: Requests — where the secret travels

    func testBraveAndTavilyKeepTheKeyOutOfTheURL() throws {
        let brave = try WebSearchClient(provider: .brave, apiKey: "SECRET").buildRequest(query: "q", count: 3)
        XCTAssertEqual(brave.value(forHTTPHeaderField: "X-Subscription-Token"), "SECRET")
        XCTAssertFalse(brave.url!.absoluteString.contains("SECRET"))

        let tavily = try WebSearchClient(provider: .tavily, apiKey: "SECRET").buildRequest(query: "q", count: 3)
        XCTAssertEqual(tavily.value(forHTTPHeaderField: "Authorization"), "Bearer SECRET")
        XCTAssertEqual(tavily.httpMethod, "POST")
        XCTAssertFalse(String(decoding: tavily.httpBody!, as: UTF8.self).contains("SECRET"))
    }

    func testGoogleRequestCarriesKeyAndEngineAndNeverCaches() throws {
        let r = try WebSearchClient(provider: .google, apiKey: "K", googleEngineID: "CX1").buildRequest(query: "a b", count: 4)
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "cx" }?.value, "CX1")
        XCTAssertEqual(items.first { $0.name == "num" }?.value, "4")
        XCTAssertEqual(r.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSearxngBuildsJSONSearchURLAndRejectsABadBase() throws {
        let r = try WebSearchClient(provider: .searxng, searxngURL: "http://localhost:8080/").buildRequest(query: "x", count: 5)
        XCTAssertEqual(r.url?.path, "/search")
        XCTAssertTrue(r.url!.absoluteString.contains("format=json"))
        XCTAssertThrowsError(try WebSearchClient(provider: .searxng, searxngURL: "not a url").buildRequest(query: "x", count: 5))
    }

    // MARK: Errors and limits

    func testStatusMapsToActionableHints() async {
        for (status, needle) in [(401, "API key"), (429, "quota")] {
            let client = WebSearchClient(provider: .brave, apiKey: "k", transport: transport(status: status, body: "{}"))
            do { _ = try await client.search(query: "q", count: 1); XCTFail() }
            catch let e as WebSearchError { XCTAssertTrue(e.message.contains(needle), e.message) }
            catch { XCTFail("\(error)") }
        }
        let searx = WebSearchClient(provider: .searxng, searxngURL: "http://h", transport: transport(status: 403, body: ""))
        do { _ = try await searx.search(query: "q", count: 1); XCTFail() }
        catch let e as WebSearchError { XCTAssertTrue(e.message.contains("search.formats")) }
        catch { XCTFail("\(error)") }
    }

    func testCountIsClampedAndResultsTrimmed() async throws {
        var seen: URLRequest?
        let rows = (1...20).map { #"{"title":"t\#($0)","url":"https://e.io/\#($0)","description":"d"}"# }.joined(separator: ",")
        let body = #"{"web":{"results":[\#(rows)]}}"#
        let client = WebSearchClient(provider: .brave, apiKey: "k", transport: transport(body: body) { seen = $0 })
        let results = try await client.search(query: "q", count: 99)
        XCTAssertEqual(results.count, WebSearchClient.maxCount)
        XCTAssertTrue(seen!.url!.absoluteString.contains("count=\(WebSearchClient.maxCount)"))
    }

    // MARK: Keys are per provider

    func testKeysDoNotLeakBetweenProviders() {
        XCTAssertTrue(WebSearchKeyStore.save("brave-key", for: .brave))
        XCTAssertEqual(WebSearchKeyStore.load(for: .brave), "brave-key")
        XCTAssertNil(WebSearchKeyStore.load(for: .tavily))
        XCTAssertNil(WebSearchKeyStore.load(for: .google))
        XCTAssertEqual(WebSearchKeyStore.keychainAccount(for: .google), WebSearchKeyStore.account,
                       "Google keeps the legacy account so an already-stored key stays readable")
    }

    // MARK: Tool

    private func decode(_ json: String) throws -> WebSearchTool.Arguments {
        try JSONDecoder().decode(WebSearchTool.Arguments.self, from: Data(json.utf8))
    }

    func testArgumentsAcceptAliasesAndStringCounts() throws {
        let a = try decode(#"{"q":"swift","count":"3"}"#)
        XCTAssertEqual(a.query, "swift"); XCTAssertEqual(a.count, 3)
        XCTAssertThrowsError(try decode("{}"))
    }

    func testToolRefusesUntilAProviderIsChosenAndConfigured() async throws {
        let tool = WebSearchTool(config: config, transport: transport(body: "{}"))
        // Nothing chosen ⇒ the Google default, which has no key yet.
        XCTAssertEqual(config.provider, .google)
        var out = try await tool.call(arguments: try decode(#"{"query":"x"}"#))
        XCTAssertTrue(out.hasPrefix("Error:") && out.contains("Settings → Web Search"), out)

        config.provider = .brave   // chosen, but no key
        out = try await tool.call(arguments: try decode(#"{"query":"x"}"#))
        XCTAssertTrue(out.hasPrefix("Error:") && out.contains("API key"), out)

        config.provider = .google  // key present is not enough without cx
        WebSearchKeyStore.save("k", for: .google)
        out = try await tool.call(arguments: try decode(#"{"query":"x"}"#))
        XCTAssertTrue(out.contains("Search Engine ID"), out)
    }

    func testToolFormatsResultsAndFlagsThemUntrusted() async throws {
        config.provider = .tavily
        WebSearchKeyStore.save("k", for: .tavily)
        let body = #"{"results":[{"title":"Hit","url":"https://hit.io","content":"snippet text"}]}"#
        let out = try await WebSearchTool(config: config, transport: transport(body: body))
            .call(arguments: try decode(#"{"query":"hello"}"#))
        XCTAssertTrue(out.contains("1. Hit") && out.contains("https://hit.io") && out.contains("snippet text"), out)
        XCTAssertTrue(out.contains("untrusted"), "results are web content and must be labelled data, not instructions")
    }

    func testToolSurfacesProviderRejectionAsAnError() async throws {
        config.provider = .brave
        WebSearchKeyStore.save("bad", for: .brave)
        let out = try await WebSearchTool(config: config, transport: transport(status: 401, body: "{}"))
            .call(arguments: try decode(#"{"query":"x"}"#))
        XCTAssertTrue(out.hasPrefix("Error:") && out.contains("401"), out)
    }

    func testCatalogueOffersWebSearchInTheLibrary() {
        let entry = NativeToolCatalog.entry(named: "web_search")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visibility, .library)
        XCTAssertTrue(ToolConfirmationDefaults.startsWithoutConfirmation("web_search"))
    }

    // MARK: Setup precondition (a tool that can only fail must not be enableable or offered)

    func testBlockerFollowsTheConfiguration() {
        XCTAssertEqual(config.provider, .google, "Google is preselected")
        XCTAssertTrue(config.setupBlocker?.contains("API key") == true, "the default is not usable until configured")

        config.provider = .brave
        XCTAssertTrue(config.setupBlocker?.contains("API key") == true, "chosen but keyless")

        WebSearchKeyStore.save("k", for: .brave)
        XCTAssertNil(config.setupBlocker, "ready")

        config.provider = .google          // Google also needs cx
        WebSearchKeyStore.save("k", for: .google)
        XCTAssertTrue(config.setupBlocker?.contains("Search Engine ID") == true)
        config.googleEngineID = "cx1"
        XCTAssertNil(config.setupBlocker)

        config.provider = .searxng         // no key needed, but needs a valid URL
        XCTAssertTrue(config.setupBlocker?.contains("SearXNG") == true)
        config.searxngURL = "http://localhost:8080"
        XCTAssertNil(config.setupBlocker)
    }

    /// The wiring: the policy above is worthless if nothing consults it. Cutting either consumer
    /// must fail a test.
    func testTheBlockerIsDeclaredOnTheCatalogueEntryAndConsultedByItsSurfaces() throws {
        XCTAssertNotNil(NativeToolCatalog.entry(named: "web_search")?.setup)
        XCTAssertEqual(NativeToolCatalog.setupSettings(for: "web_search"), .webSearch)
        XCTAssertNil(NativeToolCatalog.entry(named: "read_file")?.setup, "ordinary tools need no setup")

        let validator = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/WorkflowCanvas/WorkflowValidation.swift")
        XCTAssertTrue(validator.contains("NativeToolCatalog.setupBlocker(for: tool.name)"),
                      "the workflow validator no longer warns about an Action node whose tool is not set up")
        let library = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/Tooling/ToolLibraryView.swift")
        XCTAssertTrue(library.contains("setupBlocker == nil || $0 == .disabled"), "the Tool Library no longer restricts an unconfigured tool to Disabled + Setup")
        XCTAssertTrue(library.contains("SetupOptionRow("), "the Setup option is gone from the dropdown")
        XCTAssertTrue(library.contains("NativeToolCatalog.setupBlocker(for: name)"), "bulk enable no longer skips it")
    }
}
