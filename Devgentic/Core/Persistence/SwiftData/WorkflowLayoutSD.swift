// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowLayoutSD.swift
//  Devgentic
//
//  SwiftData @Model for `WorkflowLayout` persistence.
//  Replaces the UserDefaults-backed `WorkflowLayoutStore` (sidecar JSON blob).
//
//  One row per workflow profile, keyed by `workflowProfileID` (unique).
//  The full layout (nodes/edges/annotations) is stored as a JSON blob in
//  `layoutData` — mirrors the `BackendProfile.configData` pattern. Reads are
//  always whole-layout (canvas load, executor pre-flight), writes are atomic
//  on "Save Changes", so a single blob is the right granularity.
//
//  Denormalized counts (`nodeCount`, `edgeCount`, `annotationCount`) are kept
//  on the row so listing screens can show quick stats without decoding.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutSD")

@Model
final class WorkflowLayoutSD {

    // MARK: - Persisted Properties

    /// Foreign key to `BackendProfile.id` for the workflow profile this layout belongs to.
    /// Marked unique so each workflow has exactly one layout row.
    @Attribute(.unique)
    var workflowProfileID: UUID

    var updatedAt: Date

    /// Denormalized for queries / listing without decoding the blob.
    var nodeCount: Int
    var edgeCount: Int
    var annotationCount: Int

    /// JSON-encoded `WorkflowLayout`. Single source of truth for nodes/edges/annotations.
    var layoutData: Data

    // MARK: - Transient Cache

    @Transient
    private var _cachedLayout: WorkflowLayout?

    /// True when `layoutData` could not be decoded and `_cachedLayout` is therefore the `.empty`
    /// PLACEHOLDER rather than the user's canvas.
    ///
    /// ⚠️ This is what stops a read failure becoming a write failure — the same class of bug fixed
    /// for `BackendProfile`, but the guard here is deliberately STRICTER. See the setter.
    @Transient
    private var _layoutDecodeFailed: Bool = false

    /// Set by `primeDecodeState` when the blob's stamp exceeds `layoutBlobVersion`. Same transient
    /// discipline as `_layoutDecodeFailed`: never read raw without priming.
    @Transient
    private var _layoutFromNewerVersion: Bool = false

    // MARK: - Computed Accessor

    /// True when the stored canvas could not be read, so `layout` is a placeholder and writes are
    /// being refused. Surface this instead of presenting an empty canvas as if it were the user's.
    ///
    /// Corroborated by the denormalized counts, which live OUTSIDE the blob and were written by the
    /// last successful save: a row claiming nodes while decoding to nothing is proof it once held
    /// content. `BackendProfile` had no equivalent signal.
    var hasUnreadableLayout: Bool {
        primeDecodeState()
        return _layoutDecodeFailed
    }

    /// True when the stored blob was stamped by a NEWER build than this one (WF-PE2).
    ///
    /// ⚠️ The stamp was WRITE-ONLY before this: a v2 blob decoded cleanly on a v1 build (Codable
    /// drops unknown keys silently), and the next save re-encoded the in-memory struct — which
    /// never held the v2-only fields — freshly stamped v1. Every newer-version setting was
    /// stripped permanently, with no error, no log and no dirty indicator, and re-upgrading did
    /// not bring the data back. Sparkle self-distribution makes the rollback that triggers this a
    /// real user path. Writes are refused while this is true; viewing and RUNNING stay allowed,
    /// because the decode genuinely succeeded.
    var hasNewerVersionLayout: Bool {
        primeDecodeState()
        return _layoutFromNewerVersion
    }

    /// The blob's stamped version when it exceeds this build's — for the refusal message.
    var newerBlobVersion: Int? {
        primeDecodeState()
        return _layoutFromNewerVersion ? BlobVersioning.version(of: layoutData) : nil
    }

    /// True when the denormalized counts say this row once held content but the blob now decodes to
    /// nothing — out-of-blob evidence of corruption, independent of any decode attempt.
    var countsContradictStoredLayout: Bool {
        primeDecodeState()
        return (nodeCount > 0 || edgeCount > 0 || annotationCount > 0) && _layoutDecodeFailed
    }

