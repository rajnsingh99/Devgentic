// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InferenceRunManifest.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Engine and model

/// Where a model runs. Only `.mlx` and `.ollama` share this machine's memory and GPU.
enum InferenceEngine: Hashable, Sendable, CustomStringConvertible {
    case mlx
    /// The server URL is part of the identity: two Ollama servers are two machines' worth of memory.
    case ollama(baseURL: String)
    case cloud(ApiProvider)

    var isLocal: Bool {
        switch self {
        case .mlx, .ollama: return true
        case .cloud: return false
        }
    }

    var description: String {
        switch self {
        case .mlx: return "mlx"
        case .ollama(let url): return "ollama(\(url))"
        case .cloud(let provider): return "cloud(\(provider.providerString))"
        }
    }

    /// The engine a provider config runs on. `.openAICompatible` is cloud even when it points at localhost (LM Studio):
    /// the app does not manage that server's memory, matching `ApiProvider.isLocal`.
    static func of(_ config: ProviderConfig) -> InferenceEngine {
        switch config.apiProvider {
        case .mlx:
            return .mlx
        case .ollama:
            return .ollama(baseURL: normalizedOllamaURL(config.baseURL))
        case .openAI, .anthropic, .google, .openRouter, .openAICompatible:
            return .cloud(config.apiProvider)
        }
    }

    /// `nil`, empty and a trailing slash all mean the same server.
    static func normalizedOllamaURL(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? ProviderDefaults.ollamaBaseURL.absoluteString : trimmed
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}

/// Why a run touches a model. Logged; not yet used by the policy.
enum ModelRole: String, Sendable {
    case primary
    case workflowNode
    case classifier
    /// The Core Intelligence model, used by a background feature (Briefing, User Personal).
    case intelligenceCore
}

struct ModelRequirement: Hashable, Sendable, CustomStringConvertible {
    let engine: InferenceEngine
    /// MLX display name, Ollama tag, or cloud model name. Trimmed, so two spellings that differ only in
    /// whitespace are one model — the same rule `WorkflowExecutor.mlxSlotKey` applies.
    let modelID: String
    let role: ModelRole

    init(engine: InferenceEngine, modelID: String, role: ModelRole) {
        self.engine = engine
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
    }

    /// Engine + model, without the role: the identity residency cares about.
    var residencyKey: String { "\(engine)/\(modelID)" }

    var description: String { "\(modelID) [\(engine), \(role.rawValue)]" }
}

// MARK: - Origin and priority

/// Which surface started a run. Derived from `MessageSource` + the profile, because neither alone
/// can tell a Code send from a chat send, or a regenerate from a fresh question.
enum RunOrigin: Equatable, Sendable, CustomStringConvertible {
    case composer
    case code
    case workflow
    case chatOps(MessageSource)
    case orb
    case quickAccess
    case scheduled
    case backgroundTask
    case regenerate
    case resume
    /// A background Core Intelligence feature with no conversation (decision D7). Never derived from
    /// a message — built by `LocalInferenceCoordinator.runBackgroundIntelligence`.
    case intelligence(String)

    var description: String {
        switch self {
        case .composer: return "composer"
        case .code: return "code"
        case .workflow: return "workflow"
        case .chatOps(let source): return "chatOps(\(source.rawValue))"
        case .orb: return "orb"
        case .quickAccess: return "quickAccess"
        case .scheduled: return "scheduled"
        case .backgroundTask: return "backgroundTask"
        case .regenerate: return "regenerate"
        case .resume: return "resume"
        case .intelligence(let feature): return "intelligence(\(feature))"
        }
    }

    /// Regenerate and resume win over the source: both are a button the user just pressed, so the user is waiting
    /// regardless of which surface first asked.
    static func derive(source: MessageSource,
                       profileType: ProfileType,
                       isRegeneration: Bool,
                       isResume: Bool) -> RunOrigin {
        if isResume { return .resume }
        if isRegeneration { return .regenerate }
        switch source {
        case .telegram, .discord, .slack: return .chatOps(source)
        case .orb: return .orb
        case .quickAccess: return .quickAccess
        case .scheduled: return .scheduled
        case .backgroundTask: return .backgroundTask
        case .localUI:
            switch profileType {
            case .code: return .code
            case .workflow: return .workflow
            default: return .composer
            }
        }
    }
}

/// Queue order, highest first.
enum PriorityClass: Int, Comparable, Sendable, CustomStringConvertible {
    /// A run taking the lock back after a HITL answer (P4). Never produced in shadow mode.
    case resumedAfterHITL = 0
    case attended = 1
    case remote = 2
    case unattended = 3
    /// Briefing and User Personal.
    case backgroundIC = 4

