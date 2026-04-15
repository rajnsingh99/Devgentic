//
//  ProfileExporter.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  Export and import BackendProfileSnapshots as JSON files.
//  Uses NSSavePanel/NSOpenPanel following the ConversationExporter pattern.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ProfileExporter")

// MARK: - Custom UTType

extension UTType {
    /// Custom file type for Devgentic profile bundles.
    static let devgenticProfile = UTType(exportedAs: "com.devgentic.profile", conformingTo: .json)
}

// MARK: - Export Envelope

/// Versioned envelope wrapping exported profiles, so future builds can detect and migrate older files.
struct ProfileExportEnvelope: Codable {
    /// Format version — increment when the envelope or profile schema changes.
    let formatVersion: Int
    /// ISO-8601 timestamp of when the export was created.
    let exportedAt: Date
    /// The app build that produced this export (e.g. "98.7").
    let appVersion: String
    /// The exported profiles (API keys stripped).
    let profiles: [BackendProfileSnapshot]

    static let currentFormatVersion = 1
}

// MARK: - Import Result

/// Per-profile import result used for merge/conflict resolution.
struct ProfileImportCandidate {
    let profile: BackendProfileSnapshot
    /// `true` if a profile with the same `displayName` already exists locally.
    let isConflict: Bool
    /// The existing profile that conflicts, if any.
    let existingMatch: BackendProfileSnapshot?
}

// MARK: - Exporter

struct ProfileExporter {

    /// Exports an array of profiles to a versioned JSON file via NSSavePanel.
    /// - Parameter profiles: The profiles to export.
    /// - Returns: `true` if the export succeeded, `false` if cancelled or failed.
    @MainActor
    static func exportProfiles(_ profiles: [BackendProfileSnapshot]) -> Bool {
        guard !profiles.isEmpty else {
            logger.warning("Export called with empty profiles array.")
            return false
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Profiles"
        savePanel.nameFieldStringValue = "DevgenticProfiles.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return false
        }

        do {
            // Validate and strip API keys from exported data (security)
            let sanitized = profiles.compactMap { profile -> BackendProfileSnapshot? in
                let errors = ProfileValidator.validate(profile, strict: false)
                if !errors.isEmpty {
                    logger.warning("Skipping invalid profile '\(profile.displayName)' during export: \(errors.map(\.message).joined(separator: ", "))")
                    return nil
                }
                var copy = profile
                copy.details = clearApiKey(in: copy.details)
                return copy
            }

            let envelope = ProfileExportEnvelope(
                formatVersion: ProfileExportEnvelope.currentFormatVersion,
                exportedAt: Date(),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                profiles: sanitized
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(envelope)
            try data.write(to: url, options: .atomic)
            logger.info("Exported \(profiles.count) profile(s) to \(url.lastPathComponent)")
            return true
        } catch {
            logger.error("Failed to export profiles: \(error.localizedDescription)")
            return false
        }
    }

    /// Imports profiles from a JSON file via NSOpenPanel.
    /// Supports both the versioned envelope format and the legacy bare-array format.
    /// - Parameter existingProfiles: Current profiles for conflict detection.
    /// - Returns: Import candidates with conflict info, or `nil` if cancelled/failed.
    @MainActor
    static func importProfiles(existingProfiles: [BackendProfileSnapshot] = []) -> [ProfileImportCandidate]? {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Profiles"
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.prompt = "Import"

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var rawProfiles: [BackendProfileSnapshot]

            // Try versioned envelope first, fall back to legacy bare array
            if let envelope = try? decoder.decode(ProfileExportEnvelope.self, from: data) {
                logger.info("Importing from envelope v\(envelope.formatVersion) (exported \(envelope.exportedAt), app \(envelope.appVersion))")
                rawProfiles = envelope.profiles
            } else {
                // Legacy format: bare [BackendProfileSnapshot] array
                rawProfiles = try decoder.decode([BackendProfileSnapshot].self, from: data)
                logger.info("Importing from legacy (non-envelope) format.")
            }

            // Build existing name lookup for conflict detection
            let existingNames = Set(existingProfiles.map { $0.displayName.lowercased() })

            let candidates = rawProfiles.map { original -> ProfileImportCandidate in
                let lowerName = original.displayName.lowercased()
                let existingMatch = existingProfiles.first { $0.displayName.lowercased() == lowerName }

                // Always assign new UUID to avoid ID collisions
                let imported = BackendProfileSnapshot(
                    id: UUID(),
                    displayName: original.displayName,
                    lastSelected: nil,
                    details: original.details
                )

                return ProfileImportCandidate(
                    profile: imported,
                    isConflict: existingNames.contains(lowerName),
                    existingMatch: existingMatch
                )
            }

            // Validate each candidate — skip profiles that fail validation
            let valid = candidates.filter { candidate in
                let errors = ProfileValidator.validate(candidate.profile, strict: true)
                if !errors.isEmpty {
                    logger.warning("Skipping invalid imported profile '\(candidate.profile.displayName)': \(errors.map(\.message).joined(separator: ", "))")
                }
                return errors.isEmpty
            }

            logger.info("Imported \(valid.count) valid profile(s) from \(url.lastPathComponent) (\(candidates.count - valid.count) skipped)")
            return valid
        } catch {
            logger.error("Failed to import profiles: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Helpers

    private static func clearApiKey(in details: ProfileDetails) -> ProfileDetails {
        switch details {
        case .bot(var config):
            config.llmConfig.apiKey = nil
            return .bot(config)
        case .agent(var config):
            config.llmConfig.apiKey = nil
            return .agent(config)
        case .imageGen(var config):
            config.llmConfig.apiKey = nil
            return .imageGen(config)
        case .workflow:
            return details
        }
    }
}
