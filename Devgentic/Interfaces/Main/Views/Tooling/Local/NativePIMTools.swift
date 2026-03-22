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
    let description = "Full calendar management: read, create, update, delete, or search events."

    struct Arguments: Decodable, Sendable {
        let action: String
        let start_date: String?
        let end_date: String?
        let title: String?
        let event_id: String?
        let search_term: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'read', 'create', 'delete', 'search'"),
                ("start_date", "string", "ISO8601 start date (for read/create)"),
                ("end_date", "string", "ISO8601 end date (for read/create)"),
                ("title", "string", "Event title (for create)"),
                ("event_id", "string", "Event identifier (for delete)"),
                ("search_term", "string", "Keyword to search events (for search)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        var accessGranted: Bool

        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToEvents()
        } else {
            accessGranted = try await store.requestAccess(to: .event)
        }

        guard accessGranted else {
            return "Error: Calendar access denied."
        }

        let formatter = ISO8601DateFormatter()

        switch arguments.action {
        case "read":
            guard let startStr = arguments.start_date, let endStr = arguments.end_date,
                  let start = formatter.date(from: startStr), let end = formatter.date(from: endStr) else {
                return "Error: start_date and end_date required (ISO8601)."
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate)
            let eventStrings = events.map { "- [\($0.eventIdentifier ?? "?")] \($0.title ?? "Untitled") from \($0.startDate ?? Date()) to \($0.endDate ?? Date())" }
            return "Events:\n\(eventStrings.joined(separator: "\n"))"

        case "create":
            guard let startStr = arguments.start_date, let endStr = arguments.end_date,
                  let start = formatter.date(from: startStr), let end = formatter.date(from: endStr) else {
                return "Error: start_date and end_date required (ISO8601)."
            }
            guard let title = arguments.title else {
                return "Error: 'title' required for create."
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "Created event '\(title)' (ID: \(event.eventIdentifier ?? "unknown"))."

        case "delete":
            guard let eventID = arguments.event_id else {
                return "Error: 'event_id' required for delete."
            }
            guard let event = store.event(withIdentifier: eventID) else {
                return "Error: Event not found with ID '\(eventID)'."
            }
            try store.remove(event, span: .thisEvent)
            return "Deleted event '\(event.title ?? "Untitled")'."

        case "search":
            guard let term = arguments.search_term else {
                return "Error: 'search_term' required for search."
            }
            let start = Date()
            let end = Calendar.current.date(byAdding: .month, value: 3, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate).filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(term) ||
                ($0.notes ?? "").localizedCaseInsensitiveContains(term)
            }
            let eventStrings = events.map { "- [\($0.eventIdentifier ?? "?")] \($0.title ?? "Untitled") on \($0.startDate ?? Date())" }
            return "Search results for '\(term)' (\(events.count)):\n\(eventStrings.joined(separator: "\n"))"

        default:
            return "Error: Unknown action '\(arguments.action)'."
        }
    }
}

struct ManageRemindersTool: DevgenticTool {
    let name = "manage_reminders"
    let category = "Personal Information"
    let description = "Full reminder management: read, create, complete, or delete reminders."

    struct Arguments: Decodable, Sendable {
        let action: String
        let title: String?
        let due_date: String?
        let reminder_title: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'read', 'create', 'complete', 'delete'"),
                ("title", "string", "Title (for create, or exact title match for complete/delete)"),
                ("due_date", "string", "ISO8601 due date (optional for create)"),
                ("reminder_title", "string", "Exact title of reminder to complete/delete")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        var accessGranted: Bool

        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToReminders()
        } else {
            accessGranted = try await store.requestAccess(to: .reminder)
        }

        guard accessGranted else {
            return "Error: Reminders access denied."
        }

