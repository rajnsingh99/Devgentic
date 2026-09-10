// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPOAuthLoopbackListener.swift
//  Devgentic
//
//  Loopback OAuth redirect listener (RFC 8252 §7.3).
//
//  At authorize-time we bind a fresh TCP socket on `127.0.0.1:<random-port>`,
//  hand the resulting URL (e.g. `http://127.0.0.1:53017/callback`) to the
//  authorization server as `redirect_uri`, and wait for the user-agent to
//  redirect there with `?code=…&state=…` after the user signs in. The server
//  shuts down as soon as we capture the first valid callback or hit the timeout.
//
//  Why we don't use ASWebAuthenticationSession's callbackURLScheme: it only
//  matches custom schemes (e.g. `devgentic://`), not loopback http URLs.
//  Loopback is the spec's preferred desktop redirect (no Info.plist plumbing,
//  works in dev and production identically), so we serve it ourselves.
//

import Foundation
import Network
import os

private let logger = DGLogger(category: "MCPOAuthLoopback")

enum MCPOAuthLoopbackError: LocalizedError {
    case listenerFailed(String)
    case timedOut
    case clientCancelled
    case malformedRequest(String)
    case missingCode

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let s): return "Loopback listener failed: \(s)"
        case .timedOut:              return "OAuth flow timed out waiting for redirect."
        case .clientCancelled:       return "OAuth flow was cancelled."
        case .malformedRequest(let s): return "OAuth redirect request malformed: \(s)"
        case .missingCode:           return "OAuth redirect did not include `code`."
        }
    }
}

/// One-shot loopback listener. Construct, start, await one callback, listener
/// is then closed. Re-use is intentionally not supported — every flow gets a
/// fresh port to avoid stale `redirect_uri` registrations leaking between flows.
final class MCPOAuthLoopbackListener: Sendable {

    /// Path the AS will redirect to. Hardcoded so we can match GET requests
    /// against it verbatim — anything else is rejected.
    static let callbackPath = "/callback"

    /// Constructed `redirect_uri` to hand to the authorization server.
    let redirectURL: URL

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.devgentic.mcp.oauth.loopback")
    private let state = State()

    /// Mutable, lock-protected state. `Sendable` is enforced by funneling all
    /// reads/writes through `lock`.
    private final class State: @unchecked Sendable {
        var continuation: CheckedContinuation<URLComponents, Error>?
        var settled = false
        let lock = NSLock()

        func settle(with result: Result<URLComponents, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            settled = true
            switch result {
            case .success(let q): continuation?.resume(returning: q)
            case .failure(let e): continuation?.resume(throwing: e)
            }
            continuation = nil
        }
    }

    init() throws {
        let parameters = NWParameters.tcp

        // Confine the socket to loopback.
        //
        // `NWParameters.tcp` with no required local endpoint binds EVERY interface, so
        // the OAuth callback listener was reachable from anything on the same network —
        // an ephemeral port on the user's LAN accepting `/callback?code=…`. The `state`
        // check and PKCE meant a stranger could not actually complete a flow, but the
        // socket had no business being off-machine in the first place, and RFC 8252 §7.3
        // specifies the loopback interface for exactly this redirect.
        //
        // (`on: .any` below is the PORT — "pick any free one" — not an address. It was
        // never the thing binding all interfaces.)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw MCPOAuthLoopbackError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener

        // Bind synchronously by starting and waiting for `.ready` before
        // returning the redirect URL. Runs on a private queue so we don't
        // block the main actor.
        let semaphore = DispatchSemaphore(value: 0)
        var assignedPort: NWEndpoint.Port?
        var bindError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                assignedPort = listener.port
                semaphore.signal()
            case .failed(let err):
                bindError = err
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        // 5 seconds is generous — `NWListener` typically goes ready in <50ms.
        let waitResult = semaphore.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            listener.cancel()
            throw MCPOAuthLoopbackError.listenerFailed("Listener never became ready.")
        }
        if let bindError {
            throw MCPOAuthLoopbackError.listenerFailed(bindError.localizedDescription)
        }
        guard let port = assignedPort else {
            throw MCPOAuthLoopbackError.listenerFailed("No port assigned.")
        }

