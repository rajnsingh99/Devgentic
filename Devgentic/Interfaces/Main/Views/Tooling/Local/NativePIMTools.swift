//
//  NativePIMTools.swift
//  Devgentic
//

import Foundation
import EventKit
import Contacts

struct ManageCalendarTool: DevgenticTool {
    let name = "manage_calendar"
    let category = "Personal Information"
    let description = "Reads schedule or creates calendar events. Find free slots, list upcoming events, or add new events."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let start_date: String
        let end_date: String
        let title: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "'read' or 'create'"),
                ("start_date", "string", "ISO8601 string for start date"),
                ("end_date", "string", "ISO8601 string for end date"),
                ("title", "string", "Title of the event (required for 'create')")
            ],
            required: ["action", "start_date", "end_date"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Performed \(arguments.action) on calendar",
            operations: [
                ["action": arguments.action]
            ]
        )
        
        let store = EKEventStore()
        var accessGranted: Bool
        
        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToEvents()
        } else {
            accessGranted = try await store.requestAccess(to: .event)
        }
        
        guard accessGranted else {
            return "Error: Calendar access denied. (Audit Ref: \(logID))"
        }
        
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: arguments.start_date),
              let end = formatter.date(from: arguments.end_date) else {
            return "Error: Invalid date format. Use ISO8601. (Audit Ref: \(logID))"
        }
        
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        
        if arguments.action == "read" {
            let events = store.events(matching: predicate)
            let eventStrings = events.map { "- \($0.title ?? "Untitled") from \($0.startDate ?? Date()) to \($0.endDate ?? Date())" }
            return "Events:\n\(eventStrings.joined(separator: "\n"))\n(Audit Ref: \(logID))"
        } else if arguments.action == "create" {
            guard let title = arguments.title else {
                return "Error: 'title' is required for creating events. (Audit Ref: \(logID))"
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "Successfully created event '\(title)'. (Audit Ref: \(logID))"
        }
        
        return "Error: Unknown action '\(arguments.action)'. (Audit Ref: \(logID))"
    }
}

struct ManageRemindersTool: DevgenticTool {
    let name = "manage_reminders"
    let category = "Personal Information"
    let description = "Reads user's reminders or creates new ones. Useful for fetching todo lists or adding reminders."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let title: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "'read' or 'create'"),
                ("title", "string", "Title of the reminder (required for 'create')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Performed \(arguments.action) on reminders",
            operations: [
                ["action": arguments.action]
            ]
        )
        
        let store = EKEventStore()
        var accessGranted: Bool
        
        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToReminders()
        } else {
            accessGranted = try await store.requestAccess(to: .reminder)
        }
        
        guard accessGranted else {
            return "Error: Reminders access denied. (Audit Ref: \(logID))"
        }
        
        if arguments.action == "read" {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    let items = reminders ?? []
                    let strings = items.map { "- \($0.title ?? "Untitled")" }
                    continuation.resume(returning: "Incomplete Reminders:\n\(strings.joined(separator: "\n"))\n(Audit Ref: \(logID))")
                }
            }
        } else if arguments.action == "create" {
            guard let title = arguments.title else {
                return "Error: 'title' is required for creating reminders. (Audit Ref: \(logID))"
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            return "Successfully created reminder '\(title)'. (Audit Ref: \(logID))"
        }
        
        return "Error: Unknown action '\(arguments.action)'. (Audit Ref: \(logID))"
    }
}

struct ReadContactsTool: DevgenticTool {
    let name = "read_contacts"
    let category = "Personal Information"
    let description = "Looks up contact information including email addresses and phone numbers."
    
    struct Arguments: Decodable, Sendable {
        let query: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("query", "string", "Name to search for.")
            ],
            required: ["query"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Searched contacts for \(arguments.query)",
            operations: [
                ["query": arguments.query]
            ]
        )
        
        let store = CNContactStore()
        let access = try await store.requestAccess(for: .contacts)
        guard access else {
            return "Error: Contacts access denied. (Audit Ref: \(logID))"
        }
        
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        
        let predicate = CNContact.predicateForContacts(matchingName: arguments.query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        
        var results: [String] = []
        for contact in contacts {
            var info = "Found: \(contact.givenName) \(contact.familyName)"
            if let email = contact.emailAddresses.first?.value as? String {
                info += ", Email: \(email)"
            }
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                info += ", Phone: \(phone)"
            }
            results.append(info)
        }
        
        if results.isEmpty {
            return "No contacts found matching '\(arguments.query)'. (Audit Ref: \(logID))"
        }
        
        return results.joined(separator: "\n") + "\n(Audit Ref: \(logID))"
    }
}