    /// Brings `_cachedLayout` / `_layoutDecodeFailed` into agreement with the CURRENT stored bytes.
    ///
    /// ⚠️ EVERY accessor that consults `_layoutDecodeFailed` must call this first — the setter above
    /// all. `_layoutDecodeFailed` is `@Transient` and therefore defaults to `false` on every freshly
    /// materialized instance, so a guard that reads it raw is only correct if something already
    /// happened to run the getter on that same instance. `WorkflowLayoutStore.save` fetches a row and
    /// assigns straight to `layout` with no intervening read, which sailed past the refusal with the
    /// flag still false and overwrote the unreadable canvas — the exact loss the guard exists to
    /// prevent. Priming makes the refusal a function of what is ON DISK rather than of access order.
    ///
    /// Idempotent and cheap: `_cachedLayout` is non-nil after the first call (the failure path caches
    /// `.empty`), after `init`, and after `applyLayout`, so the decode runs at most once per instance.
    private func primeDecodeState() {
        guard _cachedLayout == nil else { return }
        let outcome = Self.decodeLayout(from: layoutData)
        _cachedLayout = outcome.layout
        _layoutDecodeFailed = outcome.didFail
        // Version probe is separate from decode success: a newer blob usually DECODES fine (the
        // enum catch-alls and decodeIfPresent defaults make it), which is exactly what made the
        // downgrade silent. Probed here so every accessor sees it regardless of access order —
        // the same prime-is-load-bearing rule as `_layoutDecodeFailed`.
        if let stamped = BlobVersioning.version(of: layoutData), stamped > Self.layoutBlobVersion {
            _layoutFromNewerVersion = true
            logger.notice(
                "[PERSISTENCE] Workflow layout for profile \(self.workflowProfileID) was saved by a "
                + "NEWER build (blob v\(stamped), this build understands v\(Self.layoutBlobVersion)). "
                + "CONSEQUENCE: the canvas is readable and runnable but READ-ONLY — saving here would "
                + "silently strip the newer version's fields on re-encode."
            )
        }
    }

    /// The decoded `WorkflowLayout`. Reading decodes from `layoutData` (cached);
    /// writing re-encodes and refreshes the denormalized counts + `updatedAt`.
    var layout: WorkflowLayout {
        get {
            primeDecodeState()
            return _cachedLayout ?? .empty
        }
        set {
            // ⚠️ REFUSE EVERY WRITE while the stored canvas is unreadable — deliberately stricter
            // than `BackendProfile`'s "refuse only the placeholder value" rule. Two reasons, both
            // specific to this entity:
            //
            //   1. `.empty` is a LEGAL user state (`WorkflowCanvasState.clearCanvas()` produces
            //      exactly it), so "the incoming value equals the placeholder" cannot distinguish an
            //      opportunistic save from a deliberate "delete everything". For a profile the
            //      placeholder is an odd blank bot nobody builds on purpose; here it is one click.
            //   2. A profile user who types a new model name can SEE that the config is blank and is
            //      knowingly replacing it. A canvas user cannot tell a decode-failure blank canvas
            //      from a legitimately empty one — so every save made in that session is uninformed,
            //      including ones that differ from `.empty`.
            //
            // (`WorkflowLayout` is not `Equatable` either, so the value test would not even compile.
            // Do not "fix" that by adding the conformance — the rule above is the point.)
            //
            // The escape hatch is `replaceUnreadableLayout(_:reason:)`, which is explicit.
            //
            // ⚠️ The prime is load-bearing, not defensive: without it this guard reads a `@Transient`
            // that is `false` on any instance whose getter has not run. See `primeDecodeState()`.
            primeDecodeState()
            guard !_layoutFromNewerVersion else {
                logger.error(
                    "[PERSISTENCE] Refusing to overwrite NEWER-VERSION workflow layout — profile "
                    + "\(workflowProfileID): the stored blob is v\(BlobVersioning.version(of: layoutData) ?? -1), "
                    + "this build writes v\(Self.layoutBlobVersion), and a re-encode would permanently strip "
                    + "every field this build does not understand. CONSEQUENCE: layoutData is left "
                    + "byte-intact; the canvas stays read-only on this build. Update Devgentic to edit it."
                )
                return
            }
            guard !_layoutDecodeFailed else {
                logger.error(
                    "[PERSISTENCE] Refusing to overwrite unreadable workflow layout — profile "
                    + "\(workflowProfileID): the stored canvas could not be decoded, so this save "
                    + "would replace \(nodeCount) node(s)/\(edgeCount) edge(s)/\(annotationCount) "
                    + "annotation(s) with a canvas the user could not see. CONSEQUENCE: layoutData is "
                    + "left byte-intact and the counts are preserved; the canvas stays read-only "
                    + "until an explicit repair."
                )
                return
            }
            applyLayout(newValue)
        }
    }

    /// Explicitly replaces a canvas that could not be read.
    ///
    /// The only sanctioned way past the setter's refusal. Separate and awkwardly named on purpose:
    /// discarding an unreadable canvas is a destructive, irreversible act and should never be
    /// reachable by an incidental `layout = …` on a save path.
    func replaceUnreadableLayout(_ newValue: WorkflowLayout, reason: String) {
        logger.warning(
            "[PERSISTENCE] Replacing unreadable workflow layout — profile \(workflowProfileID), "
            + "reason: \(reason). Previous counts were \(nodeCount) node(s)/\(edgeCount) edge(s)/"
            + "\(annotationCount) annotation(s). CONSEQUENCE: the original bytes are overwritten and "
            + "are no longer recoverable."
        )
        _layoutDecodeFailed = false
        applyLayout(newValue)
    }

