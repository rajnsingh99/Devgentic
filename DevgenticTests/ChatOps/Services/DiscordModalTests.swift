// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordModalTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class DiscordModalTests: XCTestCase {

    private let operationID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    // MARK: - The token

    /// Mutation that must turn this red: change the `hitl:answer:` prefix on either side.
    func testTheAnswerTokenRoundTripsThroughTheRealParser() {
        let wire = CallbackToken.answerClarification(operationID: operationID).wire
        XCTAssertEqual(wire, "hitl:answer:\(operationID.uuidString)")

        // The grammar is shared, so it must decode identically wherever a button can be tapped.
        for parsed in [
            ChatOpsCommand.parseCallbackData(wire),
            ChatOpsCommand.parseDiscord(customID: wire),
            ChatOpsCommand.parseSlack(actionID: wire),
        ] {
            guard case .answerClarification(let id) = parsed else {
                return XCTFail("`\(wire)` decoded as something other than an answer request")
            }
            XCTAssertEqual(id, operationID)
        }
    }

    /// ⚠️ 48 bytes. Telegram's 64-byte `callback_data` cap is the binding one for all three
    /// platforms because the grammar is shared, and a token that exceeds it makes Telegram reject
    /// the WHOLE message — the buttons simply never appear.
    func testTheAnswerTokenFitsTheBindingBudget() {
        XCTAssertTrue(CallbackToken.answerClarification(operationID: operationID).fits())
    }

    // MARK: - The affordance

    /// Mutation that must turn this red: drop the components from the Discord clarification arm.
    func testDiscordsClarificationPromptCarriesTheButtonAModalNeeds() throws {
        let view = RemoteView.prompt(operationID: operationID, kind: .clarification(question: "Which file?"))
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: view))

        let row = try XCTUnwrap(draft.components?.first)
        XCTAssertEqual(row.type, DiscordComponent.actionRow)
        let button = try XCTUnwrap(row.components?.first)
        XCTAssertEqual(button.type, DiscordComponent.button)
        XCTAssertEqual(button.custom_id, CallbackToken.answerClarification(operationID: operationID).wire, """
            The button must carry the OPERATION id. It is the only thing that survives the round \
            trip into the modal and back, and therefore the only thing that can say which \
            clarification an answer answers.
            """)
    }

    // MARK: - Opening the modal

    /// Mutation that must turn this red: remove `custom_id` or `title` from
    /// `DiscordInteractionCallbackData` — their absence was the single hard blocker on opening a
    /// modal at all, because a type-9 body could not be expressed.
    func testAModalOpenPayloadCarriesEverythingDiscordRequires() throws {
        let payload = DiscordInteractionResponsePayload(
            type: DiscordInteractionResponsePayload.modal,
            data: DiscordInteractionCallbackData(
                components: [.actionRow([
                    .textInput(customID: "answer", label: "Your answer", placeholder: "Type your answer…")
                ])],
                custom_id: CallbackToken.answerClarification(operationID: operationID).wire,
                title: "Answer the agent"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any])

        XCTAssertEqual(object["type"] as? Int, 9, "type 9 is what makes this a modal rather than a message")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["title"] as? String, "Answer the agent")
        XCTAssertEqual(data["custom_id"] as? String,
                       "hitl:answer:\(operationID.uuidString)",
                       "the modal's own custom_id is the correlation key")

        // ⚠️ Discord requires each Text Input to be the SOLE child of its own ActionRow.
        let rows = try XCTUnwrap(data["components"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let fields = try XCTUnwrap(rows[0]["components"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1, "two text inputs in one row is rejected outright")
        XCTAssertEqual(fields[0]["type"] as? Int, 4, "component type 4 is the text input")
        XCTAssertEqual(fields[0]["custom_id"] as? String, "answer")
    }

    /// Discord rejects the whole interaction response when a label or title exceeds its cap, and
    /// the only feedback is a modal that fails to open.
    func testLabelsAndTitlesAreTruncatedToDiscordsCaps() {
        let field = DiscordComponent.textInput(
            customID: "answer",
            label: String(repeating: "L", count: 200),
            placeholder: String(repeating: "P", count: 400)
        )
        XCTAssertEqual(field.label?.count, 45)
        XCTAssertEqual(field.placeholder?.count, 100)

        let data = DiscordInteractionCallbackData(title: String(repeating: "T", count: 200))
        XCTAssertEqual(data.title?.count, 45)
    }

    // MARK: - Reading the submission

    /// ⚠️ VALUES ARRIVE ONE ACTIONROW DEEP, and the obvious flat read finds nothing. Looking through
    /// `data.components` directly turns up only rows — which carry no `custom_id` and no `value` —
    /// so a flat implementation returns nil for every submission and presents as "the user
    /// submitted an empty answer".
    ///
    /// Mutation that must turn this red: make `submittedValue(forCustomID:)` search
    /// `data.components` without descending into each row.
    func testASubmittedValueIsReadThroughItsActionRow() throws {
        let json = """
        {
          "id": "111",
          "type": 5,
          "channel_id": "C1",
          "token": "tok",
          "data": {
            "custom_id": "hitl:answer:\(operationID.uuidString)",
            "components": [
              {"type": 1, "components": [
                {"type": 4, "custom_id": "answer", "value": "the second one"}
              ]}
            ]
          }
        }
        """.data(using: .utf8)!

        let interaction = try JSONDecoder().decode(DiscordInteraction.self, from: json)
        XCTAssertEqual(interaction.type, DiscordInteraction.modalSubmit)
        XCTAssertEqual(interaction.submittedValue(forCustomID: "answer"), "the second one")

        // The row itself carries neither, which is exactly why a flat read fails.
        let row = try XCTUnwrap(interaction.data?.components?.first)
        XCTAssertNil(row.custom_id)
        XCTAssertNil(row.value)

        XCTAssertNil(interaction.submittedValue(forCustomID: "not-a-field"),
                     "an unknown field must read as absent rather than as the first value found")
    }

    /// The submission names its operation, which is the whole point: the answer no longer depends
    /// on which conversation the provider cursor happens to point at when it lands.
    func testASubmittedModalNamesTheOperationItAnswers() throws {
        let customID = "hitl:answer:\(operationID.uuidString)"
        guard case .answerClarification(let id) = ChatOpsCommand.parseDiscord(customID: customID) else {
            return XCTFail("a submitted modal must decode back to the operation it answers")
        }
        XCTAssertEqual(id, operationID)
    }
}
