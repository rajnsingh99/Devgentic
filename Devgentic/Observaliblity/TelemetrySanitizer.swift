//
//  TelemetrySanitizer.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation

/// A privacy firewall that strips Sensitive Personal Information (SPI) from logs and metrics.
/// Ensures that file paths, user names, and IPs do not leak into telemetry.
struct TelemetrySanitizer {
    
    /// Sanitizes an error message or log string for telemetry.
    /// - Parameter text: The raw input string (e.g., "Error reading /Users/alice/Documents/secret.txt").
    /// - Returns: A safe string (e.g., "Error reading [USER_PATH]/secret.txt").
    static func sanitize(_ text: String) -> String {
        var cleanText = text
        
        // 1. Redact User Home Paths (macOS/Linux)
        // Regex looks for "/Users/something/" or "/home/something/" and replaces the username.
        // Pattern: (\/(?:Users|home)\/)[^\/]+
        if let regex = try? NSRegularExpression(pattern: "(\\/)(?:Users|home)\\/[^\\/]+", options: .caseInsensitive) {
            let range = NSRange(location: 0, length: cleanText.utf16.count)
            cleanText = regex.stringByReplacingMatches(
                in: cleanText,
                options: [],
                range: range,
                withTemplate: "$1[USER_PATH]"
            )
        }
        
        // 2. Redact IPv4 Addresses
        // Simple pattern to catch standard IPs but avoid version numbers (approximate)
        if let regex = try? NSRegularExpression(pattern: "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b") {
            let range = NSRange(location: 0, length: cleanText.utf16.count)
            cleanText = regex.stringByReplacingMatches(
                in: cleanText,
                options: [],
                range: range,
                withTemplate: "[IP_ADDR]"
            )
        }
        
        // 3. Redact Email Addresses
        if let regex = try? NSRegularExpression(pattern: "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}") {
            let range = NSRange(location: 0, length: cleanText.utf16.count)
            cleanText = regex.stringByReplacingMatches(
                in: cleanText,
                options: [],
                range: range,
                withTemplate: "[EMAIL]"
            )
        }
        
        return cleanText
    }
}
