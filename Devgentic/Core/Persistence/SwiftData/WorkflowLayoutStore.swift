//
//  WorkflowLayoutStore.swift
//  Devgentic
//
//  SwiftData-backed persistence for workflow canvas layouts.
//  Migrated from UserDefaults (was previously a private class inside
//  `WorkflowCanvasView.swift`).
//
//  Public API is preserved (`load`, `save`, `delete`) so existing call sites
//  (canvas view, executor, dedicated view) don't need to change beyond removing
//  the old inline definition.
//
//  Concurrency: `@MainActor`-isolated, matching `BackendProfileStore` and
//  `DownloadHistoryStore`. Off-main callers (notably `WorkflowExecutor`, which
//  is an actor) must hop with `await MainActor.run`.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutStore")

/// What actually happened to a `save`.
///
/// ⚠️ `save` used to return `Void`. That was fine while every write succeeded, but once
/// `WorkflowLayoutSD` began REFUSING writes over an unreadable canvas the refusal had nowhere to go:
/// the model logged it, the store returned, and the canvas kept accepting edits that were silently
/// discarded for the rest of the session. A caller cannot surface what it is never told.
enum WorkflowLayoutSaveOutcome: Equatable {

    /// The layout reached disk.
    case saved

    /// No container yet — the write was dropped.
    case notConfigured

    /// The stored canvas could not be decoded, so the write was refused to protect the original
    /// bytes. Carries the denormalized counts, which live outside the blob and say what the row
    /// used to hold — that is the evidence a UI should put in front of the user.
    /// Repair via `repairUnreadableLayout(_:for:reason:)`.
    case refusedUnreadable(nodeCount: Int, edgeCount: Int, annotationCount: Int)

    /// The stored blob was written by a NEWER build; re-encoding here would strip its fields
    /// permanently (WF-PE2). Byte-intact refusal; the canvas is read-only until the app updates.
    case refusedNewerVersion(blobVersion: Int, appVersion: Int)

    /// SwiftData raised on fetch or save.
    case failed(String)

    /// True only when the bytes are on disk.
    var didPersist: Bool { self == .saved }

    /// [WF-PE2] True for the two outcomes that are refused BY DESIGN and will refuse identically on
    /// every future attempt, as opposed to `.failed`/`.notConfigured`, which may plausibly succeed
    /// on retry (transient SwiftData error, or the container finishing configuration).
    ///
    /// ⚠️ This is the distinction `didPersist` collapses away. A caller that treats every non-`saved`
    /// outcome as one undifferentiated failure ends up telling the user to retry something that is
    /// refused by construction — exactly the quit-time loop this property exists to let callers
    /// break out of. Both refused branches `return` in `save(_:for:)` strictly before any mutating
    /// line, so nothing is ever attempted or left pending for either case — a caller may safely
    /// treat a refused-only batch as "nothing to roll back, safe to proceed" with no compensating
    /// logic needed.
    var isRefusedByDesign: Bool {
        switch self {
        case .refusedUnreadable, .refusedNewerVersion: return true
        case .saved, .notConfigured, .failed: return false
        }
    }

    /// [WF-PE2] User-facing reason for a refused-by-design outcome, for the quit-time choice this
    /// row's own doc comment on `.refusedNewerVersion` promises. `nil` for every other case — a
    /// caller has no business asking this of an outcome it never checked `isRefusedByDesign` on.
    ///
    /// A DELIBERATELY SEPARATE property from `WorkflowCanvasView`'s own in-canvas copy for these
    /// same two cases, not a shared one: the in-canvas banner/overlay carries node/edge/annotation
    /// counts and view-local state (`UnreadableLayoutInfo`) this type has no business holding, and
    /// unifying them would drag UI-layer detail into the persistence layer for a one-line save.
    /// Kept here rather than inline at the call site so the WORDING is testable independent of
    /// `AppDelegate`, which has no unit-test seam.
    var quitTimeRefusalReason: String? {
        switch self {
        case .refusedNewerVersion(let blobVersion, let appVersion):
            return String(localized: "This workflow was saved by a newer version of Devgentic (v\(blobVersion) format; this build writes v\(appVersion)). It's read-only here — update Devgentic to edit it.")
        case .refusedUnreadable:
            return String(localized: "This workflow's saved layout can't be read by this build, so edits are refused to keep the original bytes intact.")
        case .saved, .notConfigured, .failed:
            return nil
        }
    }
}

