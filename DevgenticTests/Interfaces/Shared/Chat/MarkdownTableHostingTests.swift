//
//  MarkdownTableHostingTests.swift
//  DevgenticTests
//
//  HOSTED-rendering regression tests for the 2026-07-16 streaming-table crash
//  (Fatal error: Index out of range). Unit-constructing a view can't reproduce
//  SwiftUI identity persistence — the crash mechanism was @State surviving across
//  updates while the inputs grew. These tests mount the real views in an
//  NSHostingView and mutate inputs under a STABLE identity, exactly like a
//  streaming response updating in place.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class MarkdownTableHostingTests: XCTestCase {

    private func makeHosting<V: View>(_ root: V) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 1200)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// A table growing row-by-row (and mutating its last row, and crossing the
    /// 50-row virtualization boundary, and shrinking) under one view identity.
    /// The crashed implementation cached parsed cells in @State sized to the FIRST
    /// appearance and indexed it with the CURRENT row count.
    func testGrowingTableUnderStableIdentityDoesNotCrash() {
        struct Harness: View {
            let rows: [[String]]
            var body: some View {
                MarkdownTableView(headers: ["File", "Purpose"], rows: rows)
            }
        }

        let (window, hosting) = makeHosting(Harness(rows: [["seed", "row"]]))
        defer { window.orderOut(nil) }

        for n in 1...60 {
            var rows = (0..<n).map { ["file\($0).swift", "Purpose **\($0)** of this file"] }
            rows[rows.count - 1][1] = "still streaming…"
            hosting.rootView = Harness(rows: rows)
            hosting.layoutSubtreeIfNeeded()
            if n % 10 == 0 { pump() }
        }

        // Shrink (a mid-stream re-parse can momentarily yield fewer rows).
        hosting.rootView = Harness(rows: [["only", "row"]])
        hosting.layoutSubtreeIfNeeded()
        pump()
    }

    /// Full streaming-pipeline fidelity: feed a markdown document containing a table
    /// through StreamingMarkdownParser chunk by chunk and render the produced blocks
    /// keyed by their positional ids — the exact identity situation of a streaming
    /// chat bubble — then apply the completion full-parse heal.
    func testStreamedTablePipelineRendersWithoutCrash() {
        struct BlocksHarness: View {
            let blocks: [ContentBlock]
            var body: some View {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        switch block.type {
                        case .table(let headers, let rows, _):
                            MarkdownTableView(headers: headers, rows: rows)
                        case .paragraph(let text):
                            Text(text)
                        case .heading(_, let text):
                            Text(text).bold()
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }

        let document = """
        Here is an explanation of each attached file:

        | File | Purpose |
        | --- | --- |
        | AgentModel.swift | Core agent model definitions and tool protocols |
        | AgentConnect.swift | The single entry point for all LLM interactions |
        | ChatExecutor.swift | Lightweight executor for direct chat calls |
        | ChatHistoryView.swift | Scrollback rendering with pagination |

        Each file plays a distinct role in the pipeline.
        """

        let parser = StreamingMarkdownParser()
        let (window, hosting) = makeHosting(BlocksHarness(blocks: []))
        defer { window.orderOut(nil) }

        var fed = ""
        var index = document.startIndex
        while index < document.endIndex {
            let end = document.index(index, offsetBy: 5, limitedBy: document.endIndex) ?? document.endIndex
            fed += document[index..<end]
            index = end

            hosting.rootView = BlocksHarness(blocks: parser.parse(fed))
            hosting.layoutSubtreeIfNeeded()
        }

        // Completion heal — the authoritative full parse replaces incremental blocks.
        hosting.rootView = BlocksHarness(blocks: parseMarkdown(document))
        hosting.layoutSubtreeIfNeeded()
        pump()
    }
}

// MARK: - Code Block Sizing

@MainActor
final class CodeBlockHostingTests: XCTestCase {

    /// Regression (2026-07-16): the code block's NSTextView was greedy — it accepted
    /// the full proposed height, so inside the newest chat row (which reserves ~a
    /// viewport of minHeight) a 3-line block rendered ~1000pt tall with a sea of
    /// empty space inside its border. It must hug its content height.
    func testCodeBlockHugsContentDespiteTallProposal() {
        let code = "[FILE] log.txt (7 bytes)\n[FILE] notes.txt (10 bytes)\nContents listed."
        let root = CodeBlockView(language: "plaintext", content: code)
            .frame(width: 800)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 1200)  // viewport-tall proposal
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.orderOut(nil) }

        let ideal = hosting.fittingSize
        XCTAssertLessThan(ideal.height, 300,
                          "A 3-line code block must hug its content, not absorb the proposed height (got \(ideal.height))")
        XCTAssertGreaterThan(ideal.height, 60,
                             "Sanity: header + 3 code lines should still have real height (got \(ideal.height))")
    }

    /// The other half of the contract, added 2026-07-17 with the height cap: a LONG block
    /// must stop growing and scroll instead. Uncapped, a 49-line block (just under the
    /// card threshold) rendered ~780pt and pushed the rest of the reply off screen.
    ///
    /// Both directions matter and pull opposite ways — the first attempt at the cap
    /// wrapped every block in a ScrollView, which fixed this and broke the hugging test
    /// above, because a ScrollView accepts whatever height it's offered.
    func testLongCodeBlockIsCappedRatherThanGrowingUnbounded() {
        let code = (1...49).map { "print(\"line \($0)\")" }.joined(separator: "\n")
        let root = CodeBlockView(language: "swift", content: code).frame(width: 800)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 2000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 2000)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.orderOut(nil) }

        let ideal = hosting.fittingSize
        // Cap + header + chrome. Generous upper bound: the point is that it's bounded at
        // all, not the exact pixel.
        XCTAssertLessThan(ideal.height, ChatUIConstants.codeBlockMaxHeight + 120,
                          "A 49-line block must be capped, not render its full ~780pt (got \(ideal.height))")
        XCTAssertGreaterThan(ideal.height, ChatUIConstants.codeBlockMaxHeight - 60,
                             "It should still fill the cap — a capped block that collapsed would be worse (got \(ideal.height))")
    }
}