        switch arguments.action {
        case "read":
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    let items = reminders ?? []
                    let strings = items.map { r -> String in
                        var line = "- \(r.title ?? "Untitled")"
                        if let dueDate = r.dueDateComponents?.date {
                            line += " (due: \(dueDate))"
                        }
                        return line
                    }
                    continuation.resume(returning: "Incomplete Reminders (\(items.count)):\n\(strings.joined(separator: "\n"))")
                }
            }

        case "create":
            guard let title = arguments.title else {
                return "Error: 'title' required for create."
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let dueDateStr = arguments.due_date {
                let formatter = ISO8601DateFormatter()
                if let dueDate = formatter.date(from: dueDateStr) {
                    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
                }
            }
            try store.save(reminder, commit: true)
            return "Created reminder '\(title)'."

        case "complete", "delete":
            let targetTitle = arguments.reminder_title ?? arguments.title
            guard let searchTitle = targetTitle else {
                return "Error: 'reminder_title' or 'title' required."
            }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    guard let match = (reminders ?? []).first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(searchTitle) }) else {
                        continuation.resume(returning: "Error: No reminder found matching '\(searchTitle)'.")
                        return
                    }
                    do {
                        if arguments.action == "complete" {
                            match.isCompleted = true
                            try store.save(match, commit: true)
                            continuation.resume(returning: "Completed reminder '\(match.title ?? "")'.")
                        } else {
                            let title = match.title ?? ""
                            try store.remove(match, commit: true)
                            continuation.resume(returning: "Deleted reminder '\(title)'.")
                        }
                    } catch {
                        continuation.resume(returning: "Error: \(error.localizedDescription)")
                    }
                }
            }

        default:
            return "Error: Unknown action '\(arguments.action)'."
        }
    }
}

struct ManageContactsTool: DevgenticTool {
    let name = "manage_contacts"
    let category = "Personal Information"
    let description = "Manages contacts: search, list, or create new contacts."

    struct Arguments: Decodable, Sendable {
        let action: String
        let query: String?
        let given_name: String?
        let family_name: String?
        let email: String?
        let phone: String?
        let limit: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'search', 'list', 'create'"),
                ("query", "string", "Name to search for (for search)"),
                ("given_name", "string", "First name (for create)"),
                ("family_name", "string", "Last name (for create)"),
                ("email", "string", "Email address (for create)"),
                ("phone", "string", "Phone number (for create)"),
                ("limit", "integer", "Max contacts to return for list (default 20)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = CNContactStore()
        let access = try await store.requestAccess(for: .contacts)
        guard access else {
            return "Error: Contacts access denied."
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        switch arguments.action {
        case "search":
            guard let query = arguments.query else {
                return "Error: 'query' required for search."
            }
            let predicate = CNContact.predicateForContacts(matchingName: query)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return formatContacts(contacts)

        case "list":
            let limit = arguments.limit ?? 20
            var allContacts: [CNContact] = []
            let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
            fetchRequest.sortOrder = .givenName
            try store.enumerateContacts(with: fetchRequest) { contact, stop in
                allContacts.append(contact)
                if allContacts.count >= limit {
                    stop.pointee = true
                }
            }
            return formatContacts(allContacts)

        case "create":
            guard let givenName = arguments.given_name else {
                return "Error: 'given_name' required for create."
            }
            let newContact = CNMutableContact()
            newContact.givenName = givenName
            newContact.familyName = arguments.family_name ?? ""
            if let email = arguments.email {
                newContact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
            }
            if let phone = arguments.phone {
                newContact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
            }
            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)
            try store.execute(saveRequest)
            return "Created contact: \(givenName) \(arguments.family_name ?? "")."

        default:
            return "Error: Unknown action '\(arguments.action)'."
        }
    }

    private func formatContacts(_ contacts: [CNContact]) -> String {
        if contacts.isEmpty {
            return "No contacts found."
        }
        var results: [String] = []
        for contact in contacts {
            var info = "- \(contact.givenName) \(contact.familyName)"
            if let email = contact.emailAddresses.first?.value as? String {
                info += ", Email: \(email)"
            }
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                info += ", Phone: \(phone)"
            }
            results.append(info)
        }
        return "Contacts (\(contacts.count)):\n\(results.joined(separator: "\n"))"
    }
}
