// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NetworkTools.swift
//  Devgentic
//
//  Created by Raj Singh.
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
        // Invoked directly rather than through `zsh -c`, since a shell hosting one fallback is a shell we do not need.
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        ipProcess.arguments = ["getifaddr", "en0"]
        let ipRun = try? ProcessRunner.run(ipProcess)
        let ip = (ipRun?.succeeded == true)
            ? ipRun!.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // Wi-Fi SSID via `networksetup`, which withholds the SSID without Location Services, so "not associated" is not proof
        // of disconnection; cross-referencing the IP tells "cannot tell" apart from "not connected".
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

            // Accepts headers as an object or as a JSON string containing one, because models keep emitting the string form;
            // a failed decode must not silently send the request with no headers.
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
                // Declared "object": whatever this declares is what a model sends, so it must name a type the decoder accepts.
                ("headers", "object", "Custom request headers as name/value pairs, e.g. {\"Authorization\": \"Bearer …\"}")
            ],
            required: ["url"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // The scheme is what must be checked: modern Foundation parses almost anything (a bare `example.com` included),
        // so a nil-check alone lets mistakes fail late inside URLSession with nothing the model can act on.
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
            // `combinedOutput`, not `standardOutput`: `nslookup` reports a failed lookup on stderr, leaving stdout empty.
            let output = try ProcessRunner.run(process).combinedOutput
            return "DNS Lookup for '\(arguments.hostname)':\n\(output)"
        } catch {
            return "Error: DNS lookup failed — \(error.localizedDescription)"
        }
    }
}
