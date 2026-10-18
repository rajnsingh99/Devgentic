// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceBoundaryEscapeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkspaceBoundaryEscapeTests: XCTestCase {

    private let root = "/Users/someone/Projects/guest-service"

    private func decide(_ tool: String, _ args: [String: JSONValue], root: String? = nil) -> WorkspaceBoundaryDecision {
        WorkspaceBoundaryDecision.evaluate(toolName: tool, arguments: args,
                                           workspaceRoot: root ?? self.root, repositoryLocator: .unavailable)
    }

    // MARK: - CR-6: every alias a tool reads is checked

    /// ⚠️⚠️ THE FIELD CASE. All four Code-preset write tools accept `file`.
    func testTheFileKeyIsConfinedOnEveryPresetWriteTool() {
        for tool in ["create_new_file", "overwrite_file", "edit_code_single", "edit_code_batch"] {
            let outside = decide(tool, ["file": .string("/Users/someone/.zshrc")])
            guard case .refuse = outside.outcome else {
                return XCTFail("'\(tool)' wrote outside the project through `file`: \(outside.outcome)")
            }
            let relative = decide(tool, ["file": .string("src/A.swift")])
            XCTAssertEqual(relative.arguments["file"], .string(WorkspaceBoundary.canonical("\(root)/src/A.swift")),
                           "'\(tool)': a relative `file` must anchor to the PROJECT, not $HOME")
        }
    }

    /// ⚠️ THE INVARIANT, from the table the decoders themselves read: every (tool, path alias) pair is
    /// confined and re-anchored. A new alias added to a decoder's list is covered automatically.
    func testEveryAliasEveryToolReadsAsAPathIsConfinedAndReAnchored() {
        var unconfined: [String] = []
        for (tool, keys) in ToolPathKeys.byTool {
            for key in keys {
                if case .proceed = decide(tool, [key: .string("/Users/someone/elsewhere")]).outcome {
                    unconfined.append("\(tool).\(key)")
                }
                if decide(tool, [key: .string("src")]).arguments[key] != .string(WorkspaceBoundary.canonical("\(root)/src")) {
                    unconfined.append("\(tool).\(key) (not re-anchored)")
                }
            }
        }
        XCTAssertTrue(unconfined.isEmpty, "path aliases the boundary never checked:\n" + unconfined.sorted().joined(separator: "\n"))
    }

    /// `batch_move_files.sourcePaths` is an ARRAY. Every element is checked and re-anchored.
    func testEveryElementOfAnArrayOfPathsIsChecked() {
        let mixed = decide("batch_move_files", ["sourcePaths": .array([.string("src/a"), .string("/Users/someone/secret")]),
                                                 "destinationFolder": .string("out")])
        guard case .refuse = mixed.outcome else { return XCTFail("an array element escaped: \(mixed.outcome)") }

        let inside = decide("batch_move_files", ["sourcePaths": .array([.string("src/a"), .number(3)]),
                                                  "destinationFolder": .string("out")])
        XCTAssertEqual(inside.outcome, .proceed)
        XCTAssertEqual(inside.arguments["sourcePaths"],
                       .array([.string(WorkspaceBoundary.canonical("\(root)/src/a")), .number(3)]),
                       "string elements re-anchored, anything else left exactly as it was")
    }

    /// ⚠️ THE CONTROL that justifies per-tool keys. `target` is a PROCESS id in `kill_process`; a
    /// global `target` would rewrite it to `/proj/1234` — content corruption.
    func testANameThatIsAPathElsewhereIsLeftAloneWhereItIsNot() {
        let decision = decide("kill_process", ["target": .string("1234")])
        XCTAssertEqual(decision.outcome, .proceed)
        XCTAssertEqual(decision.arguments["target"], .string("1234"))

        let elsewhere = decide("delete_file", ["target": .string("1234")])
        XCTAssertEqual(elsewhere.arguments["target"], .string(WorkspaceBoundary.canonical("\(root)/1234")),
                       "the control: in a tool whose decoder reads `target` as a path, it IS one")
    }

    // MARK: - CR-7: symlinks are resolved for paths that do not exist yet

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func dir(_ name: String) throws -> String {
        let url = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func link(_ name: String, to destination: String) throws -> String {
        let path = sandbox.appendingPathComponent(name).path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
        return path
    }

    /// ⚠️⚠️ THE ESCAPE. A new file under a symlinked directory inside the project.
    func testANewFileUnderASymlinkedDirectoryInsideTheProjectIsRefused() throws {
        let project = try dir("project")
        let outside = try dir("outside")
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: outside)

        let decision = decide("create_new_file", ["file_path": .string("link/new.txt")], root: project)
        guard case .refuse = decision.outcome else {
            return XCTFail("a write through a symlink left the project: \(decision.outcome)")
        }
        XCTAssertEqual(WorkspaceBoundary.canonical(project + "/link/new.txt"),
                       WorkspaceBoundary.canonical(outside) + "/new.txt",
                       "the not-yet-existing leaf is resolved through its symlinked parent")
    }

    /// The control: an EXISTING file through the same link was always caught.
    func testAnExistingFileUnderTheSameLinkIsRefusedToo() throws {
        let project = try dir("project")
        let outside = try dir("outside")
        FileManager.default.createFile(atPath: outside + "/existing.txt", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: outside)
        guard case .refuse = decide("overwrite_file", ["file_path": .string("link/existing.txt")], root: project).outcome
        else { return XCTFail() }
    }

    /// The inverse half of CR-7: a project reached THROUGH a symlink must not refuse its own new files.
    func testANewFileInAProjectWithASymlinkedRootIsAllowed() throws {
        let real = try dir("real-project")
        let rootLink = try link("project-link", to: real)

        for path in ["src/New.swift", rootLink + "/src/New.swift", real + "/src/New.swift"] {
            let decision = decide("create_new_file", ["file_path": .string(path)], root: rootLink)
            XCTAssertEqual(decision.outcome, .proceed, "'\(path)' was refused inside its own project")
        }
    }

    /// A DANGLING link has nothing to resolve via the filesystem, but its target is still outside.
    func testADanglingSymlinkIsFollowedToItsTarget() throws {
        let project = try dir("project")
        let nowhere = sandbox.appendingPathComponent("does-not-exist/yet").path
        try FileManager.default.createSymbolicLink(atPath: project + "/dangling", withDestinationPath: nowhere)
        guard case .refuse = decide("create_new_file", ["file_path": .string("dangling/x.txt")], root: project).outcome
        else { return XCTFail("a dangling link let a write leave the project") }
    }

    /// A link cycle must terminate — a tool call must never hang in the boundary.
    func testASymlinkCycleTerminates() throws {
        let a = sandbox.appendingPathComponent("a").path
        let b = sandbox.appendingPathComponent("b").path
        try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: b)
        try FileManager.default.createSymbolicLink(atPath: b, withDestinationPath: a)
        _ = WorkspaceBoundary.canonical(a + "/x")   // reaching this line is the assertion
    }
}

