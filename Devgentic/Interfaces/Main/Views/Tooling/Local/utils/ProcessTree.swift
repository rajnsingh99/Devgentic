// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessTree.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Darwin
import os

private let logger = DGLogger(category: "ProcessTree")

/// Terminates a shell command's whole process tree, not just the shell: children survive a SIGTERM to
/// `/bin/zsh -c`. A process group is not used because `Process` children inherit ours, so `killpg`
/// would signal Devgentic itself.
enum ProcessTree {

    /// A process identified in a way that survives being written down: pid plus start time.
    /// pid alone is not an identity because macOS recycles pids; two processes cannot share a pid and a
    /// start microsecond.
    struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startedAt: TimeInterval
    }

    /// Every live process on the machine, with its parent and its identity.
    /// `KERN_PROC_ALL` is sized then read and the list can grow between calls, so the second call's
    /// returned size decides the count.
    private static func allProcesses() -> [(identity: ProcessIdentity, ppid: pid_t)] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else {
            logger.error("[PROCTREE] sysctl sizing failed (errno \(errno)) — descendants cannot be enumerated. CONSEQUENCE: only the direct child is signalled, so a command's sub-processes may survive it.")
            return []
        }

        let slack = 64
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + slack)
        size = entries.count * MemoryLayout<kinfo_proc>.stride

        guard sysctl(&name, 4, &entries, &size, nil, 0) == 0 else {
            logger.error("[PROCTREE] sysctl read failed (errno \(errno)) — descendants cannot be enumerated. CONSEQUENCE: only the direct child is signalled.")
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return (0..<count).map { index in
            let row = entries[index]
            let start = row.kp_proc.p_un.__p_starttime
            return (ProcessIdentity(pid: row.kp_proc.p_pid,
                                    startedAt: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000),
                    row.kp_eproc.e_ppid)
        }
    }

    /// `root`'s descendants, deepest first, excluding `root` itself.
    /// Deepest first so a signalled parent cannot orphan a sibling subtree not yet reached.
    static func descendants(of root: pid_t) -> [pid_t] {
        descendantIdentities(of: root).map(\.pid)
    }

    /// The same walk, keeping each descendant's identity so the result can be remembered.
    /// Captured while the root is alive: once it exits, children re-parent to launchd and a later walk
    /// finds nothing.
    static func descendantIdentities(of root: pid_t) -> [ProcessIdentity] {
        guard root > 1 else { return [] }

        var childrenOf: [pid_t: [ProcessIdentity]] = [:]
        for entry in allProcesses() where entry.ppid > 0 {
            childrenOf[entry.ppid, default: []].append(entry.identity)
        }

        var ordered: [ProcessIdentity] = []
        var frontier = childrenOf[root] ?? []
        // Depth-bounded rather than `while !frontier.isEmpty`: the ppid table is live kernel state and a cycle
        // would hang the quit path.
        var depth = 0
        var seen: Set<pid_t> = [root]

        while !frontier.isEmpty, depth < 32 {
            var next: [ProcessIdentity] = []
            for child in frontier where !seen.contains(child.pid) {
                seen.insert(child.pid)
                ordered.append(child)
                next.append(contentsOf: childrenOf[child.pid] ?? [])
            }
            frontier = next
            depth += 1
        }

        return ordered.reversed()
    }

    /// SIGTERMs the tree, waits `grace`, then SIGKILLs whatever is left; returns the descendants found.
    /// `isRootRunning` is a closure so the caller can answer from its retained `Process`; `alsoKnown` holds
    /// identities captured earlier, filtered for recycled pids.
    @discardableResult
    static func terminateTree(root: pid_t,
                              grace: TimeInterval,
                              isRootRunning: @escaping () -> Bool,
                              alsoKnown: Set<ProcessIdentity> = []) -> Int {
        guard root > 1 else { return 0 }

        // Taken before any signal: killing the root first destroys the ppid chain that identifies its
        // children.
        let tree = liveTargets(root: root, alsoKnown: alsoKnown)

        signal(tree, SIGTERM)
        if isRootRunning() { kill(root, SIGTERM) }

        guard grace > 0 else {
            signal(tree, SIGKILL)
            if isRootRunning() { kill(root, SIGKILL) }
            return tree.count
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            signal(tree, SIGKILL)
            if isRootRunning() { kill(root, SIGKILL) }
        }
        return tree.count
    }

    // MARK: - Two-phase, for the quit path

    /// First step: snapshots every tree, SIGTERMs all of them, and returns the full set for the second
    /// step. Split in two so one shared grace covers all tasks inside the quit path's 3 s watchdog.
    static func requestTermination(roots: [pid_t], alsoKnown: Set<ProcessIdentity> = []) -> [pid_t] {
        var everything: [pid_t] = []
        for root in roots where root > 1 {
            everything.append(contentsOf: liveTargets(root: root, alsoKnown: alsoKnown))
            everything.append(root)
        }
        signal(everything, SIGTERM)
        return everything
    }

    /// Second step: SIGKILLs exactly what the first step signalled, from its list rather than re-walking,
    /// since the roots may be dead and their children re-parented.
    static func forceTermination(_ pids: [pid_t]) {
        signal(pids, SIGKILL)
    }

    /// The pids to signal for `root`: a fresh walk plus anything remembered that is still the same process.
    /// A remembered pid whose start time differs was recycled and must not be signalled.
    private static func liveTargets(root: pid_t, alsoKnown: Set<ProcessIdentity>) -> [pid_t] {
        let fresh = descendantIdentities(of: root)
        guard !alsoKnown.isEmpty else { return fresh.map(\.pid) }

        let currentlyAlive = Set(allProcesses().map(\.identity))
        let survivors = alsoKnown.filter { currentlyAlive.contains($0) }
        if survivors.count < alsoKnown.count {
            logger.debug("[PROCTREE] \(alsoKnown.count - survivors.count) remembered descendant(s) are gone or recycled and were not signalled.")
        }

        var seen = Set(fresh.map(\.pid))
        var targets = fresh.map(\.pid)
        for identity in survivors where !seen.contains(identity.pid) {
            seen.insert(identity.pid)
            targets.append(identity.pid)
        }
        return targets
    }

    /// Filters a remembered set down to identities that are still the same live process, keeping it
    /// bounded. A descendant whose chain broke is still alive and is kept.
    static func stillAlive(_ identities: Set<ProcessIdentity>) -> Set<ProcessIdentity> {
        guard !identities.isEmpty else { return [] }
        let alive = Set(allProcesses().map(\.identity))
        return identities.intersection(alive)
    }

    /// The only place this file signals a pid, so the refusals live once.
    /// `pid <= 1` is never a target (0 is our own group, -1 every user process) and `getpid()` is excluded
    /// outright.
    private static func signal(_ pids: [pid_t], _ sig: Int32) {
        let own = getpid()
        for pid in pids where pid > 1 && pid != own {
            kill(pid, sig)
        }
    }
}
