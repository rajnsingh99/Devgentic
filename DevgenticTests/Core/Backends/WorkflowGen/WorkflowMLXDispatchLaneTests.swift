// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh

import XCTest
@testable import devgentic

/// ⚠️ WF-CC2 — the partition key, tested in isolation from the executor.
///
/// `MLXService` keeps exactly ONE model container resident. `loadModel` calls `performUnload()`
/// before loading a DIFFERENT directory (MLXService.swift:246) but EARLY-RETURNS for the one
/// already resident (:215-219) and coalesces concurrent loads of the same directory (:210-212).
/// So two same-level nodes on different MLX models evict each other on every generation call,
/// while two on the SAME model share one container for free.
///
/// These are pure, synchronous tests over `profileDispatchLanes` — no executor, no async, no
/// model. They exist because the KEY is the part that is easy to get subtly wrong. Each wrong key
/// is caught, and the mapping below was MEASURED by running each mutation, not assumed:
///   - keying on `ApiProvider.isLocal` (sweeps in Ollama)
///         → `testOllamaNeverSplits`
///   - keying on the PROVIDER only, ignoring the model (under-partition: fails to split two
///     different models)
///         → `testTwoDistinctMLXModels_Split` + `testThreeDistinctModels_ThreeLanesInFirstSeenOrder`
///   - giving every MLX node its own lane (over-partition: serializes same-model siblings)
///         → `testOneMLXModel_SingleLane` + `testModelNameIsTrimmed_AndBlankBindsNoSlot`
///
/// ⚠️ Both DIRECTIONS are pinned deliberately. Under-partitioning leaves the bug; over-partitioning
/// is arguably worse, because it silently costs parallelism on a workload that was always safe.
final class WorkflowMLXDispatchLaneTests: XCTestCase {

    private func profile(_ name: String, _ provider: ApiProvider, _ model: String) -> BackendProfileModel {
        BackendProfileSnapshot(
            id: UUID(),
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: provider, modelName: model)))
        )
    }

    private func entry(_ name: String, _ provider: ApiProvider, _ model: String)
    -> (node: WorkflowNode, profile: BackendProfileModel) {
        let p = profile(name, provider, model)
        let node = WorkflowNode(
            kind: .profile(profileID: p.id, profileType: .bot),
            position: .zero,
            displayName: name
        )
        return (node, p)
    }

    private func names(_ lanes: [(slot: String?, members: [(node: WorkflowNode, profile: BackendProfileModel)])])
    -> [[String]] {
        lanes.map { $0.members.map(\.node.displayName) }
    }

    // MARK: - U1: the split itself

    func testTwoDistinctMLXModels_Split() {
        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("Cloud", .anthropic, "claude"),
            entry("Deep", .mlx, "qwen3-8b"),
            entry("Fast", .mlx, "llama3-3b")
        ])

        XCTAssertEqual(lanes.count, 2, "two DIFFERENT MLX models must be dispatched in two lanes")
        XCTAssertEqual(names(lanes), [["Cloud", "Deep"], ["Fast"]],
                       "the unconstrained cloud node rides with the FIRST MLX lane — it never touches the MLX slot, so it is exactly as safe beside 'Deep' as it would be alone, and this way it still overlaps real work")
        XCTAssertEqual(lanes[0].slot, "mlx:qwen3-8b")
        XCTAssertEqual(lanes[1].slot, "mlx:llama3-3b")
    }

    // MARK: - U2: DIFFERENT-model-only — the assertion that pins the whole design

    /// ⚠️ THE TEST THAT FORBIDS OVER-PARTITIONING. Serializing every MLX node — the intuitive
    /// reading of "MLX has one slot, so run MLX nodes one at a time" — would split this level for
    /// no reason: both nodes want the SAME model, so `MLXService.loadModel` early-returns for the
    /// second one (MLXService.swift:215-219) and nothing is ever evicted. Measured: mutating
    /// `mlxSlotKey(for:)` to return a per-profile key reddens exactly this test and
    /// `testModelNameIsTrimmed_AndBlankBindsNoSlot`.
    func testOneMLXModel_SingleLane() {
        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("Cloud", .openAI, "gpt"),
            entry("A", .mlx, "qwen3-8b"),
            entry("B", .mlx, "qwen3-8b")
        ])

        XCTAssertEqual(lanes.count, 1,
                       "same-model MLX siblings share ONE container (MLXService.swift:215-219) — splitting them costs parallelism for zero benefit")
        XCTAssertEqual(names(lanes), [["Cloud", "A", "B"]], "a single lane preserves input order exactly")
    }

    /// Whitespace must not manufacture a phantom second model.
    func testModelNameIsTrimmed_AndBlankBindsNoSlot() {
        XCTAssertEqual(WorkflowExecutor.mlxSlotKey(modelName: "  qwen3-8b  "), "mlx:qwen3-8b")
        XCTAssertNil(WorkflowExecutor.mlxSlotKey(modelName: "   "),
                     "an unconfigured model name binds no slot — it must not become its own lane")

        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("A", .mlx, "qwen3-8b"),
            entry("B", .mlx, " qwen3-8b ")
        ])
        XCTAssertEqual(lanes.count, 1, "the same model spelled with padding is the same model")
    }

    // MARK: - U3: Ollama is not MLX

    /// ⚠️ Ollama speaks HTTP to a separate server process that keeps several models resident and
    /// queues server-side. It has no in-process slot to contend for. Keying on
    /// `ApiProvider.isLocal` — which covers `.ollama` too — would serialize every workflow in the
    /// integration suite, since `addBotNode` defaults to `.ollama`.
    func testOllamaNeverSplits() {
        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("A", .ollama, "gemma"),
            entry("B", .ollama, "llama"),
            entry("C", .ollama, "mistral")
        ])

        XCTAssertEqual(lanes.count, 1, "Ollama has no single global slot — three different Ollama models must stay parallel")
        XCTAssertNil(lanes[0].slot)
    }

    func testCloudOnlyLevel_IsUntouched() {
        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("A", .anthropic, "claude"),
            entry("B", .openAI, "gpt")
        ])
        XCTAssertEqual(lanes.count, 1)
        XCTAssertNil(lanes[0].slot)
    }

    func testEmptyLevel_ProducesNoLanes() {
        XCTAssertTrue(WorkflowExecutor.profileDispatchLanes([]).isEmpty,
                      "an empty level must produce no lanes, not one empty lane that logs a split")
    }

    /// A workflow-typed profile resolves no LLM config at all, so it can never bind an MLX slot.
    func testWorkflowProfileBindsNoSlot() {
        let sub = BackendProfileSnapshot(
            id: UUID(),
            displayName: "Nested",
            details: .workflow(WorkflowConfig())
        )
        XCTAssertNil(WorkflowExecutor.mlxSlotKey(for: sub),
                     "`resolvedLLMConfig` is nil for .workflow — a sub-workflow node's demand lives in the CHILD layout")
    }

    /// Three distinct models produce three lanes, in first-seen order.
    func testThreeDistinctModels_ThreeLanesInFirstSeenOrder() {
        let lanes = WorkflowExecutor.profileDispatchLanes([
            entry("B", .mlx, "beta"),
            entry("A", .mlx, "alpha"),
            entry("B2", .mlx, "beta")
        ])
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(names(lanes), [["B", "B2"], ["A"]],
                       "lanes follow first-seen model order, and same-model nodes stay together in one parallel lane")
    }
}
