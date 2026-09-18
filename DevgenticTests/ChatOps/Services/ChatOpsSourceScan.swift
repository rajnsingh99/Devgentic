// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSourceScan.swift
//  devgenticTests
//
//  ONE reader for every structural scan over the ChatOps tree.
//
//  ⚠️⚠️ THREE TEST FILES CARRIED THREE READERS, AND THEY DID NOT AGREE. `ChatOpsSilentDropTests` had a
//  `codeLines` that dropped WHOLE comment lines only — so a trailing `// …` comment after code was
//  still scanned — while `ChatOpsLoggingHygieneTests` and `ChatOpsSecurityTierMatrixTests` stripped to
//  end-of-line. A scan is only as good as its reader, and a comment-blind scan has produced a false
//  verdict FOUR times in this subsystem's history, in both directions: a commented-out line failing a
//  test, and prose quoting the very pattern being searched for.
//
//  ⚠️ EVERY SCAN GOES THROUGH `strippingComments`. These files document the patterns being searched
//  for — several comments quote `_ = try? await apiClient?.sendMessage(...)` verbatim while explaining
//  why it was replaced.
//

import XCTest

enum ChatOpsSourceScan {

    struct File {
        let name: String
        let path: String
        /// Comment-stripped source.
        let code: String
    }

    /// Every `.swift` file under `Devgentic/ChatOps`, comments stripped.
    ///
    /// ⚠️ A TREE SWEEP, NOT A HARDCODED LIST. The lists it replaces named six files while the tree
    /// holds far more, and the two worst silent drops in the subsystem sat in a file no list included.
    static func chatOpsFiles() throws -> [File] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            dir.deleteLastPathComponent()
            let root = dir.appendingPathComponent("Devgentic/ChatOps")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            var out: [File] = []
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append(File(name: url.lastPathComponent,
                                path: url.path,
                                code: strippingComments(text)))
            }
            return out
        }
        throw XCTSkip("Could not locate Devgentic/ChatOps from \(#filePath)")
    }

    /// `//` to end of line, on every line.
    static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let c = line.range(of: "//") else { return line }
                return line[line.startIndex..<c.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Numbered, comment-stripped lines.
    static func lines(_ code: String) -> [(number: Int, text: String)] {
        code.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// Whether the `break` on `lines[index]` is the entire body of a switch arm.
    ///
    /// ⚠️⚠️ THIS DISCRIMINATOR IS THE WHOLE POINT OF THE REWRITE. The predicate it replaces was
    /// `line == "            break"` — full-line equality against exactly twelve spaces, sitting four
    /// lines under its own comment warning that "a guard that only recognises the shape it was written
    /// against is worth very little". A `break` at any other indentation, with a trailing space, or in
    /// a one-line `default: break` all sailed past it.
    ///
    /// ⚠️ AND IT IS WHAT MAKES A TREE-WIDE SWEEP POSSIBLE. Bare `break` is also how you leave a loop
    /// or a `catch`, and ChatOps contains 14 of those that are entirely correct. Keying on "the
    /// previous code line ends in `:`" separates a switch arm from a loop exit cleanly.
    static func isSwitchArmBreak(_ lines: [(number: Int, text: String)], at index: Int) -> Bool {
        let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
        guard trimmed == "break" else { return false }
        var i = index - 1
        while i >= 0 {
            let prev = lines[i].text.trimmingCharacters(in: .whitespaces)
            if prev.isEmpty { i -= 1; continue }
            return prev.hasSuffix(":")
        }
        return false
    }

    /// The one-line forms: `case …: break`, `default: break`.
    static func isInlineSwitchArmBreak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(": break") else { return false }
        return trimmed.hasPrefix("case ") || trimmed.hasPrefix("default")
            || trimmed.hasPrefix("@unknown default")
    }
}
