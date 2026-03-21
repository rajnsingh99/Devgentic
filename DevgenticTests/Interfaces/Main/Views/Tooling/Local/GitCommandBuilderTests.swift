//
//  GitCommandBuilderTests.swift
//  DevgenticTests
//
//  TDD: Tier 1d — GitTool Action Routing + Default Arguments
//

import XCTest
@testable import devgentic

final class GitCommandBuilderTests: XCTestCase {

    private let repoPath = "/Users/test/repo"

    // MARK: - Action Routing

    func testResolve_Status_ReturnsStatusCommand() {
        let result = GitCommandBuilder.resolve(action: "status", repoPath: repoPath, extraArgs: "")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("status --short"))
            XCTAssertTrue(cmd.contains("-C \"\(repoPath)\""))
        } else {
            XCTFail("Expected .command, got \(result)")
        }
    }

    func testResolve_Log_DefaultArgs_UsesOneline() {
        let result = GitCommandBuilder.resolve(action: "log", repoPath: repoPath, extraArgs: "")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("-n 10 --oneline"), "Default log args should be -n 10 --oneline")
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_Log_CustomArgs_OverridesDefaults() {
        let result = GitCommandBuilder.resolve(action: "log", repoPath: repoPath, extraArgs: "-n 5 --graph")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("-n 5 --graph"))
            XCTAssertFalse(cmd.contains("--oneline"), "Custom args should replace defaults")
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_Diff_PassesThroughArgs() {
        let result = GitCommandBuilder.resolve(action: "diff", repoPath: repoPath, extraArgs: "--staged")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("diff --staged"))
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_Branch_PassesThroughArgs() {
        let result = GitCommandBuilder.resolve(action: "branch", repoPath: repoPath, extraArgs: "--list")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("branch -a --list"))
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_StashList_FixedCommand() {
        let result = GitCommandBuilder.resolve(action: "stash_list", repoPath: repoPath, extraArgs: "")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("stash list"))
        } else {
            XCTFail("Expected .command")
        }
    }

    // MARK: - Blame Requires Args

    func testResolve_Blame_WithArgs_ReturnsCommand() {
        let result = GitCommandBuilder.resolve(action: "blame", repoPath: repoPath, extraArgs: "main.swift")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("blame main.swift"))
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_Blame_WithoutArgs_ReturnsError() {
        let result = GitCommandBuilder.resolve(action: "blame", repoPath: repoPath, extraArgs: "")
        if case .error(let msg) = result {
            XCTAssertTrue(msg.contains("filename for blame"))
        } else {
            XCTFail("Expected .error for blame without args, got \(result)")
        }
    }

    // MARK: - Show Defaults

    func testResolve_Show_DefaultArgs_UsesHEAD() {
        let result = GitCommandBuilder.resolve(action: "show", repoPath: repoPath, extraArgs: "")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("show HEAD --stat"))
        } else {
            XCTFail("Expected .command")
        }
    }

    func testResolve_Show_CustomArgs_OverridesHEAD() {
        let result = GitCommandBuilder.resolve(action: "show", repoPath: repoPath, extraArgs: "abc123")
        if case .command(let cmd) = result {
            XCTAssertTrue(cmd.contains("show abc123 --stat"))
            XCTAssertFalse(cmd.contains("HEAD"))
        } else {
            XCTFail("Expected .command")
        }
    }

    // MARK: - Unknown Action

    func testResolve_UnknownAction_ReturnsError() {
        let result = GitCommandBuilder.resolve(action: "rebase", repoPath: repoPath, extraArgs: "")
        if case .error(let msg) = result {
            XCTAssertTrue(msg.contains("Unknown git action"))
            XCTAssertTrue(msg.contains("rebase"))
        } else {
            XCTFail("Expected .error for unknown action, got \(result)")
        }
    }
}
