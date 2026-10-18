// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAudioRepair.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit

/// Restarts CoreAudio's daemon, the documented fix for an app-wide dead microphone that survives relaunching the
/// app. The command is a fixed literal that takes no parameters, and the macOS administrator prompt appears only
/// after the user confirms the app's own dialog.
enum OrbAudioRepair {

    /// The one command. A `static let` literal, never composed.
    private static let command = "killall coreaudiod"

    enum Outcome: Equatable {
        case repaired
        /// The user dismissed our dialog or the macOS administrator prompt.
        case cancelled
        case failed(String)
    }

    /// Asks first, then restarts the daemon. Must run on the main thread — `NSAlert` and
    /// `NSAppleScript` both require it.
    @MainActor
    static func run(logger: DGLogger, tag: String = "") -> Outcome {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart the macOS audio system?")
        alert.informativeText = String(localized: """
            The microphone is reporting that it opened but delivered no audio. That usually means \
            macOS's audio service is stuck — it survives quitting and reopening Devgentic, so \
            restarting the service is the only fix.

            Audio in every app will cut out for about a second. Nothing is deleted, and macOS \
            restarts the service automatically. You'll be asked for your password.
            """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Restart Audio"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            logger.info("[ORB_AUDIO]\(tag) Audio repair declined at the confirmation. CONSEQUENCE: the microphone stays dead; the user can retry from the orb menu or Orb settings.")
            return .cancelled
        }

        logger.notice("[ORB_AUDIO]\(tag) Restarting coreaudiod at the user's request. CONSEQUENCE: all audio output stops for about a second while launchd restarts the daemon.")

        var errorInfo: NSDictionary?
        // Do not optional-chain: if `NSAppleScript(source:)` returns nil nothing ran, and falling through would report
        // `.repaired`.
        guard let script = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges") else {
            logger.error("[ORB_AUDIO]\(tag) Could not build the repair script — NSAppleScript(source:) returned nil. CONSEQUENCE: coreaudiod was NOT restarted and the microphone is still dead; the user must run `sudo killall coreaudiod` in Terminal.")
            return .failed("The repair script could not be created.")
        }
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // -128 is the standard "user cancelled" code from the administrator prompt. It is not
            // a failure and must not be reported as one.
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 {
                logger.info("[ORB_AUDIO]\(tag) Audio repair cancelled at the administrator prompt. CONSEQUENCE: the microphone stays dead.")
                return .cancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            logger.error("[ORB_AUDIO]\(tag) Audio repair FAILED (\(code)): \(message). CONSEQUENCE: the microphone stays dead; the user must run `sudo killall coreaudiod` in Terminal.")
            return .failed(message)
        }

        logger.notice("[ORB_AUDIO]\(tag) coreaudiod restarted. CONSEQUENCE: the next microphone session should succeed — if `_StartIO error 35` persists after this, the cause is NOT the daemon and needs separate investigation.")
        return .repaired
    }
}
