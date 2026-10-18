// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ObservationStream.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A self-re-subscribing `withObservationTracking` stream. See file header for
/// the boilerplate it replaces. MainActor-isolated because the overwhelming
/// majority of consumers in this project are `@Observable @MainActor` view
/// models mirroring `@Observable @MainActor` services; isolating the helper
/// here keeps Swift 6 concurrency analysis happy.
@MainActor
final class ObservationStream {

    private var isActive = true
    private let track: @MainActor () -> Void
    private let onChange: @MainActor () -> Void

    /// Begin observing. `track` reads the observable properties whose changes
    /// should trigger updates. `onChange` runs on the MainActor whenever any
    /// tracked property changes; after it returns, a fresh observation scope
    /// is automatically re-registered for the same inputs.
    ///
    /// Callers typically capture `self` weakly in both closures to avoid
    /// keeping their owner alive through the stream.
    init(
        track: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.track = track
        self.onChange = onChange
        subscribe()
    }

    private func subscribe() {
        guard isActive else { return }
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            // onChange runs on whichever thread performed the mutation that
            // triggered the callback. Hop to the MainActor to match the
            // isolation of the closures we accepted at init.
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.onChange()
                self.subscribe()
            }
        }
    }

    /// Stop observing. Subsequent changes to tracked properties will not fire
    /// `onChange`. Idempotent — safe to call multiple times.
    func cancel() {
        isActive = false
    }

    deinit {
        isActive = false
    }
}
