// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SystemHealthSource.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Reports current system health — RAM availability, chip info, and disk space.
/// Uses the existing `SystemHardwareProfiler` infrastructure.
final class SystemHealthSource: BriefingSource {

    let id = "system_health"
    let displayName = "System"
    let icon = "desktopcomputer"

    var isEnabled: Bool { true }

    func gather() async -> [BriefFragment] {
        let profile = SystemHardwareProfiler.shared.profile
        let diskInfo = Self.queryDiskSpace()

        var detail = "\(profile.formattedAvailableRAM) available of \(profile.formattedTotalRAM)"
        if let disk = diskInfo {
            detail += " — \(disk) free on disk"
        }

        // Determine health status
        let ramRatio = Double(profile.availableRAM) / Double(profile.totalRAM)
        let statusEmoji: String
        let statusLabel: String
        if ramRatio > 0.3 {
            statusEmoji = "checkmark.circle.fill"
            statusLabel = "System healthy"
        } else if ramRatio > 0.15 {
            statusEmoji = "exclamationmark.triangle.fill"
            statusLabel = "Memory pressure detected"
        } else {
            statusEmoji = "xmark.octagon.fill"
            statusLabel = "Low memory"
        }

        let chipLabel = profile.chipFamily.rawValue

        return [
            BriefFragment(
                sourceID: id,
                title: "\(statusLabel) — \(chipLabel)",
                detail: detail,
                priority: 0,
                rawContext: "System: \(chipLabel), RAM \(profile.formattedAvailableRAM)/\(profile.formattedTotalRAM), \(diskInfo ?? "unknown") disk free"
            )
        ]
    }

    // MARK: - Disk Space

    /// Returns a human-readable free disk space string, or nil on failure.
    private static func queryDiskSpace() -> String? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeBytes = attrs[.systemFreeSize] as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }
}
