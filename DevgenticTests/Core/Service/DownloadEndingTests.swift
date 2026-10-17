// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadEndingTests.swift
//  DevgenticTests
//
//  The CR-35 follow-up (2026-10-13): MLX and Whisper download history is classified from the
//  service's own recorded ending (`lastDownloadEnding`), never from `progress >= 0.99`.
//
//  What the percentage actually decided: a download that SUCCEEDED but that the installed scan
//  does not list was recorded as CANCELLED. Cancel and pause only read correctly because every
//  one of those paths happens to reset progress to 0 first.
//

import XCTest
@testable import devgentic

@MainActor
final class DownloadEndingTests: XCTestCase {

    private func classify(_ ending: DownloadEnding?, for model: String = "m", recordedFor: String? = nil,
                          error: String? = nil, installed: Bool = false, paused: Bool = false) -> DownloadTerminalClassification {
        DownloadManager.classifyEndedDownload(
            backend: .mlx, modelIdentifier: model,
            ending: ending.map { RecordedDownloadEnding(modelID: recordedFor ?? model, ending: $0) },
            errorMessage: error, isInstalledNow: installed, isPausedNow: paused)
    }

    // MARK: - The classifier

    /// THE defect: a real success the scanner does not list.
    func testASuccessTheScannerDoesNotListIsStillCompleted() {
        XCTAssertEqual(classify(.succeeded, installed: false), .completed)
        XCTAssertEqual(classify(.succeeded, installed: true), .completed)
    }

    func testTheServicesEndingDecides() {
        XCTAssertEqual(classify(.cancelled, installed: false), .cancelled)
        XCTAssertEqual(classify(.paused), .paused)
        XCTAssertEqual(classify(.failed, error: "disk full"), .failed)
        XCTAssertEqual(classify(.cancelled, installed: true), .cancelled,
                       "a cancel of a re-download over an existing install is still a cancel")
    }

    /// An ending recorded for ANOTHER model never applies to this record.
    func testAnotherModelsEndingIsIgnored() {
        XCTAssertEqual(classify(.succeeded, for: "a", recordedFor: "b", installed: false), .cancelled)
        XCTAssertEqual(classify(.cancelled, for: "a", recordedFor: "b", installed: true), .completed)
    }

    /// No recorded ending (an older path): error, pause marker, installed list — never a percentage.
    func testWithoutAnEndingOnlyFactsDecide() {
        XCTAssertEqual(classify(nil, error: "boom"), .failed)
        XCTAssertEqual(classify(nil, installed: true), .completed)
        XCTAssertEqual(classify(nil, paused: true), .paused)
        XCTAssertEqual(classify(nil), .cancelled)
    }

    // MARK: - The MLX service records its ending (real terminal paths)

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-ending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func inFlight(_ repoId: String) -> (MLXModelService, Task<Void, Never>) {
        let service = MLXModelService(modelsRootOverride: root)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        service.downloadTask = task
        service.isDownloading = true
        service.currentDownloadName = repoId
        return (service, task)
    }

    func testMLXRecordsEachEnding_BeforeItStopsDownloading() {
        let repo = "mlx-community/ending-test"

        var (service, task) = inFlight(repo)
        service.finishTerminal(repoId: repo, generation: service.downloadGeneration, classification: "completed")
        XCTAssertEqual(service.lastDownloadEnding, RecordedDownloadEnding(modelID: repo, ending: .succeeded))
        task.cancel()

        (service, task) = inFlight(repo)
        service.finishTerminal(repoId: repo, generation: service.downloadGeneration, classification: "failed")
        XCTAssertEqual(service.lastDownloadEnding?.ending, .failed)
        task.cancel()

        (service, task) = inFlight(repo)
        service.finishCancelled(repoId: repo, generation: service.downloadGeneration, reason: "user")
        XCTAssertEqual(service.lastDownloadEnding?.ending, .cancelled)
        task.cancel()

        (service, task) = inFlight(repo)
        XCTAssertTrue(service.pauseDownload())
        XCTAssertEqual(service.lastDownloadEnding, RecordedDownloadEnding(modelID: repo, ending: .paused))
        task.cancel()
    }

    /// A SUPERSEDED download's late unwind must not overwrite the current one's ending.
    func testASupersededUnwindRecordsNothing() {
        let repo = "mlx-community/ending-test"
        let (service, task) = inFlight(repo)
        defer { task.cancel() }
        let stale = service.downloadGeneration
        service.downloadGeneration &+= 1

        service.finishCancelled(repoId: repo, generation: stale, reason: "late unwind")

        XCTAssertNil(service.lastDownloadEnding)
    }

    // MARK: - Source pins: both bridges and the Whisper service

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("source not found: \(relativePath)")
        return ""
    }

    /// Mutation that must turn this red: put `progress >= 0.99` back in either bridge.
    func testBothBridgesClassifyFromTheServicesEnding() throws {
        let source = try Self.read("Devgentic/Core/Service/DownloadManager.swift")
        for (fn, next, service) in [("private func reconcileMLX(", "// MARK: - Whisper bridge", "MLXModelService"),
                                    ("private func reconcileWhisper(", "\n}\n", "WhisperModelDownloadService")] {
            let start = try XCTUnwrap(source.range(of: fn))
            let end = try XCTUnwrap(source.range(of: next, range: start.upperBound..<source.endIndex))
            let body = source[start.lowerBound..<end.lowerBound]
            XCTAssertFalse(body.contains("progress >="), "\(fn) decides by percentage again")
            XCTAssertTrue(body.contains("ending: \(service).shared.lastDownloadEnding"), "\(fn) must pass the service's ending")
        }
    }

    /// Whisper's service has a private init and drives a real WhisperKit download, so its terminal
    /// paths are pinned in source: success, failure and both cancel shapes each record an ending.
    func testWhisperRecordsAnEndingOnEveryTerminalPath() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/Speech/WhisperModelDownloadService.swift")
        XCTAssertTrue(source.contains("RecordedDownloadEnding(modelID: modelId, ending: .succeeded)"))
        XCTAssertTrue(source.contains("RecordedDownloadEnding(modelID: modelId, ending: .failed)"))
        XCTAssertEqual(source.components(separatedBy: "RecordedDownloadEnding(modelID: modelId, ending: .cancelled)").count - 1, 2,
                       "both cancellation exits of the download task")
        XCTAssertTrue(source.contains("RecordedDownloadEnding(modelID: id, ending: .cancelled)"), "and cancelDownload()")
        let success = try XCTUnwrap(source.range(of: "ending: .succeeded)"))
        let reset = try XCTUnwrap(source.range(of: "self.resetDownloadState()", range: success.upperBound..<source.endIndex))
        XCTAssertLessThan(source.distance(from: success.upperBound, to: reset.lowerBound), 80,
                          "the ending is recorded BEFORE isDownloading flips off")
    }
}
