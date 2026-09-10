// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ObservationStream.swift
//  Devgentic
//
//  Reusable wrapper around the "manually re-subscribing" `withObservationTracking`
//  pattern. The raw idiom requires a recursive helper function at each call site:
//
//      func observe() {
//          withObservationTracking {
//              _ = source.prop1
//              _ = source.prop2
//          } onChange: {
//              Task { @MainActor [weak self] in
//                  guard let self, self.isObserving else { return }
//                  // do work...
//                  observe()   // re-register for the next change
//              }
//          }
//      }
//
//  That shape was duplicated across six+ view models / services in this project.
//  Each copy reintroduced the same small hazards:
//    - Missing `[weak self]` → retain cycle through the onChange closure.
//    - Missing the `guard self.isObserving` / `isActive` flag → continues firing
//      after the owner is deallocated, writing to zombie state.
//    - Forgetting to re-call the inner `observe()` → chain dies silently after
//      a single fire, bugs manifest as "stopped updating after the first change."
//
//  `ObservationStream` owns the flag, the recursive re-registration, and the
//  cancellation semantics in one place. Callers supply two closures:
//
//      let stream = ObservationStream(
//          track: { [weak self] in
//              _ = self?.service.someProperty
//          },
//          onChange: { [weak self] in
//              self?.mirrorServiceState()
//          }
//      )
//
//      // Later, or automatically on deinit:
//      stream.cancel()
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
