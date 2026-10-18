// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CatalogModelSelectionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CatalogModelSelectionTests: XCTestCase {

    /// What the Qwen2.5-3B analyzer reports on device.
    private let qwen = CognitiveProfile(
        capability: .parallelActions, dialect: .qwenHermesToolCall,
        metadata: ModelMetadata(tier: .tiny, contextWindow: 32768, quantization: "4bit",
                                family: "mlx-community/qwen2.5-3b-instruct-4bit"),
        modalities: .textOnly, chatTemplateSource: .extracted("{{ template }}"),
        stopSequences: ["<|im_start|>", "<|im_end|>"])

    private func mlxItem(_ profile: CognitiveProfile?) -> CatalogModelItem {
        CatalogModelItem(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen", provider: .mlx,
                         vendorKey: "mlx", cognitiveCapability: profile?.capability ?? .none,
                         modelDialect: profile?.dialect ?? .nativeJSON, isInstalled: true, detectedProfile: profile)
    }

    /// Test1 as it was stored: the healer's placeholder and a default capability.
    private func staleTest1() -> ProviderConfig {
        ProviderConfig(apiProvider: .mlx, modelName: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                       cognitiveCapability: .singleAction, modelDialect: .qwenHermesToolCall,
                       modelMetadata: ModelMetadata(tier: .medium, contextWindow: 32768))
    }

    // MARK: - Local picks

    /// ⚠️ THE DEVICE CASE. Re-picking the same model must replace the placeholder metadata, the
    /// template source and the stop sequences — not just capability.
    func testALocalPickWritesEveryMeasurementTheAnalyzerMade() {
        let out = CatalogModelSelection.applying(mlxItem(qwen), to: staleTest1())
        XCTAssertEqual(out.modelMetadata, qwen.metadata, "the 3B model is stored as Tiny, with quantization and family")
        XCTAssertEqual(out.cognitiveCapability, .parallelActions)
        XCTAssertEqual(out.modelDialect, .qwenHermesToolCall)
        XCTAssertEqual(out.chatTemplateSource, qwen.chatTemplateSource)
        XCTAssertEqual(out.stopSequences, qwen.stopSequences)
        XCTAssertEqual(out.supportedModalities, qwen.modalities)
        XCTAssertEqual(out, LiveModelDetectionShape.resolved(staleTest1(), with: qwen),
                       "after a pick the stored copy equals what a run would detect — nothing left to differ")
    }

    /// Switching to a model the analyzer measured differently drops every value of the old one.
    func testNothingMeasuredOnThePreviousModelSurvives() {
        let llama = CognitiveProfile(capability: .singleAction, dialect: .llama3JsonSingle,
                                     metadata: nil, modalities: .textOnly, chatTemplateSource: .embedded)
        let out = CatalogModelSelection.applying(mlxItem(llama), to: CatalogModelSelection.applying(mlxItem(qwen), to: staleTest1()))
        XCTAssertNil(out.modelMetadata, "no metadata measured means none stored — not Qwen's")
        XCTAssertEqual(out.chatTemplateSource, .embedded)
        XCTAssertEqual(out.stopSequences, [])
        XCTAssertEqual(out.modelDialect, .llama3JsonSingle)
    }

    // MARK: - Cloud picks

    func testACloudPickCarriesNoLocalArtifacts() {
        let fromMLX = CatalogModelSelection.applying(mlxItem(qwen), to: staleTest1())
        let claude = CatalogModelItem(id: "claude-sonnet-5-5", displayName: "Sonnet", provider: .anthropic,
                                      vendorKey: "anthropic", contextWindow: 200_000,
                                      cognitiveCapability: .parallelActions, modelDialect: .nativeJSON)
        let out = CatalogModelSelection.applying(claude, to: fromMLX)
        XCTAssertEqual(out.modelMetadata, ModelMetadata(tier: .medium, contextWindow: 200_000),
                       "the window is the catalog's; the tier is the unmeasured default, never the old model's Tiny/4bit")
        XCTAssertEqual(out.chatTemplateSource, .embedded)
        XCTAssertEqual(out.stopSequences, [])

        let unknownWindow = CatalogModelItem(id: "x", displayName: "x", provider: .openAI, vendorKey: "openai")
        XCTAssertNil(CatalogModelSelection.applying(unknownWindow, to: fromMLX).modelMetadata)
    }

    // MARK: - Endpoint

    /// ⚠️ On device, Test1 (MLX) still stored Ollama's address after a re-pick: an MLX → MLX pick
    /// is no provider change, so nothing reset it.
    func testAnMLXPickClearsAnEndpointAnEarlierProviderLeft() {
        var stale = staleTest1()
        stale.baseURL = "http://localhost:11434"
        XCTAssertNil(CatalogModelSelection.applying(mlxItem(qwen), to: stale).baseURL)
        XCTAssertNil(CatalogModelSelection.applying(mlxItem(qwen), to: stale, savedEndpoint: "http://elsewhere").baseURL,
                     "an MLX model runs in-process — no endpoint applies")
    }

    func testOtherPicksKeepTheirEndpointPrecedence() {
        let ollama = CatalogModelItem(id: "llama3.1:8b", displayName: "llama", provider: .ollama, vendorKey: "ollama",
                                      baseURL: "http://gpu-box:11434", detectedProfile: qwen)
        var config = ProviderConfig(apiProvider: .ollama, modelName: "old", baseURL: "http://localhost:11434")
        XCTAssertEqual(CatalogModelSelection.applying(ollama, to: config).baseURL, "http://gpu-box:11434",
                       "the server the catalog listed the model from")
        XCTAssertEqual(CatalogModelSelection.applying(ollama, to: config, savedEndpoint: "http://saved:11434").baseURL,
                       "http://saved:11434", "the user's saved endpoint wins")

        config = ProviderConfig(apiProvider: .openAI, modelName: "gpt-5", baseURL: "https://proxy.example/v1")
        let gpt = CatalogModelItem(id: "gpt-5.1", displayName: "gpt", provider: .openAI, vendorKey: "openai")
        XCTAssertEqual(CatalogModelSelection.applying(gpt, to: config).baseURL, "https://proxy.example/v1",
                       "with nothing better known, a cloud pick keeps the current endpoint")
    }

    // MARK: - The detection log names what differs

    /// ⚠️ On device this logged "stored Parallel Actions … detected Parallel Actions" — two
    /// identical values presented as a difference, because only metadata differed.
    func testTheDetectionLogNamesTheFieldThatActuallyDiffers() {
        var stored = staleTest1()
        stored.cognitiveCapability = .parallelActions
        let detected = LiveModelDetectionShape.resolved(stored, with: qwen)
        let differences = LiveModelDetection.differingMeasurements(stored: stored, detected: detected)
        XCTAssertFalse(differences.contains { $0.hasPrefix("capability") })
        XCTAssertTrue(differences.contains { $0.hasPrefix("metadata Medium tier") && $0.contains("Tiny tier") }, "\(differences)")
        XCTAssertTrue(differences.contains { $0.hasPrefix("stop sequences 0 → 2") }, "\(differences)")
        XCTAssertEqual(LiveModelDetection.differingMeasurements(stored: detected, detected: detected), [])
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }

    /// The pure function is worth nothing unless the catalog calls it, gives it the analyzer
    /// result, and lets the model's values land AFTER the profile-type defaults.
    func testTheCatalogPickAppliesTheFullDetectionLast() throws {
        let window = try source("Devgentic/Interfaces/Main/Views/BackendProfile/ModelCatalog/ModelCatalogWindowView.swift")
        guard let body = window.range(of: "private func applyModel(").map({ String(window[$0.lowerBound...]) }) else {
            return XCTFail("applyModel not found")
        }
        let reset = try XCTUnwrap(body.range(of: "providerConfig.switchProvider(to: model.provider)"), "a provider change must reset first")
        let defaults = try XCTUnwrap(body.range(of: "onProviderChanged?(oldProvider, model.provider)"))
        let apply = try XCTUnwrap(body.range(of: "providerConfig = CatalogModelSelection.applying("))
        XCTAssertLessThan(reset.lowerBound, defaults.lowerBound)
        XCTAssertLessThan(defaults.lowerBound, apply.lowerBound,
                          "the profile-type default must not overwrite the capability measured for the picked model")
        XCTAssertNil(body.range(of: "providerConfig.cognitiveCapability = model."),
                     "the pick writes through CatalogModelSelection, not field by field")
        XCTAssertNil(body.range(of: "providerConfig.baseURL ="),
                     "the endpoint is chosen by CatalogModelSelection too — a write after it would undo MLX's clear")
        XCTAssertTrue(body.contains("savedEndpoint: endpointOverride ?? AppProviderKeyStore.loadEndpoint(forAccount: model.vendorKey)"),
                      "the user's saved endpoint still reaches the pick")

        let service = try source("Devgentic/Interfaces/Main/Views/BackendProfile/ModelCatalog/ModelCatalogService.swift")
        XCTAssertEqual(service.components(separatedBy: "detectedProfile: profile").count - 1, 2,
                       "both local lists (Ollama and MLX) hand the analyzer result to the catalog entry")
    }
}

/// What `LiveModelDetection.detectedFromCache` does to a stored config, without its caches.
private enum LiveModelDetectionShape {
    static func resolved(_ stored: ProviderConfig, with profile: CognitiveProfile) -> ProviderConfig {
        var out = stored
        out.cognitiveCapability = profile.capability
        out.modelDialect = profile.dialect
        if let metadata = profile.metadata { out.modelMetadata = metadata }
        out.chatTemplateSource = profile.chatTemplateSource
        out.stopSequences = profile.stopSequences
        out.supportedModalities = profile.modalities
        return out
    }
}
