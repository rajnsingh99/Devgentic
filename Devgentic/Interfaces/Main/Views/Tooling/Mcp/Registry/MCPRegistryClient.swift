// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPRegistryClient.swift
//  Devgentic
//
//  Created 2026-08-01 — read-only client for the official MCP Registry.
//
//  Search runs SERVER-SIDE. The registry indexes tens of thousands of servers; mirroring
//  that locally would be a sync problem we have no reason to own, and a stale mirror is
//  worse than no catalogue at all.
//
//  Everything here is read-only and unauthenticated. The registry is treated as UNTRUSTED
//  third-party data end to end: entries are decoded leniently, URLs are scheme-checked
//  before they reach the connect path, and nothing is ever launched without the user
//  reviewing it first.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPRegistryClient")

enum MCPRegistryError: LocalizedError {
    case badResponse(status: Int)
    case transport(Error)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            return "The MCP registry returned HTTP \(status)."
        case .transport(let error):
            return "Couldn't reach the MCP registry: \(error.localizedDescription)"
        case .decoding(let detail):
            return "The MCP registry sent something unreadable: \(detail)"
        }
    }
}

@MainActor
struct MCPRegistryClient {

    /// Official registry. API frozen at v0.1 since 2025-10.
    static let baseURL = URL(string: "https://registry.modelcontextprotocol.io")!

    /// Page size. 100 is the API's ceiling — verified 2026-08-02: `limit=200` returns zero
    /// servers rather than clamping, so asking for more is strictly worse than asking for max.
    private static let pageSize = 100

    /// How much of the registry to hold locally for description search.
    ///
    /// The full registry is 6,000+ servers — measured 2026-08-02 at 60 pages, ~5 MB and
    /// **97 seconds**. Fetching all of it to answer one search is out of the question, so the
    /// corpus is bounded and loaded in the background after the first page paints. Ten pages
    /// covers the common case; beyond it the server-side name search still reaches everything.
    private static let maxCorpusPages = 10

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    struct Page {
        let servers: [MCPRegistryServer]
        let nextCursor: String?
    }

    /// Last successful UNFILTERED first page, with the time it was fetched.
    ///
    /// `MCPDiscoverView` is torn down and rebuilt every time the user toggles
    /// Installed↔Discover, so its `.task` re-ran and re-fetched ~38 KB each time — for a
    /// catalogue that changes on the order of days. Searches and paged requests are never
    /// cached; they are cheap to re-issue and staleness there is more confusing than a wait.
    private static var cachedFirstPage: (page: Page, fetchedAt: Date)?
    private static let cacheTTL: TimeInterval = 300

    /// Servers held locally for description matching, plus how far the load got.
    private static var corpus: [MCPRegistryServer] = []
    private static var corpusIsComplete = false
    private static var corpusLoadTask: Task<Void, Never>?

    /// True when the corpus covers the whole registry, so a description search is exhaustive
    /// rather than best-effort. Surfaced to the UI so the claim it makes stays honest.
    static var isCorpusComplete: Bool { corpusIsComplete }
    static var corpusCount: Int { corpus.count }

    /// Drops everything cached so the next open re-fetches from scratch.
    ///
    /// No caller yet — a manual "Refresh" affordance in Discover is the intended one, listed
    /// as an open gap. Kept because the corpus and page cache must be cleared TOGETHER, and
    /// splitting that knowledge across a future call site is how they drift apart.
    static func invalidateCache() {
        cachedFirstPage = nil
        corpusLoadTask?.cancel()
        corpusLoadTask = nil
        corpus = []
        corpusIsComplete = false
        logger.info("[MCP-REGISTRY] Cache invalidated; the next Discover open will re-fetch.")
    }

    // MARK: - Search