/// ⚠️ DRIFT GUARD for CR-6: a tool may not keep its path aliases inline again. The boundary reads
/// `ToolPathKeys`; an inline list in a decoder is a second list, and a second list is how `file` went
/// unchecked. Scans the tool sources for alias-list literals that name a path.
final class ToolPathKeysDriftTests: XCTestCase {

    func testNoToolDeclaresAPathAliasListInline() throws {
        let toolDir = try Self.locate("Devgentic/Interfaces/Main/Views/Tooling/Local")
        let files = try FileManager.default.contentsOfDirectory(atPath: toolDir).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        // An alias list: `for key in [ … ]` or `let …keys = [ … ]`, possibly over several lines.
        let regex = try NSRegularExpression(pattern: #"(for\s+key\s+in|let\s+\w*[kK]eys\s*=)\s*\[([^\]]*)\]"#)
        // ⚠️ Not `"source"`: the AppleScript tool's `["script", "code", "source", …]` means SOURCE CODE.
        // These names are paths in every tool that reads them.
        let pathNames = ["\"path\"", "\"file\"", "\"file_path\"", "\"filePath\"", "\"filename\"",
                         "\"folder\"", "\"directory\"", "\"dir\""]
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOfFile: toolDir + "/" + file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let body = Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
                if pathNames.contains(where: body.contains) {
                    offenders.append("\(file): [\(body.replacingOccurrences(of: "\n", with: " "))]")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "path alias lists declared inline — move them into ToolPathKeys:\n"
                      + offenders.joined(separator: "\n"))
    }

    private static func locate(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
