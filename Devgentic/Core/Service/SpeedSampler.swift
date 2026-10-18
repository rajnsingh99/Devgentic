// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeedSampler.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Rolling-window speed sampler. Stores (bytes, date) pairs and computes
/// `bytesPerSecond` from the span of surviving samples. Not thread-safe —
/// call from a single actor (we use it on `@MainActor DownloadManager`).
struct SpeedSampler {

    private struct Sample {
        let bytes: Int64
        let date: Date
    }

    private var samples: [Sample] = []

    /// Drop samples older than this. 3s balances responsiveness (reacts to
    /// a real slowdown within 3s) with smoothing (doesn't whiplash on each
    /// packet's instantaneous rate).
    private let windowSeconds: TimeInterval

    /// Cap on sample count — prevents unbounded growth if a backend fires
    /// progress callbacks many times per second.
    private let maxSamples: Int

    /// Minimum time-span between first and last sample before we're
    /// willing to compute a rate. Under this, `bytesPerSecond` returns nil.
    private let minimumSpanSeconds: TimeInterval

    init(
        windowSeconds: TimeInterval = 3.0,
        maxSamples: Int = 30,
        minimumSpanSeconds: TimeInterval = 0.5
    ) {
        self.windowSeconds = windowSeconds
        self.maxSamples = maxSamples
        self.minimumSpanSeconds = minimumSpanSeconds
    }

    /// Append a new sample and prune the window. Idempotent on equal
    /// `bytes` if the caller accidentally replays a value — rate just
    /// reads 0 B/s for that interval, which is a truthful statement.
    mutating func record(bytes: Int64, at date: Date = Date()) {
        samples.append(Sample(bytes: bytes, date: date))
        prune(now: date)
    }

    /// Average rate over the surviving window. Nil when we don't have
    /// enough samples yet, or the span is too short.
    var bytesPerSecond: Double? {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return nil }
        let deltaSeconds = last.date.timeIntervalSince(first.date)
        guard deltaSeconds >= minimumSpanSeconds else { return nil }
        let deltaBytes = last.bytes - first.bytes
        // Negative delta means the backend restarted / reset its counter;
        // drop the stale first sample and return nil (let the next sample
        // start a fresh window).
        guard deltaBytes >= 0 else { return nil }
        return Double(deltaBytes) / deltaSeconds
    }

    /// ETA in seconds to finish downloading `remainingBytes` at the
    /// current sampled speed. Nil when speed is unknown or zero.
    func etaSeconds(remainingBytes: Int64) -> TimeInterval? {
        guard remainingBytes > 0 else { return 0 }
        guard let speed = bytesPerSecond, speed > 0 else { return nil }
        return Double(remainingBytes) / speed
    }

    /// Clear all samples. Call on a fresh download start so stale
    /// samples from a prior download of the same model don't bleed in.
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    // MARK: - Internal

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        samples.removeAll { $0.date < cutoff }
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}

/// Snapshot of a single active download's live metrics. Published on
/// `DownloadManager.activeSpeeds` so views can render speed + ETA
/// without direct access to the internal sampler map.
struct DownloadSpeedSnapshot: Equatable {
    /// Bytes per second over the rolling window. Always ≥ 0.
    let bytesPerSecond: Double
    /// Seconds-to-completion estimate. Nil when total size is unknown
    /// (MLX pre-fetch failed, Whisper Progress hasn't settled, etc.).
    let etaSeconds: TimeInterval?
}
