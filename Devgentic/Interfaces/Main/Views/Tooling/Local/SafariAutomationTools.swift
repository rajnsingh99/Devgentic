//
//  SafariAutomationTools.swift
//  Devgentic
//

import Foundation
import AppKit

struct ManageSafariTabsTool: DevgenticTool {
    let name = "manage_safari_tabs"
    let category = "Native Browser Automation"
    let description = "Manages Safari tabs: open URL, close current, or get active URL."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let url: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('open', 'close_current', 'get_active_url')"),
                ("url", "string", "URL to open (required for 'open')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Safari tab action: \(arguments.action)",
            operations: [["action": arguments.action]]
        )
        
        return await MainActor.run {
            var script = ""
            switch arguments.action {
            case "open":
                guard let url = arguments.url else { return "Error: url missing. (Audit Ref: \(logID))" }
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
            default:
                return "Error: Unknown action '\(arguments.action)'. (Audit Ref: \(logID))"
            }
            
            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            let desc = scriptObj?.executeAndReturnError(&errorInfo)
            
            if let err = errorInfo {
                return "AppleScript Error: \(err) (Audit Ref: \(logID))"
            }
            
            let output = desc?.stringValue ?? "Success"
            return "\(output) (Audit Ref: \(logID))"
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
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Read Safari Bookmarks",
            operations: []
        )
        
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return "Error: Could not read Bookmarks.plist. Need Full Disk Access or file is missing. (Audit Ref: \(logID))"
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
        
        return "Bookmarks:\n\(foundURLs.joined(separator: "\n"))\n(Audit Ref: \(logID))"
    }
}

struct ExtractSafariReaderViewTool: DevgenticTool {
    let name = "extract_safari_reader_view"
    let category = "Native Browser Automation"
    let description = "Extracts the text or triggers Reader Mode in Safari."
    
    struct Arguments: Decodable, Sendable {}
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Extracted Safari Text",
            operations: []
        )
        
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
                return "AppleScript Error: \(err) (Audit Ref: \(logID))"
            }
            
            let output = desc?.stringValue ?? "No content found"
            let maxLen = 3000
            let res = output.count > maxLen ? String(output.prefix(maxLen)) + "...\n[Truncated]" : output
            
            return "\(res) (Audit Ref: \(logID))"
        }
    }
}