@MainActor
final class WorkflowLayoutStore {

    // MARK: - Singleton

    static let shared = WorkflowLayoutStore()
    private init() {}

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    /// Called once from `DevgenticApp` after the shared `ModelContainer` is built.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("WorkflowLayoutStore configured with SwiftData ModelContainer.")
    }

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    // MARK: - Public API (matches the old UserDefaults-backed signature)

    /// Loads the layout for a given workflow profile. Returns `.empty` on miss
    /// (no row, no container, or decode failure) — the canvas treats an empty
    /// layout as a fresh workflow.
    /// Loads every workflow layout reachable from `layout` through sub-workflow nodes, keyed by
    /// workflow profile ID. Feeds `WorkflowValidator`'s nesting and cycle rules.
    ///
    /// ⚠️ THE VISITED SET IS FOR TERMINATION, NOT CORRECTNESS. A workflow that contains itself would
    /// recurse forever *while loading* — before the validator ever gets the chance to report the
    /// cycle. The set is what makes a cyclic graph loadable at all; reporting the cycle is a
    /// separate walk over the finished map.
    ///
    /// ⚠️ Resolved by the CALLER and handed to the validator, deliberately. The validator is a pure
    /// synchronous function re-run on every canvas edit (`markDirty` → `revalidate`); making it load
    /// layouts would put a SwiftData fetch on every keystroke and let stale async results race the
    /// live ones. Same shape as `availableToolSources`.
    func resolveNestedLayouts(from layout: WorkflowLayout) -> [UUID: WorkflowLayout] {
        var resolved: [UUID: WorkflowLayout] = [:]
        var visited = Set<UUID>()
        var queue = Self.subWorkflowProfileIDs(in: layout)

        while let profileID = queue.popLast() {
            guard visited.insert(profileID).inserted else { continue }
            let sub = load(for: profileID)
            resolved[profileID] = sub
            queue.append(contentsOf: Self.subWorkflowProfileIDs(in: sub))
        }
        return resolved
    }

    /// Every workflow this layout references, with the node that references it.
    ///
    /// ⚠️ THE ONE DEFINITION of "what other workflows does this graph run". Today the only shape is
    /// a `.profile(_, .workflow)` node — but keep this the single extractor anyway. When the Loop
    /// node existed there were TWO shapes, and for a long time only the first was collected, HERE
    /// and in a private twin inside `validateNesting`: loop bodies were invisible to cycle/depth
    /// validation (a mutually-recursive composition validated completely clean and died at run time
    /// with "nesting depth exceeded", after ~2–3 canvas runs' worth of tokens). That register class
    /// (WF-VA1 ≡ WF-NS5 ≡ WF-SE4) was one defect filed three times because the extractor existed
    /// twice — any future node kind that references a workflow MUST be added here and only here.
    /// (The Loop node was retired and deleted 2026-08-15.)
    nonisolated static func workflowReferences(in layout: WorkflowLayout) -> [(profileID: UUID, nodeName: String)] {
        layout.nodes.compactMap { node in
            if case .profile(let id, .workflow) = node.kind { return (id, node.displayName) }
            return nil
        }
    }

    /// Profile IDs of every workflow this layout references (sub-workflow nodes).
    nonisolated static func subWorkflowProfileIDs(in layout: WorkflowLayout) -> [UUID] {
        workflowReferences(in: layout).map(\.profileID)
    }

    func load(for profileID: UUID) -> WorkflowLayout {
        guard let context = mainContext else {
            logger.error("load(for:) called before container was configured — returning .empty.")
            return .empty
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first?.layout ?? .empty
        } catch {
            logger.error("Failed to fetch layout for \(profileID): \(error.localizedDescription) — returning .empty.")
            return .empty
        }
    }

    /// Upserts the layout for a workflow profile. If a row already exists it's
    /// updated in place (the `@Attribute(.unique)` constraint enforces 1:1);
    /// otherwise a new row is inserted.
    ///
    /// ⚠️ Returns the outcome rather than `Void`: a write over an unreadable canvas is REFUSED by
    /// `WorkflowLayoutSD`, and a caller that is not told keeps letting the user edit a canvas whose
    /// every save is being thrown away. `@discardableResult` so the fire-and-forget callers that
    /// genuinely do not care still compile, but a UI save path should check `didPersist`.
    @discardableResult
    func save(_ layout: WorkflowLayout, for profileID: UUID) -> WorkflowLayoutSaveOutcome {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] save(_:for:) called before the container was configured — profile "
                + "\(profileID). CONSEQUENCE: this canvas edit is dropped and never reaches disk."
            )
            return .notConfigured
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        // [WF-PE3] Fetched OUTSIDE the mutate-then-save scope so a fetch throw (nothing mutated,
        // nothing to undo) and a save throw (a mutation is PENDING) are distinguishable — the old
        // single do/catch conflated them, and the save-throw case matters: every store shares one
        // `container.mainContext`, so a mutation left pending here would be silently flushed by
        // the NEXT save any other store performs (the very next line of the canvas's own
        // `saveLayout` used to call `profileService.saveProfile`, committing the "failed" layout
        // after all). The rollbacks below make `.failed` actually MEAN "not on disk and nothing
        // pending" — which is the contract the caller's guard relies on.
        let existing: WorkflowLayoutSD?
        do {
            existing = try context.fetch(descriptor).first
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to fetch the layout row for \(profileID) before saving: "
                + "\(error.localizedDescription). CONSEQUENCE: nothing was written or mutated; this "
                + "canvas edit is not on disk and stays in memory for another attempt."
            )
            return .failed(error.localizedDescription)
        }

        if let existing {
            // Ask BEFORE writing. The setter refuses silently (by design — it must not throw
            // from a property), so the refusal is only observable by checking first.
            if existing.hasNewerVersionLayout {
                let blobVersion = existing.newerBlobVersion ?? -1
                logger.error(
                    "[PERSISTENCE] Canvas save REFUSED — profile \(profileID): the stored layout "
                    + "was written by a NEWER build (blob v\(blobVersion), this build writes "
                    + "v\(WorkflowLayoutSD.layoutBlobVersion)); re-encoding would permanently strip "
                    + "every newer-version field. CONSEQUENCE: layoutData is left byte-intact and "
                    + "saves are refused on this build; viewing and running still work. The user "
                    + "needs the app update that wrote this layout."
                )
                return .refusedNewerVersion(
                    blobVersion: blobVersion,
                    appVersion: WorkflowLayoutSD.layoutBlobVersion
                )
            }
            if existing.hasUnreadableLayout {
                logger.error(
                    "[PERSISTENCE] Canvas save REFUSED — profile \(profileID): the stored layout "
                    + "could not be decoded, so this save would replace \(existing.nodeCount) "
                    + "node(s)/\(existing.edgeCount) edge(s)/\(existing.annotationCount) "
                    + "annotation(s) the user cannot see. CONSEQUENCE: layoutData is left "
                    + "byte-intact and EVERY save for this profile will be refused until "
                    + "repairUnreadableLayout(_:for:reason:) is called; the caller must tell the "
                    + "user rather than letting them keep editing."
                )
                return .refusedUnreadable(
                    nodeCount: existing.nodeCount,
                    edgeCount: existing.edgeCount,
                    annotationCount: existing.annotationCount
                )
            }
            // [WF-PE3] Captured BEFORE the mutation so a save throw can restore it. Decoding
            // is safe here: both unreadable and newer-version rows were refused above, so the
            // getter returns the real stored canvas, not a placeholder.
            let priorLayout = existing.layout
            existing.layout = layout    // setter refreshes blob + denormalized counts + updatedAt
            do {
                try context.save()
                return .saved
            } catch {
                // Un-mutate THIS row only — never `context.rollback()`, which would discard
                // every pending change on the shared mainContext, including other subsystems'.
                // Re-running the setter restores blob, counts and cache together; `updatedAt`
                // is re-stamped, which is the one field that may differ from the on-disk row
                // if this restored state is ever flushed by a later save — acceptable against
                // the alternative (the "failed" layout itself being flushed).
                existing.layout = priorLayout
                logger.error(
                    "[PERSISTENCE] Failed to save layout for \(profileID): \(error.localizedDescription). "
                    + "CONSEQUENCE: this canvas edit is not on disk and will be lost on reload. The "
                    + "in-memory row was ROLLED BACK to its pre-save state, so the failed layout "
                    + "cannot ride out on the shared context's next unrelated save."
                )
                return .failed(error.localizedDescription)
            }
        } else {
            // The FIRST save of this profile goes through a THROWAWAY context, not `mainContext`,
            // so a failed save leaves nothing pending anywhere by construction — the scratch
            // context dies with this scope. (A `context.delete(inserted)` retraction on the shared
            // context was tried first and measured NOT to work: after the throwing save, SwiftData
            // still returned the deleted-pending-insert from a fetch on that context.) On success
            // the committed row is visible to `mainContext`'s next fetch like any other row; there
            // is no prior in-memory state for this profile to go stale, because no row existed.
            guard let container = modelContainer else { return .notConfigured }
            let scratch = ModelContext(container)
            scratch.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            do {
                try scratch.save()
                return .saved
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to save the FIRST layout for \(profileID): "
                    + "\(error.localizedDescription). CONSEQUENCE: this canvas edit is not on disk "
                    + "and will be lost on reload. The insert was staged on a throwaway context, so "
                    + "nothing is left pending to ride out on the shared context's next save."
                )
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Reports whether this profile's stored canvas is unreadable, so a view can say so instead of
    /// presenting an empty canvas as the user's own.
    ///
    /// Exists because `hasUnreadableLayout` lives on the `@Model` and every UI layer goes through
    /// this store — without it the flag has no reachable consumer.
    func isLayoutUnreadable(for profileID: UUID) -> Bool {
        guard let context = mainContext else { return false }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)??.hasUnreadableLayout ?? false
    }

    /// The denormalized counts for this profile's stored layout.
    ///
    /// These live OUTSIDE the blob and were written by the last SUCCESSFUL save, so they remain
    /// trustworthy when the blob itself is not — which is what lets the canvas say "it last held
    /// 5 nodes" rather than something vague. Zeroes when there is no row.
    func storedCounts(for profileID: UUID) -> (nodes: Int, edges: Int, annotations: Int) {
        guard let context = mainContext else { return (0, 0, 0) }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return (0, 0, 0) }
        return (row.nodeCount, row.edgeCount, row.annotationCount)
    }

    /// Discards an unreadable canvas and replaces it — the only sanctioned way past the refusal.
    ///
    /// ⚠️ DESTRUCTIVE and irreversible: the undecodable bytes are gone afterwards. Deliberately not
    /// reachable from `save`, so it can only happen when a caller has explicitly decided to. Callers
    /// should confirm with the user first, quoting the counts from `.refusedUnreadable`.
    @discardableResult
    func repairUnreadableLayout(
        _ layout: WorkflowLayout,
        for profileID: UUID,
        reason: String
    ) -> WorkflowLayoutSaveOutcome {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] repairUnreadableLayout called before the container was configured — "
                + "profile \(profileID). CONSEQUENCE: the canvas stays unreadable and unsaveable."
            )
            return .notConfigured
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.replaceUnreadableLayout(layout, reason: reason)
            } else {
                context.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            }
            try context.save()
            logger.warning(
                "[PERSISTENCE] Unreadable canvas REPAIRED — profile \(profileID), reason: \(reason). "
                + "CONSEQUENCE: the previous undecodable bytes are overwritten and unrecoverable; "
                + "saves for this profile work normally again."
            )
            return .saved
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to repair layout for \(profileID): "
                + "\(error.localizedDescription). CONSEQUENCE: the canvas remains unreadable and "
                + "every save stays refused."
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes the layout row for a workflow profile (if any). Called from the
    /// cascade hook in `BackendProfileService.deleteProfile` so a deleted
    /// workflow profile doesn't leave an orphan layout behind.
    func delete(for profileID: UUID) {
        guard let context = mainContext else {
            logger.error("delete(for:) called before container was configured — drop.")
            return
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
                try context.save()
                logger.info("Deleted layout for profile \(profileID).")
            }
        } catch {
            logger.error("Failed to delete layout for \(profileID): \(error.localizedDescription)")
        }
    }
}
