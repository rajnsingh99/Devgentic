// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPIconLoader.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os.log

private let logger = DGLogger(category: "MCPIconLoader")

/// Loads and caches MCP tool icons from URLs or base64 data URIs.
@Observable @MainActor
final class MCPIconLoader {
    static let shared = MCPIconLoader()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    /// Resolves the best icon from an array based on the current color scheme.
    func bestIcon(from icons: [ToolIcon]?, for colorScheme: ColorScheme) -> ToolIcon? {
        guard let icons = icons, !icons.isEmpty else { return nil }

        let targetTheme: ToolIcon.ToolIconTheme = colorScheme == .dark ? .dark : .light

        // Prefer theme-matched, then unthemed, then any
        return icons.first(where: { $0.theme == targetTheme })
            ?? icons.first(where: { $0.theme == nil })
            ?? icons.first
    }

    /// Loads an NSImage from a ToolIcon, using cache when available.
    func loadImage(for icon: ToolIcon) async -> NSImage? {
        let cacheKey = NSString(string: icon.src)

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let image: NSImage?

        if icon.src.hasPrefix("data:") {
            image = decodeDataURI(icon.src)
        } else if let url = URL(string: icon.src) {
            image = await downloadImage(from: url)
        } else {
            image = nil
        }

        if let image = image {
            cache.setObject(image, forKey: cacheKey)
        }

        return image
    }

    // MARK: - Private

    private func decodeDataURI(_ dataURI: String) -> NSImage? {
        guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
        let base64String = String(dataURI[dataURI.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return NSImage(data: data)
    }

    /// Largest icon we will hold in memory. Icons are small; anything past this is either
    /// a mistake or a decompression bomb aimed at a process that decodes it on the MainActor.
    private static let maxIconBytes = 2 * 1024 * 1024

    /// Fetches a server-supplied icon URL.
    /// The URL comes from a third-party MCP server and the request leaves the user's machine, so it is constrained
    /// (permitted-URL check, bounded response) rather than trusted.
    private func downloadImage(from url: URL) async -> NSImage? {
        guard Self.isPermittedIconURL(url) else {
            logger.warning("""
                [MCP-ICON] Refused to fetch icon from '\(MCPRedaction.redact(url: url.absoluteString))' \
                — only https to a public host is allowed. The tool falls back to its \
                SF Symbol; no request was made.
                """)
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Icons are public decoration — never attach cookies or credentials to a URL a
        // third party chose.
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await Self.iconSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            guard data.count <= Self.maxIconBytes else {
                logger.warning("""
                    [MCP-ICON] Icon at '\(MCPRedaction.redact(url: url.absoluteString))' is \
                    \(data.count) bytes, over the \(Self.maxIconBytes)-byte cap — discarded \
                    undecoded. The tool falls back to its SF Symbol.
                    """)
                return nil
            }
            return NSImage(data: data)
        } catch {
            logger.warning("[MCP-ICON] Failed to download icon: \(error.localizedDescription)")
            return nil
        }
    }

    /// Session that refuses redirects, so an allowed URL cannot bounce to a denied one.
    /// Validating only the initial URL would leave the whole check bypassable with a 302.
    private static let iconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration, delegate: IconRedirectBlocker(), delegateQueue: nil)
    }()

    /// HTTPS to a public host, and nothing else; loopback is not exempted, so icon URLs cannot probe local services.
    /// Hostnames that resolve into private space are not caught; only direct literals are blocked.
    /// `nonisolated`: a pure predicate with no actor state.
    nonisolated static func isPermittedIconURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        guard scheme == "https" else { return false }
        if host == "localhost" || host == "::1" { return false }
        return !isPrivateOrLinkLocalIPv4(host)
    }

    nonisolated private static func isPrivateOrLinkLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _):                       return true   // 10.0.0.0/8
        case (192, 168):                    return true   // 192.168.0.0/16
        case (169, 254):                    return true   // link-local, incl. cloud metadata
        case (172, 16...31):                return true   // 172.16.0.0/12
        case (127, _):                      return true   // loopback via literal
        case (0, _):                        return true   // "this network"
        default:                            return false
        }
    }
}

/// Blocks HTTP redirects for icon fetches. Without this, a permitted https URL could 302
/// into `http://169.254.169.254/…` and the allowlist would never see it.
private final class IconRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - SwiftUI View Component

/// Asynchronously loads and displays a ToolIcon with SF Symbol fallback.
struct MCPIconView: View {
    let icons: [ToolIcon]?
    let fallbackSymbol: String
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage? = nil

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.6)) // Fixed size: proportional to caller-specified frame
                    .frame(width: size, height: size)
            }
        }
        .task(id: iconTaskId) {
            guard let bestIcon = MCPIconLoader.shared.bestIcon(from: icons, for: colorScheme) else {
                loadedImage = nil
                return
            }
            loadedImage = await MCPIconLoader.shared.loadImage(for: bestIcon)
        }
    }

    /// A stable identifier for the .task modifier to re-trigger on icon or theme changes.
    private var iconTaskId: String {
        let iconSrc = icons?.first?.src ?? "none"
        return "\(iconSrc)-\(colorScheme == .dark ? "dark" : "light")"
    }
}