    /// Searches names AND descriptions.
    ///
    /// The registry's own `search` is a substring match on the NAME only, verified against the
    /// live API — so a user looking for a capability ("database", "email") misses every server
    /// that does not happen to carry the word in its name, and no parameter fixes it. This
    /// combines two sources:
    ///
    ///   • **Server-side name search** — reaches the WHOLE registry, so a name match is never
    ///     missed however little of the corpus has loaded.
    ///   • **Local name+description filter** over the bounded corpus — catches the capability
    ///     matches the API cannot express.
    ///
    /// Union, deduplicated by server name. Description coverage stays best-effort until the
    /// corpus completes, which `isCorpusComplete` reports rather than papering over.
    static func search(_ term: String) async -> [MCPRegistryServer] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return corpus }

        let needle = trimmed.lowercased()
        let localMatches = corpus.filter { server in
            server.name.lowercased().contains(needle)
                || server.displayName.lowercased().contains(needle)
                || server.description.lowercased().contains(needle)
        }

        // The remote leg runs regardless: the corpus is a slice, and a name match outside it
        // would otherwise be invisible.
        var remoteMatches: [MCPRegistryServer] = []
        do {
            remoteMatches = try await performFetch(search: trimmed, cursor: nil, cacheAsDefaultPage: false).servers
        } catch {
            // Degrade to local-only rather than failing the whole search: partial results beat
            // an error page when the user already has a corpus in hand.
            logger.warning("""
                [MCP-REGISTRY] Remote name search for '\(trimmed)' FAILED: \(error.localizedDescription). \
                Falling back to \(localMatches.count) local match(es); servers matching by name outside \
                the \(corpus.count)-server corpus are missing from these results.
                """)
        }

        var seen = Set<String>()
        var merged: [MCPRegistryServer] = []
        for server in localMatches + remoteMatches where seen.insert(server.name).inserted {
            merged.append(server)
        }

        let descriptionOnly = localMatches.filter { !$0.name.lowercased().contains(needle) }.count
        logger.info("""
            [MCP-REGISTRY] Search '\(trimmed)': \(merged.count) result(s) — \(localMatches.count) local \
            (\(descriptionOnly) matched on DESCRIPTION only, which the registry API cannot return), \
            \(remoteMatches.count) remote name match(es). Corpus \(corpus.count) server(s), \
            \(corpusIsComplete ? "complete" : "still loading").
            """)
        return merged
    }

    // MARK: - Corpus

    /// Loads the browse corpus progressively, invoking `onPage` as each page lands so the grid
    /// fills rather than waiting on the whole thing.
    static func loadCorpus(onPage: @escaping @MainActor ([MCPRegistryServer]) -> Void) {
        guard corpusLoadTask == nil else {
            onPage(corpus)
            return
        }
        guard !corpusIsComplete else {
            onPage(corpus)
            return
        }

        onPage(corpus)

        corpusLoadTask = Task { @MainActor in
            defer { corpusLoadTask = nil }

            var cursor: String? = nil
            var seen = Set(corpus.map(\.name))
            var page = 0
            let started = Date()

            while page < maxCorpusPages {
                guard !Task.isCancelled else { return }

                let result: Page
                do {
                    result = try await performFetch(search: nil, cursor: cursor, cacheAsDefaultPage: page == 0)
                } catch {
                    logger.warning("""
                        [MCP-REGISTRY] Corpus load stopped at page \(page) (\(corpus.count) server(s)): \
                        \(error.localizedDescription). Description search stays limited to what loaded; \
                        name search is unaffected.
                        """)
                    return
                }

                for server in result.servers where seen.insert(server.name).inserted {
                    corpus.append(server)
                }
                page += 1
                onPage(corpus)

                guard let next = result.nextCursor, !next.isEmpty else {
                    corpusIsComplete = true
                    break
                }
                cursor = next
            }

            logger.info("""
                [MCP-REGISTRY] Corpus \(corpusIsComplete ? "COMPLETE" : "capped at \(maxCorpusPages) pages") — \
                \(corpus.count) server(s) in \(Self.ms(since: started))ms. \
                \(corpusIsComplete ? "Description search is exhaustive." : "Description search covers this slice; name search still reaches the whole registry.")
                """)
        }
    }

    private static func performFetch(
        search: String?,
        cursor: String?,
        cacheAsDefaultPage: Bool
    ) async throws -> Page {
        var components = URLComponents(url: baseURL.appendingPathComponent("v0/servers"), resolvingAgainstBaseURL: false)!
        // `version=latest` collapses the registry's per-VERSION rows SERVER-side. Verified
        // 2026-08-02: a 50-row page carried only 31 distinct servers without it, and 50 with.
        // The client-side dedup below is kept as a belt-and-braces guard — it is cheap, and it
        // still protects the `ForEach` identity that duplicates would corrupt.
        var items = [
            URLQueryItem(name: "limit", value: "\(pageSize)"),
            URLQueryItem(name: "version", value: "latest"),
        ]
        let trimmedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSearch, !trimmedSearch.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmedSearch))
        }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw MCPRegistryError.decoding("Could not build the registry URL.")
        }

        let started = Date()
        logger.info("""
            [MCP-REGISTRY] Fetching \(url.path) search='\(trimmedSearch ?? "")' \
            cursor=\(cursor?.isEmpty == false ? "yes" : "none") limit=\(pageSize).
            """)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            logger.error("""
                [MCP-REGISTRY] Transport failure after \(Self.ms(since: started))ms: \
                \(error.localizedDescription). The Discover list stays on whatever it last \
                showed; the user sees a retry.
                """)
            throw MCPRegistryError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            logger.error("""
                [MCP-REGISTRY] HTTP \(status) after \(Self.ms(since: started))ms \
                (\(data.count) bytes). No servers were loaded.
                """)
            throw MCPRegistryError.badResponse(status: status)
        }

        let decoded: MCPRegistryResponse
        do {
            decoded = try JSONDecoder().decode(MCPRegistryResponse.self, from: data)
        } catch {
            logger.error("""
                [MCP-REGISTRY] Decode failed after \(Self.ms(since: started))ms over \
                \(data.count) bytes: \(error). The registry schema may have moved past what \
                this build understands; Discover will show nothing.
                """)
            throw MCPRegistryError.decoding(error.localizedDescription)
        }

        let deduplicated = deduplicate(decoded.servers)
        let duplicatesCollapsed = decoded.servers.count - deduplicated.count

        // Metadata-only entries have nothing to connect to. Listing them produces rows whose
        // only possible outcome is a failure, so they are dropped — but counted, because a
        // sudden spike means the schema changed under us.
        let connectable = deduplicated.filter(\.isConnectable)
        let dropped = deduplicated.count - connectable.count
        let all = deduplicated

        logger.info("""
            [MCP-REGISTRY] Received \(decoded.servers.count) entr(ies) in \(Self.ms(since: started))ms \
            (\(data.count) bytes); \(duplicatesCollapsed) older version(s) collapsed, \
            \(connectable.count) connectable, \(dropped) dropped as metadata-only. \
            local=\(connectable.count(where: \.isLocal)) \
            remote=\(connectable.count(where: \.isRemote)) \
            nextCursor=\(decoded.metadata?.nextCursor?.isEmpty == false ? "yes" : "none").
            """)

        // The registry's first response of a session is routinely far slower than later ones
        // (cold edge cache). Worth naming, because from the user's side it is indistinguishable
        // from Discover being broken.
        let elapsed = Self.ms(since: started)
        if elapsed > 5000 {
            logger.warning("""
                [MCP-REGISTRY] Slow response: \(elapsed)ms for \(data.count) bytes. Discover shows \
                a spinner for this whole time; if this repeats the registry or the network path \
                is degraded, not the app.
                """)
        }

        if dropped > all.count / 2 && all.count > 4 {
            logger.warning("""
                [MCP-REGISTRY] ⚠️ Over half of this page (\(dropped)/\(all.count)) had neither a \
                package nor a remote. That is unusual and may mean the registry schema changed \
                and our decoder is silently missing fields — the browse list will look sparse.
                """)
        }

        let page = Page(servers: connectable, nextCursor: decoded.metadata?.nextCursor)
        if cacheAsDefaultPage {
            cachedFirstPage = (page, Date())
        }
        return page
    }

    /// Collapses the registry's per-VERSION rows into one row per server.
    ///
    /// `/v0/servers` returns every published version, so a 50-entry page can hold only ~32
    /// distinct servers — one publisher had four. Left unfiltered this is not just visual
    /// noise: SwiftUI keys `ForEach` on the server name, and duplicate identities scramble
    /// the grid into overlapping, mis-placed cells.
    ///
    /// Prefers the row the registry marks `isLatest`; anything without the flag falls back
    /// to first-seen, so a server whose metadata shape has moved still appears exactly once
    /// rather than vanishing.
    static func deduplicate(_ envelopes: [MCPRegistryEnvelope]) -> [MCPRegistryServer] {
        var seen = Set<String>()
        var result: [MCPRegistryServer] = []

        for envelope in envelopes where envelope.isLatest {
            if seen.insert(envelope.server.name).inserted {
                result.append(envelope.server)
            }
        }
        for envelope in envelopes where !envelope.isLatest {
            if seen.insert(envelope.server.name).inserted {
                result.append(envelope.server)
            }
        }
        return result
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
