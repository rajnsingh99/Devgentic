//
//  SystemToggleTools.swift
//  Devgentic
//

import Foundation
import AppKit

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
                return "AppleScript Error: \(err)"
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

struct ToggleDoNotDisturbTool: DevgenticTool {
    let name = "toggle_do_not_disturb"
    let category = "System Toggles"
    let description = "Toggles macOS Focus/Do Not Disturb mode via Shortcuts."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'on', 'off', 'toggle'")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Use AppleScript to toggle DND via Focus system
        return await MainActor.run {
            let script: String
            switch arguments.action {
            case "on":
                script = """
                tell application "System Events"
                    tell process "ControlCenter"
                        -- Click Focus in menu bar
                        click menu bar item "Focus" of menu bar 1
                        delay 0.5
                        click checkbox 1 of group 1 of window 1
                    end tell
                end tell
                """
            case "off":
                script = """
                tell application "System Events"
                    tell process "ControlCenter"
                        click menu bar item "Focus" of menu bar 1
                        delay 0.5
                        click checkbox 1 of group 1 of window 1
                    end tell
                end tell
                """
            case "toggle":
                script = """
                tell application "System Events"
                    tell process "ControlCenter"
                        click menu bar item "Focus" of menu bar 1
                        delay 0.5
                        click checkbox 1 of group 1 of window 1
                    end tell
                end tell
                """
            default:
                return "Error: Unknown action '\(arguments.action)'. Use on/off/toggle."
            }

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "Focus toggle may require accessibility permission. Error: \(err)"
            }

            return "Do Not Disturb '\(arguments.action)' executed."
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport")
        process.arguments = ["-I"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No Wi-Fi data"
            return "Wi-Fi Info:\n\(output)"
        } catch {
            return "Error getting Wi-Fi info: \(error.localizedDescription)"
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

    func call(arguments: Arguments) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")

        switch arguments.action {
        case "status", "list_devices":
            process.arguments = ["SPBluetoothDataType"]
        default:
            return "Error: Unknown action '\(arguments.action)'. Use status or list_devices."
        }

        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            var output = String(data: data, encoding: .utf8) ?? "No data"

            let maxOutput = 4000
            if output.count > maxOutput {
                output = String(output.prefix(maxOutput)) + "\n...[Truncated]"
            }

            return "Bluetooth \(arguments.action):\n\(output)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
