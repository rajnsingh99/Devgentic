// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchClient.swift
//  Devgentic
//
//  One request builder and one response parser per provider, normalised to `WebSearchResult`.
//
//  Credentials go in headers wherever the provider allows (Brave, Tavily). Google Custom Search
//  only documents a `key` query parameter, so that URL carries the secret — which is why the
//  default transport is an EPHEMERAL session: nothing is written to URLSession's on-disk cache
//  (`~/Library/Caches`), where a keyed URL would otherwise sit indefinitely.
//

import Foundation

private let logger = DGLogger(category: "WebSearchClient")

struct WebSearchResult: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

enum WebSearchError: Error, Equatable {
    case notConfigured(String)
    case rejected(status: Int, hint: String)
    case malformedResponse
    case transport(String)

    /// The text the MODEL sees. Always names what to do, because the model can relay it to the
    /// user but cannot fix a key itself.
    var message: String {
        switch self {
        case .notConfigured(let what):
            return "Web search is not set up: \(what). Ask the user to open Settings → Web Search."
        case .rejected(let status, let hint):
            return "The search provider refused the request (HTTP \(status)). \(hint)"
        case .malformedResponse:
            return "The search provider answered with something that was not a search result."
        case .transport(let detail):
            return "The search request failed — \(detail)"
        }
    }
}

struct WebSearchClient: Sendable {

    /// Sends a request, returning body and status. A seam so tests never touch the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    static let defaultTransport: Transport = { request in
        // Ephemeral: no disk cache, no cookie jar. See the file header.
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static let maxCount = 10
    static let defaultCount = 5
    private static let snippetLimit = 400

    let provider: WebSearchProvider
    let apiKey: String
    let googleEngineID: String
    let searxngURL: String
    let transport: Transport

    init(provider: WebSearchProvider, apiKey: String = "", googleEngineID: String = "",
         searxngURL: String = "", transport: @escaping Transport = WebSearchClient.defaultTransport) {
        self.provider = provider
        self.apiKey = apiKey
        self.googleEngineID = googleEngineID
        self.searxngURL = searxngURL
        self.transport = transport
    }

    func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let n = min(max(count, 1), Self.maxCount)
        let request = try buildRequest(query: query, count: n)

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch {
            logger.warning("[WEBSEARCH] \(provider.rawValue) request failed: \(error.localizedDescription). CONSEQUENCE: the agent is told the search failed and gets no results.")
            throw WebSearchError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(status) else {
            logger.warning("[WEBSEARCH] \(provider.rawValue) answered HTTP \(status). CONSEQUENCE: the agent gets an error naming the likely cause, not results.")
            throw WebSearchError.rejected(status: status, hint: hint(forStatus: status))
        }
        return Array(try parse(data).prefix(n))
    }

    // MARK: - Requests

    func buildRequest(query: String, count: Int) throws -> URLRequest {
        var request: URLRequest
        switch provider {
        case .brave:
            var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: String(count))]
            request = URLRequest(url: c.url!)
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

        case .tavily:
            request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["query": query, "max_results": count, "include_answer": false]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        case .google:
            var c = URLComponents(string: "https://www.googleapis.com/customsearch/v1")!
            c.queryItems = [.init(name: "key", value: apiKey), .init(name: "cx", value: googleEngineID),
                            .init(name: "q", value: query), .init(name: "num", value: String(count))]
            request = URLRequest(url: c.url!)

        case .searxng:
            guard let base = SearchEndpoint.baseURL(searxngURL) else {
                throw WebSearchError.notConfigured("no valid SearXNG instance URL is set")
            }
            var c = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
            request = URLRequest(url: c.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func hint(forStatus status: Int) -> String {
        switch (provider, status) {
        case (.searxng, 403):
            return "The instance has JSON output disabled: add `json` to `search.formats` in its settings.yml."
        case (_, 401), (_, 403):
            return "The API key looks invalid, expired or not enabled for this API. Check it in Settings → Web Search."
        case (_, 429):
            return "The plan's rate or monthly quota is used up. Try again later or switch provider."
        default:
            return "Try again, or switch provider in Settings → Web Search."
        }
    }

    // MARK: - Parsing

    func parse(_ data: Data) throws -> [WebSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.malformedResponse
        }
        let rows: [[String: Any]]
        let titleKey: String, urlKey: String, snippetKey: String
        switch provider {
        case .brave:
            rows = ((root["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
            (titleKey, urlKey, snippetKey) = ("title", "url", "description")
        case .tavily:
            rows = (root["results"] as? [[String: Any]]) ?? []
            (titleKey, urlKey, snippetKey) = ("title", "url", "content")
        case .google:
            // No `items` key at all means zero hits, not a malformed reply.
            rows = (root["items"] as? [[String: Any]]) ?? []
            (titleKey, urlKey, snippetKey) = ("title", "link", "snippet")
        case .searxng:
            guard root["results"] != nil else { throw WebSearchError.malformedResponse }
            rows = (root["results"] as? [[String: Any]]) ?? []
            (titleKey, urlKey, snippetKey) = ("title", "url", "content")
        }
        return rows.compactMap { row in
            guard let url = (row[urlKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { return nil }
            let title = Self.clean(row[titleKey] as? String ?? "")
            return WebSearchResult(title: title.isEmpty ? url : title, url: url,
                                   snippet: Self.clean(row[snippetKey] as? String ?? "", limit: Self.snippetLimit))
        }
    }

    /// Strips the markup providers embed in snippets (Brave wraps matches in `<strong>`),
    /// decodes the common entities and collapses whitespace.
    static func clean(_ raw: String, limit: Int? = nil) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let limit, text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }
}
