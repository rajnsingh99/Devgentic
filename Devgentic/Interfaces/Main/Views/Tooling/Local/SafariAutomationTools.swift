//
//  SafariAutomationTools.swift
//  Devgentic
//

import Foundation
import AppKit

struct ManageSafariTabsTool: DevgenticTool {
    let name = "manage_safari_tabs"
    let category = "Native Browser Automation"
    let description = "Manages Safari tabs: open URL, close current, get active URL, list all tabs, switch to tab by index, or get page source."

    struct Arguments: Decodable, Sendable {
        let action: String
        let url: String?
        let tab_index: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('open', 'close_current', 'get_active_url', 'list_tabs', 'switch_tab', 'get_page_source')"),
                ("url", "string", "URL to open (required for 'open')"),
                ("tab_index", "integer", "Tab index to switch to (required for 'switch_tab', 1-based)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            var script = ""
            switch arguments.action {
            case "open":
                guard let url = arguments.url else { return "Error: url missing." }
                script = """
                tell application "Safari"
                    open location "\(url)"
                    activate
                end tell
                """
            case "close_current":
                script = """
                tell application "Safari"
                    close current tab of front window
                end tell
                """
            case "get_active_url":
                script = """
                if application "Safari" is running then
                    tell application "Safari"
                        if (count of windows) > 0 then
                            return URL of current tab of front window
                        else
                            return "No open windows"
                        end if
                    end tell
                else
                    return "Safari is not running"
                end if
                """
            case "list_tabs":
                script = """
                if application "Safari" is running then
                    tell application "Safari"
                        set tabList to ""
                        repeat with w from 1 to (count of windows)
                            set tabList to tabList & "Window " & w & ":" & linefeed
                            repeat with t from 1 to (count of tabs of window w)
                                set tabName to name of tab t of window w
                                set tabURL to URL of tab t of window w
                                set tabList to tabList & "  [" & t & "] " & tabName & " — " & tabURL & linefeed
                            end repeat
                        end repeat
                        return tabList
                    end tell
                else
                    return "Safari is not running"
                end if
                """
            case "switch_tab":
                guard let idx = arguments.tab_index else { return "Error: tab_index required for switch_tab." }
                script = """
                tell application "Safari"
                    set current tab of front window to tab \(idx) of front window
                    activate
                end tell
                """
            case "get_page_source":
                script = """
                if application "Safari" is running then
                    tell application "Safari"
                        if (count of windows) > 0 then
                            return source of current tab of front window
                        else
                            return "No open windows"
                        end if
                    end tell
                else
                    return "Safari is not running"
                end if
                """
            default:
                return "Error: Unknown action '\(arguments.action)'."
            }

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            let desc = scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "AppleScript Error: \(err)"
            }

            let output = desc?.stringValue ?? "Success"
            return output
        }
    }
}

struct ReadSafariBookmarksTool: DevgenticTool {
    let name = "read_safari_bookmarks"
    let category = "Native Browser Automation"
    let description = "Reads a limited scope of Safari bookmarks."
    
    struct Arguments: Decodable, Sendable {
        let limit: Int?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("limit", "integer", "Number of bookmarks to return limit (default 10)")
            ],
            required: []
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return "Error: Could not read Bookmarks.plist. Need Full Disk Access or file is missing."
        }

        var foundURLs: [String] = []
        func findURLs(in dict: [String: Any]) {
            if let count = arguments.limit, foundURLs.count >= count { return }

            if let url = dict["URLString"] as? String, let titleDict = dict["URIDictionary"] as? [String: Any], let title = titleDict["title"] as? String {
                foundURLs.append("\(title): \(url)")
            } else if let children = dict["Children"] as? [[String: Any]] {
                for child in children {
                    findURLs(in: child)
                }
            }
        }

        findURLs(in: plist)

        return "Bookmarks:\n\(foundURLs.joined(separator: "\n"))"
    }
}

struct ExtractSafariReaderViewTool: DevgenticTool {
    let name = "extract_safari_reader_view"
    let category = "Native Browser Automation"
    let description = "Extracts text from Safari's current tab with pagination support. Use offset and limit to read long pages in chunks."

    struct Arguments: Decodable, Sendable {
        let offset: Int?
        let limit: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("offset", "integer", "Character offset to start reading from (default 0)"),
                ("limit", "integer", "Max characters to return (default 5000)")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            let script = """
            if application "Safari" is running then
                tell application "Safari"
                    if (count of windows) > 0 then
                        return text of current tab of front window
                    else
                        return "No open windows"
                    end if
                end tell
            else
                return "Safari is not running"
            end if
            """

            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            let desc = scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "AppleScript Error: \(err)"
            }

            let output = desc?.stringValue ?? "No content found"
            let startOffset = arguments.offset ?? 0
            let maxLen = arguments.limit ?? 5000
            let totalLen = output.count

            guard startOffset < totalLen else {
                return "Offset \(startOffset) exceeds content length \(totalLen)."
            }

            let startIdx = output.index(output.startIndex, offsetBy: startOffset)
            let endIdx = output.index(startIdx, offsetBy: min(maxLen, totalLen - startOffset))
            let chunk = String(output[startIdx..<endIdx])
            let hasMore = (startOffset + maxLen) < totalLen

            var result = chunk
            result += "\n\n[Total: \(totalLen) chars | Showing: \(startOffset)–\(startOffset + chunk.count)]"
            if hasMore {
                result += "\n[More content available — use offset: \(startOffset + chunk.count)]"
            }

            return result
        }
    }
}
