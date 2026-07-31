//
//  NativePIMTools.swift
//  Devgentic
//

import Foundation
import EventKit
import Contacts

/// Deleting a calendar event, as its own tool.
///
/// It was an `action` on `manage_calendar` until 2026-07-31. The problem was not the multiplexing
/// itself — `git_tool`'s seven subcommands share a noun and an output shape and are fine — but that
/// this one bundled frequent harmless READS with an irreversible write under a single name, and a
/// tool carries exactly one `requiresConfirmation`. The user could not express "ask before
/// deleting, not before reading", and being prompted on every read is worse than useless: it
/// teaches the reflex that approves the delete without looking.
///
/// Same reasoning, same shape as `create_file` → `create_new_file` / `overwrite_file`: reaching the
/// destructive path now takes choosing a differently-named tool, not changing one word in an
/// argument. Classified `.destructive` in `HITLRiskTier`, so the banner reads as a deletion.
struct DeleteCalendarEventTool: DevgenticTool {
    let name = "delete_calendar_event"
    let category = "Personal Information"
    let description = "Deletes a calendar event by its identifier. Irreversible — find the event id with manage_calendar first."

    struct Arguments: Decodable, Sendable {
        let event_id: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("event_id", "string", "Identifier of the event to delete (from manage_calendar read/search).")
            ],
            required: ["event_id"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        let accessGranted: Bool
        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToEvents()
        } else {
            accessGranted = try await store.requestAccess(to: .event)
        }
        guard accessGranted else { return "Error: Calendar access denied." }

        guard let event = store.event(withIdentifier: arguments.event_id) else {
            return "Error: Event not found with ID '\(arguments.event_id)'."
        }
        // Title captured BEFORE removal — reading it afterwards is reading a deleted object.
        let title = event.title ?? "Untitled"
        try store.remove(event, span: .thisEvent)
        return "Deleted event '\(title)'."
    }
}

struct ManageCalendarTool: DevgenticTool {
    let name = "manage_calendar"
    let category = "Personal Information"
    let description = "Calendar reads and additions: read a date range, create an event, or search. Deleting is a separate tool."

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
                ("action", "string", "Action: 'read', 'create', 'search'"),
                ("start_date", "string", "ISO8601 start date (for read/create)"),
                ("end_date", "string", "ISO8601 end date (for read/create)"),
                ("title", "string", "Event title (for create)"),
                ("event_id", "string", "Event identifier (unused here; deleting is `delete_calendar_event`)"),
                ("search_term", "string", "Keyword to search events (for search)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Checked BEFORE requesting calendar access: an action that no longer lives here should
        // not trigger a permission prompt, and the answer does not depend on the store.
        if arguments.action == "delete" {
            // Split out to `delete_calendar_event` on 2026-07-31. A tool carries ONE
            // `requiresConfirmation`, so while deletion lived here the user had to choose between
            // being prompted for every calendar READ — which trains the reflex that then approves
            // the delete — or never being prompted at all. Neither expresses "ask before
            // destroying, not before looking".
            return "Error: 'delete' has moved to the `delete_calendar_event` tool, so it can carry "
                + "its own confirmation setting. Call that tool with the event_id instead."
        }

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

/// Deleting a reminder, as its own tool — split from `manage_reminders` on 2026-07-31 for the
/// reason given on `DeleteCalendarEventTool`. Note the pairing this separates: `complete` marks a
/// reminder done and can be undone; `delete` removes it and cannot.
struct DeleteReminderTool: DevgenticTool {
    let name = "delete_reminder"
    let category = "Personal Information"
    let description = "Deletes a reminder matching a title. Irreversible — use manage_reminders 'complete' to just mark it done."

    struct Arguments: Decodable, Sendable {
        let reminder_title: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("reminder_title", "string", "Title of the reminder to delete (matched case-insensitively).")
            ],
            required: ["reminder_title"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        let accessGranted: Bool
        if #available(macOS 14.0, *) {
            accessGranted = try await store.requestFullAccessToReminders()
        } else {
            accessGranted = try await store.requestAccess(to: .reminder)
        }
        guard accessGranted else { return "Error: Reminders access denied." }

        let searchTitle = arguments.reminder_title
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let match = (reminders ?? []).first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(searchTitle) }) else {
                    continuation.resume(returning: "Error: No reminder found matching '\(searchTitle)'.")
                    return
                }
                do {
                    // Title captured BEFORE removal — reading it afterwards reads a deleted object.
                    let title = match.title ?? ""
                    try store.remove(match, commit: true)
                    continuation.resume(returning: "Deleted reminder '\(title)'.")
                } catch {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct ManageRemindersTool: DevgenticTool {
    let name = "manage_reminders"
    let category = "Personal Information"
    let description = "Reminder reads and additions: list incomplete reminders, create one, or mark one complete. Deleting is a separate tool."

    struct Arguments: Decodable, Sendable {
        let action: String
        let title: String?
        let due_date: String?
        let reminder_title: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'read', 'create', 'complete'"),
                ("title", "string", "Title (for create, or exact title match for complete)"),
                ("due_date", "string", "ISO8601 due date (optional for create)"),
                ("reminder_title", "string", "Exact title of reminder to complete")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Checked BEFORE requesting reminders access — see the note in `ManageCalendarTool`.
        if arguments.action == "delete" {
            return "Error: 'delete' has moved to the `delete_reminder` tool, so it can carry its "
                + "own confirmation setting. Completing a reminder is reversible; deleting is not."
        }

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

        case "complete":
            // `complete` and `delete` shared this branch until 2026-07-31 — one reversible, one
            // not, separated by a single word in a JSON string inside the same block. Deletion
            // now lives in `delete_reminder` so it can carry its own confirmation setting.
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
                        match.isCompleted = true
                        try store.save(match, commit: true)
                        continuation.resume(returning: "Completed reminder '\(match.title ?? "")'.")
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
