// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisAppleSpeechAssets.swift
//  Devgentic
//
//  Which Apple Speech languages this Mac can use, which are actually installed, and the
//  install itself — so the choice can be made in Settings BEFORE the recognizer is switched on.
//
//  ⚠️ WHY THIS IS A MODEL PICKER, NOT A LANGUAGE PREFERENCE. Apple ships one on-device model per
//  locale, and `SpeechTranscriber` does NOT fail when that model was never reserved and installed
//  — it warns once (`Cannot use modules with unallocated locales …`) and then transcribes in a
//  degraded mode. Device test 2026-09-04: an unallocated `en_IN` turned "write an essay on
//  technology" into "write an SM technology", while WhisperKit heard the same speech correctly.
//  Making the language explicit, and its installed state visible, is what stops that happening
//  silently.
//

import Foundation
import Speech

@available(macOS 26.0, *)
@Observable
final class JarvisAppleSpeechAssets {

    @MainActor static let shared = JarvisAppleSpeechAssets()

    private let logger = DGLogger(category: "JarvisAppleSpeech")

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
            logger.info("[JARVIS_APPLE_ASR] Refresh ignored — one is already running. CONSEQUENCE: none; the in-flight refresh will publish the same result.")
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
        logger.info("[JARVIS_APPLE_ASR] Assets refreshed — \(self.supported.count) supported locale(s), \(self.installedIdentifiers.count) installed.")
    }

    /// Reserves the locale and downloads its model. This is the step whose absence degrades
    /// recognition silently, so it is a deliberate, visible action rather than a lazy side effect.
    @MainActor
    func install(_ locale: Locale) async {
        guard !isInstalling else {
            // ⚠️ This returns WITHOUT setting `lastError`, so the settings pane shows nothing at
            // all — the Download button simply appears dead and neither the UI nor the log says
            // an install is already running.
            logger.info("[JARVIS_APPLE_ASR] Install of \(locale.identifier) ignored — another install is already in progress. CONSEQUENCE: the Download button looks inert; wait for the running install to finish.")
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
            // ⚠️ Reservations PERSIST and the cap is small (5 on the 2026-09-04 test machine).
            // Without releasing the ones we took, a user trying a few languages would silently
            // exhaust it and every later reserve would fail. Release everything we hold that is
            // not the locale being installed — recognition only ever uses one at a time.
            for stale in await AssetInventory.reservedLocales
            where stale.identifier != locale.identifier {
                let released = await AssetInventory.release(reservedLocale: stale)
                logger.info("[JARVIS_APPLE_ASR] Released stale reservation \(stale.identifier): \(released). CONSEQUENCE: frees a slot toward the \(AssetInventory.maximumReservedLocales) limit; its downloaded model stays on disk.")
            }

            let reserved = try await AssetInventory.reserve(locale: locale)
            logger.notice("[JARVIS_APPLE_ASR] Reserved \(locale.identifier) for install: \(reserved).")
            guard reserved else {
                // The cap is real and small; say which knob is full rather than failing vaguely.
                lastError = String(localized: "Couldn't reserve a slot for this language. Remove another downloaded language first (limit \(AssetInventory.maximumReservedLocales)).")
                logger.error("[JARVIS_APPLE_ASR] Reservation refused for \(locale.identifier) — \(AssetInventory.maximumReservedLocales) reserved-locale slots are full. CONSEQUENCE: the model cannot install and Apple Speech would run degraded.")
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
            logger.notice("[JARVIS_APPLE_ASR] Model install complete for \(locale.identifier).")
        } catch {
            lastError = error.localizedDescription
            logger.error("[JARVIS_APPLE_ASR] Model install FAILED for \(locale.identifier): \(error.localizedDescription). CONSEQUENCE: Apple Speech would transcribe degraded for this language; Jarvis falls back to WhisperKit until it succeeds.")
        }
    }
}
