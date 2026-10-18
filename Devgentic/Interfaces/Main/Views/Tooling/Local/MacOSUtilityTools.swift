// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MacOSUtilityTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AppKit
import CoreGraphics
import os

private let logger = DGLogger(category: "MacOSUtilityTools")

// MARK: - Screen Capture Tool

/// Captures the screen to an image file; one of the macOS utility tools (Finder tags, disk usage, displays, settings).
struct ScreenCaptureTool: DevgenticTool {
    let name = "screen_capture"
    let category = "Vision & UI"
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
        let mode = arguments.mode ?? "fullscreen"
        let timestamp = Int(Date().timeIntervalSince1970)
        let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/screenshot_\(timestamp).png")
        let outputPath = arguments.output_path.map(FilePathResolver.resolve) ?? defaultPath

        var cmdArgs: [String] = []

        switch mode {
        case "region":
            guard let x = arguments.x, let y = arguments.y,
                  let w = arguments.width, let h = arguments.height else {
                return "Error: 'x', 'y', 'width', and 'height' are required for region mode."
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
            return "Error: Unknown mode '\(mode)'. Use 'fullscreen', 'region', or 'window'."
        }

        if arguments.hide_cursor ?? true {
            cmdArgs.append("-C")
        }

        cmdArgs.append(outputPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = cmdArgs

        // Runs `screencapture` through `ProcessRunner` so its stderr (denied Screen Recording permission, bad region,
        // unwritable path) reaches the model instead of a generic "capture may have been cancelled" guess.
        let run: ProcessRunner.Result
        do {
            run = try ProcessRunner.run(process)
        } catch {
            return "Error capturing screen: \(error.localizedDescription)"
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            let reason = run.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("[SCREENCAP] screencapture exited \(run.exitCode) and wrote no file to '\(outputPath)' — mode '\(mode)'. Reason: \(reason.isEmpty ? "(silent)" : reason). Most often this is a missing Screen Recording permission, which the model cannot infer from a generic message.")
            return reason.isEmpty
                ? "Error: no screenshot was saved (screencapture exited \(run.exitCode)). "
                    + "The capture may have been cancelled, or Screen Recording permission may not be granted "
                    + "(System Settings ▸ Privacy & Security ▸ Screen Recording)."
                : "Error: no screenshot was saved (screencapture exited \(run.exitCode)) — \(reason)"
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
        let size = (attrs?[.size] as? Int) ?? 0
        let sizeKB = size / 1024

        return "Screenshot saved to: \(outputPath) (\(sizeKB) KB)"
    }
}

// MARK: - Finder Tags Tools

/// Replaces every Finder tag on a file; an empty `tags` array clears the file.
/// Separate from `finder_tags` because `add`/`remove` are relative, whereas this discards the existing set.
/// Classified `.destructive`.
struct ReplaceFinderTagsTool: DevgenticTool {
    let name = "replace_finder_tags"
    let category = "File System"
    let description = "Replaces ALL Finder tags on a file with the given list, discarding any existing tags. Pass an empty list to clear. Use manage_finder_tags 'add'/'remove' to change tags without discarding the rest."

    struct Arguments: Decodable, Sendable {
        let path: String
        let tags: [String]
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "File or folder path whose tags are being replaced."),
                ("tags", "array", "The complete new tag list. Every existing tag not in it is removed.")
            ],
            required: ["path", "tags"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = FilePathResolver.resolve(arguments.path)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "Error: File not found at '\(expandedPath)'."
        }
        let url = URL(fileURLWithPath: expandedPath) as NSURL

        // Report what was discarded — otherwise the user approving this has no way to know what
        // the file had, and neither does the model on a later turn.
        let previous = (try? (url as URL).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        try url.setResourceValue(arguments.tags, forKey: .tagNamesKey)

        let now = arguments.tags.isEmpty ? "none" : arguments.tags.joined(separator: ", ")
        let before = previous.isEmpty ? "none" : previous.joined(separator: ", ")
        return "Replaced tags on '\(arguments.path)'. Was: \(before). Now: \(now)."
    }
}

struct FinderTagsTool: DevgenticTool {
    let name = "manage_finder_tags"
    let category = "File System"
    let description = "Reads, adds, removes, or searches macOS Finder tags. Additive and subtractive only — replacing all tags is a separate tool."

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
                ("action", "string", "Action: 'read' (get tags on file), 'add' (add tags), 'remove' (remove tags), 'search' (find files by tag)."),
                ("path", "string", "File or folder path (required for read/add/remove). For search, the directory to search in."),
                ("tags", "array", "Tag names to add or remove (e.g. ['Important', 'Red', 'Work'])."),
                ("search_tag", "string", "Tag name to search for (for 'search' action).")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.action {
        case "read":
            guard let path = arguments.path else {
                return "Error: 'path' required for read."
            }
            let expandedPath = FilePathResolver.resolve(path)
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "Error: File not found at '\(expandedPath)'."
            }

