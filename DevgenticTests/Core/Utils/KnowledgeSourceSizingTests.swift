// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KnowledgeSourceSizingTests.swift
//  DevgenticTests
//
//  Knowledge sources ride EVERY request for a profile that has them, so the composer ring and
//  the send-time fit check both price them — and both were guessing. The estimate stat'd byte
//  sizes and charged a flat `wrapperCharsPerFile: 60`, a number that appears nowhere in the
//  assembler, while claiming in its doc to be "sized exactly like attachments — same reader,
//  same drop-don't-clip rule".
//
//  Two things it did not model:
//
//   1. `assembleKnowledgeSourceContent` caps each file at a SHRINKING `remainingBudget` —
//      `min(perFile, total - assembled)`. The estimate counted every file in full.
//   2. Past that budget a source is CUT to what fits (it was dropped whole until 2026-10-05,
//      when knowledge moved onto the attachments' `DirectInjectionPlan`).
//
//  The estimate now runs that same plan, so it cannot drift from the assembler.
//
//  Both errors push the same way: the gauge charges for text that never ships, which raises an
//  overflow warning the user cannot clear by any action that would actually help.
//

import XCTest
@testable import devgentic

@MainActor
final class KnowledgeSourceSizingTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knowledge-sizing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// ASCII, so byte count and character count are the same number and the arithmetic below
    /// is readable.
    private func makeSource(_ name: String, bytes: Int) throws -> KnowledgeSource {
        let url = scratch.appendingPathComponent(name)
        try String(repeating: "x", count: bytes).write(to: url, atomically: true, encoding: .utf8)
        return KnowledgeSource(type: .file, location: url.path)
    }

    /// `.directInjection` is stated explicitly, never left to the default: `.agent` resolves to
    /// `.stateless`, so a profile built without this exercises the manifest path and none of
    /// the injection arithmetic below would be under test at all.
    private func profile(_ sources: [KnowledgeSource]) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: "K",
            details: .agent(
                AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"),
                            tools: [], knowledgeSources: sources)),
            fileContextStrategy: .directInjection)
    }

    /// The assembler's own wrapper literal. Restated here on purpose: if someone changes the
    /// header format, this test should fail rather than silently track it.
    private func wrapper(_ fileName: String) -> Int {
        "\n\n--- Knowledge: \(fileName) ---\n".count
    }

    // MARK: - Wrapper width

    func testASourceIsChargedItsBytesPlusTheAssemblersWrapper() throws {
        let source = try makeSource("notes.md", bytes: 1_000)
        XCTAssertEqual(
            PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([source])),
            1_000 + wrapper("notes.md")
        )
    }

    /// The old flat 60 was not the wrapper's width for any real filename, so the error scaled
    /// with the number of sources rather than cancelling out.
    func testTheWrapperIsDerivedFromTheLiteralNotAFlatSixty() throws {
        let source = try makeSource("a-deliberately-long-knowledge-file-name.md", bytes: 100)
        let charged = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([source]))

        XCTAssertEqual(charged, 100 + wrapper("a-deliberately-long-knowledge-file-name.md"))
        XCTAssertNotEqual(charged, 100 + 60, "the flat 60 was never the real width")
    }

    func testNoSourcesCostNothing() {
        XCTAssertEqual(PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([])), 0)
    }

    // MARK: - Cut, don't drop (2026-10-05)
    //
    // Knowledge sources follow the attachments' rule: past the per-file budget a source is CUT
    // to what fits, with a marker — it used to be refused whole. The gauge must price the slice.

    /// THE invariant: the gauge equals what the knowledge assembler emits (ASCII, so stat'd
    /// bytes == chars). Pinned against the plan, not arithmetic, so a policy change moves both.
    func testGaugeEqualsTheKnowledgeAssemblersOutput() throws {
        let perFile = DirectInjectionBudget.perFile
        let cases: [[Int]] = [
            [500, 700],
            [perFile + 1],
            [500, perFile + 1, 700],
            [perFile, perFile, perFile, perFile - 10_000, 30_000],   // the shrinking total
            [perFile, perFile, perFile, 49_500, 5_000],              // room under minimumSlice
        ]
        for (index, lengths) in cases.enumerated() {
            let sources = try lengths.enumerated().map { try makeSource("c\(index)-\($0.offset).txt", bytes: $0.element) }
            let files = try sources.map {
                DirectInjectionPlan.File(name: $0.fileName, path: $0.location, content: try String(contentsOf: $0.url, encoding: .utf8))
            }
            XCTAssertEqual(
                PromptFitCheck.estimatedKnowledgeSourceChars(for: profile(sources)),
                DirectInjectionPlan.assemble(files, layout: .knowledge).text.count,
                "lengths \(lengths)")
        }
    }

    func testAnOverBudgetSourceIsPricedAsTheSliceThatShips() throws {
        let total = DirectInjectionBudget.perFile + 1
        let oversized = try makeSource("huge.txt", bytes: total)
        XCTAssertEqual(
            PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([oversized])),
            wrapper("huge.txt") + DirectInjectionBudget.perFile
                + DirectInjectionPlan.truncationMarker(sent: DirectInjectionBudget.perFile, total: total).count)
    }

    func testASourcePastTheReadCapCostsNothing() throws {
        let unread = try makeSource("giant.txt", bytes: DirectInjectionBudget.readCap + 1)
        XCTAssertEqual(PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([unread])), 0,
                       "the reader throws .tooLarge before the plan sees it")
    }

    /// The running total is bounded by the same ceiling the assembler is, give or take the
    /// wrapper that lands on top of the last accepted file — which is why this asserts a band
    /// rather than an exact equality.
    func testTheTotalNeverRunsAwayPastTheBudget() throws {
        var sources: [KnowledgeSource] = []
        for i in 0..<12 {
            sources.append(try makeSource("f\(i).txt", bytes: DirectInjectionBudget.perFile))
        }
        let charged = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile(sources))

        XCTAssertGreaterThan(charged, DirectInjectionBudget.total / 2)
        XCTAssertLessThan(charged, DirectInjectionBudget.total + 1_000,
                          "600 KB of sources must not be priced as 600 KB")
    }

    // MARK: - Stateless

    private func readFileTool() -> Tool {
        Tool(name: "read_file", description: "d", isEnabled: true, requiresConfirmation: false,
             sourceId: UUID(),
             parameters: ToolParameters(type: "object", properties: [:], required: []))
    }

    private func statelessProfile(_ sources: [KnowledgeSource], tools: [Tool]) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: "K",
            details: .agent(
                AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"),
                            tools: tools, knowledgeSources: sources)),
            fileContextStrategy: .stateless)
    }

    /// A `.stateless` profile hands over a path manifest and lets the agent `read_file` on
    /// demand, so charging file bytes there over-warns by orders of magnitude.
    func testStatelessProfilesArePricedAsAManifestNotAsContent() throws {
        let big = try makeSource("big.txt", bytes: 40_000)
        let injected = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([big]))
        let manifest = PromptFitCheck.estimatedKnowledgeSourceChars(
            for: statelessProfile([big], tools: [readFileTool()]))

        XCTAssertLessThan(manifest, 1_000, "a manifest is paths, not contents")
        XCTAssertLessThan(manifest, injected / 10)
    }

    /// The gating mismatch, stated directly. The orchestrator's `.stateless` arm emits the
    /// manifest whenever the strategy is stateless; `read_file` only changes the wording. The
    /// estimate used to require the tool before taking the manifest path at all, so a
    /// stateless profile with it switched off fell through to the full-injection arithmetic
    /// and was billed for content that never ships.
    func testStatelessPricingDoesNotFallBackToInjectionWhenReadFileIsOff() throws {
        let big = try makeSource("big.txt", bytes: 40_000)

        let withoutTool = PromptFitCheck.estimatedKnowledgeSourceChars(
            for: statelessProfile([big], tools: []))
        let asInjection = PromptFitCheck.estimatedKnowledgeSourceChars(for: profile([big]))

        XCTAssertLessThan(withoutTool, 1_000,
                          "billed \(withoutTool) chars for a manifest of paths")
        XCTAssertLessThan(withoutTool, asInjection / 10,
                          "the old behaviour priced this as \(asInjection) chars of content")
    }

    /// Priced against the shared owner rather than a re-derivation, so neither the preamble
    /// nor the choice between the two preambles can go uncounted.
    func testStatelessEstimateEqualsTheStringThatShips() throws {
        let a = try makeSource("one.md", bytes: 10)
        let b = try makeSource("two.md", bytes: 10)
        let paths = [a.location, b.location]

        for tools in [[readFileTool()], []] {
            let shipped = StatelessKnowledgeManifest.text(
                paths: paths,
                canReadFiles: StatelessKnowledgeManifest.canReadFiles(statelessProfile([a, b], tools: tools))
            )
            XCTAssertEqual(
                PromptFitCheck.estimatedKnowledgeSourceChars(for: statelessProfile([a, b], tools: tools)),
                shipped.count,
                "read_file enabled: \(!tools.isEmpty)"
            )
            XCTAssertGreaterThan(shipped.count, paths.joined(separator: "\n").count,
                                 "the paths alone are not the payload — a preamble ships too")
        }
    }

    // MARK: - The sentence has to be true

    /// Listing paths under the word "available" while offering no way to open them invites the
    /// model to invent their contents. The manifest must not name an instrument the profile
    /// does not have — the same rule the episodic pointer `<outcome>` follows.
    func testTheManifestDoesNotNameAToolTheProfileLacks() {
        let withTool = StatelessKnowledgeManifest.text(paths: ["/tmp/a.md"], canReadFiles: true)
        let withoutTool = StatelessKnowledgeManifest.text(paths: ["/tmp/a.md"], canReadFiles: false)

        XCTAssertTrue(withTool.contains("read_file tool"))
        XCTAssertFalse(withoutTool.contains("Read them with the read_file tool"),
                       "it cannot: \(withoutTool)")
        XCTAssertTrue(withoutTool.contains("cannot be retrieved"))
        XCTAssertTrue(withoutTool.contains("/tmp/a.md"), "the paths are true either way")
    }

    /// The tool-bearing wording is load-bearing for prompt caching — knowledge context is a
    /// system layer chosen to be byte-stable per profile. Pinned so a later reword is a
    /// deliberate act rather than a silent cache invalidation for every existing profile.
    func testTheToolBearingPreambleIsUnchanged() {
        XCTAssertEqual(
            StatelessKnowledgeManifest.text(paths: ["/p"], canReadFiles: true),
            "The following profile reference documents are available. Read them with the read_file tool when needed:\n/p"
        )
    }

    /// A profile type with no tools at all must get the honest variant rather than be assumed
    /// capable — `enabledToolNames` is empty for those, which is the right answer, not a gap.
    func testAProfileWithNoToolsAtAllCannotReadFiles() throws {
        let source = try makeSource("x.md", bytes: 10)
        XCTAssertFalse(StatelessKnowledgeManifest.canReadFiles(statelessProfile([source], tools: [])))
        XCTAssertTrue(StatelessKnowledgeManifest.canReadFiles(
            statelessProfile([source], tools: [readFileTool()])))
    }
}
