// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackModalTests.swift
//  DevgenticTests
//
//  Slice 4.3: Slack structured input via `views.open`.
//
//  ⚠️ `trigger_id` WAS DECODED AND USED NOWHERE. It sat on two payload structs, referenced by no
//  other line in the repository, and it is the only key to `views.open` — so Slack had the highest
//  structured-input ceiling of the three platforms and reached none of it.
//

import XCTest
@testable import devgentic

final class SlackModalTests: XCTestCase {

    private let operationID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private var token: String { CallbackToken.answerClarification(operationID: operationID).wire }

    // MARK: - The affordance

    /// ⚠️ WITHOUT A BUTTON THERE IS NO MODAL, EVER. `views.open` needs a live `trigger_id`, and
    /// that arrives only on a button tap or a slash command — never on the `events_api` path that
    /// carries typed text. A clarification is raised asynchronously with no interaction in flight,
    /// so the affordance on the prompt is the only thing that can create one.
    ///
    /// Mutation that must turn this red: return the text-only draft with `blocks: nil`.
    func testSlacksClarificationPromptCarriesTheButtonAModalNeeds() throws {
        let view = RemoteView.prompt(operationID: operationID, kind: .clarification(question: "Which file?"))
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: view))

        let blocks = try XCTUnwrap(draft.blocks)
        let actions = try XCTUnwrap(blocks.first { $0.type == SlackBlock.actions })
        let button = try XCTUnwrap(actions.elements?.first)
        XCTAssertEqual(button.action_id, token, """
            The button must carry the OPERATION id — it is what survives into the modal's \
            private_metadata and back out on submission.
            """)

        // The text still ships too: Slack shows `text` as the notification fallback.
        XCTAssertTrue(draft.text.contains("Which file?"))
    }

    // MARK: - Opening

    /// Mutation that must turn this red: drop `private_metadata` from the view.
    func testTheModalCarriesTheOperationInPrivateMetadata() throws {
        let view = SlackModalView(
            callbackID: "clarification_answer",
            privateMetadata: token,
            title: "Answer the agent",
            blocks: [SlackInputBlock(
                blockID: "answer_block",
                label: "Your answer",
                element: SlackPlainTextInput(actionID: "answer", placeholder: "Type your answer…")
            )]
        )
        let payload = SlackViewsOpenPayload(trigger_id: "trigger.123", view: view)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any])

        XCTAssertEqual(object["trigger_id"] as? String, "trigger.123")
        let viewObject = try XCTUnwrap(object["view"] as? [String: Any])
        XCTAssertEqual(viewObject["type"] as? String, "modal")
        XCTAssertEqual(viewObject["private_metadata"] as? String, token, """
            A modal is not in a channel, so a submission has no channel to infer from. \
            private_metadata is the only field that goes out with the view and returns untouched.
            """)

        // ⚠️ An INPUT block needs a `label` and a SINGULAR `element` — the two things `SlackBlock`
        // cannot express, which is why a separate outbound type exists.
        let blocks = try XCTUnwrap(viewObject["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["type"] as? String, "input")
        XCTAssertNotNil(blocks[0]["label"], "an input block without a label is rejected")
        let element = try XCTUnwrap(blocks[0]["element"] as? [String: Any])
        XCTAssertEqual(element["type"] as? String, "plain_text_input")
        XCTAssertEqual(element["action_id"] as? String, "answer")
        XCTAssertEqual(element["multiline"] as? Bool, true)
    }

    /// Slack rejects the whole `views.open` when title/submit/close exceed 24 characters, and the
    /// only symptom is a button that does nothing.
    func testTheModalTitleIsTruncatedToSlacksLimit() throws {
        let view = SlackModalView(
            callbackID: "c", privateMetadata: token,
            title: String(repeating: "T", count: 100),
            blocks: []
        )
        XCTAssertEqual(view.title.text.count, 24)
        XCTAssertEqual(view.submit.text, "Send")
        XCTAssertEqual(view.close.text, "Cancel")
    }

    // MARK: - The submission

    /// ⚠️ THE DROP THIS SLICE FIXES. A `view_submission` has no `actions` array, and the bridge's
    /// first line was `guard let action = payload.actions?.first else { return }` — so every modal
    /// submission was discarded, unlogged, before anything looked at it.
    ///
    /// Mutation that must turn this red: remove `view` from `SlackInteractivePayload`.
    func testASubmittedModalDecodesWithItsValuesAndCorrelation() throws {
        let json = """
        {
          "type": "view_submission",
          "user": {"id": "U1"},
          "view": {
            "callback_id": "clarification_answer",
            "private_metadata": "\(token)",
            "state": {"values": {"answer_block": {"answer": {"type": "plain_text_input", "value": "the second one"}}}}
          }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackInteractivePayload.self, from: json)
        XCTAssertEqual(payload.type, SlackInteractivePayload.viewSubmission)
        XCTAssertNil(payload.actions, "this is exactly why routing by `actions` dropped it")
        XCTAssertEqual(payload.view?.private_metadata, token)
        XCTAssertEqual(payload.submittedValue(blockID: "answer_block", actionID: "answer"),
                       "the second one")
        XCTAssertNil(payload.submittedValue(blockID: "answer_block", actionID: "not-a-field"),
                     "an unknown field reads as absent rather than as the first value found")
    }

    /// The metadata round-trips through the shared grammar, so the submission names its operation.
    func testTheReturnedMetadataNamesTheOperation() {
        guard case .answerClarification(let id) = ChatOpsCommand.parseCallbackData(token) else {
            return XCTFail("private_metadata must decode back to the clarification it answers")
        }
        XCTAssertEqual(id, operationID)
    }

    // MARK: - Failure reporting

    /// ⚠️ SLACK REJECTS A VIEW WITH HTTP 200. `ok: false` plus an `error` that names nothing
    /// ("invalid_arguments"), with the real detail in `response_metadata.messages` — which this app
    /// discarded entirely, making a malformed modal undebuggable from logs.
    ///
    /// ⚠️ Mutation that must turn this red: map `response_metadata` to a CodingKey Slack never
    /// sends. REMOVING the field does not compile — production reads it and so does this test — so
    /// the field's existence is compiler-protected and what this test actually guards is that it
    /// still decodes from the shape Slack really returns.
    func testARejectedViewCarriesTheReasonSlackActuallyGives() throws {
        let json = """
        {"ok": false, "error": "invalid_arguments",
         "response_metadata": {"messages": ["[ERROR] missing required field: title"]}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SlackAPIResponse<EmptyResponse>.self, from: json)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "invalid_arguments")
        XCTAssertEqual(response.response_metadata?.messages?.first,
                       "[ERROR] missing required field: title",
                       "without this the log says only `invalid_arguments`, which names nothing")
    }
}
