// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NetworkTools.swift
//  Devgentic
//

import Foundation
import SystemConfiguration

// MARK: - Check Network Status Tool

struct CheckNetworkStatusTool: DevgenticTool {
    let name = "check_network_status"
    let category = "Network & Connectivity"
    let description = "Checks network connectivity, returns Wi-Fi SSID, IP address, and internet reachability."

    struct Arguments: Decodable, Sendable {}

    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }

    func call(arguments: Arguments) async throws -> String {
        var info = "Network Status:\n"

        // Internet reachability via SCNetworkReachability
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)

        let reachable: Bool = withUnsafePointer(to: &zeroAddress) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                guard let ref = SCNetworkReachabilityCreateWithAddress(nil, addrPtr) else { return false }
                var flags = SCNetworkReachabilityFlags()
                guard SCNetworkReachabilityGetFlags(ref, &flags) else { return false }
                return flags.contains(.reachable) && !flags.contains(.connectionRequired)
            }
        }
        info += "Internet Reachable: \(reachable ? "Yes" : "No")\n"

        // IP address first: it is the evidence the SSID line needs to interpret itself.
        // Invoked directly rather than through `zsh -c "… || echo 'No IP'"` — a shell hosting one
        // fallback is a shell we do not need.
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        ipProcess.arguments = ["getifaddr", "en0"]
        let ipRun = try? ProcessRunner.run(ipProcess)
        let ip = (ipRun?.succeeded == true)
            ? ipRun!.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // Wi-Fi SSID.
        //
        // The previous probe piped `Apple80211.framework/.../airport -I` through awk — and macOS
        // NO LONGER SHIPS THAT BINARY. The pipeline produced nothing on stdout, the empty result
        // was read as "no SSID", and the tool printed **"Wi-Fi SSID: Not connected"**. On a
        // machine sitting on Wi-Fi, the agent was told flatly that it was not — a positive claim
        // about the network derived from a probe that does not exist. "Cannot tell" and "not
        // connected" are different answers and must read differently.
        //
        // `networksetup` still ships. It reports one of two sentences, and on Sonoma and later it
        // withholds the SSID unless Location Services is granted — so its "not associated" reply
        // is NOT by itself proof of disconnection. Cross-referencing the IP is what makes the
        // difference legible: an interface holding an address is on a network whatever
        // `networksetup` is willing to name.
        let ssidProcess = Process()
        ssidProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        ssidProcess.arguments = ["-getairportnetwork", "en0"]
        let ssidRun = try? ProcessRunner.run(ssidProcess)
        let ssidOutput = (ssidRun?.combinedOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let ssidLine: String
        if let range = ssidOutput.range(of: "Current Wi-Fi Network: ") {
            ssidLine = String(ssidOutput[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ssidRun == nil || ssidOutput.isEmpty {
            ssidLine = "Unavailable (the Wi-Fi probe could not be run on this system)"
        } else if !ip.isEmpty {
            ssidLine = "Unavailable (en0 holds an IP address, so a network IS connected; "
                + "macOS withholds the network name without Location Services permission)"
        } else {
            ssidLine = "Not connected"
        }
        info += "Wi-Fi SSID: \(ssidLine)\n"

        info += "Local IP: \(ip.isEmpty ? "No IP on en0" : ip)\n"

        return info
    }
}

// MARK: - HTTP Request Tool

struct HTTPRequestTool: DevgenticTool {
    let name = "http_request"
    let category = "Network & Connectivity"
    let description = "Makes HTTP GET or POST requests and returns the response status, headers, and body."

    struct Arguments: Decodable, Sendable {
        let url: String
        let method: String?
        let body: String?
        let headers: [String: String]?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var foundURL: String? = nil
            for key in ["url", "endpoint", "uri", "address"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundURL = val
                    break
                }
            }
            guard let val = foundURL else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'url'"))
            }
            self.url = val
            self.method = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "method")!))
            self.body = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "body")!))

            // Accepts headers as an OBJECT or as a JSON STRING containing one.
            //
            // The schema used to advertise `headers` as a "string" ("JSON object of custom
            // headers") while this decoded `[String: String]` — so a model that followed the
            // schema it was given sent `"{\"Authorization\":\"Bearer …\"}"`, the decode threw,
            // `try?` turned it into nil, and the request went out with NO HEADERS AT ALL. The
            // server answered 401 and nothing anywhere said the credentials had been dropped on
            // the way out. The schema now says "object", and the string form is still honoured
            // because models will keep emitting it.
            var foundHeaders: [String: String]? = nil
            if let key = DynamicKey(stringValue: "headers") {
                if let dictionary = try? container.decodeIfPresent([String: String].self, forKey: key) {
                    foundHeaders = dictionary
                } else if let raw = try? container.decodeIfPresent(String.self, forKey: key),
                          let data = raw.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                    foundHeaders = decoded
                }
            }
            self.headers = foundHeaders
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("url", "string", "The URL to request."),
                ("method", "string", "HTTP method: 'GET' or 'POST' (default 'GET')"),
                ("body", "string", "Request body for POST requests"),
                // "object", not "string": whatever this declares is what a model will send, so it
                // has to name a type the decoder accepts. It said "string" while the decoder took
                // only an object, and the mismatch dropped headers silently.
                ("headers", "object", "Custom request headers as name/value pairs, e.g. {\"Authorization\": \"Bearer …\"}")
            ],
            required: ["url"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // The SCHEME is what actually has to be checked, not merely that `URL(string:)` returns
        // something. Modern Foundation parses almost anything — `URL(string: "not a url at all")`
        // succeeds by percent-encoding the spaces — so the old nil-check was nearly dead code,
        // and the most common real mistake (a bare `example.com`, which models emit constantly)
        // sailed past it to fail inside URLSession as "unsupported URL": late, after a round
        // trip, and giving the model nothing it could act on.
        guard let url = URL(string: arguments.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Error: '\(arguments.url)' is not a usable HTTP URL. "
                + "Include the scheme, e.g. https://example.com."
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = (arguments.method ?? "GET").uppercased()

        if let body = arguments.body {
            request.httpBody = body.data(using: .utf8)
        }

        if let headers = arguments.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return "Error: Non-HTTP response."
            }

            let statusCode = httpResponse.statusCode
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary data, \(data.count) bytes>"
            let maxBody = 5000
            let truncatedBody = bodyString.count > maxBody ? String(bodyString.prefix(maxBody)) + "\n...[Truncated at \(maxBody) chars]" : bodyString

            return "HTTP \(statusCode)\nHeaders: \(httpResponse.allHeaderFields.count) fields\nBody:\n\(truncatedBody)"
        } catch {
            return "Error: HTTP request failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - DNS Lookup Tool

struct DNSLookupTool: DevgenticTool {
    let name = "dns_lookup"
    let category = "Network & Connectivity"
    let description = "Resolves a hostname to IP addresses using DNS lookup."

    struct Arguments: Decodable, Sendable {
        let hostname: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("hostname", "string", "The hostname to resolve (e.g. 'apple.com')")
            ],
            required: ["hostname"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nslookup")
        process.arguments = [arguments.hostname]

        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            //
            // combinedOutput, not standardOutput: this site set `standardError = outPipe`,
            // so its single read returned both. `nslookup` reports a failed lookup
            // ("can't find <host>: NXDOMAIN") on stderr and exits non-zero with EMPTY
            // stdout — reading stdout alone turns every failed lookup into blank output.
            let output = try ProcessRunner.run(process).combinedOutput
            return "DNS Lookup for '\(arguments.hostname)':\n\(output)"
        } catch {
            return "Error: DNS lookup failed — \(error.localizedDescription)"
        }
    }
}
