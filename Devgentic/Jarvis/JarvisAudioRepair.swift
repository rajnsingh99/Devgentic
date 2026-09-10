// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisAudioRepair.swift
//  Devgentic
//
//  Restarts CoreAudio's daemon — the documented fix for an app-wide dead microphone.
//
//  WHY THIS EXISTS IN THE APP AT ALL. `coreaudiod` can be left in a state where every
//  `AVAudioEngine` start fails with `-10877` / `_StartIO error 35` AND speech synthesis produces
//  zero-byte buffers, and it SURVIVES relaunching the app — so nothing the app does on its own
//  recovers. It was hit on 2026-07-18 and again on 2026-09-04. The only fix is restarting the
//  daemon, which needs root, which means the user either opens Terminal or the app offers it.
//  A voice feature whose documented failure mode is silence should not require a terminal.
//
//  ⚠️ SAFETY. The command is a FIXED LITERAL. Nothing from a transcript, a model, a tool result
//  or any other dynamic source reaches it, and it takes no parameters — there is deliberately no
//  code path that builds this string. `coreaudiod` is launchd-managed and restarts immediately;
//  the cost is roughly a second of silence in every app, and no data is touched.
//
//  ⚠️ The administrator prompt is macOS's own and cannot be suppressed. It is shown only after
//  the user has confirmed our own dialog, so the system prompt is never the first thing they see.
//

import AppKit

enum JarvisAudioRepair {

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
            logger.info("[JARVIS_AUDIO]\(tag) Audio repair declined at the confirmation. CONSEQUENCE: the microphone stays dead; the user can retry from the orb menu or Jarvis settings.")
            return .cancelled
        }

        logger.notice("[JARVIS_AUDIO]\(tag) Restarting coreaudiod at the user's request. CONSEQUENCE: all audio output stops for about a second while launchd restarts the daemon.")

        var errorInfo: NSDictionary?
        // ⚠️ Optional-chaining this was a lie in the log. If `NSAppleScript(source:)` returned nil
        // the script never ran, `errorInfo` stayed nil, and the function fell through to the
        // success notice and returned `.repaired` — telling the user their audio was repaired
        // while nothing had executed, which sends them back to a still-dead microphone believing
        // the remedy is exhausted.
        guard let script = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges") else {
            logger.error("[JARVIS_AUDIO]\(tag) Could not build the repair script — NSAppleScript(source:) returned nil. CONSEQUENCE: coreaudiod was NOT restarted and the microphone is still dead; the user must run `sudo killall coreaudiod` in Terminal.")
            return .failed("The repair script could not be created.")
        }
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // -128 is the standard "user cancelled" code from the administrator prompt. It is not
            // a failure and must not be reported as one.
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 {
                logger.info("[JARVIS_AUDIO]\(tag) Audio repair cancelled at the administrator prompt. CONSEQUENCE: the microphone stays dead.")
                return .cancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            logger.error("[JARVIS_AUDIO]\(tag) Audio repair FAILED (\(code)): \(message). CONSEQUENCE: the microphone stays dead; the user must run `sudo killall coreaudiod` in Terminal.")
            return .failed(message)
        }

        logger.notice("[JARVIS_AUDIO]\(tag) coreaudiod restarted. CONSEQUENCE: the next microphone session should succeed — if `_StartIO error 35` persists after this, the cause is NOT the daemon and needs separate investigation.")
        return .repaired
    }
}
