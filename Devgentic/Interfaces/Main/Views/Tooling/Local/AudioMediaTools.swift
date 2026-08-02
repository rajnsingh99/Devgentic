//
//  AudioMediaTools.swift
//  Devgentic
//

import Foundation
import AppKit

// MARK: - Manage Audio Tool

struct ManageAudioTool: DevgenticTool {
    let name = "manage_audio"
    let category = "Audio & Media"
    let description = "Controls system audio: get/set volume, mute/unmute."

    struct Arguments: Decodable, Sendable {
        let action: String
        let level: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'get_volume', 'set_volume', 'mute', 'unmute'"),
                ("level", "integer", "Volume level 0-100 (required for 'set_volume')")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            var script = ""
            switch arguments.action {
            case "get_volume":
                script = "output volume of (get volume settings) & \",\" & input volume of (get volume settings) & \",\" & output muted of (get volume settings)"
            case "set_volume":
                guard let level = arguments.level, level >= 0, level <= 100 else {
                    return "Error: level (0-100) required for set_volume."
                }
                script = "set volume output volume \(level)"
            case "mute":
                script = "set volume with output muted"
            case "unmute":
                script = "set volume without output muted"
            default:
                return "Error: Unknown action '\(arguments.action)'."
            }

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            let desc = scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "Error: AppleScript failed — \(err)"
            }

            if arguments.action == "get_volume" {
                let raw = desc?.stringValue ?? ""
                let parts = raw.split(separator: ",")
                if parts.count >= 3 {
                    return "Output Volume: \(parts[0])%, Input Volume: \(parts[1])%, Muted: \(parts[2])"
                }
            }

            return "Audio action '\(arguments.action)' executed."
        }
    }
}

// MARK: - Media Control Tool

struct MediaControlTool: DevgenticTool {
    let name = "media_control"
    let category = "Audio & Media"
    let description = "Controls media playback: play, pause, next track, previous track via system media keys."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'play_pause', 'next_track', 'previous_track'")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Use NX key codes for media keys
        let keyCode: UInt32
        switch arguments.action {
        case "play_pause": keyCode = 0x10 // NX_KEYTYPE_PLAY
        case "next_track": keyCode = 0x11 // NX_KEYTYPE_NEXT
        case "previous_track": keyCode = 0x12 // NX_KEYTYPE_PREVIOUS
        default:
            return "Error: Unknown action '\(arguments.action)'. Use play_pause, next_track, previous_track."
        }

        func postMediaKeyEvent(keyCode: UInt32, keyDown: Bool) {
            let flags: UInt32 = keyDown ? 0xa00 : 0xb00
            let data1 = Int((keyCode << 16) | (flags << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }

        postMediaKeyEvent(keyCode: keyCode, keyDown: true)
        postMediaKeyEvent(keyCode: keyCode, keyDown: false)

        return "Media action '\(arguments.action)' sent."
    }
}
