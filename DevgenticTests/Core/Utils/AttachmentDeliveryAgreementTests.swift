// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentDeliveryAgreementTests.swift
//  DevgenticTests
//
//  The transcript stored up to 500K chars of an attachment while the model, past the 50K
//  per-file budget, received NOTHING of a text file (the reader threw `.tooLarge`) and only
//  the first 50K of a document. Now the backend cuts both to the budget and the transcript
//  records exactly that, from the same `DirectInjectionPlan`. These drive the REAL backend
//  assembler and the REAL transcript builder over the same files and require them to agree.
//

import XCTest
@testable import devgentic

@MainActor
final class AttachmentDeliveryAgreementTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeliveryAgreement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func file(_ name: String, chars: Int) throws -> FileSystemItem {
        let url = dir.appendingPathComponent(name)
        try Data(String(repeating: "x", count: chars).utf8).write(to: url)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    private let big = DirectInjectionBudget.perFile + 70_000   // 120K — the reported case

    /// The headline: a 120K text file reaches the model CUT (it used to reach it as nothing),
    /// and the transcript says exactly that.
    func testBackendAndTranscriptAgreeOnACutFile() async throws {
        let files = [try file("Small.java", chars: 100), try file("Big.java", chars: big)]

        let backend = await BackendOrchestrationService(fileProcessorService: FileProcessorService())
            .assembleTextFileContent(for: files, includeAbsolutePaths: false)
        let transcript = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
            .build(from: files, deliveryMode: .inject(includeAbsolutePaths: false))

        XCTAssertTrue(backend.failures.isEmpty, "a cut file is delivered, not a failure: \(backend.failures)")
        XCTAssertTrue(backend.content.contains("[Truncated: only the first \(DirectInjectionBudget.perFile) of \(big)"))
        XCTAssertEqual(transcript.textFiles.map(\.delivery), [.full, .truncated(sentChars: DirectInjectionBudget.perFile, totalChars: big)])
        XCTAssertEqual(transcript.textFiles.last?.content.count, big, "the transcript keeps the FULL file for the code viewer")

        // Same plan, same input → the transcript's record reproduces the backend's text exactly.
        let replay = DirectInjectionPlan.assemble(
            transcript.textFiles.map { .init(name: $0.name, path: $0.url.path, content: $0.content) },
            includeAbsolutePaths: false)
        XCTAssertEqual(replay.text, backend.content)
    }

    /// Past the total budget the backend reports `.tooLarge` and the transcript records `.omitted`.
    func testOmittedFilesAgree() async throws {
        let files = try (0..<5).map { try file("f\($0).txt", chars: 60_000) }

        let backend = await BackendOrchestrationService(fileProcessorService: FileProcessorService())
            .assembleTextFileContent(for: files, includeAbsolutePaths: true)
        let transcript = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
            .build(from: files, deliveryMode: .inject(includeAbsolutePaths: true))

        let omitted = transcript.textFiles.filter { if case .omitted = $0.delivery { return true } else { return false } }
        XCTAssertEqual(omitted.map(\.url.path), backend.failures.map(\.path),
                       "every file the transcript marks omitted is one the backend reported")
        XCTAssertFalse(omitted.isEmpty)
    }

    /// Wiring: the factory every sender (main, QuickAccess, Scheduler) builds its row with must
    /// hand the mode through — a dropped parameter here records nothing and nobody notices.
    func testMessageFactoryRecordsDelivery() async throws {
        let message = await MessagingCoordinator.makeUserMessage(
            conversationID: UUID(), query: "q", files: [try file("Big.java", chars: big)],
            fileProcessorService: FileProcessorService(),
            deliveryMode: .inject(includeAbsolutePaths: true))
        XCTAssertEqual(message.attachedTextFiles?.map(\.delivery),
                       [.truncated(sentChars: DirectInjectionBudget.perFile, totalChars: big)])
    }

    /// ATT-3 backstop: a folder that reaches injection (attached under another profile) is
    /// reported as a folder — never as a read failure whose remedy is "re-attach".
    func testBackendReportsAFolderAsAFolder() async throws {
        let folderURL = dir.appendingPathComponent("java")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = FileSystemItem(id: folderURL, name: "java", url: folderURL, isDirectory: true)

        let backend = await BackendOrchestrationService(fileProcessorService: FileProcessorService())
            .assembleTextFileContent(for: [folder, try file("a.txt", chars: 10)], includeAbsolutePaths: false)

        guard case .isFolder(let path)? = backend.failures.first, backend.failures.count == 1 else {
            return XCTFail("expected exactly one .isFolder failure, got \(backend.failures)")
        }
        XCTAssertEqual(path, folderURL.path)
        XCTAssertFalse(backend.failures[0].suggestion?.contains("re-attach") ?? false)
        XCTAssertTrue(backend.content.contains("a.txt"), "the folder must not suppress its neighbours")
    }

    func testPathManifestRecordsPathOnly() async throws {
        let result = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
            .build(from: [try file("Big.java", chars: big)], deliveryMode: .pathManifest)
        XCTAssertEqual(result.textFiles.map(\.delivery), [.pathOnly])
    }

    func testNoModeRecordsNothing() async throws {
        let result = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
            .build(from: [try file("a.txt", chars: 10)])
        XCTAssertEqual(result.textFiles.map(\.delivery), [nil])
    }

    /// The delivery survives the SwiftData row — through `from` / `toStruct`, the persisted path.
    func testDeliverySurvivesTheRow() {
        let url = URL(fileURLWithPath: "/p/Big.java")
        var file = AttachedTextFile(name: "Big.java", url: url, fileExtension: "java", content: "x", size: 1)
        file.delivery = .truncated(sentChars: 50_000, totalChars: 120_000)
        XCTAssertEqual(AttachedTextFileSD.from(file).toStruct().delivery, file.delivery)

        file.delivery = nil
        XCTAssertNil(AttachedTextFileSD.from(file).toStruct().delivery)
    }
}
