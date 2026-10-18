// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LogRecorder.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Singleton actor that buffers log entries and periodically persists them.
actor LogRecorder {

    static let shared = LogRecorder()

    private let osLogger = Logger(subsystem: DGLogger.subsystem,
                                   category: "LogRecorder")

    // MARK: - Configuration

    /// Max entries held in memory before the ring drops oldest. At 5000 entries
    /// × ~500 bytes each, worst-case ~2.5 MB RAM. Bounded and safe.
    private let capacity: Int = 5_000

    /// Flush to disk when buffer reaches this many entries. Amortizes write cost.
    private let flushThreshold: Int = 500

    /// Periodic flush interval. Mitigates data loss from sudden quits.
    private let flushInterval: TimeInterval = 5.0

    // MARK: - State

    private var buffer: [LogEntry] = []
    private var flushTask: Task<Void, Never>?
    private let store: TraceStore?

    private init() {
        self.store = TraceStore.shared
        startFlushLoop()
    }

    private func startFlushLoop() {
        // Capture the interval before the Task so the loop doesn't need to
        // round-trip through actor isolation to read an immutable constant.
        let interval = flushInterval
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.flush()
            }
        }
    }

    // MARK: - Write

    /// Records a log entry. Append to the ring, evict oldest on overflow, trigger
    /// a threshold flush if the buffer is getting fat. Safe to call at high frequency.
    func record(_ entry: LogEntry) {
        if buffer.count >= capacity {
            // Evict oldest — ring semantics. Chose eviction over drop-newest because
            // the most recent entries are usually most relevant to a bug report.
            buffer.removeFirst()
        }
        buffer.append(entry)

        if buffer.count >= flushThreshold {
            // Fire-and-forget threshold flush. Separate Task so `record` stays fast.
            Task { await self.flush() }
        }
    }

    // MARK: - Flush

    /// Writes pending entries to SQLite and clears the in-memory buffer.
    /// Fails soft — a flush error leaves entries in-buffer for retry; if the
    /// buffer keeps growing past capacity, oldest are evicted per `record(_:)`.
    func flush() {
        guard let store, !buffer.isEmpty else { return }

        let toFlush = buffer
        do {
            try store.insertLogEntries(toFlush)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            osLogger.warning("LogRecorder flush failed: \(error.localizedDescription). \(self.buffer.count) entries pending retry.")
        }
    }

    // MARK: - Query

    /// In-memory recent entries. Use for live tailing; for older data hit SQLite.
    /// - Parameters:
    ///   - since: lower-bound timestamp (exclusive). Nil returns all buffered.
    ///   - minLevel: drop entries below this severity.
    ///   - limit: cap result count to the most recent N after filtering.
    func recent(since: Date? = nil, minLevel: LogLevel? = nil, limit: Int? = nil) -> [LogEntry] {
        var result = buffer
        if let since {
            result = result.filter { $0.timestamp > since }
        }
        if let minLevel {
            result = result.filter { $0.level >= minLevel }
        }
        if let limit, result.count > limit {
            result = Array(result.suffix(limit))
        }
        return result
    }

    /// Persisted entries from SQLite. Use for historical queries beyond the
    /// in-memory ring's window (~5 min of heavy logging).
    func persistedRecent(since: Date, minLevel: LogLevel? = nil, limit: Int = 10_000) -> [LogEntry] {
        guard let store else { return [] }
        return (try? store.fetchLogEntries(since: since, minLevel: minLevel, limit: limit)) ?? []
    }

    /// Full recent (buffer + persisted) deduplicated by id. Useful for the
    /// diagnostic export bundle — pulls the last N hours regardless of where
    /// entries live.
    func export(since: Date, minLevel: LogLevel? = nil) -> [LogEntry] {
        let persisted = persistedRecent(since: since, minLevel: minLevel)
        let inMemory = recent(since: since, minLevel: minLevel)
        // Inmemory entries have nil IDs (not yet persisted); persisted have IDs.
        // A quick dedup by (timestamp, message) — imperfect but avoids a round-trip
        // dance with the flush state.
        var seen = Set<String>()
        var merged: [LogEntry] = []
        for entry in persisted + inMemory {
            let key = "\(entry.timestamp.timeIntervalSince1970)|\(entry.message)"
            if seen.insert(key).inserted {
                merged.append(entry)
            }
        }
        return merged.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Lifecycle

    /// Called from app lifecycle hooks. Final opportunity to persist pending logs
    /// before quit/suspension. Synchronous from the caller's perspective because
    /// we `await` — but still fast (single batch insert).
    func prepareForTermination() {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }
}
