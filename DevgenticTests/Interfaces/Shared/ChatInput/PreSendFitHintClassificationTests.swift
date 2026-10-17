// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PreSendFitHintClassificationTests.swift
//  DevgenticTests
//
//  The context gauge decides what to price — and how — through `AttachmentClassifier`, the
//  same owner the send path asks. It used to carry its own extension lists, which priced an
//  `.svg` as text (the backend ships it as an image) and an `.xls` by its binary bytes (the
//  backend extracts it).
//

import XCTest
@testable import devgentic

@MainActor
final class PreSendFitHintClassificationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PreSendFitHint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func item(_ name: String, _ data: Data) throws -> FileSystemItem {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    private func text(_ name: String, chars: Int = 2_000) throws -> FileSystemItem {
        try item(name, Data(String(repeating: "a", count: chars).utf8))
    }

    /// NULs in the head — what an OLE `.xls`, a zipped `.docx` or a `.class` carries.
    private func binary(_ name: String) throws -> FileSystemItem {
        try item(name, Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34] + Array(repeating: 0, count: 2_000)))
    }

    private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8)

    // MARK: - What is priced as text

    func testTextAndTextFormatDocumentsArePricedByTheirSize() throws {
        let files = try [text("Main.java", chars: 1_234), text("README", chars: 77), text("data.csv", chars: 500)]
        XCTAssertEqual(PreSendFitHint.estimatableSizes(of: files), [1_234, 77, 500],
                       "plain text, an extension-less file and a CSV's bytes are all priced")
    }

    func testAnSVGIsPricedAsTheImageItShipsAsNotAsText() throws {
        let file = try item("logo.svg", svg)
        XCTAssertEqual(AttachmentClassifier.classify(file), .image, "fixture: the send path sends it as an image")
        XCTAssertEqual(PreSendFitHint.estimatableSizes(of: [file]), [])
        XCTAssertEqual(PreSendFitHint.imageURLs(of: [file]), [file.url])
    }

    func testBinaryDocumentsBinariesAndFoldersAreNotPricedAsText() throws {
        let folderURL = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = FileSystemItem(id: folderURL, name: "src", url: folderURL, isDirectory: true)
        let xls = try binary("sheet.xls")
        XCTAssertEqual(AttachmentClassifier.classify(xls), .document, "fixture: an extractable document")

        let files = [xls, try binary("January2026.class"), folder]
        XCTAssertEqual(PreSendFitHint.estimatableSizes(of: files), [])
        XCTAssertEqual(PreSendFitHint.imageURLs(of: files), [])
    }

    // MARK: - Wiring: the gauge's attachment term uses this

    func testTheGaugesAttachmentTermSkipsAnSVGAndPricesAText() throws {
        let profile = BackendProfileModel(
            displayName: "Gauge test bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "test-model",
                                          apiKey: nil, baseURL: nil, advancedConfiguration: nil),
                instructions: nil, knowledgeSources: nil)))
        XCTAssertEqual(AttachmentDeliveryMode.resolve(for: profile), .inject(includeAbsolutePaths: false),
                       "fixture: a bot injects content")

        let logo = try item("logo.svg", svg)
        XCTAssertEqual(PromptFitCheck.estimatedAttachmentChars(for: [logo], profile: profile), 0,
                       "an image costs tokens on the image term, not characters here")

        let java = try text("Main.java", chars: 1_000)
        XCTAssertEqual(PromptFitCheck.estimatedAttachmentChars(for: [logo, java], profile: profile),
                       1_000 + DirectInjectionPlan.wrapperWidth(name: "Main.java", path: java.url.path,
                                                                layout: .attachment(includeAbsolutePaths: false)))
    }
}
