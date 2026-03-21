//
//  MacOSUtilityTools.swift
//  Devgentic
//
//  High-value macOS utility tools for autonomous AI agents.
//  Screen capture, Finder tags, disk usage, display management,
//  system settings, login items, and external device enumeration.
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Screen Capture Tool

struct ScreenCaptureTool: DevgenticTool {
    let name = "screen_capture"
    let category = "macOS Utilities"
    let description = "Captures a screenshot of the entire screen, a specific window, or a region. Saves as PNG. Useful for feeding visual context into vision pipelines."

    struct Arguments: Decodable, Sendable {
        let mode: String?
        let output_path: String?
        let x: Int?
        let y: Int?
        let width: Int?
        let height: Int?
        let bundle_id: String?
        let hide_cursor: Bool?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.mode = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "mode")!)
            self.output_path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "output_path")!)
            self.x = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "x")!)
            self.y = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "y")!)
            self.width = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "width")!)
            self.height = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "height")!)
            self.bundle_id = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "bundle_id")!)
            self.hide_cursor = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "hide_cursor")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("mode", "string", "Capture mode: 'fullscreen' (default), 'region', 'window'."),
                ("output_path", "string", "File path to save the screenshot. Defaults to ~/Desktop/screenshot_<timestamp>.png."),
                ("x", "integer", "X coordinate of region top-left corner (for 'region' mode)."),
                ("y", "integer", "Y coordinate of region top-left corner (for 'region' mode)."),
                ("width", "integer", "Width of capture region in pixels (for 'region' mode)."),
                ("height", "integer", "Height of capture region in pixels (for 'region' mode)."),
                ("bundle_id", "string", "Bundle ID of the app whose frontmost window to capture (for 'window' mode)."),
                ("hide_cursor", "boolean", "Hide the mouse cursor in the capture (default true).")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Screen capture: \(arguments.mode ?? "fullscreen")",
            operations: [["mode": arguments.mode ?? "fullscreen"]]
        )

        let mode = arguments.mode ?? "fullscreen"
        let timestamp = Int(Date().timeIntervalSince1970)
        let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/screenshot_\(timestamp).png")
        let outputPath = (arguments.output_path as NSString?)?.expandingTildeInPath ?? defaultPath

        var cmdArgs: [String] = []

        switch mode {
        case "region":
            guard let x = arguments.x, let y = arguments.y,
                  let w = arguments.width, let h = arguments.height else {
                return "Error: 'x', 'y', 'width', and 'height' are required for region mode. (Audit Ref: \(logID))"
            }
            cmdArgs = ["-R", "\(x),\(y),\(w),\(h)"]

        case "window":
            if let bundleID = arguments.bundle_id {
                // Activate the app first, then capture frontmost window
                let activateProcess = Process()
                activateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                activateProcess.arguments = ["-b", bundleID]
                try? activateProcess.run()
                activateProcess.waitUntilExit()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s for window to come forward
            }
            cmdArgs = ["-w", "-o"]

        case "fullscreen":
            break

        default:
            return "Error: Unknown mode '\(mode)'. Use 'fullscreen', 'region', or 'window'. (Audit Ref: \(logID))"
        }

        if arguments.hide_cursor ?? true {
            cmdArgs.append("-C")
        }

        cmdArgs.append(outputPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = cmdArgs

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Error capturing screen: \(error.localizedDescription) (Audit Ref: \(logID))"
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            return "Error: Screenshot was not saved. The capture may have been cancelled. (Audit Ref: \(logID))"
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
        let size = (attrs?[.size] as? Int) ?? 0
        let sizeKB = size / 1024

        return "Screenshot saved to: \(outputPath) (\(sizeKB) KB) (Audit Ref: \(logID))"
    }
}

// MARK: - Finder Tags Tool

struct FinderTagsTool: DevgenticTool {
    let name = "finder_tags"
    let category = "macOS Utilities"
    let description = "Manages macOS Finder tags on files and folders: read, add, remove, or search by tag. Supports both color tags and custom text tags."

