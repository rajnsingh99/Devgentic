//
//  WorkflowRunHistoryStore.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Persists workflow run records to UserDefaults (JSON-encoded).
//  Keyed by conversation ID — each conversation owns independent run history.
//  Max 20 records per conversation.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkflowRunHistoryStore")

final class WorkflowRunHistoryStore {
    static let shared = WorkflowRunHistoryStore()
    private let userDefaultsPrefix = "workflowConvHistory_"
    private let maxRecordsPerConversation = 20

    func load(forConversation conversationID: UUID) -> [WorkflowRunRecord] {
        let key = userDefaultsPrefix + conversationID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([WorkflowRunRecord].self, from: data) else {
            return []
        }
        return records
    }

    func append(_ record: WorkflowRunRecord, forConversation conversationID: UUID) {
        var records = load(forConversation: conversationID)
        records.insert(record, at: 0)
        if records.count > maxRecordsPerConversation {
            records = Array(records.prefix(maxRecordsPerConversation))
        }
        save(records, forConversation: conversationID)
        logger.info("Persisted run \(record.id) for conversation \(conversationID) (\(records.count) total)")
    }

    func clearHistory(forConversation conversationID: UUID) {
        let key = userDefaultsPrefix + conversationID.uuidString
        UserDefaults.standard.removeObject(forKey: key)
        logger.info("Cleared run history for conversation \(conversationID)")
    }

    // MARK: - Migration

    /// One-time migration from profile-keyed storage to conversation-keyed storage.
    /// Reads old `workflowRunHistory_{profileID}` keys, groups records by their
    /// embedded `conversationID`, writes under new `workflowConvHistory_{conversationID}` keys,
    /// and removes the old keys.
    func migrateFromProfileKeyedStorage(profileIDs: [UUID]) {
        let migrationKey = "workflowRunHistory_migrated_v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let oldPrefix = "workflowRunHistory_"
        var migrated = 0

        for profileID in profileIDs {
            let oldKey = oldPrefix + profileID.uuidString
            guard let data = UserDefaults.standard.data(forKey: oldKey),
                  let records = try? JSONDecoder().decode([WorkflowRunRecord].self, from: data)
            else { continue }

            // Group records by their conversationID and write each group under the new key
            let grouped = Dictionary(grouping: records, by: \.conversationID)
            for (conversationID, convRecords) in grouped {
                var existing = load(forConversation: conversationID)
                existing.append(contentsOf: convRecords)
                existing.sort(by: { $0.timestamp > $1.timestamp })
                if existing.count > maxRecordsPerConversation {
                    existing = Array(existing.prefix(maxRecordsPerConversation))
                }
                save(existing, forConversation: conversationID)
                migrated += convRecords.count
            }

            // Remove old profile-keyed entry
            UserDefaults.standard.removeObject(forKey: oldKey)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        if migrated > 0 {
            logger.info("Migrated \(migrated) workflow run records from profile-keyed to conversation-keyed storage.")
        }
    }

    // MARK: - Private

    private func save(_ records: [WorkflowRunRecord], forConversation conversationID: UUID) {
        let key = userDefaultsPrefix + conversationID.uuidString
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
