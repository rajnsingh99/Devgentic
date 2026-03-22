//
//  DeviceControlTools.swift
//  Devgentic
//

import Foundation

// MARK: - Toggle System Settings Tool
struct ToggleSystemSettingsTool: DevgenticTool {
    let name = "toggle_system_settings"
    let category = "Device & Peripheral Control"
    let description = "Toggles system settings like Dark Mode or Wi-Fi."
    
    struct Arguments: Decodable, Sendable {
        let setting: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("setting", "string", "The setting to toggle (e.g., 'dark_mode', 'wifi').")
            ],
            required: ["setting"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            switch arguments.setting.lowercased() {
            case "dark_mode":
                let script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to not dark mode
                    end tell
                end tell
                """
                var errorInfo: NSDictionary?
                guard let scriptObject = NSAppleScript(source: script) else {
                    return "Failed to init AppleScript."
                }
                _ = scriptObject.executeAndReturnError(&errorInfo)
                if let err = errorInfo {
                    return "AppleScript Error: \(err)"
                }
                return "Successfully toggled dark mode."

            case "wifi":
                let checkProcess = Process()
                checkProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                checkProcess.arguments = ["-getairportpower", "Wi-Fi"]
                let outPipe = Pipe()
                checkProcess.standardOutput = outPipe

                do {
                    try checkProcess.run()
                    checkProcess.waitUntilExit()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    let newState = output.contains("On") ? "off" : "on"

                    let setProcess = Process()
                    setProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    setProcess.arguments = ["-setairportpower", "Wi-Fi", newState]
                    try setProcess.run()
                    setProcess.waitUntilExit()

                    return "Successfully toggled Wi-Fi to \(newState)."
                } catch {
                    return "Error toggling Wi-Fi: \(error)."
                }
            default:
                return "Error: Unsupported setting '\(arguments.setting)'. Supported: 'dark_mode', 'wifi'."
            }
        }
    }
}

// MARK: - Manage Displays Tool
struct ManageDisplaysTool: DevgenticTool {
    let name = "manage_displays"
    let category = "Device & Peripheral Control"
    let description = "Manages connected displays or retrieves information."
    
    struct Arguments: Decodable, Sendable {
        let action: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action to perform (e.g., 'list_displays')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType"]
        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return "Displays Info:\n\(output)"
        } catch {
            return "Error retrieving display info: \(error)"
        }
    }
}

// MARK: - Manage Media Playback Tool
struct ManageMediaPlaybackTool: DevgenticTool {
    let name = "manage_media_playback"
    let category = "Device & Peripheral Control"
    let description = "Controls system media playback (play, pause, next, previous) and volume via Apple Music/system controls."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let volume_level: Int?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Playback action ('play', 'pause', 'next', 'previous', 'set_volume')"),
                ("volume_level", "integer", "Volume level from 0 to 100 (required if action is 'set_volume')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            var script = ""
            switch arguments.action.lowercased() {
            case "play", "pause":
                script = "tell application \"Music\" to playpause"
            case "next":
                script = "tell application \"Music\" to next track"
            case "previous":
                script = "tell application \"Music\" to previous track"
            case "set_volume":
                if let vol = arguments.volume_level {
                    script = "set volume output volume \(max(0, min(100, vol)))"
                } else {
                    return "Error: volume_level required for set_volume."
                }
            default:
                return "Error: Unknown action '\(arguments.action)'."
            }

            var errorInfo: NSDictionary?
            guard let scriptObject = NSAppleScript(source: script) else {
                return "Failed to init AppleScript for media playback."
            }
            let descriptor = scriptObject.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                return "AppleScript Error: \(err)"
            }
            return "Successfully executed \(arguments.action). Output: \(descriptor.stringValue ?? "")"
        }
    }
}
