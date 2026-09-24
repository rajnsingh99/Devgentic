// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessTree.swift
//  Devgentic
//
//  Killing a shell command means killing what it STARTED, not just the shell.
//
//  `batch_command` runs `/bin/zsh -c "xcodebuild …"`. SIGTERM to that zsh reaches the zsh. The
//  compiler under it is a separate process that survives, gets re-parented to launchd, and keeps
//  burning CPU — so `command_stop` reported "stopped" while the build ran on. Over a 15-minute
//  bound that is the difference between stopped and invisible.
//
//  ── Why not killpg ─────────────────────────────────────────────────────────────────────
//
//  The obvious fix is a process group: give the child its own, then `killpg` it. We cannot,
//  yet, and the reason matters. `Process` offers no way to set the child's process group, so a
//  child spawned by it INHERITS OURS. `killpg(getpgid(child))` would therefore signal
//  **Devgentic itself** — precisely the `pid == 0` case `kill_process` refuses by name.
//
//  Getting a real process group means `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, which also
//  means giving up `Process` — and with it `isRunning`, `terminationHandler` and
//  `terminationStatus`. `isRunning` is the pid-reuse guard every signal in this codebase is
//  built on, so trading it away to gain `killpg` would swap a known-safe kill for a
//  hand-rolled one. Walking the tree keeps both.
//
//  ── Why the tree is snapshotted BEFORE anything is signalled ────────────────────────────
//
//  ⚠️ THE ORDERING IS THE WHOLE TRICK. Signal the root first and its children are re-parented
//  to launchd (ppid 1) the moment it dies — at which point the ppid chain that identifies them
//  as ours is GONE and they cannot be found at all. So: snapshot the descendants, and only
//  then start signalling. Everything after the snapshot works from that list.
//
//  Best-effort by nature: a process forked between the snapshot and the signal is missed. That
//  is a real limit, not a bug to be fixed by trying harder — only a process group closes it,
//  and the trade above is why we do not have one.
//

import Foundation
import Darwin
import os

private let logger = DGLogger(category: "ProcessTree")

enum ProcessTree {

