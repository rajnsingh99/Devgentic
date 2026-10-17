// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Shared fixtures for the local-inference coordinator tests.
//

import Foundation
import CoreGraphics
@testable import devgentic

enum LIFixtures {

    static func bot(_ provider: ApiProvider, _ model: String, baseURL: String? = nil, id: UUID = UUID()) -> BackendProfileModel {
        BackendProfileSnapshot(
            id: id, displayName: "Bot \(model)",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: provider, modelName: model, baseURL: baseURL))))
    }

    static func workflow(id: UUID = UUID()) -> BackendProfileModel {
        BackendProfileSnapshot(id: id, displayName: "Workflow", details: .workflow(WorkflowConfig()))
    }

    static func node(_ profile: BackendProfileModel) -> WorkflowNode {
        WorkflowNode(profileID: profile.id, position: .zero, displayName: profile.displayName,
                     profileType: profile.profileType)
    }

    static func classifier(model: String?, enabled: Bool = true) -> WorkflowNode {
        var config = ConditionNodeConfig()
        config.llmFallbackEnabled = enabled
        config.llmModelName = model
        return WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
    }

    static func layout(_ nodes: [WorkflowNode]) -> WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: [], annotations: [])
    }

    static func manifest(runID: UUID = UUID(),
                         origin: RunOrigin = .composer,
                         attended: Bool = true,
                         shape: RunShape = .single,
                         models: [ModelRequirement],
                         unresolvedNodes: Int = 0,
                         footprints: [String: UInt64] = [:]) -> InferenceRunManifest {
        InferenceRunManifest(runID: runID, conversationID: UUID(), origin: origin, attended: attended,
                             shape: shape, models: models, unresolvedNodes: unresolvedNodes,
                             footprints: footprints)
    }

    static let mlxQwen = ModelRequirement(engine: .mlx, modelID: "qwen", role: .primary)
    static let mlxLlama = ModelRequirement(engine: .mlx, modelID: "llama", role: .primary)
    static let claude = ModelRequirement(engine: .cloud(.anthropic), modelID: "claude", role: .primary)
}

/// A clock tests move by hand.
final class LIClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
