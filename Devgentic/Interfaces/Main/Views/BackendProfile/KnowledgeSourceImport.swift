//
//  KnowledgeSourceImport.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  The "Add File" importer shared by the agent and bot editors.
//
//  ⚠️ Register A60. The two editors each carried their own copy of this loop, both written
//  `if case let .success(urls) = result` — so a `.failure` was dropped entirely: no message, no log,
//  no retry hint. An iCloud placeholder that fails to materialise, a file on an ejected volume, or a
//  sandbox permission denial all looked exactly like pressing Cancel.
//
//  ⚠️ Both copies also dropped duplicates in silence. Re-adding a file already attached is not an
//  error and must not be reported as one — but selecting three files and seeing the list grow by one
//  needs a word of explanation, or it reads as a broken import.
//
//  One implementation because two copies of the same loop is how they came to be wrong in the same
//  way twice (cf. registers A28, A32).
//

import SwiftUI

enum KnowledgeSourceImport {

    /// Applies a `.fileImporter` result to a knowledge-source list.
    /// - Returns: a message to show the user, or `nil` when there is nothing to say.
    static func apply(
        _ result: Result<[URL], Error>,
        to sources: Binding<[KnowledgeSource]>,
        profileKind: String
    ) -> String? {
        switch result.fileImportOutcome() {
        case .cancelled:
            logger.debug("[PROFILE] Knowledge file import dismissed by the user (\(profileKind)); nothing added.")
            return nil

        case .failed(let message):
            logger.error(
                "[PROFILE] Knowledge file import FAILED (\(profileKind)): \(message). CONSEQUENCE: "
                + "no file was attached and the profile's knowledge sources are unchanged; the "
                + "reason is shown inline so the user can retry instead of assuming the picker is broken."
            )
            return String(localized: "Couldn't add the selected file(s): \(message)")

        case .selected(let urls):
            var added = 0
            var duplicates: [String] = []

            for url in urls {
                let source = KnowledgeSource(type: .file, location: url.path)
                if sources.wrappedValue.contains(where: { $0.location == source.location }) {
                    duplicates.append(url.lastPathComponent)
                    continue
                }
                sources.wrappedValue.append(source)
                added += 1
            }

            if duplicates.isEmpty {
                logger.info("[PROFILE] Attached \(added) knowledge file(s) to the \(profileKind) draft.")
                return nil
            }

            logger.notice(
                "[PROFILE] \(duplicates.count) selected knowledge file(s) were already attached to "
                + "the \(profileKind) draft and were skipped (\(duplicates.joined(separator: ", "))); "
                + "\(added) added. CONSEQUENCE: no duplicate entries are created — the existing ones stand."
            )
            // Not styled as an error: re-picking an attached file is a reasonable thing to do. It is
            // reported only so the count of newly-added files makes sense.
            return String(localized: "Already attached, so skipped: \(duplicates.joined(separator: ", "))")
        }
    }
}

private let logger = DGLogger(category: "KnowledgeSourceImport")
