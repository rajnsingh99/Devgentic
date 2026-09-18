// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPHostBridge+App.swift
//  Devgentic
//
//  Created 2026-08-02 — the app half of the MCP host bridge.
//
//  Kept in its own file, and deliberately NOT part of `MCPHarness`: this is the one place
//  that names `MCPToolStore` and the two brokers, and therefore the one place that drags in
//  SwiftData, `AgentConnect` and the InteractionCenter. `MCPHostBridge.swift` next door
//  stays free of all three, which is what lets the harness compile the real connect path.
//

import Foundation

@MainActor
extension MCPHostBridge {

    /// Wires Devgentic's real implementations into the bridge.
    ///
    /// Called from `AppDelegate.applicationDidFinishLaunching`, which runs before the
    /// SwiftUI scene's startup task (and therefore before the launch connect sweep) and
    /// before any user interaction that could reach `MCPClientService.connect`. Anything
    /// later would leave a window in which a connect succeeds but its tool list goes
    /// nowhere.
    static func installAppImplementations() {
        install(
            toolListSink: MCPToolStore.shared,
            sourceStore: MCPToolStore.shared,
            samplingHandler: MCPSamplingBroker.shared,
            elicitationHandler: MCPElicitationBroker.shared
        )
    }
}
