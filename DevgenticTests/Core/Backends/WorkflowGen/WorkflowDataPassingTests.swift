//
//  WorkflowDataPassingTests.swift
//  DevgenticTests
//
//  Unit tests for structured-data + artifact passing between workflow nodes:
//    • JSONValue structured parsing, path access, and template rendering
//    • WorkflowTemplate placeholder resolution ({{ input }}, {{ input.json.path }},
//      {{ var.name }}, {{ var.name.path }}) including injection safety
//    • WorkflowInputAssembler artifact manifest rendering
//
//  Pure-logic tests — no LLM, network, or filesystem (manifest uses in-memory
//  references; document extraction is covered by integration tests).
//

import XCTest
@testable import devgentic

final class WorkflowDataPassingTests: XCTestCase {

    // MARK: - JSONValue.parseStructured

    func testParseStructuredAcceptsObjectAndArray() {
        XCTAssertNotNil(JSONValue.parseStructured(#"{"a":1}"#))
        XCTAssertNotNil(JSONValue.parseStructured(#"[1,2,3]"#))
    }

    func testParseStructuredRejectsScalarsAndText() {
        // Bare scalars are *text*, not structured payloads.
        XCTAssertNil(JSONValue.parseStructured("42"))
        XCTAssertNil(JSONValue.parseStructured("\"quoted\""))
        XCTAssertNil(JSONValue.parseStructured("true"))
        XCTAssertNil(JSONValue.parseStructured("hello world"))
        XCTAssertNil(JSONValue.parseStructured(""))
        XCTAssertNil(JSONValue.parseStructured("   "))
    }

    func testParseStructuredStripsMarkdownFence() {
        let v = JSONValue.parseStructured("```json\n{\"x\":1}\n```")
        XCTAssertEqual(v?.value(atDotPath: "x")?.intValue, 1)
    }

    func testParseStructuredDetectsFencedJSONInProse() {
        // Chatty model: explanation, then a fenced payload.
        let v = JSONValue.parseStructured("Here is the result:\n```json\n{\"x\":7}\n```")
        XCTAssertEqual(v?.value(atDotPath: "x")?.intValue, 7)

        let bare = JSONValue.parseStructured("Done.\n```\n[1,2,3]\n```")
        XCTAssertEqual(bare?.value(atDotPath: "2")?.intValue, 3)
    }

    func testParseStructuredDoesNotFalsePositiveOnProseBraces() {
        // Incidental braces in prose (no fence) must NOT be treated as structured.
        XCTAssertNil(JSONValue.parseStructured("the set {a, b} is nice"))
        // A fenced block that isn't JSON is also not structured.
        XCTAssertNil(JSONValue.parseStructured("text\n```\nnot json\n```"))
    }

    func testParseStructuredRejectsMalformed() {
        XCTAssertNil(JSONValue.parseStructured("{not valid json"))
    }

    // MARK: - JSONValue path access

    func testValueAtPathNavigatesObjectsAndArrays() {
        let j = JSONValue.parseStructured(#"{"a":{"b":[10,20,30]},"name":"chart"}"#)
        XCTAssertEqual(j?.value(atDotPath: "a.b.1")?.intValue, 20)
        XCTAssertEqual(j?.value(atDotPath: "name")?.stringValue, "chart")
    }

    func testValueAtPathReturnsNilForMissingOrOutOfBounds() {
        let j = JSONValue.parseStructured(#"{"a":{"b":[10]}}"#)
        XCTAssertNil(j?.value(atDotPath: "a.z"))      // missing key
        XCTAssertNil(j?.value(atDotPath: "a.b.9"))    // out-of-bounds index
        XCTAssertNil(j?.value(atDotPath: "a.b.x"))    // non-numeric index into array
    }

    // MARK: - JSONValue.templateString

    func testTemplateStringRendersScalarsNaturally() {
        XCTAssertEqual(JSONValue.number(20).templateString, "20")      // no trailing .0
        XCTAssertEqual(JSONValue.number(2.5).templateString, "2.5")
        XCTAssertEqual(JSONValue.bool(true).templateString, "true")
        XCTAssertEqual(JSONValue.string("hi").templateString, "hi")
        XCTAssertEqual(JSONValue.null.templateString, "")
    }

    func testTemplateStringRendersContainersAsCompactJSON() {
        let obj = JSONValue.object(["k": .string("v")])
        XCTAssertEqual(obj.templateString, #"{"k":"v"}"#)
    }

    // MARK: - WorkflowTemplate

    func testRenderInputAndVariables() {
        XCTAssertEqual(
            WorkflowTemplate.render("X={{ input }}", input: "up", inputJSON: nil, variables: [:]),
            "X=up"
        )
        XCTAssertEqual(
            WorkflowTemplate.render("{{ var.k }}", input: "", inputJSON: nil, variables: ["k": "VAL"]),
            "VAL"
        )
        // Unspaced form stays backward-compatible.
        XCTAssertEqual(
            WorkflowTemplate.render("{{input}}", input: "u", inputJSON: nil, variables: [:]),
            "u"
        )
    }

    func testRenderJSONPaths() {
        let j = JSONValue.parseStructured(#"{"a":{"b":[10,20,30]}}"#)
        XCTAssertEqual(
            WorkflowTemplate.render("v={{ input.json.a.b.2 }}", input: "", inputJSON: j, variables: [:]),
            "v=30"
        )
        // Variable holding JSON text → path access via lazy parse.
        XCTAssertEqual(
            WorkflowTemplate.render("{{ var.obj.k }}", input: "", inputJSON: nil, variables: ["obj": #"{"k":"hit"}"#]),
            "hit"
        )
    }

    func testRenderLeavesUnresolvedPlaceholdersVerbatim() {
        XCTAssertEqual(
            WorkflowTemplate.render("{{ var.missing }}", input: "", inputJSON: nil, variables: [:]),
            "{{ var.missing }}"
        )
    }

    func testRenderExactDottedKeyTakesPrecedenceOverPath() {
        // A variable whose literal name contains a dot still resolves by exact match.
        XCTAssertEqual(
            WorkflowTemplate.render("{{ var.a.b }}", input: "", inputJSON: nil, variables: ["a.b": "literal"]),
            "literal"
        )
    }

    func testRenderIsInjectionSafe() {
        // Upstream text that *looks* like a placeholder must not be re-scanned and
        // must not pull in a variable value — single-pass over the original template.
        XCTAssertEqual(
            WorkflowTemplate.render(
                "{{ input }}",
                input: "danger {{ var.secret }}",
                inputJSON: nil,
                variables: ["secret": "LEAK"]
            ),
            "danger {{ var.secret }}"
        )
    }

    // MARK: - WorkflowInputAssembler artifact manifest

    func testArtifactManifestListsKindLabelMimeAndLocator() {
        let artifact = MediaArtifact(
            kind: .image,
            reference: .diskPath(URL(fileURLWithPath: "/tmp/chart.png")),
            mimeType: "image/png",
            label: "Sales chart"
        )
        let manifest = WorkflowInputAssembler.renderArtifactManifest([artifact])
        XCTAssertTrue(manifest.contains("image"))
        XCTAssertTrue(manifest.contains("Sales chart"))
        XCTAssertTrue(manifest.contains("image/png"))
        XCTAssertTrue(manifest.contains("/tmp/chart.png"))
    }

    func testArtifactManifestEmptyForNoArtifacts() {
        XCTAssertEqual(WorkflowInputAssembler.renderArtifactManifest([]), "")
    }

    // MARK: - WorkflowActionArgs (Action node argument assembly)

    private func schema(_ props: [String: String], required: [String] = []) -> ToolParameters {
        ToolParameters(
            type: "object",
            properties: props.mapValues { ToolParameterProperty(type: $0, description: nil, items: nil) },
            required: required
        )
    }

    func testActionArgsCoercesTypesAndResolvesTemplates() throws {
        let data = WorkflowActionArgs.build(
            bindings: ["url": "https://x.test", "body": "{{ input }}", "retries": "3", "verbose": "true"],
            schema: schema(["url": "string", "body": "string", "retries": "integer", "verbose": "boolean"]),
            input: "payload",
            inputJSON: nil,
            variables: [:]
        )
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(obj["url"]?.stringValue, "https://x.test")
        XCTAssertEqual(obj["body"]?.stringValue, "payload")        // {{ input }} resolved
        XCTAssertEqual(obj["retries"]?.intValue, 3)                 // integer coercion
        XCTAssertEqual(obj["verbose"]?.boolValue, true)            // boolean coercion
    }

    func testActionArgsOmitsUnboundArguments() throws {
        let data = WorkflowActionArgs.build(
            bindings: ["url": "https://x.test", "timeout": "   "],  // whitespace = unbound
            schema: schema(["url": "string", "timeout": "integer"]),
            input: "",
            inputJSON: nil,
            variables: [:]
        )
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertNotNil(obj["url"])
        XCTAssertNil(obj["timeout"])  // omitted, not sent as ""
    }

    func testActionArgsBindsFromJSONPathAndVariables() throws {
        let json = JSONValue.parseStructured(#"{"user":{"id":42}}"#)
        let data = WorkflowActionArgs.build(
            bindings: ["id": "{{ input.json.user.id }}", "key": "{{ var.token }}"],
            schema: schema(["id": "integer", "key": "string"]),
            input: "",
            inputJSON: json,
            variables: ["token": "secret123"]
        )
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(obj["id"]?.intValue, 42)
        XCTAssertEqual(obj["key"]?.stringValue, "secret123")
    }
}
