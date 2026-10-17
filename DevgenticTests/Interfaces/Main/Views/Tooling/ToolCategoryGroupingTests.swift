// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolCategoryGroupingTests.swift
//  DevgenticTests
//
//  `BuiltInToolCategory.allGroups` maps each sidebar group to the tool `category` values it
//  gathers, and nothing checked it against the tools that actually exist.
//
//  The two directions fail differently, and only one of them is visible:
//
//  - A group naming a category no tool uses is INERT — `builtInGroups` drops zero-count groups —
//    so it survives indefinitely as a description of a shape the app no longer has. Four such
//    names accumulated from the 2026-07-31 catalogue cleanup and were removed on 2026-08-01.
//  - A tool whose category is in NO group gets no sidebar row. It still appears under "All
//    Tools", so it is not missing exactly — just unreachable by the route most people use, with
//    nothing anywhere reporting it.
//
//  The second is why this test exists; the first is why it checks both ways.
//

import XCTest
@testable import devgentic

final class ToolCategoryGroupingTests: XCTestCase {

    /// Categories declared by tools the Tool Library actually offers.
    private var libraryCategories: Set<String> {
        Set(NativeToolCatalog.libraryTools.map(\.category))
    }

    // MARK: - Every group gathers something

    func testEveryGroupedCategoryIsUsedByARealTool() {
        let declared = libraryCategories
        var orphans: [String] = []

        for group in BuiltInToolCategory.allGroups {
            for raw in group.rawCategories where !declared.contains(raw) {
                orphans.append("\(group.name) → '\(raw)'")
            }
        }

        XCTAssertTrue(orphans.isEmpty, """
            These sidebar groups gather categories no tool declares. They are invisible at \
            runtime — a group with no tools is dropped — so they persist as a description of a \
            shape the app does not have:
            \(orphans.joined(separator: "\n"))
            """)
    }

    // MARK: - Every tool lands somewhere

    /// The direction that actually costs the user something.
    func testEveryLibraryToolCategoryBelongsToAGroup() {
        let grouped = Set(BuiltInToolCategory.allGroups.flatMap(\.rawCategories))
        let ungrouped = libraryCategories.subtracting(grouped).sorted()

        XCTAssertTrue(ungrouped.isEmpty, """
            Tools in these categories have no sidebar group, so they appear only under \
            "All Tools" and cannot be found by browsing: \(ungrouped).
            Add the category to a group in BuiltInToolCategory.allGroups.
            """)
    }

    func testGroupNameLookupResolvesForEveryLibraryCategory() {
        for category in libraryCategories {
            XCTAssertNotNil(BuiltInToolCategory.groupName(for: category),
                            "'\(category)' resolves to no group name")
        }
    }

    // MARK: - Structure

    /// A category in two groups would put the same tool under two sidebar rows, and the counts
    /// would not add up to the total.
    func testNoCategoryAppearsInTwoGroups() {
        var seen: [String: String] = [:]
        var duplicates: [String] = []

        for group in BuiltInToolCategory.allGroups {
            for raw in group.rawCategories {
                if let owner = seen[raw] {
                    duplicates.append("'\(raw)' is in both \(owner) and \(group.name)")
                } else {
                    seen[raw] = group.name
                }
            }
        }
        XCTAssertTrue(duplicates.isEmpty, duplicates.joined(separator: "\n"))
    }

    /// `Internal` is deliberately absent: `ask_user`, `final_answer`, `load_skill`,
    /// the Code memory tools and `get_conversation_history` are injected per run, never
    /// offered in the Library. Pinned so a well-meaning "every category needs a group" change
    /// does not surface them.
    func testInternalToolsAreNotGrouped() {
        let grouped = Set(BuiltInToolCategory.allGroups.flatMap(\.rawCategories))
        XCTAssertFalse(grouped.contains("Internal"),
                       "Internal tools are injected per run and must not appear in the Library")
        XCTAssertFalse(libraryCategories.contains("Internal"),
                       "an Internal tool has become library-visible")
    }

    func testEveryGroupHasANameAndIcon() {
        for group in BuiltInToolCategory.allGroups {
            XCTAssertFalse(group.name.isEmpty)
            XCTAssertFalse(group.icon.isEmpty, "\(group.name) has no SF Symbol")
            XCTAssertFalse(group.rawCategories.isEmpty, "\(group.name) gathers nothing")
        }
    }

    // MARK: - The two risk classifications agree

