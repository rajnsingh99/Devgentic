// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ⚠️ WIRING for phase 3. The unloads below were each deleted because they acted without knowing who
//  needed the model; a later edit that puts one back fails no unit test. Source-scanned over joined,
//  comment-stripped bodies, in the `LocalInferenceWiringTests` idiom.
//

import XCTest

final class LocalResidencyWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Devgentic").path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        return try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// U1 / D10 — looking at a conversation is not a request.
    func testAConversationSwitchUnloadsNothing() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationSwitchCoordinator.swift")
        XCTAssertFalse(code.contains("MLXService.shared.unloadModel"))
        XCTAssertFalse(code.contains("ollamaService.unloadModel"))
        XCTAssertFalse(code.contains("shouldUnloadModels"))
    }

    /// U2 / G2 — a cloud request never unloads a local model.
    func testACloudRequestUnloadsNothing() throws {
        XCTAssertFalse(try source("Devgentic/Core/Backends/BackendOrchestrationService.swift").contains("MLXService.shared.unloadModel"))
    }

    /// U3 — a classifier does not unload the model the next node may be about to use.
    func testTheClassifierUnloadsNothing() throws {
        XCTAssertFalse(try source("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift").contains("MLXService.shared.unloadModel"))
    }

    /// U10 / U11 — Ollama models are unloaded by name, only the ones this app used, never the server's
    /// whole working set.
    func testOllamaIsNeverUnloadedWholesale() throws {
        let ollama = try source("Devgentic/Core/Service/OllamaService.swift")
        XCTAssertFalse(ollama.contains("func unloadModel()"), "the unload-everything function must stay deleted")
        let app = try source("Devgentic/AppDelegate.swift")
        XCTAssertTrue(app.contains("await LocalInferenceCoordinator.shared.unloadOllamaModelsWeUsed()"))
        XCTAssertFalse(app.contains("OllamaService.shared.unloadModel"))
    }

    /// U8 — one owner of the process-wide MLX buffer cache: the policy sets its cap and is the only
    /// code that clears it.
    func testTheMLXBufferCacheHasOneOwner() throws {
        let mlx = try source("Devgentic/Core/Service/MLXService.swift")
        XCTAssertNotNil(mlx.range(of: #"private init\(\) \{\s*MLXMemoryPolicy\.configure\(\)"#, options: .regularExpression))
        for path in ["Devgentic/Core/Service/MLXService.swift", "Devgentic/Core/Service/IntelligenceCoreService.swift"] {
            let code = try source(path)
            XCTAssertFalse(code.contains("MLX.Memory.clearCache()") || code.contains("MLX.GPU.clearCache()"),
                           "\(path) clears the process-wide cache directly")
        }
    }

    /// U12 — a model a registered run expects is not deleted from disk.
    func testModelDeletionConsultsTheCoordinator() throws {
        let code = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift")
        XCTAssertNotNil(code.range(of: #"func deleteModel\([\s\S]{0,1600}?\n\s*if LocalInferenceCoordinator\.shared\.modelsInUse\(on: \.mlx\)\s*\.contains\(where: \{ MLXModelIdentity\.matches\(installed: item\.displayName, candidate: \$0\) \}\) \{[\s\S]{0,500}?return false[\s\S]{0,800}?try FileManager\.default\.removeItem"#,
                                   options: .regularExpression),
                        "deleteModel must refuse — on exactly that condition, nothing ANDed into it — before removing files")
    }

    /// D7 — background Core Intelligence features wait for the local model like runs.
    func testBackgroundIntelligenceFeaturesQueue() throws {
        for (path, feature) in [("Devgentic/Intelligence/MorningBrief/MorningBriefService.swift", "Morning Brief"),
                                ("Devgentic/Intelligence/UserPersonal/UserPersonalService.swift", "User Personal")] {
            let code = try source(path)
            let pattern = #"runBackgroundIntelligence\(feature: ""# + feature + #""\) \{\s*try await IntelligenceCoreService\.shared\.generate\("#
            XCTAssertNotNil(code.range(of: pattern, options: .regularExpression), "\(feature) must generate inside runBackgroundIntelligence")
        }
    }

    /// The MLX buffer-cache cap is set by whichever MLX container starts first — a session that only
    /// runs Core Intelligence never starts `MLXService`.
    func testBothMLXContainersApplyTheCacheCap() throws {
        for path in ["Devgentic/Core/Service/MLXService.swift", "Devgentic/Core/Service/IntelligenceCoreService.swift"] {
            let code = try source(path)
            XCTAssertNotNil(code.range(of: #"private init\(\) \{\s*MLXMemoryPolicy\.configure\(\)"#, options: .regularExpression),
                            "\(path) must configure the MLX cache cap in its init")
        }
    }

    /// The residency unload says "Unloading" only when it will: while a generation is in flight it
    /// defers to `unloadModel()`, which logs the refusal.
    func testTheResidencyUnloadChecksInFlightBeforeClaimingAnUnload() throws {
        let code = try source("Devgentic/Core/Service/MLXService.swift")
        XCTAssertNotNil(code.range(of: #"func unloadModel\(unlessResidentIn keep: \[URL\], reason: String\) -> Bool \{[\s\S]{0,900}?guard activeGenerations == 0 else \{ return !unloadModel\(\)\.isEmpty \}\s*logger\.notice\("\[MLX-LOAD\] Unloading"#,
                                   options: .regularExpression))
    }

    /// A switch no longer unloads anything (D10), so the refusal to delete a loaded MLX model must not
    /// tell the user to switch models — it says when the model unloads.
    func testTheLoadedModelDeleteRefusalDoesNotAdviseASwitch() throws {
        let code = try source("Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelService.swift")
        XCTAssertFalse(code.contains("Switch to another model before deleting it"))
        XCTAssertTrue(code.contains("is still loaded in memory. It unloads by itself 2 minutes after its last use"))
    }

    /// The Ollama context window reaches the ledger at every gate, so a reload is visible.
    func testOllamaGatesCarryTheContextWindow() throws {
        let code = try source("Devgentic/Core/Backends/OllamaLLMProvider.swift")
        XCTAssertEqual(code.components(separatedBy: "contextTokens: requestedContext)").count - 1, 2, "both counted gates")
        XCTAssertNotNil(code.range(of: #"LocalInferenceScope\.beginGeneration\(engine: engine, modelID: model,\s*contextTokens: context\)"#,
                                   options: .regularExpression), "the stream's gate carries the context window too")
    }
}
