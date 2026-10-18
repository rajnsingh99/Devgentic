// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentSizingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AttachmentSizingTests: XCTestCase {

    /// ASCII so stat'd bytes == decoded chars — the one case where the gauge is exact.
    private func files(_ lengths: [Int]) -> [DirectInjectionPlan.File] {
        lengths.enumerated().map { index, length in
            .init(name: "f\(index).txt", path: "/p/f\(index).txt", content: String(repeating: "a", count: length))
        }
    }

    private func gauge(for files: [DirectInjectionPlan.File], includeAbsolutePaths: Bool) -> Int {
        PromptFitCheck.attachmentInjectionChars(
            forFileSizes: files.map(\.content.count),
            wrapperWidths: files.map {
                DirectInjectionPlan.wrapperWidth(
                    name: $0.name,
                    label: DirectInjectionPlan.wrapperLabel(name: $0.name, path: $0.path, includeAbsolutePaths: includeAbsolutePaths))
            })
    }

    // MARK: - The invariant: gauge == what ships

    func testGaugeEqualsAssembledLengthAcrossTheBudgetBoundaries() {
        let perFile = DirectInjectionBudget.perFile
        let cases: [[Int]] = [
            [],
            [100, 200],
            [perFile],                                   // inclusive boundary
            [perFile + 1],                               // cut by one
            [1_000, perFile + 5_000, 2_000],             // a cut file between full ones
            Array(repeating: 60_000, count: 10),         // total budget runs out mid-batch
            Array(repeating: 40_000, count: 20),
            [50_000, 50_000, 50_000, 49_500, 5_000],     // remaining room under minimumSlice
        ]
        for lengths in cases {
            for includePaths in [false, true] {
                let batch = files(lengths)
                XCTAssertEqual(
                    gauge(for: batch, includeAbsolutePaths: includePaths),
                    DirectInjectionPlan.assemble(batch, includeAbsolutePaths: includePaths).text.count,
                    "lengths \(lengths), paths \(includePaths)")
            }
        }
    }

    // MARK: - Plan behaviour

    func testOverBudgetFileIsCutNotDropped() {
        let total = DirectInjectionBudget.perFile + 10_000
        let (text, deliveries) = DirectInjectionPlan.assemble(files([total]), includeAbsolutePaths: false)
        XCTAssertEqual(deliveries, [.truncated(sentChars: DirectInjectionBudget.perFile, totalChars: total)])
        XCTAssertTrue(text.contains("[Truncated: only the first \(DirectInjectionBudget.perFile) of \(total)"),
                      "the model must be told it saw part of the file")
    }

    func testFileAtTheBudgetIsSentWhole() {
        XCTAssertEqual(DirectInjectionPlan.assemble(files([DirectInjectionBudget.perFile]), includeAbsolutePaths: false).deliveries,
                       [.full])
    }

    func testFilesPastTheTotalBudgetAreOmitted() {
        let deliveries = DirectInjectionPlan.assemble(files(Array(repeating: 60_000, count: 6)), includeAbsolutePaths: false).deliveries
        XCTAssertEqual(Array(deliveries.prefix(3)), [
            .truncated(sentChars: 50_000, totalChars: 60_000),
            .truncated(sentChars: 50_000, totalChars: 60_000),
            .truncated(sentChars: 50_000, totalChars: 60_000),
        ])
        XCTAssertEqual(deliveries.last, .omitted(totalChars: 60_000))
    }

    /// Room smaller than `minimumSlice` omits rather than sending a meaningless sliver.
    func testASliverOfRemainingRoomOmitsInsteadOfCutting() {
        // Four files leave ~250 chars of the 200K total — under minimumSlice.
        let deliveries = DirectInjectionPlan.assemble(files([50_000, 50_000, 50_000, 49_500, 5_000]), includeAbsolutePaths: false).deliveries
        XCTAssertEqual(Array(deliveries.prefix(4)), [.full, .full, .full, .full])
        XCTAssertEqual(deliveries.last, .omitted(totalChars: 5_000))
    }

    func testAFileOverTheReadCapCostsNothing() {
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [DirectInjectionBudget.readCap + 1], wrapperCharsPerFile: 80), 0,
            "the reader throws .tooLarge before the plan ever sees it")
    }

    func testNoAttachmentsCostNothing() {
        XCTAssertEqual(PromptFitCheck.attachmentInjectionChars(forFileSizes: [], wrapperCharsPerFile: 80), 0)
    }

    // MARK: - Delivery storage codec (the ONLY codec — see AttachmentDelivery.storage)

    func testDeliveryStorageRoundTrips() {
        let all: [AttachmentDelivery] = [.full, .truncated(sentChars: 50_000, totalChars: 120_000), .omitted(totalChars: 9), .pathOnly]
        for delivery in all {
            let stored = delivery.storage
            XCTAssertEqual(AttachmentDelivery(kind: stored.kind, sent: stored.sent, total: stored.total), delivery)
        }
        XCTAssertNil(AttachmentDelivery(kind: nil, sent: nil, total: nil), "a row written before the column reads as unrecorded")
    }
}