    struct Arguments: Decodable, Sendable {
        let action: String
        let path: String?
        let tags: [String]?
        let search_tag: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
            self.tags = try? container.decodeIfPresent([String].self, forKey: DynamicKey(stringValue: "tags")!)
            self.search_tag = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "search_tag")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'read' (get tags on file), 'add' (add tags), 'remove' (remove tags), 'set' (replace all tags), 'search' (find files by tag)."),
                ("path", "string", "File or folder path (required for read/add/remove/set). For search, the directory to search in."),
                ("tags", "array", "Tag names to add, remove, or set (e.g. ['Important', 'Red', 'Work'])."),
                ("search_tag", "string", "Tag name to search for (for 'search' action).")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Finder tags: \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        switch arguments.action {
        case "read":
            guard let path = arguments.path else {
                return "Error: 'path' required for read. (Audit Ref: \(logID))"
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "Error: File not found at '\(expandedPath)'. (Audit Ref: \(logID))"
            }

            let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey])
            let tags = resourceValues?.tagNames ?? []

            if tags.isEmpty {
                return "No tags on '\(path)'. (Audit Ref: \(logID))"
            }
            return "Tags on '\(path)': \(tags.joined(separator: ", ")) (Audit Ref: \(logID))"

        case "add":
            guard let path = arguments.path, let newTags = arguments.tags, !newTags.isEmpty else {
                return "Error: 'path' and 'tags' required for add. (Audit Ref: \(logID))"
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath) as NSURL

            let existingValues = try? (url as URL).resourceValues(forKeys: [.tagNamesKey])
            var currentTags = existingValues?.tagNames ?? []
            for tag in newTags where !currentTags.contains(tag) {
                currentTags.append(tag)
            }

            try url.setResourceValue(currentTags, forKey: .tagNamesKey)
            return "Added tags \(newTags) to '\(path)'. Current tags: \(currentTags.joined(separator: ", ")) (Audit Ref: \(logID))"

        case "remove":
            guard let path = arguments.path, let removeTags = arguments.tags, !removeTags.isEmpty else {
                return "Error: 'path' and 'tags' required for remove. (Audit Ref: \(logID))"
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath) as NSURL

            let existingValues = try? (url as URL).resourceValues(forKeys: [.tagNamesKey])
            var currentTags = existingValues?.tagNames ?? []
            currentTags.removeAll { removeTags.contains($0) }

            try url.setResourceValue(currentTags, forKey: .tagNamesKey)
            return "Removed tags \(removeTags) from '\(path)'. Remaining: \(currentTags.isEmpty ? "none" : currentTags.joined(separator: ", ")) (Audit Ref: \(logID))"

        case "set":
            guard let path = arguments.path, let tags = arguments.tags else {
                return "Error: 'path' and 'tags' required for set. (Audit Ref: \(logID))"
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath) as NSURL

            try url.setResourceValue(tags, forKey: .tagNamesKey)
            return "Set tags on '\(path)' to: \(tags.isEmpty ? "none" : tags.joined(separator: ", ")) (Audit Ref: \(logID))"

        case "search":
            guard let searchTag = arguments.search_tag else {
                return "Error: 'search_tag' required for search. (Audit Ref: \(logID))"
            }
            let searchPath = (arguments.path as NSString?)?.expandingTildeInPath ?? NSHomeDirectory()

            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", searchPath, "kMDItemUserTags == '\(searchTag)'"]
            process.standardOutput = outPipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output.isEmpty {
                    return "No files found with tag '\(searchTag)' in \(searchPath). (Audit Ref: \(logID))"
                }

                let files = output.components(separatedBy: "\n").prefix(50)
                return "Files with tag '\(searchTag)' (\(files.count)):\n\(files.joined(separator: "\n"))\n(Audit Ref: \(logID))"
            } catch {
                return "Error searching: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use read/add/remove/set/search. (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Disk Usage Tool

struct DiskUsageTool: DevgenticTool {
    let name = "disk_usage"
    let category = "macOS Utilities"
    let description = "Reports disk space usage: available/total volume capacity, folder sizes, or finds the largest files in a directory."

    struct Arguments: Decodable, Sendable {
        let action: String
        let path: String?
        let top_n: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
            self.top_n = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "top_n")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'volume' (disk space info), 'folder_size' (size of a directory), 'largest_files' (find biggest files in a directory)."),
                ("path", "string", "Path for folder_size or largest_files. Defaults to home directory."),
                ("top_n", "integer", "Number of largest files to return (default 10, for 'largest_files').")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Disk usage: \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        switch arguments.action {
        case "volume":
            let path = (arguments.path as NSString?)?.expandingTildeInPath ?? "/"
            let url = URL(fileURLWithPath: path)

            do {
                let values = try url.resourceValues(forKeys: [
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityForImportantUsageKey,
                    .volumeAvailableCapacityKey,
                    .volumeNameKey
                ])

                let totalBytes = values.volumeTotalCapacity ?? 0
                let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
                let usedBytes = Int64(totalBytes) - availableBytes
                let volumeName = values.volumeName ?? "Unknown"

                let totalGB = String(format: "%.1f", Double(totalBytes) / 1_073_741_824)
                let availableGB = String(format: "%.1f", Double(availableBytes) / 1_073_741_824)
                let usedGB = String(format: "%.1f", Double(usedBytes) / 1_073_741_824)
                let usedPercent = totalBytes > 0 ? String(format: "%.1f", Double(usedBytes) / Double(totalBytes) * 100) : "0"

                return """
                Volume: \(volumeName)
                Total: \(totalGB) GB
                Used: \(usedGB) GB (\(usedPercent)%)
                Available: \(availableGB) GB
                (Audit Ref: \(logID))
                """
            } catch {
                return "Error reading volume info: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        case "folder_size":
            guard let path = arguments.path else {
                return "Error: 'path' required for folder_size. (Audit Ref: \(logID))"
            }
            let expandedPath = (path as NSString).expandingTildeInPath

            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sh", expandedPath]
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "Folder size: \(output)\n(Audit Ref: \(logID))"
            } catch {
                return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        case "largest_files":
            let searchPath = (arguments.path as NSString?)?.expandingTildeInPath ?? NSHomeDirectory()
            let topN = arguments.top_n ?? 10

            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "find \"\(searchPath)\" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/DerivedData/*' -exec du -h {} + 2>/dev/null | sort -rh | head -\(topN)"]
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output.isEmpty {
                    return "No files found in '\(searchPath)'. (Audit Ref: \(logID))"
                }
                return "Largest files in '\(searchPath)':\n\(output)\n(Audit Ref: \(logID))"
            } catch {
                return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use volume/folder_size/largest_files. (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Display Management Tool

struct DisplayManagementTool: DevgenticTool {
    let name = "display_management"
    let category = "macOS Utilities"
    let description = "Manages display settings: list connected displays with resolution info, get/set brightness, and get display arrangement details."

    struct Arguments: Decodable, Sendable {
        let action: String
        let brightness: Double?
        let display_id: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)
            self.brightness = try? container.decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: "brightness")!)
            self.display_id = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "display_id")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'list' (all displays with info), 'get_brightness', 'set_brightness'."),
                ("brightness", "number", "Brightness level 0.0 to 1.0 (for 'set_brightness')."),
                ("display_id", "integer", "Display index, 0-based (default 0 for main display).")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Display: \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        switch arguments.action {
        case "list":
            let screens = NSScreen.screens
            if screens.isEmpty {
                return "No displays detected. (Audit Ref: \(logID))"
            }

            var result = "Connected Displays (\(screens.count)):\n"
            for (idx, screen) in screens.enumerated() {
                let frame = screen.frame
                let visibleFrame = screen.visibleFrame
                let name = screen.localizedName
                let isMain = screen == NSScreen.main
                let scaleFactor = screen.backingScaleFactor

                let nativeWidth = Int(frame.width * scaleFactor)
                let nativeHeight = Int(frame.height * scaleFactor)

                result += """
                [\(idx)] \(name)\(isMain ? " (Main)" : "")
                  Resolution: \(Int(frame.width))x\(Int(frame.height)) (native: \(nativeWidth)x\(nativeHeight), scale: \(scaleFactor)x)
                  Usable area: \(Int(visibleFrame.width))x\(Int(visibleFrame.height))
                  Position: (\(Int(frame.origin.x)), \(Int(frame.origin.y)))

                """
            }
            return "\(result)(Audit Ref: \(logID))"

        case "get_brightness":
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Use ioreg to read brightness from AppleBacklightDisplay
            process.arguments = ["-c", "ioreg -c AppleBacklightDisplay | grep -i brightness | tail -1"]
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output.isEmpty {
                    return "Could not read brightness. External displays may not support programmatic brightness control. (Audit Ref: \(logID))"
                }
                return "Brightness info: \(output)\n(Audit Ref: \(logID))"
            } catch {
                return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        case "set_brightness":
            guard let brightness = arguments.brightness, brightness >= 0.0, brightness <= 1.0 else {
                return "Error: 'brightness' must be between 0.0 and 1.0. (Audit Ref: \(logID))"
            }

            // Use AppleScript to set brightness via System Events
            let script = """
            tell application "System Events"
                tell appearance preferences
                    -- Brightness is controlled at the display level
                end tell
            end tell
            do shell script "brightness \(brightness)"
            """

            // Fallback: use CoreDisplay private API via shell
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Try the brightness CLI if available, otherwise use osascript
            process.arguments = ["-c", """
            if command -v brightness &>/dev/null; then
                brightness \(brightness)
            else
                osascript -e 'tell application "System Preferences" to quit' 2>/dev/null
                echo "Brightness CLI not found. Install via: brew install brightness"
            fi
            """]
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output.contains("not found") {
                    return "\(output) (Audit Ref: \(logID))"
                }
                return "Brightness set to \(brightness). \(output)\n(Audit Ref: \(logID))"
            } catch {
                return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/get_brightness/set_brightness. (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Open System Settings Tool

struct OpenSystemSettingsTool: DevgenticTool {
    let name = "open_system_settings"
    let category = "macOS Utilities"
    let description = "Opens macOS System Settings to a specific pane. Useful for directing users to configure permissions, network, displays, etc."

    struct Arguments: Decodable, Sendable {
        let pane: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pane", "string", "Settings pane to open: 'general', 'appearance', 'accessibility', 'privacy', 'security', 'network', 'wifi', 'bluetooth', 'sound', 'displays', 'keyboard', 'trackpad', 'mouse', 'printers', 'battery', 'date_time', 'notifications', 'focus', 'users', 'passwords', 'software_update', 'storage', 'desktop', 'dock', 'wallpaper', 'login_items', 'siri', 'spotlight'.")
            ],
            required: ["pane"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Open settings: \(arguments.pane)",
            operations: [["pane": arguments.pane]]
        )

        // macOS 13+ uses x-apple.systempreferences URL scheme
        let paneURL: String

        switch arguments.pane.lowercased() {
        case "general": paneURL = "x-apple.systempreferences:com.apple.settings.General"
        case "appearance": paneURL = "x-apple.systempreferences:com.apple.Appearance-Settings.extension"
        case "accessibility": paneURL = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
        case "privacy", "security": paneURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        case "network": paneURL = "x-apple.systempreferences:com.apple.Network-Settings.extension"
        case "wifi": paneURL = "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case "bluetooth": paneURL = "x-apple.systempreferences:com.apple.BluetoothSettings"
        case "sound": paneURL = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case "displays": paneURL = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        case "keyboard": paneURL = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case "trackpad": paneURL = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case "mouse": paneURL = "x-apple.systempreferences:com.apple.Mouse-Settings.extension"
        case "printers": paneURL = "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension"
        case "battery": paneURL = "x-apple.systempreferences:com.apple.settings.Battery"
        case "date_time": paneURL = "x-apple.systempreferences:com.apple.Date-Time-Settings.extension"
        case "notifications": paneURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case "focus": paneURL = "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case "users": paneURL = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        case "passwords": paneURL = "x-apple.systempreferences:com.apple.Passwords-Settings.extension"
        case "software_update": paneURL = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        case "storage": paneURL = "x-apple.systempreferences:com.apple.settings.Storage"
        case "desktop", "dock": paneURL = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        case "wallpaper": paneURL = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
        case "login_items": paneURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case "siri": paneURL = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        case "spotlight": paneURL = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        default:
            // Fallback: just open System Settings
            paneURL = "x-apple.systempreferences:"
        }

        return await MainActor.run {
            if let url = URL(string: paneURL) {
                NSWorkspace.shared.open(url)
                return "Opened System Settings: \(arguments.pane). (Audit Ref: \(logID))"
            }
            return "Error: Could not construct URL for pane '\(arguments.pane)'. (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Login Items Tool

struct LoginItemsTool: DevgenticTool {
    let name = "login_items"
    let category = "macOS Utilities"
    let description = "Lists macOS login items (apps that launch at startup) and can open the Login Items settings pane for management."

    struct Arguments: Decodable, Sendable {
        let action: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'list' (show all login items), 'open_settings' (open Login Items in System Settings).")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Login items: \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        switch arguments.action {
        case "list":
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
            tell application "System Events"
                set loginList to name of every login item
                set output to ""
                repeat with i from 1 to count of loginList
                    set output to output & item i of loginList & linefeed
                end repeat
                return output
            end tell
            """]
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output.isEmpty {
                    return "No login items found. (Audit Ref: \(logID))"
                }

                let items = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                var result = "Login Items (\(items.count)):\n"
                for (idx, item) in items.enumerated() {
                    result += "  \(idx + 1). \(item)\n"
                }
                return "\(result)(Audit Ref: \(logID))"
            } catch {
                return "Error listing login items: \(error.localizedDescription) (Audit Ref: \(logID))"
            }

        case "open_settings":
            return await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                    return "Opened Login Items settings. (Audit Ref: \(logID))"
                }
                return "Error opening settings. (Audit Ref: \(logID))"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/open_settings. (Audit Ref: \(logID))"
        }
    }
}

// MARK: - External Devices Tool

struct ExternalDevicesTool: DevgenticTool {
    let name = "external_devices"
    let category = "macOS Utilities"
    let description = "Lists connected external devices: USB devices, external disks, or all connected peripherals via system profiler."

    struct Arguments: Decodable, Sendable {
        let device_type: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("device_type", "string", "Type of devices to list: 'usb' (USB devices), 'disks' (mounted volumes), 'all' (full peripheral list). Default 'usb'.")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "List devices: \(arguments.device_type ?? "usb")",
            operations: [["type": arguments.device_type ?? "usb"]]
        )

        let deviceType = arguments.device_type ?? "usb"

        switch deviceType {
        case "usb":
            return await shellCommand(
                "/usr/sbin/system_profiler", ["SPUSBDataType", "-detailLevel", "mini"],
                logID: logID
            )

        case "disks":
            // List mounted volumes with size info
            let fm = FileManager.default
            guard let mountedURLs = fm.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey],
                options: [.skipHiddenVolumes]
            ) else {
                return "No mounted volumes found. (Audit Ref: \(logID))"
            }

            var result = "Mounted Volumes (\(mountedURLs.count)):\n"
            for url in mountedURLs {
                let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey])
                let name = values?.volumeName ?? url.lastPathComponent
                let totalBytes = values?.volumeTotalCapacity ?? 0
                let availableBytes = values?.volumeAvailableCapacity ?? 0
                let isRemovable = values?.volumeIsRemovable ?? false

                let totalGB = String(format: "%.1f", Double(totalBytes) / 1_073_741_824)
                let availableGB = String(format: "%.1f", Double(availableBytes) / 1_073_741_824)

                result += "  - \(name)\(isRemovable ? " [Removable]" : "")\n"
                result += "    Path: \(url.path)\n"
                result += "    Total: \(totalGB) GB, Available: \(availableGB) GB\n"
            }
            return "\(result)(Audit Ref: \(logID))"

        case "all":
            return await shellCommand(
                "/usr/sbin/system_profiler",
                ["SPUSBDataType", "SPBluetoothDataType", "SPDisplaysDataType", "SPAudioDataType", "-detailLevel", "mini"],
                logID: logID
            )

        default:
            return "Error: Unknown device_type '\(deviceType)'. Use usb/disks/all. (Audit Ref: \(logID))"
        }
    }

    private func shellCommand(_ executable: String, _ args: [String], logID: String) async -> String {
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            var output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let maxOutput = 6000
            if output.count > maxOutput {
                output = String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
            }
            return "\(output)\n(Audit Ref: \(logID))"
        } catch {
            return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Apple Notes Tool

struct AppleNotesTool: DevgenticTool {
    let name = "apple_notes"
    let category = "macOS Utilities"
    let description = "Manages Apple Notes: list notes, read a note's content, create a new note, or search notes by keyword."

    struct Arguments: Decodable, Sendable {
        let action: String
        let title: String?
        let body: String?
        let folder: String?
        let search_term: String?
        let limit: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)
            self.title = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "title")!)
            self.body = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "body")!)
            self.folder = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "folder")!)
            self.search_term = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "search_term")!)
            self.limit = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "limit")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'list' (list notes), 'read' (read a note by title), 'create' (create a new note), 'search' (search notes by keyword), 'list_folders' (list all folders)."),
                ("title", "string", "Note title (for 'read' or 'create')."),
                ("body", "string", "Note body content (for 'create'). Supports plain text."),
                ("folder", "string", "Folder name to list notes from or create note in (default: Notes)."),
                ("search_term", "string", "Keyword to search for (for 'search')."),
                ("limit", "integer", "Max notes to return for list/search (default 20).")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Apple Notes: \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        switch arguments.action {
        case "list":
            let limit = arguments.limit ?? 20
            let folderClause: String
            if let folder = arguments.folder {
                folderClause = "of folder \"\(folder)\""
            } else {
                folderClause = ""
            }

            let script = """
            tell application "Notes"
                set noteList to {}
                set allNotes to notes \(folderClause)
                set maxCount to \(limit)
                if (count of allNotes) < maxCount then set maxCount to (count of allNotes)
                repeat with i from 1 to maxCount
                    set n to item i of allNotes
                    set noteTitle to name of n
                    set noteDate to modification date of n
                    set end of noteList to "- " & noteTitle & " (modified: " & (noteDate as string) & ")"
                end repeat
                return noteList as string
            end tell
            """
            return await runAppleScript(script, logID: logID, prefix: "Notes")

        case "read":
            guard let title = arguments.title else {
                return "Error: 'title' required for read. (Audit Ref: \(logID))"
            }

            let script = """
            tell application "Notes"
                set matchedNotes to notes whose name is "\(Self.escapeAppleScript(title))"
                if (count of matchedNotes) is 0 then
                    return "Note not found: \(Self.escapeAppleScript(title))"
                end if
                set n to item 1 of matchedNotes
                set noteBody to plaintext of n
                set noteTitle to name of n
                set noteDate to modification date of n
                return "Title: " & noteTitle & linefeed & "Modified: " & (noteDate as string) & linefeed & linefeed & noteBody
            end tell
            """
            return await runAppleScript(script, logID: logID, prefix: "Note Content")

        case "create":
            guard let title = arguments.title else {
                return "Error: 'title' required for create. (Audit Ref: \(logID))"
            }
            let body = arguments.body ?? ""
            let htmlBody = "<h1>\(Self.escapeHTML(title))</h1><br>\(Self.escapeHTML(body).replacingOccurrences(of: "\n", with: "<br>"))"

            let folderClause: String
            if let folder = arguments.folder {
                folderClause = """
                set targetFolder to folder "\(Self.escapeAppleScript(folder))"
                make new note at targetFolder with properties {body:"\(Self.escapeAppleScript(htmlBody))"}
                """
            } else {
                folderClause = """
                make new note with properties {body:"\(Self.escapeAppleScript(htmlBody))"}
                """
            }

            let script = """
            tell application "Notes"
                \(folderClause)
                return "Created note: \(Self.escapeAppleScript(title))"
            end tell
            """
            return await runAppleScript(script, logID: logID, prefix: "")

        case "search":
            guard let term = arguments.search_term else {
                return "Error: 'search_term' required for search. (Audit Ref: \(logID))"
            }
            let limit = arguments.limit ?? 20

            let script = """
            tell application "Notes"
                set results to {}
                set allNotes to every note
                set matchCount to 0
                repeat with n in allNotes
                    if matchCount ≥ \(limit) then exit repeat
                    set noteTitle to name of n
                    set noteText to plaintext of n
                    if noteTitle contains "\(Self.escapeAppleScript(term))" or noteText contains "\(Self.escapeAppleScript(term))" then
                        set noteDate to modification date of n
                        set end of results to "- " & noteTitle & " (modified: " & (noteDate as string) & ")"
                        set matchCount to matchCount + 1
                    end if
                end repeat
                if matchCount is 0 then return "No notes found matching '\(Self.escapeAppleScript(term))'."
                return results as string
            end tell
            """
            return await runAppleScript(script, logID: logID, prefix: "Search results for '\(term)'")

        case "list_folders":
            let script = """
            tell application "Notes"
                set folderList to {}
                repeat with f in folders
                    set folderName to name of f
                    set noteCount to count of notes of f
                    set end of folderList to "- " & folderName & " (" & noteCount & " notes)"
                end repeat
                return folderList as string
            end tell
            """
            return await runAppleScript(script, logID: logID, prefix: "Note Folders")

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/read/create/search/list_folders. (Audit Ref: \(logID))"
        }
    }

    private func runAppleScript(_ script: String, logID: String, prefix: String) async -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                return "Error: \(errOutput.isEmpty ? "AppleScript execution failed" : errOutput) (Audit Ref: \(logID))"
            }

            if output.isEmpty {
                return "\(prefix.isEmpty ? "" : prefix + ": ")No results. (Audit Ref: \(logID))"
            }

            var result = output
            let maxOutput = 8000
            if result.count > maxOutput {
                result = String(result.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
            }

            if prefix.isEmpty {
                return "\(result) (Audit Ref: \(logID))"
            }
            return "\(prefix):\n\(result)\n(Audit Ref: \(logID))"
        } catch {
            return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }

    private static func escapeAppleScript(_ str: String) -> String {
        return str.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeHTML(_ str: String) -> String {
        return str.replacingOccurrences(of: "&", with: "&amp;")
                  .replacingOccurrences(of: "<", with: "&lt;")
                  .replacingOccurrences(of: ">", with: "&gt;")
                  .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