    /// The actual write. Never call this directly from a save path — go through `layout` so the
    /// refusal applies.
    private func applyLayout(_ newValue: WorkflowLayout) {
        _cachedLayout = newValue
        layoutData = Self.encodeLayout(newValue)
        nodeCount = newValue.nodes.count
        edgeCount = newValue.edges.count
        annotationCount = newValue.annotations.count
        updatedAt = Date()
    }

    // MARK: - Initializer

    init(workflowProfileID: UUID, layout: WorkflowLayout) {
        self.workflowProfileID = workflowProfileID
        self.updatedAt = Date()
        self.nodeCount = layout.nodes.count
        self.edgeCount = layout.edges.count
        self.annotationCount = layout.annotations.count
        self.layoutData = Self.encodeLayout(layout)
        self._cachedLayout = layout
    }

    // MARK: - Encode / Decode Helpers

    /// Encodes `WorkflowLayout` to JSON. Asserts on failure rather than writing a
    /// corrupt blob — a valid in-memory layout should always encode cleanly.
    /// Current persisted shape of `layoutData`.
    ///
    /// Inline key: `WorkflowLayout` encodes to an OBJECT whose keys are developer-defined, so the
    /// version rides as a sibling and the blob keeps its shape — existing readers are unaffected and
    /// no type gains a `schemaVersion` property (which would be the G13 trap). Bump on any change to
    /// the persisted shape of nodes, edges or annotations.
    ///
    /// ⚠️ INCLUDING A PURELY ADDITIVE OPTIONAL FIELD. Additive is NOT free here: no Codable in
    /// `WorkflowModels.swift` carries an unknown-key sidecar, so an older build drops the new key on
    /// decode and omits it on re-encode. This stamp is the ONLY thing that turns that drop into a
    /// refused write instead of permanent loss (WF-TS5, pinned by
    /// `BlobWriteRefusalTests.testNewerVersionBlobKeepsAFutureFieldTheDecoderCannotSee`).
    ///
    /// **v2 (2026-08-17)** — `ConditionNodeConfig.decisionPolicy` added (the unified Router
    /// decision setting). Additive and optional, and bumped anyway BECAUSE it is additive: an older
    /// build drops the key on decode and omits it on re-encode, so without the bump a v1 build
    /// could silently launder a Router's policy out of a layout on any ordinary save. With it, that
    /// build reads and RUNS the layout normally and is refused the write — a read-only canvas on
    /// downgrade, which is the trade this stamp exists to make.
    ///
    /// **v3 (2026-08-24)** — `WorkflowNodeConfig.unattendedAutoApprove` added (the explicit
    /// per-node unattended tool approval, WF-SE6/SE11). Additive and optional; bumped for the
    /// same reason as v2 — this key is a SECURITY setting, and a v2 build laundering it out of a
    /// layout on an ordinary save would silently revert a scheduled workflow from "auto-approve
    /// this node's tool" to "refuse it unattended" (or vice versa on a later upgrade re-read).
    static let layoutBlobVersion = 3

    private static func encodeLayout(_ layout: WorkflowLayout) -> Data {
        do {
            return BlobVersioning.stamped(try JSONEncoder().encode(layout), version: layoutBlobVersion)
        } catch {
            logger.fault(
                "[PERSISTENCE] Failed to encode WorkflowLayout (\(layout.nodes.count) node(s)): "
                + "\(error). CONSEQUENCE: an UNDECODABLE marker blob is written instead, so the next "
                + "read reports the canvas as unreadable and refuses further writes rather than "
                + "silently presenting an empty canvas."
            )
            assertionFailure("WorkflowLayout encoding should never fail for a valid in-memory value.")
            // ⚠️ Deliberately NOT an encoded `WorkflowLayout.empty`.
            //
            // That was the previous fallback, and it is the worse of the two failures: an encoded
            // `.empty` DECODES CLEANLY, so it is permanently indistinguishable from a canvas the
            // user really did empty — the corruption becomes invisible and the read path has nothing
            // to flag. The paired `assertionFailure` above is stripped in release, so in a shipped
            // build that was silent, total, and undetectable.
            //
            // A blob that cannot decode is strictly better: `decodeLayout` reports the failure, the
            // setter starts refusing writes, and `countsContradictStoredLayout` still shows what the
            // row used to hold.
            return Data(#"{"__devgentic_encode_failure__":true}"#.utf8)
        }
    }

    /// Decodes `WorkflowLayout` from JSON.
    ///
    /// Returns the value plus whether the decode FAILED. The caller must propagate `didFail`: the
    /// `.empty` returned on failure is safe to display but must never be written back over
    /// `layoutData` (see the `layout` setter).
    private static func decodeLayout(from data: Data) -> (layout: WorkflowLayout, didFail: Bool) {
        do {
            return (try JSONDecoder().decode(WorkflowLayout.self, from: data), false)
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to decode WorkflowLayout (\(data.count) bytes): \(error). "
                + "CONSEQUENCE: an empty canvas is returned for display ONLY — the stored bytes are "
                + "not overwritten, and writes are refused until an explicit repair."
            )
            return (.empty, true)
        }
    }
}