            let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey])
            let tags = resourceValues?.tagNames ?? []

            if tags.isEmpty {
                return "No tags on '\(path)'."
            }
            return "Tags on '\(path)': \(tags.joined(separator: ", "))"

        case "add":
            guard let path = arguments.path, let newTags = arguments.tags, !newTags.isEmpty else {
                return "Error: 'path' and 'tags' required for add."
            }
            let expandedPath = FilePathResolver.resolve(path)
            // Checked up front, as in `read`, so a missing file returns a message rather than a raw Foundation error.
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "Error: File not found at '\(expandedPath)'."
            }
            let url = URL(fileURLWithPath: expandedPath) as NSURL

            let existingValues = try? (url as URL).resourceValues(forKeys: [.tagNamesKey])
            var currentTags = existingValues?.tagNames ?? []
            for tag in newTags where !currentTags.contains(tag) {
                currentTags.append(tag)
            }

            try url.setResourceValue(currentTags, forKey: .tagNamesKey)
            return "Added tags \(newTags) to '\(path)'. Current tags: \(currentTags.joined(separator: ", "))"

        case "remove":
            guard let path = arguments.path, let removeTags = arguments.tags, !removeTags.isEmpty else {
                return "Error: 'path' and 'tags' required for remove."
            }
            let expandedPath = FilePathResolver.resolve(path)
            // See `add`: checked so a missing file is reported, not thrown.
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "Error: File not found at '\(expandedPath)'."
            }
            let url = URL(fileURLWithPath: expandedPath) as NSURL

            let existingValues = try? (url as URL).resourceValues(forKeys: [.tagNamesKey])
            var currentTags = existingValues?.tagNames ?? []
            currentTags.removeAll { removeTags.contains($0) }

            try url.setResourceValue(currentTags, forKey: .tagNamesKey)
            return "Removed tags \(removeTags) from '\(path)'. Remaining: \(currentTags.isEmpty ? "none" : currentTags.joined(separator: ", "))"

        case "set":
            // `set` lives in `replace_finder_tags` because it discards every existing tag and needs its own confirmation setting.
            return "Error: 'set' has moved to the `replace_finder_tags` tool, so it can carry its "
                + "own confirmation setting. Use 'add' or 'remove' here to change tags without "
                + "discarding the others."

        case "search":
            guard let searchTag = arguments.search_tag else {
                return "Error: 'search_tag' required for search."
            }
            let searchPath = arguments.path.map(FilePathResolver.resolve) ?? NSHomeDirectory()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            // `mdfind` takes a query language: a `'` in `searchTag` would end the literal and be parsed as query syntax.
            // Escape the backslash first, then the quote, or the added escapes would themselves be escaped.
            let escapedTag = searchTag
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            process.arguments = ["-onlyin", searchPath, "kMDItemUserTags == '\(escapedTag)'"]

            do {
                let output = try ProcessRunner.run(process).standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if output.isEmpty {
                    return "No files found with tag '\(searchTag)' in \(searchPath)."
                }

                let files = output.components(separatedBy: "\n").prefix(50)
                return "Files with tag '\(searchTag)' (\(files.count)):\n\(files.joined(separator: "\n"))"
            } catch {
                return "Error searching: \(error.localizedDescription)"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use read/add/remove/set/search."
        }
    }
}

// MARK: - Disk Usage Tool

