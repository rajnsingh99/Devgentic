// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPHostBridge+App.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The app half of the MCP host bridge, separate from `MCPHostBridge.swift` so that file stays free of
/// SwiftData, `AgentConnect` and the InteractionCenter; this is the one place that names `MCPToolStore` and the brokers.
@MainActor
extension MCPHostBridge {

    /// Wires Devgentic's real implementations into the bridge.
    /// Called from `AppDelegate.applicationDidFinishLaunching`, before the launch connect sweep or any user action
    /// that could reach `MCPClientService.connect`; later, a connect could succeed with its tool list going nowhere.
    static func installAppImplementations() {
        install(
            toolListSink: MCPToolStore.shared,
            sourceStore: MCPToolStore.shared,
            samplingHandler: MCPSamplingBroker.shared,
            elicitationHandler: MCPElicitationBroker.shared
        )
    }
}
