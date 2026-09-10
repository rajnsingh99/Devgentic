// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OllamaServerStatus.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI // For Color

/// Represents the connection status of the Ollama server.
enum OllamaServerStatus: String, CaseIterable {
    case unknown      // Initial state
    case checking     // Currently attempting to connect
    case connected    // Successfully connected
    case disconnected // Connection failed or server not found
    case error        // An error occurred during status check

    /// A user-friendly description of the status.
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking Status..."
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .error: return "Error Checking Status"
        }
    }

    /// System image name for the status icon.
    var systemImageName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Color associated with the status.
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .checking: return .blue
        case .connected: return .green
        case .disconnected: return .red
        case .error: return .orange
        }
    }
}
