//
//  MCPIconLoader.swift
//  Devgentic
//
//  Created on 27/02/26.
//  MCP v0.11.0: Icon loading service with caching and SwiftUI view component.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "MCPIconLoader")

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

    private func downloadImage(from url: URL) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            return NSImage(data: data)
        } catch {
            logger.warning("Failed to download icon from \(url.absoluteString): \(error.localizedDescription)")
            return nil
        }
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
                    .font(.system(size: size * 0.6))
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
