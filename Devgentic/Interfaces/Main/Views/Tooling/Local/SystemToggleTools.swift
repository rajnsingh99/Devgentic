// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SystemToggleTools.swift
//  Devgentic
//

import Foundation
import AppKit
import os

private let logger = DGLogger(category: "SystemToggleTools")

// MARK: - Toggle Dark Mode Tool

struct ToggleDarkModeTool: DevgenticTool {
    let name = "toggle_dark_mode"
    let category = "System Toggles"
    let description = "Toggles macOS Dark/Light mode or queries the current appearance."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'toggle', 'get', 'dark', 'light'")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            var script = ""
            switch arguments.action {
            case "get":
                script = """
                tell application "System Events"
                    tell appearance preferences
                        return dark mode
                    end tell
                end tell
                """
            case "toggle":
                script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to not dark mode
                    end tell
                end tell
                """
            case "dark":
                script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to true
                    end tell
                end tell
                """
            case "light":
                script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to false
                    end tell
                end tell
                """
            default:
                return "Error: Unknown action '\(arguments.action)'. Use toggle/get/dark/light."
            }

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            let desc = scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "Error: AppleScript failed — \(err)"
            }

            if arguments.action == "get" {
                let isDark = desc?.booleanValue ?? false
                return "Current mode: \(isDark ? "Dark" : "Light")"
            }

            return "Appearance updated."
        }
    }
}

// MARK: - Toggle Do Not Disturb Tool

/// ⚠️ This tool can only TOGGLE Focus. It cannot set it to a known state.
///
/// It works by clicking the Focus checkbox in Control Centre through the accessibility API, and
/// a click flips whatever is currently there. macOS exposes no readable Focus state to query
/// first, which is why the implementation clicks a checkbox rather than setting a value.
///
/// Until 2026-08-01 the schema advertised `'on'`, `'off'` and `'toggle'`, and all three ran
/// BYTE-IDENTICAL scripts — so asking to turn Focus ON while it was already on turned it OFF, and
/// the tool reported `Do Not Disturb 'on' executed`. A model that wanted silence got noise, with
/// a success message. `on` and `off` are now refused rather than quietly mistranslated: an action
/// the tool cannot perform must not be advertised as one it can.
struct ToggleDoNotDisturbTool: DevgenticTool {
    let name = "toggle_do_not_disturb"
    let category = "System Toggles"
    let description = "Toggles macOS Focus / Do Not Disturb on or off. This FLIPS the current state — it cannot set a specific state, because macOS does not expose the current one to read first."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Must be 'toggle'. Focus can only be flipped; 'on' and 'off' are not supported because the current state cannot be read.")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Use AppleScript to toggle DND via Focus system
        return await MainActor.run {
            // `on` and `off` are refused BEFORE any script runs. They used to map to the same
            // click as `toggle`, so half the time they did the opposite of what was asked and
            // said they had succeeded. Refusing names the real capability and lets the model
            // decide, instead of silently guessing on its behalf.
            switch arguments.action {
            case "toggle":
                break
            case "on", "off":
                logger.notice("[FOCUS] refused '\(arguments.action)' — Focus can only be flipped, and this used to run the toggle script under both names, so it turned Focus the WRONG WAY half the time while reporting success. No change made.")
                return "Error: Focus cannot be set to a specific state — macOS does not expose the "
                    + "current state to read. Use action 'toggle' to flip it. If you need a known "
                    + "state, ask the user to confirm the current one first."
            default:
                return "Error: Unknown action '\(arguments.action)'. Use 'toggle'."
            }

            let script = """
            tell application "System Events"
                tell process "ControlCenter"
                    -- Click the Focus control in the menu bar, then its checkbox.
                    click menu bar item "Focus" of menu bar 1
                    delay 0.5
                    click checkbox 1 of group 1 of window 1
                end tell
            end tell
            """

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "Error: could not toggle Focus — this needs Accessibility permission. \(err)"
            }

            // States what actually happened — a flip — rather than echoing the requested action.
            // The old wording ("Do Not Disturb 'on' executed") was the success message that made
            // the wrong-direction bug invisible.
            return "Focus toggled. Its state was flipped, not set — check the menu bar to confirm "
                + "which way it went."
        }
    }
}

// MARK: - Get WiFi Info Tool

struct GetWiFiInfoTool: DevgenticTool {
    let name = "get_wifi_info"
    let category = "System Toggles"
    let description = "Returns detailed Wi-Fi information including SSID, BSSID, signal strength, channel, and security."

    struct Arguments: Decodable, Sendable {}

    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }

    func call(arguments: Arguments) async throws -> String {
        // `system_profiler SPAirPortDataType`, not the `airport` binary.
        //
        // This tool was **100% broken on any current macOS**: it invoked
        // `Apple80211.framework/…/airport -I`, and Apple REMOVED that binary. Every call threw
        // at launch ("The file 'airport' doesn't exist") — so a tool whose description promises
        // SSID, BSSID, signal strength, channel and security returned nothing but a failure,
        // every time, on every machine. Earlier work here corrected how the failure was
        // *reported*; it was still a failure.
        //
        // `system_profiler` still ships and still carries what the description advertises —
        // Card Type, PHY modes, Country Code, and a Current Network Information block with
        // channel, security and signal. Some fields are withheld unless Location Services is
        // granted, which is a macOS policy the tool cannot and should not work around; what it
        // can do is return the data that IS available instead of nothing at all.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPAirPortDataType", "-detailLevel", "basic"]

        do {
            let run = try ProcessRunner.run(process)
            let output = run.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            guard run.succeeded, !output.isEmpty else {
                logger.error("[WIFI] system_profiler SPAirPortDataType exited \(run.exitCode) with \(output.count) bytes — no Wi-Fi details available to the model this turn.")
                return "Error: could not read Wi-Fi information (system_profiler exited \(run.exitCode))"
                    + (output.isEmpty ? "." : ".\n\(output)")
            }

            // The report is verbose — the supported-channel list alone runs to hundreds of
            // characters — and the interesting part is near the top.
            let maxOutput = 4000
            let trimmed = output.count > maxOutput
                ? String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
                : output
            return "Wi-Fi Info:\n\(trimmed)"
        } catch {
            return "Error: could not read Wi-Fi information — \(error.localizedDescription)"
        }
    }
}

// MARK: - Manage Bluetooth Tool

struct ManageBluetoothTool: DevgenticTool {
    let name = "manage_bluetooth"
    let category = "System Toggles"
    let description = "Lists paired Bluetooth devices or checks Bluetooth status using system_profiler."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'status' (power state), 'list_devices' (paired devices)")
            ],
            required: ["action"]
        )
    }


    /// The parts of `system_profiler SPBluetoothDataType -json` these two actions need.
    ///
    /// `static` and given its own type so it can be tested without a Bluetooth radio, and so the
    /// two actions demonstrably read the SAME report rather than each rolling its own parse.
    struct Report: Equatable {
        let poweredOn: Bool
        let discoverable: Bool?
        let chipset: String?
        /// Device names, in the order system_profiler reported them.
        let connected: [String]
        let paired: [String]
    }

    /// Returns nil when the payload is not the shape we expect — the caller then degrades to the
    /// raw report rather than inventing an answer.
    static func parseReport(_ json: String) -> Report? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPBluetoothDataType"] as? [[String: Any]],
              let entry = entries.first else { return nil }

        // Values arrive as "attrib_on" / "attrib_off" rather than booleans.
        func flag(_ raw: Any?) -> Bool? {
            guard let text = raw as? String else { return nil }
            if text.hasSuffix("_on") { return true }
            if text.hasSuffix("_off") { return false }
            return nil
        }
        func names(_ key: String) -> [String] {
            (entry[key] as? [[String: Any]] ?? []).compactMap { $0.keys.first }
        }

        let controller = entry["controller_properties"] as? [String: Any] ?? [:]
        guard let powered = flag(controller["controller_state"]) else { return nil }

        return Report(
            poweredOn: powered,
            discoverable: flag(controller["controller_discoverable"]),
            chipset: controller["controller_chipset"] as? String,
            connected: names("device_connected"),
            paired: names("device_not_connected")
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // The two actions produce DIFFERENT answers.
        //
        // Until 2026-08-01 they shared a case — `case "status", "list_devices":` — and both
        // returned the same ~2 KB `system_profiler` text dump. So a model asking "is Bluetooth
        // on?" received every paired device's address, chipset and service mask, and had to find
        // the one word it wanted inside it; and the two actions, advertised as "power state" and
        // "paired devices", were indistinguishable. Not wrong in the way `toggle_do_not_disturb`
        // was wrong — the answer was in there — but the caller pays a page of context for a fact
        // that fits in a line.
        //
        // `-json` rather than parsing the human report: the keys are stable, `controller_state`
        // is a single value, and connected/paired devices arrive already separated.
        guard arguments.action == "status" || arguments.action == "list_devices" else {
            return "Error: Unknown action '\(arguments.action)'. Use status or list_devices."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        do {
            let run = try ProcessRunner.run(process)
            guard run.succeeded else {
                let detail = run.standardError.isEmpty ? run.standardOutput : run.standardError
                logger.error("[BLUETOOTH] system_profiler exited \(run.exitCode) — no Bluetooth information available to the model this turn. \(detail.prefix(200))")
                return "Error: could not read Bluetooth information (system_profiler exited \(run.exitCode))."
            }

            guard let report = Self.parseReport(run.standardOutput) else {
                // Degrade rather than fail: hand back the raw report so the caller still gets
                // something, and say the structured read did not work.
                logger.notice("[BLUETOOTH] could not parse the -json report; returning it raw. The status/list_devices distinction is lost for this call.")
                let raw = run.standardOutput.prefix(4000)
                return "Bluetooth \(arguments.action) (unparsed report):\n\(raw)"
            }

            switch arguments.action {
            case "status":
                var lines = ["Bluetooth: \(report.poweredOn ? "On" : "Off")"]
                if let discoverable = report.discoverable { lines.append("Discoverable: \(discoverable ? "Yes" : "No")") }
                if let chipset = report.chipset { lines.append("Chipset: \(chipset)") }
                lines.append("Connected devices: \(report.connected.count)")
                lines.append("Paired but not connected: \(report.paired.count)")
                return lines.joined(separator: "\n")

            default:
                guard !report.connected.isEmpty || !report.paired.isEmpty else {
                    return "No paired Bluetooth devices."
                }
                var out = ""
                if !report.connected.isEmpty {
                    out += "Connected (\(report.connected.count)):\n"
                    out += report.connected.map { "  - \($0)" }.joined(separator: "\n")
                }
                if !report.paired.isEmpty {
                    if !out.isEmpty { out += "\n\n" }
                    out += "Paired, not connected (\(report.paired.count)):\n"
                    out += report.paired.map { "  - \($0)" }.joined(separator: "\n")
                }
                return out
            }
        } catch {
            return "Error: could not read Bluetooth information — \(error.localizedDescription)"
        }
    }
}
