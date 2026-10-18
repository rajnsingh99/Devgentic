// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeliveryWarningTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class DeliveryWarningTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeliveryWarning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func file(_ name: String, chars: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(String(repeating: "x", count: chars).utf8).write(to: url)
        return url
    }

    private func candidate(_ url: URL) -> DeliveryWarnings.Candidate {
        .init(name: url.lastPathComponent, path: url.path, url: url)
    }

    private let big = DirectInjectionBudget.perFile + 70_000

    // MARK: - What the warnings say

    func testOnlyFilesThatLoseContentAreWarned() async throws {
        let small = try file("Small.java", chars: 100)
        let cut = try file("Big.java", chars: big)
        let unread = try file("Giant.log", chars: DirectInjectionBudget.readCap + 1)

        let outcomes = await DeliveryWarnings.outcomes(
            for: [small, cut, unread].map(candidate), lane: .attachment(includeAbsolutePaths: false),
            reader: FileProcessorService())
        let warnings = DeliveryWarnings.warnings(for: outcomes, lane: .attachment(includeAbsolutePaths: false), remedy: .split)

        XCTAssertEqual(warnings.map(\.fileName), ["Big.java", "Giant.log"], "a file sent whole is not warned")
        XCTAssertTrue(warnings[0].problem.contains(DirectInjectionBudget.perFile.formatted()))
        XCTAssertTrue(warnings[0].reason.contains("limited to"), "per-file limit is the reason")
        XCTAssertTrue(warnings[1].reason.contains("too large to read"))
        XCTAssertTrue(warnings.allSatisfy { $0.suggestion.contains("split") })
    }

    func testTheSuggestionIsTheRemedyThatExistsForTheProfile() {
        XCTAssertEqual(DeliveryWarnings.Remedy.forProfileType(.agent), .readOnDemand)
        XCTAssertEqual(DeliveryWarnings.Remedy.forProfileType(.bot), .split)
        XCTAssertEqual(DeliveryWarnings.Remedy.forProfileType(.workflow), .split)
        XCTAssertTrue(DeliveryWarnings.suggestion(remedy: .readOnDemand, lane: .attachment(includeAbsolutePaths: true)).contains("read_file"))
    }

    // MARK: - Agreement with the send

    /// The preview, the transcript's delivery record and the backend's assembled text all agree.
    func testAttachmentPreviewMatchesWhatTheSendDoes() async throws {
        let urls = try [file("A.java", chars: 30_000), file("B.java", chars: big), file("C.java", chars: 60_000),
                        file("D.java", chars: 60_000), file("E.java", chars: 40_000)]
        let items = urls.map { FileSystemItem(id: $0, name: $0.lastPathComponent, url: $0, isDirectory: false) }

        let preview = await DeliveryWarnings.outcomes(for: urls.map(candidate), lane: .attachment(includeAbsolutePaths: true),
                                                      reader: FileProcessorService())
        let transcript = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
            .build(from: items, deliveryMode: .inject(includeAbsolutePaths: true))
        let backend = await BackendOrchestrationService(fileProcessorService: FileProcessorService())
            .assembleTextFileContent(for: items, includeAbsolutePaths: true)

        XCTAssertEqual(preview.map(\.1), transcript.textFiles.map { .planned($0.delivery!) })
        let omitted = preview.filter { if case .planned(.omitted) = $0.1 { return true }; return false }.map(\.0.path)
        XCTAssertEqual(omitted, backend.failures.map(\.path), "every file previewed as not sent is one the backend reports")
    }

    /// Knowledge sources are now CUT like attachments — the backend's text carries the marker,
    /// and the editor's preview says so for the same source.
    func testKnowledgeIsCutAndThePreviewSaysSo() async throws {
        let url = try file("handbook.md", chars: big)
        let source = KnowledgeSource(type: .file, location: url.path)

        let backend = await BackendOrchestrationService(fileProcessorService: FileProcessorService())
            .assembleKnowledgeSourceContent(sources: [source])
        let preview = await DeliveryWarnings.outcomes(for: [candidate(url)], lane: .knowledge, reader: FileProcessorService())

        XCTAssertTrue(backend.failures.isEmpty, "a cut source is delivered, not a failure")
        XCTAssertTrue(backend.content.contains("--- Knowledge: handbook.md ---"))
        XCTAssertTrue(backend.content.contains("[Truncated: only the first \(DirectInjectionBudget.perFile) of \(big)"))
        XCTAssertEqual(preview.map(\.1), [.planned(.truncated(sentChars: DirectInjectionBudget.perFile, totalChars: big))])
    }

    // MARK: - Composer wiring (view model)

    func testTheComposerWarnsOnlyForAnInjectingProfile() async throws {
        let url = try file("Big.java", chars: big)
        let delegate = MockChatInputMainDelegate()
        delegate.attachedFiles = [FileSystemItem(id: url, name: "Big.java", url: url, isDirectory: false)]
        let sut = ChatInputViewModel(recognitionService: MockRecognitionService(),
                                     promptService: MockPromptService())
        sut.mainDelegate = delegate
        sut.setupMainDelegateObservers()

        sut.refreshDeliveryWarnings(mode: .inject(includeAbsolutePaths: false), profileType: .bot)
        let deadline = ContinuousClock.now + .seconds(3)
        while sut.deliveryWarnings.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(sut.deliveryWarnings.map(\.fileName), ["Big.java"])

        sut.refreshDeliveryWarnings(mode: .pathManifest, profileType: .agent)
        XCTAssertTrue(sut.deliveryWarnings.isEmpty, "an agent reading on demand loses nothing")
    }
}
