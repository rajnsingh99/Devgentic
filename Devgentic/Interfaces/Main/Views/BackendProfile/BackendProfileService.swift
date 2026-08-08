//
//  BackendProfileService.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 27/08/25 to fix advanced configuration encoding.
//

import Foundation
import SwiftUI
import OSLog

private let logger = DGLogger(category: "BackendProfileService")

/// An ObservableObject that acts as the central service for the Backend Profile UI.
/// It manages the list of profiles, handles persistence, and provides logic for advanced configurations.
///
/// **Change tracking** is NOT handled here — it lives in `ProfileEditBuffer`.
/// The service is a thin persistence + list layer. Detail views own an edit buffer
/// and only call `saveProfile(_:)` when the user explicitly saves.
@Observable @MainActor
final class BackendProfileService {

    /// The array of profiles that the sidebar observes.
    /// This always reflects the **last-persisted** state.
    var profiles: [BackendProfileModel] = []

    /// The active edit buffer for the currently selected profile.
    /// Owned by the service so the panel view's navigation guard can check `editBuffer?.isDirty`.
    var editBuffer: ProfileEditBuffer?

    /// Dirty state of a workflow canvas hosted INSIDE the profile editor.
    ///
    /// ⚠️ Owned here for the same reason `editBuffer` is: the sidebar's navigation guard has to be
    /// able to see it. Canvas geometry (nodes, edges, positions) lives in `WorkflowCanvasState` and
    /// `WorkflowLayoutSD`, never in `editBuffer.draft` — so `editBuffer?.isDirty` is false no matter
    /// how much the user has drawn, and the sidebar used to switch profiles without a prompt and
    /// destroy the lot. The canvas registers its save/discard hooks on this guard, which is why
    /// Discard can now actually revert instead of just navigating away.
    let canvasEditGuard = WorkflowEditGuard()

    /// Commits a floating prompt editor's pending text back into `editBuffer.draft`.
    ///
    /// ⚠️ THE THIRD SOURCE OF UNSAVED WORK, and the reason `hasUnsavedEditorChanges` alone is not
    /// enough at an exit point. `AdvancedPromptEditorView` holds typing in its own `@State
    /// localText` and writes back only on an explicit commit — so both the buffer and the canvas
    /// report clean while the floating window holds thousands of characters the user just typed.
    /// Navigation already handles this by committing on teardown
    /// (`AdvancedPromptWindowManager.closeWindowCommittingChanges`, register A27); ⌘Q has no
    /// teardown to hang that on, so the owner registers the hook here instead.
    ///
    /// Registered by `AgentConfigDetailView` while it is on screen, nil otherwise. The bot and
    /// scheduler editors use `SimplePromptWindowManager`, which pushes every keystroke back to its
    /// binding and therefore has nothing pending to flush.
    var commitPendingPromptEdits: (() -> Void)?

    /// Flushes any floating prompt editor's pending text into the draft so the dirty check below
    /// can see it. Call this BEFORE reading `hasUnsavedEditorChanges` at an exit point.
    ///
    /// Deliberately a separate call rather than a side effect of the property: `hasUnsavedEditorChanges`
    /// is read from view bodies, and a property that mutates the draft on read would fire during a
    /// SwiftUI update pass.
    func flushPendingEditorText() {
        commitPendingPromptEdits?()
    }

    /// Whether anything in the profile editor has unsaved work — the field edit buffer or a hosted
    /// workflow canvas. Every navigation guard must use this, never `editBuffer?.isDirty` alone.
    ///
    /// ⚠️ Text still sitting in a floating prompt editor is NOT visible here until it has been
    /// committed; call `flushPendingEditorText()` first at any exit that can destroy it.
    var hasUnsavedEditorChanges: Bool {
        editBuffer?.isDirty == true || canvasEditGuard.hasUnsavedChanges
    }

    private let profileStore: BackendProfileStoreProtocol

    /// Initializes the service, optionally with a specific store for testing.
    /// On initialization, it immediately loads the profiles from persistence.
    init(store: BackendProfileStoreProtocol = BackendProfileStore.shared) {
        self.profileStore = store
        loadProfiles()
    }

    // MARK: - Persistence Methods

    /// The last `loadProfiles()` failure, or nil when the list reflects a successful read.
    ///
    /// ⚠️ Exists so the sidebar can tell "you have no profiles" apart from "we could not read your
    /// profiles". Those render identically without it, and the second is far more alarming: at
    /// launch `loadProfiles()` runs from `init`, where there is no prior list to keep, so a fetch
    /// failure showed a FIRST-RUN EMPTY STATE to a user with a store full of profiles.
    private(set) var lastLoadError: String?

