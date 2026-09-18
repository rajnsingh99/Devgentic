// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeProfileFactory.swift
//  Devgentic
//
//  Created on 29/08/26.
//
//  Builds the private profile row that backs a workflow node.
//
//  ⚠️ A workflow node's configuration is SCOPED TO ITS WORKFLOW. It is stored as an ordinary
//  `BackendProfile` row carrying `ownerWorkflowID` / `ownerNodeID`, hidden from every surface that
//  offers a shared profile (`BackendProfileService.sharedProfiles`). Storing the config inside the
//  layout blob instead was rejected: `ProviderConfig.encode` writes `apiKey` unconditionally and the
//  only strip-on-write seam is `BackendProfileSD`, so a layout blob would carry live cloud keys in
//  cleartext — the exact condition `ProviderKeyStore` exists to prevent. Keeping it a real row also
//  inherits `ProfileValidator`, the `ProfileDetails` migration ladder and the MLX context-window
//  healer, none of which reach into layout blobs.
//
//  Both functions here are PURE and `static` so the rules they encode are testable directly — a
//  SwiftUI view's private helper is not reachable from a test.
//

import Foundation

enum WorkflowNodeProfileFactory {

    /// A brand-new configuration for a node the user is building from scratch.
    ///
    /// ⚠️ DEFAULTS TO MLX (owner decision 2026-08-29), and that is load-bearing rather than a
    /// preference: `ApiProvider.isLocal` is true for `.mlx`, and `ProfileValidator` Rule 4 demands
    /// an API key only for the four cloud providers — so a fresh node needs no credential at all,
    /// and nothing has to be copied out of the Keychain to create one.
    ///
    /// ⚠️ `modelName` may legitimately be EMPTY when no MLX model is installed. That is deliberate:
    /// `BackendProfileStore.saveProfile` validates leniently on INSERT precisely so a row can be
    /// created before it is configured, and refusing to create the node instead would strand a user
    /// with no local models — they could not add a node at all, not even to import into one.
    ///
    /// ⚠️ NOTHING VALIDATES THE RESULT BEFORE A RUN, and an earlier version of this comment claimed
    /// the canvas surfaces "A model must be selected." until the user picks one. It does not:
    /// `WorkflowValidator.validateProfileNode` checks only that the profile RESOLVES and that it is
    /// not an imageGen; that message lives in `ProfileValidator`, reachable only from a profile
    /// SAVE. So an unconfigured fresh node fails when it executes, not at pre-flight. Filed as a
    /// gap rather than fixed here — adding the rule is a product change, not a comment fix.
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
            // Bot is the fallback for every non-agent request. `.workflow` never reaches here — a
            // sub-workflow node stays a REFERENCE to another workflow's canvas and is added through
            // the import path — and `.imageGen` / `.code` cannot run as workflow steps at all.
            details = .bot(BotConfig(llmConfig: llmConfig))
        }

        return BackendProfileModel(
            displayName: name,
            details: details,
            ownerWorkflowID: workflowID,
            ownerNodeID: nodeID
        )
    }

    /// A detached copy of an existing profile, owned by `nodeID`.
    ///
    /// ⚠️ Built on `duplicated(as:)`, which is COPY-BY-DEFAULT (`var copy = self`) so it carries
    /// every present and future property for free. Do NOT replace it with a field list: register
    /// A31 records that shape silently dropping `fileContextStrategy`, which turned file CONTENT
    /// into file PATHS in the prompt — the same profile, a different answer, nothing on screen.
    ///
    /// ⚠️ The API key rides along inside `ProfileDetails` (an in-memory snapshot legitimately
    /// carries it — `BackendProfileSD` re-injects on read) and is re-secured into the Keychain under
    /// the NEW row's id by `saveProfile`. That is what makes an imported cloud node runnable while
    /// keeping the credential out of the layout blob.
    static func importedProfile(
        from source: BackendProfileModel,
        workflowID: UUID,
        nodeID: UUID
    ) -> BackendProfileModel {
        // Decision #2 (2026-08-29): keep the source's name. The row is private, so there is no list
        // for a name to collide in, and the node card renders `displayName` anyway.
        var copy = source.duplicated(as: source.displayName)

        // ⚠️ RE-STAMPED, because `duplicated(as:)` copied the SOURCE's ownership too. Importing from
        // a profile that is itself a node's config (possible once nodes own rows) would otherwise
        // hand the new node a row still claiming to belong to the old node — and the save-time
        // reconcile would delete it out from under the workflow that just created it.
        copy.ownerWorkflowID = workflowID
        copy.ownerNodeID = nodeID

        copy = severingCrossProfileReferences(copy)
        return copy
    }

    /// Clears pointers to OTHER profiles that a copy would otherwise smuggle across the detachment
    /// boundary.
    ///
    /// ⚠️ `SelfReflectionConfig.evaluatorProfileID` is a profile UUID living inside `AgentConfig`,
    /// so copy-by-default carries it. It is persisted but has NO reader in app code today, which is
    /// exactly why it is severed now: it costs nothing while inert, and the moment a reader ships,
    /// a supposedly-detached node would fail or silently fall back because of a profile deleted
    /// somewhere else — the class of coupling node-owned configuration exists to remove.
    ///
    /// If evaluators later matter, the node-owned answer is to own the evaluator's row too. That is
    /// additive and decidable then; this is not a decision it forecloses.
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