        self.redirectURL = URL(string: "http://127.0.0.1:\(port.rawValue)\(Self.callbackPath)")!
        logger.info("Loopback listener bound at \(self.redirectURL.absoluteString)")
    }

    /// Wait for a single redirect on `/callback`. Returns the parsed query as
    /// `URLComponents` so the caller can read `code`, `state`, `error`, etc.
    /// Listener shuts down before the function returns regardless of outcome.
    func awaitCallback(timeout: TimeInterval = 300) async throws -> URLComponents {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLComponents, Error>) in
            state.lock.lock()
            state.continuation = continuation
            state.lock.unlock()

            // Hand off incoming connections to the parser.
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.handle(connection: connection)
            }

            // Timeout safety net — flips the continuation if no redirect arrives.
            // Without this a stuck browser tab would hang the whole flow forever.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.state.settle(with: .failure(MCPOAuthLoopbackError.timedOut))
                self?.shutdown()
            }
        }
    }

    /// Manual cancel — used by the higher-level `MCPOAuthBrowserRedirectHandler`
    /// when the user dismisses the browser session (ASWebAuthenticationSession
    /// would otherwise leave us hanging forever).
    func cancel() {
        state.settle(with: .failure(MCPOAuthLoopbackError.clientCancelled))
        shutdown()
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        // Most browsers send the request in a single packet (~300-500 bytes).
        // 4 KB is more than enough for any reasonable redirect URL.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            defer { connection.cancel() }

            if let error {
                self.state.settle(with: .failure(MCPOAuthLoopbackError.malformedRequest(error.localizedDescription)))
                self.shutdown()
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.state.settle(with: .failure(MCPOAuthLoopbackError.malformedRequest("Empty body.")))
                self.shutdown()
                return
            }

            // Parse "GET /callback?code=…&state=… HTTP/1.1" — first line only.
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
            let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, parts[0] == "GET" else {
                self.respondNotFound(connection: connection)
                self.state.settle(with: .failure(MCPOAuthLoopbackError.malformedRequest("Non-GET request.")))
                self.shutdown()
                return
            }

            // The path may have query: "/callback?code=…". Reject anything
            // that doesn't start with our exact path (e.g. /favicon.ico).
            let pathAndQuery = parts[1]
            guard pathAndQuery.hasPrefix(Self.callbackPath) else {
                self.respondNotFound(connection: connection)
                // Not done yet — favicon etc. could fire here. Keep waiting.
                return
            }

            // Build a URLComponents we can extract the query from.
            guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)") else {
                self.respondNotFound(connection: connection)
                self.state.settle(with: .failure(MCPOAuthLoopbackError.malformedRequest("Bad URL.")))
                self.shutdown()
                return
            }

            // Send the success page before settling so the browser tab updates
            // immediately. The body is a tiny self-contained HTML.
            self.respondSuccess(connection: connection)
            self.state.settle(with: .success(components))
            self.shutdown()
        }
    }

    private func respondSuccess(connection: NWConnection) {
        let body = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <title>Devgentic — Sign-in complete</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; padding: 40px; max-width: 480px; color: #1a1a1a; }
          h1 { font-size: 22px; margin-bottom: 8px; }
          p { color: #666; line-height: 1.5; }
        </style></head>
        <body>
        <h1>✓ Signed in to Devgentic</h1>
        <p>You can close this window and return to the app.</p>
        </body></html>
        """
        respond(connection: connection, status: "200 OK", body: body)
    }

    private func respondNotFound(connection: NWConnection) {
        respond(connection: connection, status: "404 Not Found", body: "Not Found")
    }

    private func respond(connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func shutdown() {
        listener.newConnectionHandler = nil
        listener.cancel()
    }
}
