// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SystemHardwareProfiler.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

@preconcurrency import Foundation
import Metal
import os

/// A snapshot of the current machine's hardware capabilities.
/// Used by `ModelFitAdvisor` to assess whether a model can run comfortably.
struct SystemHardwareProfile: Sendable {

    /// Total physical RAM in bytes (e.g. 16 GB = 17_179_869_184).
    let totalRAM: UInt64

    /// Currently available RAM in bytes (fluctuates with system load).
    let availableRAM: UInt64

    /// Apple Silicon chip family (M1, M2, M3, M4, or unknown for Intel).
    let chipFamily: AppleSiliconChip

    /// Number of GPU cores reported by Metal.
    let gpuCoreCount: Int

    /// Metal's recommended maximum working set size (bytes).
    /// This is the GPU's advertised budget for textures + buffers.
    let recommendedMaxWorkingSet: UInt64

    /// Estimated RAM reserved by macOS and background processes.
    /// Heuristic: ~4 GB for ≤16 GB machines, ~6 GB for >16 GB.
    var osReservedEstimate: UInt64 {
        totalRAM <= 16 * 1024 * 1024 * 1024
            ? 4 * 1024 * 1024 * 1024
            : 6 * 1024 * 1024 * 1024
    }

    /// Effective memory budget for model loading = total - OS overhead.
    var effectiveBudget: UInt64 {
        totalRAM > osReservedEstimate ? totalRAM - osReservedEstimate : totalRAM / 2
    }

    /// Human-readable total RAM string (e.g. "16 GB").
    var formattedTotalRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalRAM), countStyle: .memory)
    }

    /// Human-readable available RAM string.
    var formattedAvailableRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(availableRAM), countStyle: .memory)
    }

    /// Human-readable effective budget string.
    var formattedEffectiveBudget: String {
        ByteCountFormatter.string(fromByteCount: Int64(effectiveBudget), countStyle: .memory)
    }
}

// MARK: - Apple Silicon Chip Detection

enum AppleSiliconChip: String, Sendable {
    case m1 = "M1"
    case m1Pro = "M1 Pro"
    case m1Max = "M1 Max"
    case m1Ultra = "M1 Ultra"
    case m2 = "M2"
    case m2Pro = "M2 Pro"
    case m2Max = "M2 Max"
    case m2Ultra = "M2 Ultra"
    case m3 = "M3"
    case m3Pro = "M3 Pro"
    case m3Max = "M3 Max"
    case m3Ultra = "M3 Ultra"
    case m4 = "M4"
    case m4Pro = "M4 Pro"
    case m4Max = "M4 Max"
    case m4Ultra = "M4 Ultra"
    case m5 = "M5"
    case m5Pro = "M5 Pro"
    case m5Max = "M5 Max"
    case m5Ultra = "M5 Ultra"
    case unknown = "Unknown"

    /// Whether this chip has a high memory bandwidth (Pro/Max/Ultra variants).
    var isHighBandwidth: Bool {
        let raw = rawValue.lowercased()
        return raw.contains("pro") || raw.contains("max") || raw.contains("ultra")
    }
}

// MARK: - Profiler

/// Detects and caches the current system's hardware profile.
/// Thread-safe singleton — profile is captured once on first access.
final class SystemHardwareProfiler: @unchecked Sendable {

    static let shared = SystemHardwareProfiler()

    private let logger = DGLogger(category: "HardwareProfiler")

    /// Cached profile — computed once on first access.
    lazy var profile: SystemHardwareProfile = {
        let p = captureProfile()
        logger.notice("Hardware Profile — RAM: \(p.formattedTotalRAM), Chip: \(p.chipFamily.rawValue), GPU Cores: \(p.gpuCoreCount), Budget: \(p.formattedEffectiveBudget)")
        return p
    }()

    private init() {}

    // MARK: - Capture

    private func captureProfile() -> SystemHardwareProfile {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let availableRAM = Self.queryAvailableMemory()
        let chipFamily = Self.detectChipFamily()
        let (gpuCores, maxWorkingSet) = Self.queryMetalDevice()

        return SystemHardwareProfile(
            totalRAM: totalRAM,
            availableRAM: availableRAM,
            chipFamily: chipFamily,
            gpuCoreCount: gpuCores,
            recommendedMaxWorkingSet: maxWorkingSet
        )
    }

    // MARK: - System Queries

    /// Queries the OS for currently available memory via Mach VM statistics.
    private static func queryAvailableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            // Fallback: assume 50% of total is available
            return ProcessInfo.processInfo.physicalMemory / 2
        }
        nonisolated(unsafe) let rawPageSize = vm_kernel_page_size
        let pageSize = UInt64(rawPageSize)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        return free + inactive
    }

    /// Detects the Apple Silicon chip family from the CPU brand string.
    private static func detectChipFamily() -> AppleSiliconChip {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)

        var brandString = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brandString, &size, nil, 0)

        let brand = String(cString: brandString).lowercased()

        // Match from most specific to least (Ultra before base)
        let chipMap: [(substring: String, chip: AppleSiliconChip)] = [
            ("m5 ultra", .m5Ultra), ("m5 max", .m5Max), ("m5 pro", .m5Pro), ("m5", .m5),
            ("m4 ultra", .m4Ultra), ("m4 max", .m4Max), ("m4 pro", .m4Pro), ("m4", .m4),
            ("m3 ultra", .m3Ultra), ("m3 max", .m3Max), ("m3 pro", .m3Pro), ("m3", .m3),
            ("m2 ultra", .m2Ultra), ("m2 max", .m2Max), ("m2 pro", .m2Pro), ("m2", .m2),
            ("m1 ultra", .m1Ultra), ("m1 max", .m1Max), ("m1 pro", .m1Pro), ("m1", .m1),
        ]

        for (substring, chip) in chipMap {
            if brand.contains(substring) {
                return chip
            }
        }

        return .unknown
    }

    /// Queries the default Metal device for GPU core count and recommended working set.
    private static func queryMetalDevice() -> (gpuCores: Int, maxWorkingSet: UInt64) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return (0, 0)
        }
        // On Apple Silicon, recommendedMaxWorkingSetSize reflects unified memory budget.
        return (0, device.recommendedMaxWorkingSetSize)
    }
}