    /// A process, identified in a way that survives being written down.
    ///
    /// ⚠️ pid ALONE IS NOT AN IDENTITY. macOS recycles pids, so a pid captured a minute ago may
    /// name something entirely different by the time it is signalled — the hazard this codebase
    /// guards against everywhere it holds a `Process` object instead of a number. Here there IS no
    /// `Process` object to hold: these are grandchildren spawned by a shell. The start time closes
    /// the gap, because two processes can share a pid over time but cannot share a pid AND the
    /// microsecond they started.
    struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startedAt: TimeInterval
    }

    /// Every live process on the machine, with its parent and its identity.
    ///
    /// `KERN_PROC_ALL` is sized then read, and the list can GROW between the two calls — so the
    /// buffer carries headroom and the second call's returned size, not the first's, decides how
    /// many entries are real. Reading the first call's count back would walk uninitialised memory.
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

    /// `root`'s descendants, DEEPEST FIRST, excluding `root` itself.
    ///
    /// Deepest-first so a signalled parent cannot orphan a sibling subtree we have not reached —
    /// the same reason the snapshot comes first, one level down.
    static func descendants(of root: pid_t) -> [pid_t] {
        descendantIdentities(of: root).map(\.pid)
    }

    /// The same walk, keeping each descendant's identity so the result can be REMEMBERED.
    ///
    /// ⚠️ This is the fix for the orphan defect. Walking only at kill time fails when the root has
    /// already exited: its children are re-parented to launchd and the ppid chain that identified
    /// them as ours is gone, so the walk returns nothing and the bound kills a process that had
    /// already left. Captured WHILE the root is alive, the list stays usable afterwards.
    static func descendantIdentities(of root: pid_t) -> [ProcessIdentity] {
        guard root > 1 else { return [] }

        var childrenOf: [pid_t: [ProcessIdentity]] = [:]
        for entry in allProcesses() where entry.ppid > 0 {
            childrenOf[entry.ppid, default: []].append(entry.identity)
        }

        var ordered: [ProcessIdentity] = []
        var frontier = childrenOf[root] ?? []
        // Depth-bounded rather than `while !frontier.isEmpty`. A ppid table is a tree in practice,
        // but it is read from live kernel state with no such guarantee, and a cycle here would
        // hang the quit path inside a 3 s watchdog.
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

    /// SIGTERM the tree, wait `grace`, SIGKILL whatever is left.
    ///
    /// `isRootRunning` is passed as a closure rather than re-derived from the pid, so the caller
    /// can answer it from its retained `Process` — the pid-reuse guard. Descendants have no such
    /// handle and are signalled by pid; the snapshot is taken microseconds earlier, which is the
    /// narrowest window available without a process group.
    ///
    /// Returns the number of descendants it found, for the caller's log.
    ///
    /// `alsoKnown` is a set captured EARLIER, while the root was alive. Identities in it that are
    /// no longer present — or whose pid has been recycled onto a different process — are dropped
    /// before anything is signalled.
    @discardableResult
    static func terminateTree(root: pid_t,
                              grace: TimeInterval,
                              isRootRunning: @escaping () -> Bool,
                              alsoKnown: Set<ProcessIdentity> = []) -> Int {
        guard root > 1 else { return 0 }

        // ⚠️ BEFORE any signal. See the type comment — killing the root first destroys the ppid
        // chain that identifies its children as ours.
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

    /// Phase 1: snapshot every tree, SIGTERM all of them, and hand back the full set for phase 2.
    ///
    /// ⚠️ Split in two deliberately. The quit path has SEVERAL tasks and a 3 s watchdog over the
    /// whole teardown, so a per-task `snapshot → TERM → sleep → KILL` would spend the grace once
    /// per task and blow the budget on four of them — the app gets killed mid-teardown instead of
    /// exiting cleanly, which is the orphan this code exists to prevent. One shared grace between
    /// the phases costs it once.
    static func requestTermination(roots: [pid_t], alsoKnown: Set<ProcessIdentity> = []) -> [pid_t] {
        var everything: [pid_t] = []
        for root in roots where root > 1 {
            everything.append(contentsOf: liveTargets(root: root, alsoKnown: alsoKnown))
            everything.append(root)
        }
        signal(everything, SIGTERM)
        return everything
    }

    /// Phase 2: SIGKILL exactly what phase 1 signalled.
    ///
    /// Works from phase 1's list rather than re-walking: by now the roots may be dead and their
    /// children re-parented to launchd, so a second walk would find nothing.
    static func forceTermination(_ pids: [pid_t]) {
        signal(pids, SIGKILL)
    }

    /// The pids to signal for `root`: a fresh walk, plus anything remembered from earlier that is
    /// STILL THE SAME PROCESS.
    ///
    /// ⚠️ The validation is the point, not a formality. A remembered pid whose start time no
    /// longer matches has been recycled onto something else — signalling it would kill an
    /// unrelated process, which is a far worse failure than the orphan it was meant to catch.
    /// One `sysctl` serves both the walk and the check.
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

    /// Filters a remembered set down to the identities that are still the same live process.
    ///
    /// Lets a caller keep its set bounded to what actually exists instead of accumulating every
    /// process a long build ever spawned. A descendant whose CHAIN broke is still alive and
    /// survives this — that is exactly what the set is for.
    static func stillAlive(_ identities: Set<ProcessIdentity>) -> Set<ProcessIdentity> {
        guard !identities.isEmpty else { return [] }
        let alive = Set(allProcesses().map(\.identity))
        return identities.intersection(alive)
    }

    /// ⚠️ The only place this file signals a pid, so the refusals live once.
    ///
    /// `pid <= 1` is never a target: in POSIX `kill`, 0 is the caller's own process group and -1
    /// is every process the user owns. `getpid()` is excluded outright — a corrupt ppid table
    /// naming us as our own descendant would otherwise have this method kill the app. Neither
    /// has been observed; both cost one comparison, and `kill_process` has already paid for the
    /// version of this lesson where the guard was missing.
    private static func signal(_ pids: [pid_t], _ sig: Int32) {
        let own = getpid()
        for pid in pids where pid > 1 && pid != own {
            kill(pid, sig)
        }
    }
}
