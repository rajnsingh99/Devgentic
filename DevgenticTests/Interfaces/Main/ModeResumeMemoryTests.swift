// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModeResumeMemoryTests.swift
//  DevgenticTests
//
//  A mode switch used to drop every mode to Home. `ModeResumeMemory` decides where a mode
//  resumes; re-selecting that conversation restores its messages, profile and Code project.
//

import XCTest
@testable import devgentic

final class ModeResumeMemoryTests: XCTestCase {

    private let conv = UUID()
    private let profile = UUID()

    func testAModeResumesTheConversationItWasLeftOn() {
        var memory = ModeResumeMemory()
        memory.leave(.code, at: .init(conversationID: conv, profileID: profile))

        XCTAssertEqual(memory.resume(.code) { _ in true }, .init(conversationID: conv, profileID: nil),
                       "the conversation brings its own profile")
    }

    func testHomeResumesWithTheProfilePickedOnIt() {
        var memory = ModeResumeMemory()
        memory.leave(.chat, at: .init(conversationID: nil, profileID: profile))

        XCTAssertEqual(memory.resume(.chat) { _ in true }, .init(conversationID: nil, profileID: profile))
    }

    func testEachModeKeepsItsOwnSpot() {
        var memory = ModeResumeMemory()
        let chatConv = UUID()
        memory.leave(.chat, at: .init(conversationID: chatConv))
        memory.leave(.code, at: .init(conversationID: conv))

        XCTAssertEqual(memory.resume(.chat) { _ in true }.conversationID, chatConv)
        XCTAssertEqual(memory.resume(.code) { _ in true }.conversationID, conv)
        XCTAssertEqual(memory.resume(.workflow) { _ in true }, .init(), "a mode never left starts at Home")
    }

    /// Deleted while away → that mode's Home, never a selection of a conversation that is gone.
    func testADeletedConversationResumesAsHome() {
        var memory = ModeResumeMemory()
        memory.leave(.code, at: .init(conversationID: conv, profileID: profile))

        XCTAssertEqual(memory.resume(.code) { _ in false }, .init())
    }
}