struct DiskUsageTool: DevgenticTool {
    let name = "get_disk_usage"
    let category = "File System"
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
        switch arguments.action {
        case "volume":
            let path = arguments.path.map(FilePathResolver.resolve) ?? "/"
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
                """
            } catch {
                return "Error reading volume info: \(error.localizedDescription)"
            }

        case "folder_size":
            guard let path = arguments.path else {
                return "Error: 'path' required for folder_size."
            }
            let expandedPath = FilePathResolver.resolve(path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sh", expandedPath]

            do {
                let output = try ProcessRunner.run(process).standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "Folder size: \(output)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        case "largest_files":
            let searchPath = arguments.path.map(FilePathResolver.resolve) ?? NSHomeDirectory()
            // Clamped: `top_n` only bounds a Swift `prefix` now, but an unbounded value would
            // let one call return the entire tree.
            let topN = max(1, min(arguments.top_n ?? 10, 200))

            // `find` is invoked directly, never through a shell: `path` is a model-supplied argument.
            // `du`, `{}` and `+` are literals in our argv; `-exec ... +` keeps batching, and the sort/head step runs in Swift.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            process.arguments = [
                searchPath, "-type", "f",
                "-not", "-path", "*/.git/*",
                "-not", "-path", "*/node_modules/*",
                "-not", "-path", "*/DerivedData/*",
                // `-k` rather than `-h`: kilobyte counts sort numerically in Swift, with no shell `sort -rh` needed.
                "-exec", "du", "-k", "{}", "+",
            ]

            do {
                // stderr is ignored: `find` reports unreadable directories there and exits non-zero, which is not a search failure.
                let output = try ProcessRunner.run(process).standardOutput

                // `du -k` emits one record per file, but a filename may contain a newline, so a record is not always a line.
                // A record starts at a line that begins with `<digits>\t` and whose path begins with the search root.
                let entries: [(kb: Int, path: String)] = Self.parseDiskUsageRecords(
                    output, rootedAt: searchPath
                )
                .sorted { $0.kb > $1.kb }
                .prefix(topN)
                .map { $0 }

                if entries.isEmpty {
                    return "No files found in '\(searchPath)'."
                }

                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let listing = entries
                    .map { "\(formatter.string(fromByteCount: Int64($0.kb) * 1024))\t\($0.path)" }
                    .joined(separator: "\n")
                return "Largest files in '\(searchPath)':\n\(listing)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use volume/folder_size/largest_files."
        }
    }

    // Why: an empty segment in a name (`\n\n` or a trailing `\n`) is unrecoverable, and the empty-segment guard must stay,
    // or every ordinary path would gain a spurious trailing newline.
    /// Parses `du -k` output into records, tolerating filenames that contain newlines.
    /// `static` so the ambiguity is directly testable; a parse failure shows up as a missing row, not an error.
    /// Limitation: a name whose embedded newline is followed by `<digits>\t<root>` text starts a spurious record.
    static func parseDiskUsageRecords(_ output: String, rootedAt root: String) -> [(kb: Int, path: String)] {
        var records: [(kb: Int, path: String)] = []

        // Split on scalars, not Characters: `\r\n` is a single grapheme, so a filename ending in `\r` would merge
        // with the record separator and the next record would be absorbed into its path.
        let lines = output.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }

        for line in lines {
            if let tabIndex = line.firstIndex(of: "\t"),
               let kb = Int(line[line.startIndex..<tabIndex].trimmingCharacters(in: .whitespaces)) {
                let path = String(line[line.index(after: tabIndex)...])
                if path.hasPrefix(root) {
                    records.append((kb, path))
                    continue
                }
            }
            // Not a record start: this is the rest of a filename that contained a newline.
            if !records.isEmpty && !line.isEmpty {
                records[records.count - 1].path += "\n" + String(line)
            }
        }

        return records
    }
}

// MARK: - Display Management Tool

struct DisplayManagementTool: DevgenticTool {
    let name = "manage_displays"
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
        switch arguments.action {
        case "list":
            let screens = NSScreen.screens
            if screens.isEmpty {
                return "No displays detected."
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
            return "\(result)"

        case "get_brightness":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Use ioreg to read brightness from AppleBacklightDisplay
            process.arguments = ["-c", "ioreg -c AppleBacklightDisplay | grep -i brightness | tail -1"]

            do {
                let output = try ProcessRunner.run(process).standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if output.isEmpty {
                    return "Error: could not read brightness. External displays may not support programmatic brightness control."
                }
                return "Brightness info: \(output)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        case "set_brightness":
            guard let brightness = arguments.brightness, brightness >= 0.0, brightness <= 1.0 else {
                return "Error: 'brightness' must be between 0.0 and 1.0."
            }

            // Looks for the `brightness` CLI directly rather than through a shell; results start with "Error" so the
            // mediator records a missing tool as a failure.
            let brightnessCLI = ["/opt/homebrew/bin/brightness", "/usr/local/bin/brightness"]
                .first { FileManager.default.fileExists(atPath: $0) }

            guard let brightnessCLI else {
                logger.notice("[DISPLAY] set_brightness requested but the `brightness` CLI is not installed — the display was NOT changed.")
                return "Error: setting brightness needs the `brightness` command-line tool, which "
                    + "is not installed. Install it with `brew install brightness`. The display "
                    + "was not changed."
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: brightnessCLI)
            process.arguments = [String(brightness)]

            do {
                let run = try ProcessRunner.run(process)
                guard run.succeeded else {
                    let detail = (run.standardError.isEmpty ? run.standardOutput : run.standardError)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("[DISPLAY] brightness exited \(run.exitCode) — the display was NOT changed. \(detail.prefix(200))")
                    return "Error: could not set brightness (exit \(run.exitCode))"
                        + (detail.isEmpty ? "." : " — \(detail)")
                }
                let output = run.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Brightness set to \(brightness).\(output.isEmpty ? "" : " \(output)")"
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/get_brightness/set_brightness."
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

    /// Maps a pane name to its `x-apple.systempreferences:` URL.
    /// Returns nil for an unrecognised name, in which case the caller opens Settings at its default location.
    static func paneURL(for pane: String) -> String? {
        // macOS 13+ uses the x-apple.systempreferences URL scheme.
        switch pane.lowercased() {
        case "general": return "x-apple.systempreferences:com.apple.settings.General"
        case "appearance": return "x-apple.systempreferences:com.apple.Appearance-Settings.extension"
        case "accessibility": return "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
        case "privacy", "security": return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        case "network": return "x-apple.systempreferences:com.apple.Network-Settings.extension"
        case "wifi": return "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case "bluetooth": return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case "sound": return "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case "displays": return "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        case "keyboard": return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case "trackpad": return "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case "mouse": return "x-apple.systempreferences:com.apple.Mouse-Settings.extension"
        case "printers": return "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension"
        case "battery": return "x-apple.systempreferences:com.apple.settings.Battery"
        case "date_time": return "x-apple.systempreferences:com.apple.Date-Time-Settings.extension"
        case "notifications": return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case "focus": return "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case "users": return "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        case "passwords": return "x-apple.systempreferences:com.apple.Passwords-Settings.extension"
        case "software_update": return "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        case "storage": return "x-apple.systempreferences:com.apple.settings.Storage"
        case "desktop", "dock": return "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        case "wallpaper": return "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
        case "login_items": return "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case "siri": return "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        case "spotlight": return "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        default:
            // An unrecognised name is not an error: Settings opens at its default location, and nil lets the caller say so.
            return nil
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let resolved = Self.paneURL(for: arguments.pane)
        let target = resolved ?? "x-apple.systempreferences:"

        return await MainActor.run {
            guard let url = URL(string: target) else {
                return "Error: could not construct a URL for pane '\(arguments.pane)'."
            }
            NSWorkspace.shared.open(url)
            // The two outcomes are reported distinctly so a model that guessed a nonexistent pane is not told it landed on it.
            return resolved == nil
                ? "Opened System Settings. '\(arguments.pane)' is not a pane this tool recognises, so it opened at the default location."
                : "Opened System Settings: \(arguments.pane)."
        }
    }
}

// MARK: - Login Items Tool

struct LoginItemsTool: DevgenticTool {
    let name = "manage_login_items"
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
        switch arguments.action {
        case "list":
            let process = Process()
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

            do {
                let output = try ProcessRunner.run(process).standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if output.isEmpty {
                    return "No login items found."
                }

                let items = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                var result = "Login Items (\(items.count)):\n"
                for (idx, item) in items.enumerated() {
                    result += "  \(idx + 1). \(item)\n"
                }
                return "\(result)"
            } catch {
                return "Error listing login items: \(error.localizedDescription)"
            }

        case "open_settings":
            return await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                    return "Opened Login Items settings."
                }
                return "Error opening settings."
            }

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/open_settings."
        }
    }
}

// MARK: - External Devices Tool

struct ExternalDevicesTool: DevgenticTool {
    let name = "list_external_devices"
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
        let deviceType = arguments.device_type ?? "usb"

        switch deviceType {
        case "usb":
            return await shellCommand(
                "/usr/sbin/system_profiler", ["SPUSBDataType", "-detailLevel", "mini"]
            )

        case "disks":
            // List mounted volumes with size info
            let fm = FileManager.default
            guard let mountedURLs = fm.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey],
                options: [.skipHiddenVolumes]
            ) else {
                return "No mounted volumes found."
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
            return "\(result)"

        case "all":
            return await shellCommand(
                "/usr/sbin/system_profiler",
                ["SPUSBDataType", "SPBluetoothDataType", "SPDisplaysDataType", "SPAudioDataType", "-detailLevel", "mini"]
            )

        default:
            return "Error: Unknown device_type '\(deviceType)'. Use usb/disks/all."
        }
    }

    private func shellCommand(_ executable: String, _ args: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        do {
            var output = try ProcessRunner.run(process).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let maxOutput = 6000
            if output.count > maxOutput {
                output = String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
            }
            return "\(output)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Apple Notes Tool

struct AppleNotesTool: DevgenticTool {
    let name = "manage_apple_notes"
    let category = "Personal Information"
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
        switch arguments.action {
        case "list":
            let limit = arguments.limit ?? 20
            let folderClause: String
            if let folder = arguments.folder {
                // Escaped like every other interpolation: a raw `folder` could close the literal and append `do shell script`.
                folderClause = "of folder \"\(Self.escapeAppleScript(folder))\""
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
            return await runAppleScript(script, prefix: "Notes")

        case "read":
            guard let title = arguments.title else {
                return "Error: 'title' required for read."
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
            return await runAppleScript(script, prefix: "Note Content")

        case "create":
            guard let title = arguments.title else {
                return "Error: 'title' required for create."
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
            return await runAppleScript(script, prefix: "")

        case "search":
            guard let term = arguments.search_term else {
                return "Error: 'search_term' required for search."
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
            return await runAppleScript(script, prefix: "Search results for '\(term)'")

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
            return await runAppleScript(script, prefix: "Note Folders")

        default:
            return "Error: Unknown action '\(arguments.action)'. Use list/read/create/search/list_folders."
        }
    }

    private func runAppleScript(_ script: String, prefix: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            let run = try ProcessRunner.run(process)
            let output = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let errOutput = run.standardError.trimmingCharacters(in: .whitespacesAndNewlines)

            if !run.succeeded {
                return "Error: \(errOutput.isEmpty ? "AppleScript execution failed" : errOutput)"
            }

            if output.isEmpty {
                return "\(prefix.isEmpty ? "" : prefix + ": ")No results."
            }

            var result = output
            let maxOutput = 8000
            if result.count > maxOutput {
                result = String(result.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
            }

            if prefix.isEmpty {
                return "\(result)"
            }
            return "\(prefix):\n\(result)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Retained as the name every call site in this tool already uses; the rule itself lives in
    /// `AppleScriptEscaping` so `manage_safari_tabs` and this tool cannot drift apart.
    static func escapeAppleScript(_ str: String) -> String {
        return AppleScriptEscaping.escapeStringLiteral(str)
    }

    private static func escapeHTML(_ str: String) -> String {
        return str.replacingOccurrences(of: "&", with: "&amp;")
                  .replacingOccurrences(of: "<", with: "&lt;")
                  .replacingOccurrences(of: ">", with: "&gt;")
                  .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
