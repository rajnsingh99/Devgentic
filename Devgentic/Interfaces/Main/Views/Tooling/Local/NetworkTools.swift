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

        // Wi-Fi SSID via airport command
        let ssidProcess = Process()
        ssidProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        ssidProcess.arguments = ["-c", "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/ SSID/ {print substr($0, index($0, $2))}'"]
        // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe only
        // after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
        //
        // `try?`, matching the original: this tool reports SEVERAL facts and degrades one at a
        // time. `airport` was removed in recent macOS, so a launch failure here is expected —
        // it must cost the SSID line, not the whole network report.
        let ssid = (try? ProcessRunner.run(ssidProcess).standardOutput)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        info += "Wi-Fi SSID: \(ssid.isEmpty ? "Not connected" : ssid)\n"

        // IP address
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        ipProcess.arguments = ["-c", "ipconfig getifaddr en0 2>/dev/null || echo 'No IP'"]
        // Same graceful-degradation contract as the SSID probe above.
        let ip = (try? ProcessRunner.run(ipProcess).standardOutput)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        info += "Local IP: \(ip)\n"

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
            self.headers = (try? container.decodeIfPresent([String: String].self, forKey: DynamicKey(stringValue: "headers")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("url", "string", "The URL to request."),
                ("method", "string", "HTTP method: 'GET' or 'POST' (default 'GET')"),
                ("body", "string", "Request body for POST requests"),
                ("headers", "string", "JSON object of custom headers")
            ],
            required: ["url"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url) else {
            return "Error: Invalid URL '\(arguments.url)'."
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
            return "Request failed: \(error.localizedDescription)"
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
            return "DNS lookup failed: \(error.localizedDescription)"
        }
    }
}
