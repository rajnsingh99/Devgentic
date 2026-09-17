// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillLaunchSequence.swift
//  Devgentic
//
//  What the skill library does at launch, and in what order.
//
//  ⚠️⚠️ EXTRACTED BECAUSE BOTH HALVES OF THIS HAVE ALREADY FAILED IN PRODUCTION, AND NEITHER HAD A
//  TEST.
//
//  1. ORDER. `SkillStore.configureContainer` was once `nonisolated` and deferred its assignment
//     through `Task { @MainActor in … }`. The launch site is itself inside one, so the assignment
//     queued BEHIND the sweep: the sweep ran with no container, every store call returned
//     `.containerUnavailable`, and because an aborted pass keeps its state it failed identically on
//     every launch afterwards. Configure must complete BEFORE the sweep, synchronously.
//
//  2. PRESENCE. The sweep is the only thing that carries a pre-V6 user's skills into the library.
//     Delete the call — or move it inside the launch-sweep gate, which defers on exactly the launch
//     this runs on — and every upgrading user gets a permanently empty Skills library, silently.
//
//  Inline in `DevgenticApp`'s init closure, neither property could be asserted. Here both can, and
//  `SkillLaunchSequenceTests` asserts them.
//

import Foundation
import SwiftData

enum SkillLaunchSequence {

    /// Prepares the skill library for this launch.
    ///
    /// The effects are injectable so a test can observe ORDER without a real container, real
    /// folders or a real Application Support directory. Production calls it with no arguments.
    ///
    /// ⚠️ `async` because the sweep's ingest moved OFF the main actor — it walks and reads every file
    /// of every skill, which on an unmounted volume or a network share blocks for the mount timeout.
    /// `configure` stays synchronous and still completes BEFORE the first suspension point, which is
    /// the ordering property this type exists to protect.
    ///
    /// ⚠️ `permits` is the test-host refusal, and it is a parameter rather than a direct
    /// `TestHost.permits` call for one reason: refusing in the test host is exactly what would make
    /// "does the sweep run?" untestable from inside the test host. The default is the real gate.
    @MainActor
    static func run(
        container: ModelContainer,
        logger: DGLogger,
        permits: (String, DGLogger) -> Bool = { TestHost.permits($0, logger: $1) },
        configure: (ModelContainer) -> Void = { SkillStore.shared.configureContainer($0) },
        sweep: (ModelContainer) async -> Void = { _ = await SkillLibraryImportSweep.run(container: $0) }
    ) async {
        // ⚠️ FIRST, AND SYNCHRONOUS. See the header — a deferred assignment here broke every skill
        // import for every upgrading user.
        configure(container)
        logger.notice("[SKILL_LAUNCH] Skill store configured. CONSEQUENCE: the library is readable from here on — anything before this point that asked the store for skills got 'unavailable', which is what made an earlier ordering bug produce a permanently empty library.")

        // ⚠️ Refused in the test host. The sweep READS the user's real skill folders and WRITES
        // rows plus the failure record in the real Application Support directory. Store writes are
        // redirected by TEST_RUNNER_DEVGENTIC_STORE_URL; the failure record is not, so without this
        // an ordinary `test-without-building` run would consume the developer's own pending import
        // and their next real launch would find nothing left to migrate — a one-way loss with no
        // error anywhere.
        guard permits("run the V6 skill-library import sweep (it reads real skill folders and consumes the real pending-import file)", logger) else {
            logger.notice("[SKILL_LAUNCH] Import sweep REFUSED by the host gate. CONSEQUENCE: expected in the test host and NOT expected in a real launch — if you see this while hand-testing the app, pre-V6 skill folders are not being migrated and the library will look empty for an upgrading profile.")
            return
        }
        logger.notice("[SKILL_LAUNCH] Running the import sweep. CONSEQUENCE: it reads real skill folders off disk and may take time on a network volume; the main actor is free while it does, so the UI stays responsive.")
        await sweep(container)
        logger.notice("[SKILL_LAUNCH] Import sweep finished. CONSEQUENCE: the library is now in its final state for this launch — a profile still showing 'awaiting re-link' after this point needs the Retry button, not another relaunch.")
    }
}