    /// Fetches all profiles from the persistence layer and updates the published `profiles` array.
    func loadProfiles() {
        do {
            self.profiles = try profileStore.fetchProfiles()
            self.lastLoadError = nil
        } catch {
            self.lastLoadError = error.localizedDescription
            // Keep existing in-memory profiles rather than clearing on transient errors.
            let consequence = profiles.isEmpty
                ? "the sidebar is EMPTY and reads as a first run — the user's profiles are not gone, "
                  + "they were not read"
                : "the sidebar keeps the \(profiles.count) profile(s) already in memory, which may "
                  + "now be stale"
            logger.error(
                "[PERSISTENCE] loadProfiles failed: \(error.localizedDescription). "
                + "CONSEQUENCE: \(consequence)."
            )
        }
    }

    /// Saves a given profile to the persistence layer and updates the in-memory array in-place.
    /// Throws `ProfileStoreError` on validation or persistence failure so callers can show errors.
    /// - Returns: advisory findings for the saved profile (register A34). Empty is the common case.
    ///   ⚠️ `@discardableResult` on purpose: of ~23 call sites, only the profile editors have a
    ///   place to show these. Forcing the rest to write `_ =` would be noise, and forcing them to
    ///   render something would put the same warning on screen from four directions.
    @discardableResult
    func saveProfile(_ profile: BackendProfileModel) throws -> [ProfileValidationError] {
        let advisories = try profileStore.saveProfile(profile)

        // Update in-place to preserve sidebar ordering
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            // New profile — reload to get correct sort order
            loadProfiles()
        }
        // Knowledge sources need no save-time indexing: they're read fresh from disk
        // and delivered as the <knowledge_base> prompt layer on every request
        // (2026-07 redesign — the old KnowledgeSourceMonitor vector-indexing path,
        // which stamped a synthetic conversation ID no retrieval could match, is gone).
        return advisories
    }

    /// Deletes a profile using its ID from the persistence layer and reloads the local array.
    /// Cascades to the matching `WorkflowLayoutSD` row (if any) — a no-op for non-workflow
    /// profiles since the layout store keys on profile ID and simply finds nothing to delete.
    func deleteProfile(withId id: UUID) throws {
        try profileStore.deleteProfile(withId: id)
        WorkflowLayoutStore.shared.delete(for: id)
        if editBuffer?.draft.id == id {
            editBuffer = nil
        }
        loadProfiles()
    }

    // MARK: - Edit Buffer Management

    /// Creates (or replaces) the edit buffer for the given profile ID.
    /// Call when the user selects a profile in the sidebar.
    ///
    /// ⚠️ Reads the STORE, not the in-memory `profiles` array. Three writers persist profiles
    /// without going through this service — `BackendOrchestrationService.disableThinkingOnProfile`
    /// (auto-healing an unsupported thinking flag), `MLXContextWindowHealer` (backfilling a context
    /// window) and the composer's capability chips — and none of them refresh `profiles`. Seeding
    /// the editor from that stale array meant the user saw the pre-heal value, and saving any
    /// unrelated field wrote it back, undoing the heal: the provider 400 the healer had just fixed
    /// would return on the very next send, silently, every time.
    func activateEditBuffer(for id: UUID) {
        let cached = profiles.first(where: { $0.id == id })
        let fresh: BackendProfileModel?
        do {
            fresh = try profileStore.fetchProfile(byId: id)
        } catch {
            logger.error(
                "[PROFILE] Could not re-read profile \(id) from the store when opening the editor: "
                + "\(error.localizedDescription). CONSEQUENCE: falling back to the in-memory copy, "
                + "which may predate an out-of-band write (auto-healed thinking flag, backfilled "
                + "context window) — saving could revert it."
            )
            fresh = nil
        }

        guard let profile = fresh ?? cached else {
            logger.error(
                "[PROFILE] activateEditBuffer found no profile \(id) in the store or in memory. "
                + "CONSEQUENCE: the previous edit buffer is cleared and the detail view renders its "
                + "not-found state rather than silently editing the wrong profile."
            )
            editBuffer = nil
            return
        }

        // Keep the list in step with what the editor is about to show, so the sidebar row and the
        // editor cannot disagree about the same profile.
        if let index = profiles.firstIndex(where: { $0.id == id }), profiles[index] != profile {
            profiles[index] = profile
        }

        editBuffer = ProfileEditBuffer(profile: profile)
        logProfileSelection(profileID: id)
    }

    /// Discards the current edit buffer.
    func deactivateEditBuffer() {
        editBuffer = nil
    }

    /// Re-baselines the open edit buffer after a facet of the profile was persisted elsewhere
    /// (Tool Library, workflow canvas, capability chips).
    ///
    /// ⚠️ Call this after EVERY out-of-band `saveProfile` that targets a profile the editor may
    /// have open. Skipping it leaves `original` describing bytes that are no longer on disk, which
    /// is what made the editor show a Save/Revert pill for an edit the user never made and made
    /// Revert restore a superseded state. No-ops when the buffer is for a different profile.
    func rebaseEditBuffer(to persisted: BackendProfileModel) {
        guard let buffer = editBuffer, buffer.draft.id == persisted.id else { return }
        buffer.rebase(onto: persisted)
    }

    // MARK: - Advanced Configuration Logic

    // ⚠️ `getAdvancedConfig(for:)` was DELETED here (register A49). It had zero callers — the live
    // path is `ProviderAdvancedConfigManager.load(from:using:defaultProfile:)` — and it carried a
    // latent bug that only a reviver would have hit: its `switch config.apiProvider` used a
    // `default:` clause instead of exhaustive cases, so `.mlx` fell through and returned an OLLAMA
    // parameter set for an MLX profile. Being `default:` rather than exhaustive, the compiler could
    // never have flagged it. Deleted rather than fixed: reviving a second source of truth for
    // advanced config is how the panel and the executor drifted apart in the first place (A24/A25).

    /// Encodes a specific `Codable` model into the `[String: JSONValue]` dictionary format.
    /// - Returns: The encoded dictionary, or `nil` if encoding fails.
    func encodeConfig<T: Codable>(from config: T) -> [String: JSONValue]? {
        do {
            let data = try JSONEncoder().encode(config)
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                logger.warning("Failed to cast JSON object to [String: Any] during advanced config encode.")
                return nil
            }
            return dictionary.mapValues { JSONValue($0) ?? .null }
        } catch {
            logger.error("Failed to encode advanced configuration: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decodes a `[String: JSONValue]` dictionary back into a specific `Codable` model type.
    /// - Returns: The decoded model, or `nil` if the dictionary is missing or decoding fails.
    /// - Parameter context: a human-readable identifier for the profile/provider being decoded,
    ///   used only in the failure log. ⚠️ Defaulted so existing call sites keep compiling, but pass
    ///   it: without it the log names a TYPE and nothing else, which cannot be tied to a profile.
    func decodeConfig<T: Codable>(
        from dictionary: [String: JSONValue]?,
        as type: T.Type,
        context: String = "unspecified profile"
    ) -> T? {
        guard let dictionary = dictionary else { return nil }

        let unwrappedDict = dictionary.mapValues { $0.rawValue }

        do {
            let data = try JSONSerialization.data(withJSONObject: unwrappedDict)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // ⚠️ Every caller answers this nil with `?? .default()`, so the user does not lose one
            // field — they lose the WHOLE advanced panel, and it then presents app defaults as
            // their own settings. The log must say so, and must name the profile: the previous
            // line ("Failed to decode advanced configuration: …") identified neither the profile,
            // the provider, nor the target type, so a burst of them was unattributable.
            logger.error(
                "[PROFILE] Advanced configuration for \(context) could not be decoded as "
                + "\(String(describing: T.self)): \(error.localizedDescription). Stored keys: "
                + "[\(dictionary.keys.sorted().joined(separator: ", "))]. CONSEQUENCE: the panel "
                + "falls back to app DEFAULTS and presents them as the user's settings; saving from "
                + "that state overwrites the stored configuration."
            )
            return nil
        }
    }

    // MARK: - Diagnostics / Logging

    /// Dumps the full resolved configuration of a profile: provider, model, endpoint, capability
    /// verdict, per-tool enabled/confirm state, knowledge sources and advanced-config keys.
    ///
    /// ⚠️ This had ZERO callers (register A50) — 70 lines built to answer exactly the questions a
    /// support engineer asks ("my agent stopped calling tools", "responses got much shorter") and
    /// nothing ever invoked it, so no run recorded which settings it used. Now called from
    /// `activateEditBuffer`, i.e. once per profile activation.
    ///
    /// ⚠️ Deliberately NOT called from the send path. It is a multi-line dump and a send happens
    /// per message; at activation it fires once when the user opens a profile, which is the moment
    /// that actually needs anchoring in the log. If a per-run record is wanted later, add a
    /// one-line summary at the send seam rather than moving this.
    ///
    /// ⚠️ The API key is masked by `formatLLMConfig`; knowledge-source PATHS are included because
    /// a missing or moved source is a common cause of "the agent ignored my documents".
    func logProfileSelection(profileID: UUID) {
        guard let logOutput = profileSelectionSummary(profileID: profileID) else {
            logger.notice(
                "[PROFILE] Cannot log configuration for \(profileID): not in the loaded list. "
                + "CONSEQUENCE: this activation has no configuration record in the log."
            )
            return
        }

        logger.info("[PROFILE] \(logOutput)")
    }

    /// Builds the dump `logProfileSelection` emits, or `nil` when the profile is not loaded.
    ///
    /// Split out from the logging call so the CONTENT is assertable: the reason A50 sat dead for so
    /// long is that nothing — not a caller, not a test — ever looked at what it produced.
    func profileSelectionSummary(profileID: UUID) -> String? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }

        var logOutput = "\n\n==================================================\n"
        logOutput += "PROFILE SELECTED: \(profile.displayName)\n"
        logOutput += "==================================================\n"
        logOutput += "ID: \(profile.id)\n"
        logOutput += "Type: \(profile.profileType.rawValue)\n"
        logOutput += "Last Selected: \(profile.lastSelected?.description ?? "Never")\n\n"

        switch profile.details {
        case .bot(let config):
            logOutput += "[BOT CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n"

        case .agent(let config):
            logOutput += "[AGENT CONFIGURATION]\n"
            logOutput += "Capabilities: \(config.capabilities.summary)\n"
            logOutput += "Description: \(config.description ?? "None")\n"
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n\n"

            logOutput += "[TOOLS (\(config.tools.filter({ $0.isEnabled }).count) Active)]\n"
            if config.tools.isEmpty {
                logOutput += "  - No tools configured.\n"
            } else {
                for tool in config.tools {
                    let status = tool.isEnabled ? "ON" : "OFF"
                    logOutput += "  [\(status)] \(tool.name) (Requires Confirmation: \(tool.requiresConfirmation))\n"
                }
            }
            logOutput += "\n"

            logOutput += "[KNOWLEDGE SOURCES (\(config.knowledgeSources?.count ?? 0) Active)]\n"
            if let sources = config.knowledgeSources, !sources.isEmpty {
                for source in sources {
                    logOutput += "  - [\(source.type.rawValue)] \(source.location)\n"
                }
            } else {
                logOutput += "  - No knowledge sources.\n"
            }
            logOutput += "\n"

            logOutput += "[LLM / PROVIDER CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)

        case .workflow(let config):
            logOutput += "[WORKFLOW CONFIGURATION]\n"
            logOutput += "Agent Profile IDs: \(config.agentProfileIDs.count)\n"
            for (index, id) in config.agentProfileIDs.enumerated() {
                logOutput += "  \(index + 1). \(id.uuidString)\n"
            }

        case .imageGen(let config):
            logOutput += "[IMAGE GENERATOR CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Negative Prompt: \(config.negativePrompt ?? "None")\n"
            logOutput += "Default Aspect Ratio: \(config.defaultAspectRatio?.rawValue ?? "Not set")\n"

        case .code(let config):
            logOutput += "[CODE SESSION CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Tools: \(config.tools.filter({ $0.isEnabled }).count) active\n"
            // ⚠️ Register A38: this said `?? 20` while the executor used 15 — the support dump
            // stated a cap the run never had. One constant now.
            logOutput += "Max Iterations: \(config.maxIterations ?? AgentExecutionDefaults.maxIterations)\n"
        }

        logOutput += "==================================================\n\n"
        return logOutput
    }

    private func formatLLMConfig(_ config: ProviderConfig) -> String {
        var str = "Provider: \(config.apiProvider.rawValue)\n"
        str += "Model Name: \(config.modelName)\n"
        str += "Base URL: \(config.baseURL ?? "Default (Not set)")\n"

        let flagIndicator = "Capability: \(config.cognitiveCapability.rawValue)"
        str += "Supports Native Tools: \(flagIndicator)\n"

        if let key = config.apiKey, !key.isEmpty {
            let masked = key.count > 8 ? "\(key.prefix(4))...\(key.suffix(4))" : "****"
            str += "API Key: \(masked) (Masked for Security)\n"
        } else {
            str += "API Key: None\n"
        }

        if let adv = config.advancedConfiguration, !adv.isEmpty {
            str += "Advanced Config Keys: \(adv.keys.joined(separator: ", "))\n"
        } else {
            str += "Advanced Config: Default / None\n"
        }

        return str
    }
}