    static func < (lhs: PriorityClass, rhs: PriorityClass) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .resumedAfterHITL: return "P0-resumed"
        case .attended: return "P1-attended"
        case .remote: return "P2-remote"
        case .unattended: return "P3-unattended"
        case .backgroundIC: return "P4-backgroundIC"
        }
    }

    /// ChatOps is checked before attendance: its runs are bound unattended, yet a person is waiting on the other end,
    /// which is what `.remote` is for. Other surfaces become `.unattended` when the caller bound them so.
    static func of(origin: RunOrigin, attended: Bool) -> PriorityClass {
        switch origin {
        case .chatOps: return .remote
        case .scheduled, .backgroundTask: return .unattended
        case .intelligence: return .backgroundIC
        case .composer, .code, .workflow, .orb, .quickAccess, .regenerate, .resume:
            return attended ? .attended : .unattended
        }
    }
}

/// The run's structure. `.delegating` never occurs in v1 (decision D5 — sub-agents are withdrawn).
enum RunShape: Equatable, Sendable {
    case single
    case workflow(nodeCount: Int)
    case delegating
}

// MARK: - Manifest

struct InferenceRunManifest: Sendable {
    let runID: UUID
    /// Nil only for a background feature that belongs to no conversation (`RunOrigin.intelligence`).
    let conversationID: UUID?
    let origin: RunOrigin
    let attended: Bool
    let shape: RunShape
    /// Unique, in first-seen order.
    let models: [ModelRequirement]
    /// Workflow nodes whose model could not be resolved (a missing profile, an unreadable nested
    /// layout, the depth cap). Counted as LOCAL — see `needsLocalLock`.
    let unresolvedNodes: Int
    /// Estimated runtime bytes per local model (`residencyKey`), where an estimate exists.
    let footprints: [String: UInt64]

    var priority: PriorityClass { PriorityClass.of(origin: origin, attended: attended) }

    /// This manifest with `model` added — for a local model a run turned out to use that its
    /// derivation missed (`LocalInferenceCoordinator.ensureHeld`).
    func declaring(_ model: ModelRequirement) -> InferenceRunManifest {
        guard !models.contains(where: { $0.residencyKey == model.residencyKey }) else { return self }
        return InferenceRunManifest(runID: runID, conversationID: conversationID, origin: origin, attended: attended,
                                    shape: shape, models: models + [model], unresolvedNodes: unresolvedNodes,
                                    footprints: footprints)
    }

    var localModels: [ModelRequirement] { models.filter { $0.engine.isLocal } }

    /// An unresolvable node counts as local on purpose: the worst case is a run that waits unnecessarily, while the
    /// opposite guess lets two local runs collide.
    var needsLocalLock: Bool { !localModels.isEmpty || unresolvedNodes > 0 }

    /// One line for `[LOCAL-COORD]`.
    var summary: String {
        let local = localModels.map(\.description).joined(separator: ", ")
        let cloud = models.filter { !$0.engine.isLocal }.map(\.description).joined(separator: ", ")
        return "run \(runID.uuidString.prefix(8)) conv \(conversationID.map { String($0.uuidString.prefix(8)) } ?? "none") origin=\(origin) \(priority) "
            + "local=[\(local)] cloud=[\(cloud)]"
            + (unresolvedNodes > 0 ? " unresolvedNodes=\(unresolvedNodes)" : "")
    }
}

// MARK: - Derivation

/// Pure derivation of the models a profile will use. The stores are injected so the workflow walk is
/// testable without SwiftData.
enum ManifestModelResolver {

    /// Nested workflows deeper than this are counted as unresolved rather than walked. Mirrors the
    /// executor's own nesting cap in spirit; the exact value only bounds this walk.
    static let maxWorkflowDepth = 8

    struct Result: Equatable {
        var models: [ModelRequirement] = []
        var unresolvedNodes = 0
        var nodeCount = 0
        /// Estimated runtime bytes per LOCAL model (`residencyKey`), where `estimate` had an answer.
        var footprints: [String: UInt64] = [:]
    }

