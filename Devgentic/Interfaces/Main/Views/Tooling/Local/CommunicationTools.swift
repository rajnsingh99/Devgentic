//
//  CommunicationTools.swift
//  Devgentic
//

import Foundation
import AppKit

struct ManageAppleMailTool: DevgenticTool {
    let name = "manage_apple_mail"
    let category = "Communication & Mail"
    let description = "Gets unread emails or creates a new email draft."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let to: String?
        let subject: String?
        let body: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('get_unread', 'create_draft')"),
                ("to", "string", "Recipient email address for draft"),
                ("subject", "string", "Subject for the draft"),
                ("body", "string", "Body text for the draft")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Mail action: \(arguments.action)",
            operations: [["action": arguments.action]]
        )
        
        return await MainActor.run {
            var script = ""
            switch arguments.action {
            case "get_unread":
                script = """
                tell application "Mail"
                    set unreadMsgs to (messages of inbox whose read status is false)
                    set output to ""
                    set limit to 5
                    set i to 1
                    repeat with msg in unreadMsgs
                        if i > limit then exit repeat
                        set msgSubject to subject of msg
                        set msgSender to sender of msg
                        set output to output & "- " & msgSubject & " (from: " & msgSender & ")" & return
                        set i to i + 1
                    end repeat
                    if output is "" then set output to "No unread messages."
                    return output
                end tell
                """
            case "create_draft":
                let t = arguments.to ?? ""
                let s = arguments.subject ?? ""
                let b = arguments.body ?? ""
                script = """
                tell application "Mail"
                    set theMessage to make new outgoing message with properties {subject:"\(s)", content:"\(b)", visible:true}
                    tell theMessage
                        make new to recipient at end of to recipients with properties {address:"\(t)"}
                    end tell
                    activate
                end tell
                """
            default:
                return "Error: Unknown action. (Audit Ref: \(logID))"
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

struct SendIMessageTool: DevgenticTool {
    let name = "send_imessage"
    let category = "Communication & Mail"
    let description = "Sends an iMessage to a recipient."
    
    struct Arguments: Decodable, Sendable {
        let target_buddy: String
        let message: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("target_buddy", "string", "Phone number or email of the recipient"),
                ("message", "string", "Message to send")
            ],
            required: ["target_buddy", "message"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Sent iMessage to \(arguments.target_buddy)",
            operations: [["target": arguments.target_buddy]]
        )
        
        return await MainActor.run {
            let script = """
            tell application "Messages"
                set targetBuddy to "\(arguments.target_buddy)"
                set targetService to 1st service whose service type = iMessage
                set theBuddy to buddy targetBuddy of targetService
                send "\(arguments.message)" to theBuddy
            end tell
            """
            
            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            _ = scriptObj?.executeAndReturnError(&errorInfo)
            
            if let err = errorInfo {
                return "AppleScript Error: \(err) (Audit Ref: \(logID))"
            }
            return "Successfully sent iMessage. (Audit Ref: \(logID))"
        }
    }
}
