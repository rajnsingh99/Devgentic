// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAppleSpeechAssets.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Speech

/// Which Apple Speech languages this Mac can use, which are installed, and the install itself, chosen in Settings first.
/// Apple ships one on-device model per locale and `SpeechTranscriber` degrades silently without it, so installed state is
/// explicit.
@available(macOS 26.0, *)
@Observable
final class OrbAppleSpeechAssets {

    @MainActor static let shared = OrbAppleSpeechAssets()

    private let logger = DGLogger(category: "OrbAppleSpeech")

    /// Locales this Mac can recognize at all.
    private(set) var supported: [Locale] = []
    /// Identifiers whose on-device model is already downloaded.
    private(set) var installedIdentifiers: Set<String> = []
    private(set) var isLoading = false
    private(set) var isInstalling = false
    private(set) var installProgress: Double = 0
    private(set) var installingIdentifier: String?
    private(set) var lastError: String?

    private init() {}

    func isInstalled(_ locale: Locale) -> Bool {
        installedIdentifiers.contains(locale.identifier)
    }

    /// Loads the supported and installed lists. Cheap enough to call whenever the pane appears.
    @MainActor
    func refresh() async {
        guard !isLoading else {
            logger.info("[ORB_APPLE_ASR] Refresh ignored — one is already running. CONSEQUENCE: none; the in-flight refresh will publish the same result.")
            return
        }
        isLoading = true
        defer { isLoading = false }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        supported = supportedLocales.sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
        installedIdentifiers = Set(installedLocales.map(\.identifier))
        logger.info("[ORB_APPLE_ASR] Assets refreshed — \(self.supported.count) supported locale(s), \(self.installedIdentifiers.count) installed.")
    }

    /// Reserves the locale and downloads its model. This is the step whose absence degrades
    /// recognition silently, so it is a deliberate, visible action rather than a lazy side effect.
    @MainActor
    func install(_ locale: Locale) async {
        guard !isInstalling else {
            // Returns without setting `lastError`, so the pane shows nothing; the log line below is the only record that an install
            // is already running.
            logger.info("[ORB_APPLE_ASR] Install of \(locale.identifier) ignored — another install is already in progress. CONSEQUENCE: the Download button looks inert; wait for the running install to finish.")
            return
        }
        isInstalling = true
        installingIdentifier = locale.identifier
        installProgress = 0
        lastError = nil
        defer {
            isInstalling = false
            installingIdentifier = nil
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [transcriber, detector]

        do {
            // Reservations persist and the cap is small, so release everything held except the locale being installed;
            // otherwise trying a few languages would exhaust the cap and every later reserve would fail.
            for stale in await AssetInventory.reservedLocales
            where stale.identifier != locale.identifier {
                let released = await AssetInventory.release(reservedLocale: stale)
                logger.info("[ORB_APPLE_ASR] Released stale reservation \(stale.identifier): \(released). CONSEQUENCE: frees a slot toward the \(AssetInventory.maximumReservedLocales) limit; its downloaded model stays on disk.")
            }

            let reserved = try await AssetInventory.reserve(locale: locale)
            logger.notice("[ORB_APPLE_ASR] Reserved \(locale.identifier) for install: \(reserved).")
            guard reserved else {
                // The cap is real and small; say which knob is full rather than failing vaguely.
                lastError = String(localized: "Couldn't reserve a slot for this language. Remove another downloaded language first (limit \(AssetInventory.maximumReservedLocales)).")
                logger.error("[ORB_APPLE_ASR] Reservation refused for \(locale.identifier) — \(AssetInventory.maximumReservedLocales) reserved-locale slots are full. CONSEQUENCE: the model cannot install and Apple Speech would run degraded.")
                return
            }

            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                let progress = request.progress
                let watcher = Task { @MainActor [weak self] in
                    while !Task.isCancelled, self?.isInstalling == true {
                        self?.installProgress = progress.fractionCompleted
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                defer { watcher.cancel() }
                try await request.downloadAndInstall()
            }
            installProgress = 1
            await refresh()
            logger.notice("[ORB_APPLE_ASR] Model install complete for \(locale.identifier).")
        } catch {
            lastError = error.localizedDescription
            logger.error("[ORB_APPLE_ASR] Model install FAILED for \(locale.identifier): \(error.localizedDescription). CONSEQUENCE: Apple Speech would transcribe degraded for this language; Orb falls back to WhisperKit until it succeeds.")
        }
    }
}