    /// - Parameter estimate: runtime bytes for a local model's config, or nil when unknown. Asked only
    ///   for local models; the largest answer wins when one model appears under several configs.
    static func models(
        for profile: BackendProfileModel,
        layout: (UUID) -> WorkflowLayout?,
        profiles: (Set<UUID>) -> [BackendProfileModel],
        estimate: (ProviderConfig) -> UInt64? = { _ in nil }
    ) -> Result {
        var result = Result()
        var visited = WalkState()
        collect(profile, role: .primary, depth: 0, into: &result, visited: &visited,
                layout: layout, profiles: profiles, estimate: estimate)
        result.models = unique(result.models)
        return result
    }

    /// Which nested workflows the walk has seen. A workflow on the current path is a cycle (unresolvable); one already
    /// walked elsewhere has had its models added, so reuse is not an unresolved node.
    struct WalkState {
        var onPath: Set<UUID> = []
        var walked: Set<UUID> = []
    }

    private static func collect(
        _ profile: BackendProfileModel,
        role: ModelRole,
        depth: Int,
        into result: inout Result,
        visited: inout WalkState,
        layout: (UUID) -> WorkflowLayout?,
        profiles: (Set<UUID>) -> [BackendProfileModel],
        estimate: (ProviderConfig) -> UInt64?
    ) {
        switch profile.details {
        case .bot(let config): add(config.llmConfig, role: role, into: &result, estimate: estimate)
        case .agent(let config), .code(let config): add(config.llmConfig, role: role, into: &result, estimate: estimate)
        case .imageGen(let config): add(config.llmConfig, role: role, into: &result, estimate: estimate)
        case .workflow:
            // A workflow that contains itself would loop forever here; the executor refuses it at run time and this walk just
            // stops. A reused workflow is not a cycle: its models are already in the result.
            if visited.walked.contains(profile.id) { return }
            guard depth < maxWorkflowDepth, !visited.onPath.contains(profile.id),
                  let graph = layout(profile.id) else {
                result.unresolvedNodes += 1
                return
            }
            visited.onPath.insert(profile.id)
            walk(graph, depth: depth, into: &result, visited: &visited, layout: layout,
                 profiles: profiles, estimate: estimate)
            visited.onPath.remove(profile.id)
            visited.walked.insert(profile.id)
        }
    }

    private static func walk(
        _ graph: WorkflowLayout,
        depth: Int,
        into result: inout Result,
        visited: inout WalkState,
        layout: (UUID) -> WorkflowLayout?,
        profiles: (Set<UUID>) -> [BackendProfileModel],
        estimate: (ProviderConfig) -> UInt64?
    ) {
        let ids = Set(graph.nodes.compactMap(\.profileID))
        let byID = Dictionary(profiles(ids).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for node in graph.nodes {
            result.nodeCount += 1
            switch node.kind {
            case .profile(let id, _):
                guard let nodeProfile = byID[id] else {
                    result.unresolvedNodes += 1
                    continue
                }
                collect(nodeProfile, role: .workflowNode, depth: depth + 1, into: &result,
                        visited: &visited, layout: layout, profiles: profiles, estimate: estimate)
            case .condition(let config):
                // The AI Classifier is MLX-only and runs only when no pattern rule matches — declared
                // whenever it is enabled, because whether it fires is decided by the run's content.
                if config.llmFallbackEnabled, let name = config.llmModelName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.models.append(ModelRequirement(engine: .mlx, modelID: name, role: .classifier))
                }
            case .code, .gate, .trigger, .action, .unsupported:
                continue
            }
        }
    }

    private static func add(_ config: ProviderConfig, role: ModelRole, into result: inout Result,
                            estimate: (ProviderConfig) -> UInt64?) {
        let model = ModelRequirement(engine: InferenceEngine.of(config), modelID: config.modelName, role: role)
        result.models.append(model)
        if model.engine.isLocal, let bytes = estimate(config), bytes > 0 {
            result.footprints[model.residencyKey] = max(result.footprints[model.residencyKey] ?? 0, bytes)
        }
    }

    /// First occurrence wins, by `residencyKey` — one model used as primary AND as a node is one model.
    private static func unique(_ models: [ModelRequirement]) -> [ModelRequirement] {
        var seen: Set<String> = []
        return models.filter { seen.insert($0.residencyKey).inserted }
    }
}
