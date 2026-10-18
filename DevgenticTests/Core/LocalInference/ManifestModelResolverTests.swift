// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ManifestModelResolverTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ManifestModelResolverTests: XCTestCase {

    private func resolve(_ profile: BackendProfileModel,
                         layouts: [UUID: WorkflowLayout] = [:],
                         profiles: [BackendProfileModel] = [],
                         estimate: (ProviderConfig) -> UInt64? = { _ in nil }) -> ManifestModelResolver.Result {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return ManifestModelResolver.models(
            for: profile,
            layout: { layouts[$0] },
            profiles: { ids in ids.compactMap { byID[$0] } },
            estimate: estimate)
    }

    // MARK: Single-model profiles

    func testAnMLXBotDeclaresOneLocalModel() {
        let result = resolve(LIFixtures.bot(.mlx, "qwen"))
        XCTAssertEqual(result.models, [ModelRequirement(engine: .mlx, modelID: "qwen", role: .primary)])
        XCTAssertEqual(result.unresolvedNodes, 0)
    }

    func testACloudBotDeclaresNoLocalModel() {
        let result = resolve(LIFixtures.bot(.anthropic, "claude"))
        XCTAssertEqual(result.models.map(\.engine), [.cloud(.anthropic)])
        XCTAssertFalse(result.models.contains { $0.engine.isLocal })
    }

    /// LM Studio behind the OpenAI-compatible provider is a server the app does not manage.
    func testAnOpenAICompatibleEndpointIsCloudEvenOnLocalhost() {
        let result = resolve(LIFixtures.bot(.openAICompatible, "local", baseURL: "http://localhost:1234"))
        XCTAssertEqual(result.models.map(\.engine), [.cloud(.openAICompatible)])
    }

    func testOllamaServerSpellingsNormaliseToOneEngine() {
        let a = resolve(LIFixtures.bot(.ollama, "llama3")).models.first?.engine
        let b = resolve(LIFixtures.bot(.ollama, "llama3", baseURL: "http://localhost:11434/")).models.first?.engine
        let c = resolve(LIFixtures.bot(.ollama, "llama3", baseURL: "  ")).models.first?.engine
        XCTAssertEqual(a, .ollama(baseURL: "http://localhost:11434"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    // MARK: Workflow walk

    func testAWorkflowDeclaresEveryNodeModelOnceAndItsClassifier() {
        let wf = LIFixtures.workflow()
        let local = LIFixtures.bot(.mlx, "qwen")
        let sameModel = LIFixtures.bot(.mlx, " qwen ")
        let cloud = LIFixtures.bot(.openAI, "gpt")
        let layout = LIFixtures.layout([LIFixtures.node(local), LIFixtures.node(sameModel), LIFixtures.node(cloud),
                                        LIFixtures.classifier(model: "tiny")])
        let result = resolve(wf, layouts: [wf.id: layout], profiles: [local, sameModel, cloud])

        XCTAssertEqual(result.models.map(\.residencyKey), ["mlx/qwen", "cloud(openai)/gpt", "mlx/tiny"],
                       "one model under two spellings is ONE model; the Router's classifier is declared")
        XCTAssertEqual(result.models.last?.role, .classifier)
        XCTAssertEqual(result.nodeCount, 4)
    }

    func testADisabledClassifierIsNotDeclared() {
        let wf = LIFixtures.workflow()
        let result = resolve(wf, layouts: [wf.id: LIFixtures.layout([LIFixtures.classifier(model: "tiny", enabled: false),
                                                                       LIFixtures.classifier(model: nil)])])
        XCTAssertTrue(result.models.isEmpty)
    }

    func testANestedWorkflowIsWalkedToItsLeaves() {
        let outer = LIFixtures.workflow()
        let inner = LIFixtures.workflow()
        let leaf = LIFixtures.bot(.ollama, "llama3")
        let result = resolve(outer,
                             layouts: [outer.id: LIFixtures.layout([LIFixtures.node(inner)]),
                                       inner.id: LIFixtures.layout([LIFixtures.node(leaf)])],
                             profiles: [inner, leaf])
        XCTAssertEqual(result.models.map(\.modelID), ["llama3"])
        XCTAssertEqual(result.models.first?.role, .workflowNode)
        XCTAssertEqual(result.unresolvedNodes, 0)
    }

    /// ⚠️ A cloud-only-looking workflow with a node the walk could not resolve must still take the
    /// lock: the guess that it is cloud is the one that lets two local runs collide.
    func testAMissingNodeProfileIsUnresolvedNotIgnored() {
        let wf = LIFixtures.workflow()
        let ghost = LIFixtures.bot(.mlx, "gone")
        let cloud = LIFixtures.bot(.anthropic, "claude")
        let result = resolve(wf, layouts: [wf.id: LIFixtures.layout([LIFixtures.node(ghost), LIFixtures.node(cloud)])],
                             profiles: [cloud])
        XCTAssertEqual(result.unresolvedNodes, 1)
        XCTAssertEqual(result.models.map(\.modelID), ["claude"])
    }

    func testAnUnreadableLayoutIsUnresolved() {
        let wf = LIFixtures.workflow()
        XCTAssertEqual(resolve(wf, layouts: [:]).unresolvedNodes, 1)
    }

    func testAWorkflowThatContainsItselfTerminates() {
        let wf = LIFixtures.workflow()
        let result = resolve(wf, layouts: [wf.id: LIFixtures.layout([LIFixtures.node(wf)])], profiles: [wf])
        XCTAssertEqual(result.unresolvedNodes, 1, "the second visit is counted, not walked")
    }

    // MARK: Footprints

    func testFootprintsAreAskedOnlyForLocalModelsAndTheLargestWins() {
        let wf = LIFixtures.workflow()
        let small = LIFixtures.bot(.mlx, "qwen")
        var big = LIFixtures.bot(.mlx, "qwen")
        if case .bot(var c) = big.details { c.llmConfig.apiKey = "marker"; big.details = .bot(c) }
        let cloud = LIFixtures.bot(.anthropic, "claude")
        var asked: [String] = []
        let result = resolve(wf, layouts: [wf.id: LIFixtures.layout([LIFixtures.node(small), LIFixtures.node(big), LIFixtures.node(cloud)])],
                             profiles: [small, big, cloud],
                             estimate: { config in
                                 asked.append(config.modelName)
                                 return config.apiKey == "marker" ? 9 : 4
                             })
        XCTAssertEqual(asked, ["qwen", "qwen"], "a cloud model's footprint is never estimated")
        XCTAssertEqual(result.footprints, ["mlx/qwen": 9])
    }

    // MARK: Origin

    func testOriginDerivation() {
        XCTAssertEqual(RunOrigin.derive(source: .localUI, profileType: .agent, isRegeneration: false, isResume: false), .composer)
        XCTAssertEqual(RunOrigin.derive(source: .localUI, profileType: .code, isRegeneration: false, isResume: false), .code)
        XCTAssertEqual(RunOrigin.derive(source: .localUI, profileType: .workflow, isRegeneration: false, isResume: false), .workflow)
        XCTAssertEqual(RunOrigin.derive(source: .slack, profileType: .bot, isRegeneration: false, isResume: false), .chatOps(.slack))
        XCTAssertEqual(RunOrigin.derive(source: .scheduled, profileType: .workflow, isRegeneration: false, isResume: false), .scheduled)
        XCTAssertEqual(RunOrigin.derive(source: .backgroundTask, profileType: .code, isRegeneration: false, isResume: false), .backgroundTask)
        XCTAssertEqual(RunOrigin.derive(source: .orb, profileType: .agent, isRegeneration: false, isResume: false), .orb)
        XCTAssertEqual(RunOrigin.derive(source: .quickAccess, profileType: .bot, isRegeneration: false, isResume: false), .quickAccess)
        // A button the user just pressed wins over the surface that first asked.
        XCTAssertEqual(RunOrigin.derive(source: .telegram, profileType: .bot, isRegeneration: true, isResume: false), .regenerate)
        XCTAssertEqual(RunOrigin.derive(source: .scheduled, profileType: .bot, isRegeneration: true, isResume: true), .resume)
    }
}

/// A local model's footprint comes from measurements only — never from a tier label.
final class ManifestFootprintTests: XCTestCase {

    private func config(_ metadata: ModelMetadata?) -> ProviderConfig {
        var c = ProviderConfig(apiProvider: .mlx, modelName: "mlx-community/Qwen2.5-3B-Instruct-4bit")
        c.modelMetadata = metadata
        return c
    }

    /// ⚠️ The device regression: tier "medium", no parameter count → the advisor's flat 20 GB guess,
    /// which refused a 1.75 GB model. With nothing measured, the footprint is UNKNOWN.
    func testATierLabelAloneIsNotAFootprint() {
        XCTAssertNil(InferenceRunManifest.footprint(of: config(ModelMetadata(tier: .medium)), onDiskBytes: nil))
        XCTAssertNil(InferenceRunManifest.footprint(of: config(nil), onDiskBytes: nil))
    }

    /// The size on disk wins over any label — the same input the MLX loader's own estimate uses.
    func testTheSizeOnDiskWins() {
        let onDisk: Int64 = 1_750_000_000
        let bytes = InferenceRunManifest.footprint(of: config(ModelMetadata(tier: .medium)), onDiskBytes: onDisk)
        XCTAssertEqual(bytes, ModelFitAdvisor.estimateRuntimeRAM(metadata: nil, diskSizeBytes: onDisk))
        XCTAssertLessThan(bytes ?? .max, 3 << 30, "a 1.75 GB model is estimated near 2 GB, not 20")
    }

    func testAParameterCountIsAMeasurement() {
        let metadata = ModelMetadata(tier: .medium, quantization: "4bit", parameterCount: "3B")
        let bytes = InferenceRunManifest.footprint(of: config(metadata), onDiskBytes: nil)
        XCTAssertEqual(bytes, ModelFitAdvisor.estimateRuntimeRAM(metadata: metadata))
        XCTAssertLessThan(bytes ?? .max, 3 << 30)
    }
}

/// ⚠️ WIRING — the live estimate must pass the measured on-disk size.
final class ManifestFootprintWiringTests: XCTestCase {
    func testTheLiveManifestUsesTheMeasuredSize() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let code = try? String(contentsOf: repoRoot.appendingPathComponent("Devgentic/Core/LocalInference/LocalInferenceCoordinator.swift"), encoding: .utf8) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        XCTAssertNotNil(code.range(of: #"estimate: \{ config in[\s\S]{0,300}?MLXModelService\.shared\.installedSizeBytes\[\$0\.displayName\][\s\S]{0,120}?return InferenceRunManifest\.footprint\(of: config, onDiskBytes: installed\)"#,
                                   options: .regularExpression))
        let closure = code.components(separatedBy: "estimate: { config in")[1].components(separatedBy: "\n            }")[0]
        XCTAssertFalse(closure.contains("estimateRuntimeRAM"),
                       "the tier-falling-back estimator must not be the manifest's estimate: \(closure)")
    }
}