    /// `NativeToolWrapper.requiresConfirmation` picks the DEFAULT a tool carries into the Library;
    /// `HITLRiskTier.classify` picks the badge on the permission banner. They describe the same
    /// property from two places, and they disagreed about `fs_watch_folder` — "strictly read-only"
    /// in one, `.moderate` in the other — until 2026-08-01.
    ///
    /// Neither ENFORCES anything: the profile's own `requiresConfirmation` is the only gate, and
    /// the user's choice always wins. But two descriptions of one tool must not contradict each
    /// other, or the banner and the default tell the operator different stories.
    func testSafeDefaultsAgreeWithRiskTier() {
        var contradictions: [String] = []

        for entry in NativeToolCatalog.libraryTools {
            let tool = entry.executable()
            let defaultsToSafe = !tool.requiresConfirmation
            let tier = HITLRiskTier.classify(toolName: tool.name)

            // The documented exception (2026-09-26): changes state, but only the agent's own work
            // in its own conversation. Checked against its OWN rule below, not this one.
            if ToolConfirmationDefaults.ownWorkOnlyTools.contains(tool.name) { continue }

            if defaultsToSafe && tier != .safe {
                contradictions.append(
                    "\(tool.name): defaults to NO confirmation (treated as read-only) but "
                    + "HITLRiskTier calls it .\(tier.rawValue)")
            }
        }

        XCTAssertTrue(contradictions.isEmpty, """
            A tool is described as read-only in one place and state-changing in another:
            \(contradictions.joined(separator: "\n"))
            """)
    }

    /// The own-work exception must stay honest: these start without confirmation, but the banner
    /// still says they change state — and none of them may run arbitrary code or be destructive.
    func testOwnWorkOnlyToolsAreStateChangingButNotDestructive() {
        XCTAssertEqual(ToolConfirmationDefaults.ownWorkOnlyTools, ["stop_background_task"],
                       "a tool joined the own-work exception — it must be provably scoped to the agent's own work")
        for name in ToolConfirmationDefaults.ownWorkOnlyTools {
            XCTAssertEqual(HITLRiskTier.classify(toolName: name), .moderate,
                           "\(name) is in the own-work exception, so its badge must still say it changes state")
            XCTAssertFalse(ToolCapability.executesArbitraryCode(name))
            XCTAssertFalse(ToolConfirmationDefaults.readOnlyTools.contains(name),
                           "\(name) is listed as read-only too — the two reasons must stay apart")
            let tool = try? XCTUnwrap(NativeToolCatalog.entry(named: name)).executable()
            XCTAssertEqual(tool?.requiresConfirmation, false, "\(name) should start without confirmation")
        }
    }

    /// THE PREMISE of the exception: `stop_background_task` cannot reach another conversation's task.
    func testStopBackgroundTaskCannotStopAnotherConversationsTask() async throws {
        let owner = UUID(), other = UUID()
        defer {
            BackgroundProcessRegistry.shared.discard(conversationID: owner)
            BackgroundProcessRegistry.shared.discard(conversationID: other)
        }
        let task = try BackgroundProcessRegistry.shared.launch(
            command: "sleep 20", workingDirectory: NSTemporaryDirectory(), timeout: 30, conversationID: owner)

        let args = try JSONDecoder().decode(CommandStopTool.Arguments.self,
                                            from: Data(#"{"task_id":"\#(task.id)"}"#.utf8))
        _ = try await CommandStopTool(conversationID: other).call(arguments: args)

        XCTAssertEqual(BackgroundProcessRegistry.shared.snapshot(conversationID: owner, taskID: task.id)?.status, .running,
                       "a stop from another conversation ended this task — the own-work exception no longer holds")
    }

    /// The specific tool that was wrong, pinned by name so the fix cannot silently regress.
    func testWatchFolderIsNotTreatedAsReadOnly() {
        let watcher = NativeToolCatalog.libraryTools
            .first { $0.name == "watch_folder" }
            .map { $0.executable() }
        XCTAssertNotNil(watcher, "watch_folder is no longer offered in the Library")

        XCTAssertTrue(watcher?.requiresConfirmation == true, """
            watch_folder defaults to no confirmation. Its `start` action opens a file \
            descriptor and arms a dispatch source that lives until something stops it — only \
            `list` is read-only, and this default is per-tool.
            """)
        XCTAssertEqual(HITLRiskTier.classify(toolName: "watch_folder"), .moderate)
        XCTAssertEqual(HITLRiskTier.classify(toolName: "watch_folder"), .moderate)
    }
}
