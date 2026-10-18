// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeProfileFactory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: the config is not stored in the layout blob: `ProviderConfig.encode` writes `apiKey` unconditionally, and only
// `BackendProfileSD` strips it on write, so a blob would hold live cloud keys in cleartext.
/// Builds the private profile row that backs a workflow node: an ordinary `BackendProfile` carrying `ownerWorkflowID` /
/// `ownerNodeID`, hidden from every surface that offers shared profiles. Both functions are pure and `static` so the
/// rules they encode are testable directly.
enum WorkflowNodeProfileFactory {

    // Why: an unconfigured fresh node passes pre-flight (`WorkflowValidator.validateProfileNode` checks only that the profile
    // resolves and is not an imageGen) and fails when it executes.
    /// A brand-new configuration for a node the user is building from scratch.
    /// Defaults to MLX, which is local: `ProfileValidator` demands an API key only for cloud providers.
    /// `modelName` may be empty when no MLX model is installed: `saveProfile` validates leniently on insert.
    static func freshProfile(
        type: ProfileType,
        name: String,
        workflowID: UUID,
        nodeID: UUID,
        defaultMLXModelName: String
    ) -> BackendProfileModel {
        let llmConfig = ProviderConfig(apiProvider: .mlx, modelName: defaultMLXModelName)

        let details: ProfileDetails
        switch type {
        case .agent:
            details = .agent(AgentConfig(llmConfig: llmConfig, tools: []))
        default:
            // Bot is the fallback for every non-agent request. `.workflow` never reaches here (a sub-workflow node stays a reference
            // to another canvas) and `.imageGen` / `.code` cannot run as workflow steps.
            details = .bot(BotConfig(llmConfig: llmConfig))
        }

        return BackendProfileModel(
            displayName: name,
            details: details,
            ownerWorkflowID: workflowID,
            ownerNodeID: nodeID
        )
    }

    // Why: built on `duplicated(as:)`, which copies by default; a hand-written field list would silently drop properties
    // such as `fileContextStrategy` (file content would become file paths in the prompt).
    /// A detached copy of an existing profile, owned by `nodeID`.
    /// The API key rides along in `ProfileDetails` and is re-secured into the Keychain under the new row's id by
    /// `saveProfile`, keeping the credential out of the layout blob.
    static func importedProfile(
        from source: BackendProfileModel,
        workflowID: UUID,
        nodeID: UUID
    ) -> BackendProfileModel {
        // Keep the source's name: the row is private, so no list exists for a name to collide in, and the node card renders
        // `displayName` anyway.
        var copy = source.duplicated(as: source.displayName)

        // Re-stamp ownership: `duplicated(as:)` copied the source's owner too, and a row still claiming the old node would be
        // deleted by the save-time reconcile out from under the workflow that created it.
        copy.ownerWorkflowID = workflowID
        copy.ownerNodeID = nodeID

        copy = severingCrossProfileReferences(copy)
        return copy
    }

    /// Clears pointers to other profiles that a copy would otherwise carry across the detachment boundary.
    /// `SelfReflectionConfig.evaluatorProfileID` is such a UUID inside `AgentConfig`; severing it keeps a detached node from
    /// failing or falling back because of a profile deleted somewhere else.
    static func severingCrossProfileReferences(_ profile: BackendProfileModel) -> BackendProfileModel {
        guard case .agent(var config) = profile.details,
              var reflection = config.capabilities.selfReflection,
              reflection.evaluatorProfileID != nil
        else { return profile }

        reflection.evaluatorProfileID = nil
        config.capabilities.selfReflection = reflection

        var severed = profile
        severed.details = .agent(config)
        return severed
    }
}
