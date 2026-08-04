//
//  QuickAccessScreenCaptureService.swift
//  Devgentic
//
//  [QA revival P3] Screenshot capture for the QuickAccess panel. Runs the system's
//  interactive capture (`screencapture -i`): crosshair region-select, spacebar toggles to
//  window-pick — the native UX, covering both "capture a region" and "capture a window"
//  with one flow. The panel is ordered out during capture so it never occludes the shot
//  (works because Phase 0 made the panel non-activating: the user's app is still frontmost).
//
//  Permission: Screen Recording TCC. The app never called CGRequestScreenCaptureAccess
//  anywhere (recon bug #9) — without one request the app doesn't even appear in
//  System Settings → Privacy & Security → Screen Recording for manual enablement.
//  Note: macOS applies a first-time grant only after the app is relaunched.
//

import AppKit
import CoreGraphics

@MainActor
enum QuickAccessScreenCaptureService {

    enum PermissionState {
        case granted
        /// Just prompted (or previously denied) — not usable this launch; a fresh grant
        /// takes effect after relaunch.
        case denied
    }

    private static let logger = DGLogger(category: "QuickAccessScreenCapture")

    /// Filename prefix for interactive-capture temp files, so callers can identify and clean
    /// them up. [H1]
    nonisolated static let captureFilePrefix = "QuickAccess-Capture-"

    // MARK: - Temp-file cleanup [H1]

    /// True if `url` is one of our interactive-capture temp files (lives in the temporary
    /// directory and carries the capture prefix).
    /// Uses `sameLocation` rather than `URL` equality. **This is hardening, not a bug fix** —
    /// the previous `==` on two `standardizedFileURL`s was correct here, and measured to be:
    /// both sides are directory-flavoured (`deletingLastPathComponent()` and
    /// `temporaryDirectory` both produce trailing slashes), and `standardizedFileURL` already
    /// strips a `/private` prefix, so the `/private/var/folders/…` form matched too.
    ///
    /// It is changed because the guard fails in the UNSAFE direction — a false negative means
    /// `deleteCaptureTempFileIfNeeded` silently no-ops and an unsent screenshot, which
    /// routinely contains secrets, lingers in $TMPDIR. `sameLocation` additionally resolves
    /// real symlinks (`standardizedFileURL` does not), so a caller that hands us a path through
    /// a symlinked directory still gets swept. The prefix check confines deletion to our files.
    nonisolated static func isCaptureTempFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().sameLocation(as: FileManager.default.temporaryDirectory)
            && url.lastPathComponent.hasPrefix(captureFilePrefix)
    }

    /// Delete a capture temp file if (and only if) it is one of ours. No-op otherwise, so it is
    /// safe to hand any attachment URL. Screen captures routinely contain secrets — an unsent
    /// one (chip removed / panel closed) must not linger in $TMPDIR.
    nonisolated static func deleteCaptureTempFileIfNeeded(_ url: URL) {
        guard isCaptureTempFile(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Sweep leftover capture temp files at launch: sent captures (whose bytes are already
    /// persisted in the message) and any orphaned by a crash mid-flow. Skips files younger than
    /// `minAge` so an in-progress capture is never swept out from under the user.
    nonisolated static func sweepOrphanedCaptureFiles(olderThan minAge: TimeInterval = 3600) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        for url in entries where url.lastPathComponent.hasPrefix(captureFilePrefix) {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modDate, now.timeIntervalSince(modDate) < minAge { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Preflight + (once) request Screen Recording access. The system prompt appears only on
    /// the first request per launch; afterwards this returns the current TCC state.
    static func ensurePermission() -> PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        logger.info("Screen Recording not granted — requesting (system prompt on first ask).")
        let granted = CGRequestScreenCaptureAccess()
        return granted ? .granted : .denied
    }

    /// Deep link to the Screen Recording pane in System Settings.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Interactive capture. Hides the QuickAccess panel for the duration, then restores it.
    /// Returns the captured PNG's URL, or nil if the user cancelled (Esc) or capture failed.
    static func captureInteractive() async -> URL? {
        let panel = AppDelegate.shared?.contentWindow
        panel?.orderOut(nil)
        defer {
            // [C5] Only restore the panel we hid. If the user re-summoned during the (interactive,
            // possibly long) capture, a NEW panel replaced it — re-showing this now-stale one would
            // leave a zombie panel on screen. Identity-guard against the current contentWindow.
            if let panel, panel === AppDelegate.shared?.contentWindow {
                panel.makeKeyAndOrderFront(nil)
            }
        }

        let fileName = "\(Self.captureFilePrefix)\(Int(Date().timeIntervalSince1970)).png"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        // -i interactive (region; space toggles window pick), -x no shutter sound.
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", outputURL.path]
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                logger.error("Failed to launch screencapture: \(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }

        // Esc/cancel exits without creating the file; treat as a silent no-op.
        guard exitCode == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64,
              size > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        logger.info("Captured screenshot (\(size) bytes) at \(outputURL.lastPathComponent).")
        return outputURL
    }
}
