// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowVariableLintTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowVariableLintTests: XCTestCase {

    // MARK: - EXA-9 — the dead Executor conformance must refuse, and SETTLE

    /// ⚠️ EXA-9's only production BEHAVIOUR change, and it had no test. `ExecutorFactory.create`
    /// builds `WorkflowExecutor()` with a RANDOM `workflowProfileID`, so the old forwarding would
    /// have loaded an empty layout and reported `.emptyWorkflow` about a canvas that has nodes.
    ///
    /// ⚠️ The THROW is the load-bearing half. `ActiveStreamManager`'s workflow settle keys off the
    /// engine's own `.executionFinished(.failed)` and NOT off `.error` events, and its error-card
    /// fallback runs after the run-record settle — so yielding `.error` and finishing cleanly froze
    /// the run record GREEN while the chat message froze failed. Two surfaces, one turn,
    /// contradicting each other.
    func testTheDeadExecutorConformanceRefusesAndSettlesFailed() async {
        let executor = WorkflowExecutor()
        let input = AgentInput(
            userInput: "hi", chatHistory: [], conversationID: UUID(), tools: [],
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            generatorStrategy: MockCognitiveGenerator(),
            workingMemory: WindowedLinearMemory(
                config: MemoryBudgetConfig.derive(contextWindow: 8192, tier: .small)),
            rateLimitKey: "test", rateLimitCategory: .local, instructions: nil,
            traceContext: TraceContext(subAgentName: "test", provider: .anthropic))

        var events: [AgentStreamEvent] = []
        var thrown: Error?
        do {
            for try await event in executor.execute(model: MockLLMProvider(steps: []),
                                                    input: input, onTraceUpdate: { _ in }) {
                events.append(event)
            }
        } catch {
            thrown = error
        }

        XCTAssertNotNil(thrown, "a clean finish leaves the run record settling as a SUCCESS")
        XCTAssertTrue(events.contains {
            if case .executionFinished(let outcome, _) = $0 { return outcome == .failed }
            return false
        }, "the run record settles off this event, not off `.error`; got \(events.count) event(s)")
        XCTAssertTrue(events.contains {
            if case .error = $0 { return true }
            return false
        }, "…and the user still gets an error card")
    }

    // MARK: - The extraction rule the lint and the engine must share

    /// ⚠️ THE ORDERED UNION, and it is the whole reason this is one function rather than two.
    /// For `{{ var.result.status }}` an exact-key-only reader false-warns when the canvas writes
    /// `result`, and a first-segment-only reader false-warns when it writes `result.status`. Both
    /// names are authorable — `outputVariable` is an unvalidated free-text field — so the lint must
    /// consider both, in the resolver's order.
    func testADottedReferenceOffersTheExactKeyThenTheFirstSegment() {
        XCTAssertEqual(WorkflowTemplate.variableCandidates(for: "var.result.status"),
                       ["result.status", "result"])
    }

    func testASingleSegmentReferenceOffersOnlyItself() {
        XCTAssertEqual(WorkflowTemplate.variableCandidates(for: "var.status"), ["status"])
    }

    /// EIO-5's trim, one layer up. The regex strips the outer whitespace; this strips what the user
    /// typed INSIDE. Without it the lint extracts `" status"`, which no writer set contains, and
    /// false-warns on a template the engine resolves fine.
    func testWhitespaceInsideTheReferenceIsTrimmedExactlyAsTheResolverDoes() {
        XCTAssertEqual(WorkflowTemplate.variableCandidates(for: "var. status"), ["status"])
    }

    /// ⚠️ The input family must never be read as a variable, or every `{{ input.json.x }}` on the
    /// canvas becomes a spurious "no Code node writes it" warning.
    func testTheInputFamilyIsNotAVariableReference() {
        for expr in ["input", "input.json", "input.json.city", "notvar.x", "var.", "var.  "] {
            XCTAssertTrue(WorkflowTemplate.variableCandidates(for: expr).isEmpty, expr)
        }
    }

    func testEveryVariableReferenceInATemplateIsExtracted() {
        let names = WorkflowTemplate.referencedVariableNames(
            in: "{{ input }} then {{ var.a }} and {{ var.b.c }} and {{ input.json.d }}"
        )
        XCTAssertEqual(names, [["a"], ["b.c", "b"]],
                       "the input family is excluded; each var reference keeps its ordered list")
    }

    func testATemplateWithNoPlaceholdersExtractsNothing() {
        XCTAssertTrue(WorkflowTemplate.referencedVariableNames(in: "plain text").isEmpty)
        XCTAssertTrue(WorkflowTemplate.referencedVariableNames(in: "").isEmpty)
    }

    /// The extractor must agree with the RESOLVER, not merely with itself: whatever
    /// `variableCandidates` offers, one of those keys is what `render` actually reads.
    func testTheExtractedCandidatesAreTheKeysTheResolverActuallyReads() {
        let exact = WorkflowTemplate.render("{{ var.result.status }}", input: "",
                                            inputJSON: nil, variables: ["result.status": "EXACT"])
        XCTAssertEqual(exact, "EXACT", "the exact key wins, as candidate[0]")

        let segment = WorkflowTemplate.render("{{ var.result.status }}", input: "",
                                              inputJSON: nil, variables: ["result": #"{"status":"SEG"}"#])
        XCTAssertEqual(segment, "SEG", "…and candidate[1] is the JSON-path fallback")
    }

    // MARK: - [EIO-11] `{{ input.parsed… }}` — the explicit "parse my input as JSON" form

    /// ⚠️ THE ROW. At a TOP-LEVEL entry node nothing upstream produced structured output, so
    /// `inputJSON` is nil and `{{ input.json.city }}` leaves its literal text in the output. The
    /// author can now say so explicitly instead.
    func testParsedReadsAFieldOutOfTheInputTextItself() {
        let rendered = WorkflowTemplate.render(
            "City is {{ input.parsed.city }}",
            input: #"{"city":"NYC"}"#, inputJSON: nil, variables: [:])
        XCTAssertEqual(rendered, "City is NYC")
    }

    func testParsedWithNoPathYieldsTheWholeDocument() {
        let rendered = WorkflowTemplate.render(
            "{{ input.parsed }}", input: #"{"a":1}"#, inputJSON: nil, variables: [:])
        XCTAssertEqual(rendered, #"{"a":1}"#)
    }

    func testParsedResolvesNestedAndIndexedPaths() {
        let rendered = WorkflowTemplate.render(
            "{{ input.parsed.items.1.name }}",
            input: #"{"items":[{"name":"a"},{"name":"b"}]}"#, inputJSON: nil, variables: [:])
        XCTAssertEqual(rendered, "b")
    }

    /// ⚠️ THE FAIL-LOUD CONTRACT, which is the reason this is a separate expression rather than a
    /// change to `input.json`'s meaning. Unparseable input, or a path that is not there, leaves the
    /// placeholder verbatim AND reports it — so `WorkflowActionArgs` still logs the EIO-6 warning
    /// and the tool still rejects the literal, exactly as before.
    func testParsedFailsLoudlyOnUnparseableInputOrAMissingPath() {
        let unparseable = WorkflowTemplate.renderReportingUnresolved(
            "{{ input.parsed.city }}", input: "just prose", inputJSON: nil, variables: [:])
        XCTAssertEqual(unparseable.rendered, "{{ input.parsed.city }}")
        XCTAssertEqual(unparseable.unresolved, ["input.parsed.city"])

        let missingPath = WorkflowTemplate.renderReportingUnresolved(
            "{{ input.parsed.town }}", input: #"{"city":"NYC"}"#, inputJSON: nil, variables: [:])
        XCTAssertEqual(missingPath.rendered, "{{ input.parsed.town }}")
        XCTAssertEqual(missingPath.unresolved, ["input.parsed.town"])
    }

    /// ⚠️ `input.json` KEEPS ITS MEANING — "a producing upstream declared this JSON". The whole
    /// point of the separate expression is that adding it changes nothing about the existing one,
    /// so the four in-app help strings that define it stay true.
    func testInputJSONStillMeansUpstreamDeclaredOutputAndIsNotAffected() {
        let entryNode = WorkflowTemplate.renderReportingUnresolved(
            "{{ input.json.city }}", input: #"{"city":"NYC"}"#, inputJSON: nil, variables: [:])
        XCTAssertEqual(entryNode.rendered, "{{ input.json.city }}",
                       "⚠️ do NOT make this resolve — that is the implicit rule the row rejected")
        XCTAssertEqual(entryNode.unresolved, ["input.json.city"])

        let withUpstream = WorkflowTemplate.render(
            "{{ input.json.city }}", input: "ignored",
            inputJSON: JSONValue.parseStructured(#"{"city":"LDN"}"#), variables: [:])
        XCTAssertEqual(withUpstream, "LDN", "…and the declared-JSON path is untouched")
    }

    /// The two are independent: a node can read a declared upstream field AND its own input text.
    func testBothFormsCoexistInOneTemplate() {
        let rendered = WorkflowTemplate.render(
            "{{ input.json.a }}/{{ input.parsed.b }}",
            input: #"{"b":"two"}"#,
            inputJSON: JSONValue.parseStructured(#"{"a":"one"}"#), variables: [:])
        XCTAssertEqual(rendered, "one/two")
    }

    /// ⚠️ THE SEPARATOR IS LOAD-BEARING, and a mutant dropping it survived the first battery.
    /// `hasPrefix("input.parsed")` without the dot lets a NEAR-MISS token into the path arm, where
    /// `dropFirst("input.parsed.".count)` slices off one character too many and resolves whatever
    /// tail is left — so `{{ input.parsedcity }}` silently reads the field `ty`, or nothing, rather
    /// than failing loudly. That is precisely the fail-loud contract this expression exists to keep.
    func testANearMissTokenFailsLoudlyInsteadOfResolvingGarbage() {
        for expr in ["input.parsedcity", "input.parsedX", "input.parsed_city"] {
            let result = WorkflowTemplate.renderReportingUnresolved(
                "{{ \(expr) }}", input: #"{"city":"NYC","ty":"trap"}"#,
                inputJSON: nil, variables: [:])
            XCTAssertEqual(result.rendered, "{{ \(expr) }}", expr)
            XCTAssertEqual(result.unresolved, [expr], expr)
        }
    }

    /// It is not a variable reference, so the EXA-10 lint must stay silent about it.
    func testParsedIsNotMistakenForAVariableReference() {
        XCTAssertTrue(WorkflowTemplate.variableCandidates(for: "input.parsed").isEmpty)
        XCTAssertTrue(WorkflowTemplate.variableCandidates(for: "input.parsed.city").isEmpty)
        XCTAssertTrue(WorkflowTemplate.referencedVariableNames(in: "{{ input.parsed.city }}").isEmpty)
    }

    // MARK: - The verdict

    private let levels: [String: [Int]] = ["written": [0], "late": [2]]
    private var writers: Set<String> { ["written", "late"] }

    func testAReferenceToAVariableNothingWritesIsNeverWritten() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["staus"], writtenVariables: writers,
                readerLevel: 1, variableWriterLevels: levels),
            .neverWritten)
    }

    func testAReferenceToAnEarlierWriterIsFine() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["written"], writtenVariables: writers,
                readerLevel: 1, variableWriterLevels: levels),
            .ok)
    }

    /// EXA-5's shape: the writer exists but runs on the reader's own level, so the read resolves to
    /// nothing on EVERY run — deterministically, not as a race.
    func testASameLevelWriterIsWrittenTooLate() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["written"], writtenVariables: writers,
                readerLevel: 0, variableWriterLevels: levels),
            .writtenTooLate(name: "written", earliestWriterLevel: 0))
    }

    /// ⚠️ THE FALSE-POSITIVE GUARD, half one. `{{ var.result.status }}` with `result` written is a
    /// canvas that RUNS — an exact-key-only lint warns on it.
    func testADottedReferenceSatisfiedByItsFirstSegmentIsNotWarnedAbout() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: WorkflowTemplate.variableCandidates(for: "var.result.status"),
                writtenVariables: ["result"], readerLevel: 1,
                variableWriterLevels: ["result": [0]]),
            .ok)
    }

    /// ⚠️ THE FALSE-POSITIVE GUARD, half two. The same reference with the DOTTED name written is
    /// also a canvas that runs — a first-segment-only lint warns on this one instead.
    func testADottedReferenceSatisfiedByTheExactKeyIsNotWarnedAbout() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: WorkflowTemplate.variableCandidates(for: "var.result.status"),
                writtenVariables: ["result.status"], readerLevel: 1,
                variableWriterLevels: ["result.status": [0]]),
            .ok)
    }

    /// ⚠️⚠️ THIS TEST PINNED A FALSE POSITIVE, and its old rationale ("the engine reads the exact
    /// key") misdescribed the engine. The resolver reads the first candidate PRESENT IN THE
    /// SNAPSHOT, not the first one written somewhere on the canvas: a same-level write is never in
    /// the snapshot, so `variables["result.status"]` is absent, the first-segment JSON-path
    /// fallback fires, and the template renders. The canvas below RUNS — warning about it is the
    /// exact failure this file's own header calls the dominant risk. Do not re-invert this.
    func testAVisibleCandidateMakesTheReferenceFineEvenIfAnotherIsWrittenTooLate() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["result.status", "result"],
                writtenVariables: ["result.status", "result"], readerLevel: 1,
                variableWriterLevels: ["result.status": [1], "result": [0]]),
            .ok,
            "the level-0 `result` write IS visible, and the resolver falls back to it")
    }

    /// The mirror: when NO candidate is visible, the warning must name the candidate the verdict
    /// actually matched — never the text the user typed under another name's level.
    func testWhenNoCandidateIsVisibleTheWarningNamesTheMatchedCandidate() {
        let verdict = WorkflowValidator.variableReferenceVerdict(
            candidates: WorkflowTemplate.variableCandidates(for: "var.result.status"),
            writtenVariables: ["result"], readerLevel: 0,
            variableWriterLevels: ["result": [0]])

        XCTAssertEqual(verdict, .writtenTooLate(name: "result", earliestWriterLevel: 0),
                       "the only written candidate is the first SEGMENT, so that is what to name")

        let message = WorkflowValidator.variableReferenceMessage(
            verdict: verdict, site: .codeTemplate, typedName: "result.status", readerLevel: 0)
        XCTAssertTrue(message?.contains("variable 'result'") ?? false,
                      "naming 'result.status' sends the user hunting for a Code node that does not "
                      + "exist; got: \(message ?? "nil")")
    }

    /// ⚠️ A CYCLIC layout has no levels at all, so ordering is unknowable. Saying "runs at the same
    /// time as this node" there is a fabricated diagnosis with a remedy pointing away from the real
    /// problem — and the panel does not even mention the cycle. Same opt-out the WF-CC2 contention
    /// rule takes.
    func testAnUnknownReaderLevelSaysNothingAboutOrdering() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["written"], writtenVariables: writers,
                readerLevel: nil, variableWriterLevels: levels),
            .ok, "ordering is unknowable on a cycle")

        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: ["staus"], writtenVariables: writers,
                readerLevel: nil, variableWriterLevels: levels),
            .neverWritten, "…but a name nothing writes is still worth saying")
    }

    /// A writer that runs STRICTLY LATER is not the same advice as a same-level writer, and the
    /// branch that says so had no test — the `late` fixture existed for it and was never used.
    func testAStrictlyLaterWriterIsDescribedAsAfterNotAtTheSameTime() {
        let verdict = WorkflowValidator.variableReferenceVerdict(
            candidates: ["late"], writtenVariables: writers,
            readerLevel: 0, variableWriterLevels: levels)
        XCTAssertEqual(verdict, .writtenTooLate(name: "late", earliestWriterLevel: 2))

        let message = WorkflowValidator.variableReferenceMessage(
            verdict: verdict, site: .codeTemplate, typedName: "late", readerLevel: 0)
        XCTAssertTrue(message?.contains("after this node") ?? false, "got: \(message ?? "nil")")
        XCTAssertFalse(message?.contains("at the same time") ?? true)
    }

    // MARK: - The consequence is per SURFACE, even though the decision is shared

    /// ⚠️ THE REGRESSION THIS CAUGHT. Sharing the decision is right; sharing the SENTENCE was not.
    /// A Router rule has no placeholder — the engine does `state.variables[key] ?? ""` — so telling
    /// the user "the placeholder text is left in place" described a mechanism that does not exist
    /// there, and dropped the one fact that matters: an always-empty comparison makes the negative
    /// operators match unconditionally.
    func testEachSurfaceGetsItsOwnConsequence() {
        let router = WorkflowValidator.variableReferenceMessage(
            verdict: .neverWritten, site: .routerRule(label: "R1"),
            typedName: "status", readerLevel: 0)
        XCTAssertTrue(router?.hasPrefix("Rule 'R1'") ?? false)
        XCTAssertTrue(router?.contains("compared as an empty string") ?? false, "got: \(router ?? "nil")")
        XCTAssertFalse(router?.contains("placeholder") ?? true,
                       "a Router rule has no placeholder to leave in place")

        let template = WorkflowValidator.variableReferenceMessage(
            verdict: .neverWritten, site: .codeTemplate, typedName: "status", readerLevel: 0)
        XCTAssertTrue(template?.contains("placeholder text is left in this node's output") ?? false)

        let argument = WorkflowValidator.variableReferenceMessage(
            verdict: .neverWritten, site: .actionArgument(name: "url"),
            typedName: "status", readerLevel: 0)
        XCTAssertTrue(argument?.hasPrefix("Argument 'url'") ?? false)
        XCTAssertTrue(argument?.contains("the tool receives the literal placeholder text") ?? false)
    }

    func testAnEmptyCandidateListSaysNothing() {
        XCTAssertEqual(
            WorkflowValidator.variableReferenceVerdict(
                candidates: [], writtenVariables: [], readerLevel: 0, variableWriterLevels: [:]),
            .ok, "a non-variable placeholder must not produce a variable warning")
    }

    // MARK: - End to end on a real canvas

    @MainActor
    private func codeNode(_ name: String, template: String = "", writes: String? = nil,
                          at x: CGFloat) -> WorkflowNode {
        var config = CodeNodeConfig()
        config.template = template
        config.outputVariable = writes
        return WorkflowNode(kind: .code(config), position: CGPoint(x: x, y: 0), displayName: name)
    }

    /// ⚠️ THE FILED ROW. Two Code nodes fanning out from one entry land on the SAME level — the
    /// default outcome of the obvious canvas, because levelling is by in-degree peel and not by
    /// where the user drew things. Before this fix the panel said "Workflow Ready".
    @MainActor
    func testASameLevelVariableReadInACodeTemplateIsWarnedAbout() {
        let entry = codeNode("Entry", template: "{{ input }}", at: 0)
        let writer = codeNode("Writer", template: "{{ input }}", writes: "status", at: 300)
        let reader = codeNode("Reader", template: "Status is {{ var.status }}", at: 300)
        let layout = WorkflowLayout(
            nodes: [entry, writer, reader],
            edges: [WorkflowEdge(sourceNodeID: entry.id, targetNodeID: writer.id),
                    WorkflowEdge(sourceNodeID: entry.id, targetNodeID: reader.id)],
            annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let issue = issues.first { $0.nodeID == reader.id && $0.message.contains("variable 'status'") }

        XCTAssertNotNil(issue, "the reader must be told its writer runs at the same time; got: "
                        + issues.map(\.message).joined(separator: " | "))
        XCTAssertEqual(issue?.severity, .warning,
                       "⚠️ never .error — the executor refuses to run on any error-severity issue")
        XCTAssertTrue(issue?.message.contains("at the same time as this node") ?? false)
    }

    /// A plain TYPO — the cheaper, higher-frequency half the row did not name. It was silent in a
    /// Code template while the identical typo in a Router rule was warned.
    @MainActor
    func testATypoedVariableInACodeTemplateIsWarnedAbout() {
        let writer = codeNode("Writer", template: "{{ input }}", writes: "status", at: 0)
        let reader = codeNode("Reader", template: "{{ var.staus }}", at: 300)
        let layout = WorkflowLayout(
            nodes: [writer, reader],
            edges: [WorkflowEdge(sourceNodeID: writer.id, targetNodeID: reader.id)],
            annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let issue = issues.first { $0.nodeID == reader.id && $0.message.contains("'staus'") }

        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.message.contains("no Code node on this canvas writes it") ?? false)
    }

    /// ⚠️ THE CANVAS THAT RUNS. A correctly wired writer→reader chain must stay silent, or the
    /// warning is worse than the bug.
    @MainActor
    func testACorrectlyWiredVariableReadIsNotWarnedAbout() {
        let writer = codeNode("Writer", template: "{{ input }}", writes: "status", at: 0)
        let reader = codeNode("Reader", template: "{{ var.status }}", at: 300)
        let layout = WorkflowLayout(
            nodes: [writer, reader],
            edges: [WorkflowEdge(sourceNodeID: writer.id, targetNodeID: reader.id)],
            annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertNil(issues.first { $0.message.contains("variable 'status'") },
                     "an upstream writer is visible; warning here teaches people to ignore the panel")
    }

    /// An Action node renders N bindings, not one — and the message names WHICH argument, matching
    /// `WorkflowActionArgs`' runtime line so design time and run time read as one system.
    @MainActor
    func testAVariableReadInAnActionBindingIsWarnedAboutAndNamesTheArgument() {
        var action = ActionNodeConfig()
        action.argumentBindings = ["url": "https://api/x?s={{ var.staus }}", "body": "{{ input }}"]
        let node = WorkflowNode(kind: .action(action), position: .zero, displayName: "A1")
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let issue = issues.first { $0.message.contains("'staus'") }

        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.message.hasPrefix("Argument 'url'") ?? false,
                      "got: \(issue?.message ?? "nil")")
        XCTAssertEqual(issue?.severity, .warning)
    }

    /// ⚠️ THE ROUTER SURFACE — the only one whose user-visible behaviour changed for EXISTING
    /// canvases, and the one with no coverage until the cold read pointed it out. Drop the
    /// `readerLevel:`/`variableWriterLevels:` arguments back to a membership-only check and every
    /// other test in the repo still passes.
    @MainActor
    func testASameLevelVariableReadInARouterRuleIsWarnedAbout() {
        let entry = codeNode("Entry", template: "{{ input }}", at: 0)
        let writer = codeNode("Writer", template: "{{ input }}", writes: "status", at: 300)
        let rule = ConditionRule(label: "go", field: .variable, op: .isNotEmpty,
                                 value: "", variableName: "status")
        var config = ConditionNodeConfig()
        config.rules = [rule]
        let router = WorkflowNode(kind: .condition(config), position: CGPoint(x: 300, y: 200),
                                  displayName: "R1")
        let layout = WorkflowLayout(
            nodes: [entry, writer, router],
            edges: [WorkflowEdge(sourceNodeID: entry.id, targetNodeID: writer.id),
                    WorkflowEdge(sourceNodeID: entry.id, targetNodeID: router.id)],
            annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let issue = issues.first { $0.nodeID == router.id && $0.message.contains("variable 'status'") }

        XCTAssertNotNil(issue, "got: " + issues.map(\.message).joined(separator: " | "))
        XCTAssertTrue(issue?.message.contains("at the same time as this node") ?? false)
        XCTAssertTrue(issue?.message.contains("compared as an empty string") ?? false,
                      "the Router keeps its OWN consequence: \(issue?.message ?? "nil")")
        XCTAssertEqual(issue?.severity, .warning)
    }

    /// ⚠️ One mistake, one row. Repeated references produced N byte-identical warnings and an
    /// inflated "N issues" header — the credibility spend this rule exists to prevent, arriving
    /// through the rule itself.
    @MainActor
    func testRepeatedReferencesToTheSameVariableProduceOneWarning() {
        let reader = codeNode("Reader", template: "{{ var.staus }} then {{ var.staus }} and {{var.staus}}", at: 0)
        let layout = WorkflowLayout(nodes: [reader], edges: [], annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertEqual(issues.filter { $0.message.contains("'staus'") }.count, 1)
    }

    /// …but the same variable in two different ARGUMENTS is two facts, each naming its argument.
    @MainActor
    func testTheSameVariableInTwoArgumentsWarnsOncePerArgument() {
        var action = ActionNodeConfig()
        action.argumentBindings = ["url": "{{ var.staus }}", "body": "{{ var.staus }}"]
        let node = WorkflowNode(kind: .action(action), position: .zero, displayName: "A1")
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let named = issues.filter { $0.message.contains("'staus'") }

        XCTAssertEqual(named.count, 2)
        XCTAssertTrue(named.contains { $0.message.hasPrefix("Argument 'url'") })
        XCTAssertTrue(named.contains { $0.message.hasPrefix("Argument 'body'") })
    }

    /// ⚠️ A CYCLIC canvas has no levels, so every node falls to "unknown". The sentinel used to make
    /// EVERY variable report "runs at the same time as this node" while the panel said nothing at
    /// all about the cycle — a fabricated diagnosis whose remedy points away from the real problem.
    @MainActor
    func testACyclicCanvasIsNotToldItsVariablesRunAtTheSameTime() {
        let a = codeNode("A", template: "{{ var.status }}", at: 0)
        let b = codeNode("B", template: "{{ input }}", writes: "status", at: 300)
        let layout = WorkflowLayout(
            nodes: [a, b],
            edges: [WorkflowEdge(sourceNodeID: a.id, targetNodeID: b.id),
                    WorkflowEdge(sourceNodeID: b.id, targetNodeID: a.id)],
            annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertNil(issues.first { $0.message.contains("at the same time as this node") },
                     "got: " + issues.map(\.message).joined(separator: " | "))
    }

    /// `{{ input.json.x }}` in a binding is not a variable read. If this fires, every Action node
    /// on a canvas gets a spurious warning.
    @MainActor
    func testAnInputJSONBindingIsNotReportedAsAVariable() {
        var action = ActionNodeConfig()
        action.argumentBindings = ["city": "{{ input.json.city }}"]
        let node = WorkflowNode(kind: .action(action), position: .zero, displayName: "A1")
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertNil(issues.first { $0.message.contains("reads variable") })
    }
}
