//
//  ChatHistoryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import os

private let logger = DGLogger(category: "ChatHistoryViewModel")

/// Why `applyChanges` couldn't write a snippet back to its source file. Surfaced to the
/// user via `ChatHistoryViewModel.codeApplyError` — previously these were log-only, so a
/// failed apply was indistinguishable from a successful one.
enum CodeApplyError: LocalizedError, Sendable {
    case sourceFileMissing
    case diskDrift(fileName: String)
    case writeFailed(fileName: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing:
            return String(localized: "Couldn't find the file these changes belong to — it may have been detached.")
        case .diskDrift(let name):
            return String(localized: "\"\(name)\" changed on disk since it was attached, so applying now would overwrite those edits. Re-attach the file and try again.")
        case .writeFailed(let name, let underlying):
            return String(localized: "Couldn't save changes to \"\(name)\": \(underlying)")
        }
    }
}

@Observable @MainActor
final class ChatHistoryViewModel {

    // MARK: - Dependencies
    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol
    @ObservationIgnored private let activeStreamManager: ActiveStreamManager

    // MARK: - State Properties for Code Viewer
    var codeViewerContent: (snippets: [CodeSnippet], currentIndex: Int)? = nil
    var isShowingDiff: Bool = false
    var originalCodeForDiff: String? = nil
    /// Set when `applyChanges` can't write (missing source file, on-disk drift, or an
    /// I/O error) so the panel can surface it. These failures were previously log-only,
    /// leaving the user believing the change had applied.
    var codeApplyError: String? = nil

    // MARK: - State Properties for Chat History
    // OPTIMIZATION: Stores messages in Descending order (Newest -> Oldest).
    // This allows O(1) appending of history pages instead of O(n) insertion at index 0.
    var currentChatMessages: [ChatMessage] = []

    var isInitiallyLoadingConversation = false

    var isLoadingPage = false
    var canLoadMorePages = true
    @ObservationIgnored private let initialPageSize = 20
    @ObservationIgnored private let subsequentPageSize = 10

    // Monotonic counter bumped on every `loadConversation` entry. Each in-flight
    // load captures its own epoch and refuses to write results if a newer load
    // has started while it was awaiting persistence — guards against any caller
    // that doesn't cancel the previous task (e.g. fire-and-forget Task closures).
    @ObservationIgnored private var loadEpoch: UInt64 = 0

    // Tracks the in-flight task spawned by `toggleUserMessagesFilter` so rapid
    // toggles cancel the prior reload instead of racing it.
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    var isSending: Bool = false
    var isUserMessagesOnlyFilterActive: Bool = false

    /// Aggregated token usage across all messages in the current conversation.
    var conversationTokenUsage: TokenUsage? {
        let usages = currentChatMessages.compactMap(\.tokenUsage)
        guard !usages.isEmpty else { return nil }
        return usages.dropFirst().reduce(into: usages[0]) { $0.accumulate($1) }
    }

    // MARK: - Initialization
    init(
        persistenceService: ChatPersistenceProtocol = ChatPersistenceStore.shared,
        activeStreamManager: ActiveStreamManager
    ) {
        self.persistenceService = persistenceService
        self.activeStreamManager = activeStreamManager
        logger.info("ChatHistoryViewModel initialized.")
    }

    // MARK: - Code Viewer Panel Control
    
    func showCodeInViewer(language: String?, code: String) {
        let snippet = CodeSnippet(language: language, code: code)
        codeViewerContent = (snippets: [snippet], currentIndex: 0)
        // Reset any diff left over from a previous snippet — otherwise the panel renders
        // a garbage diff (the OLD baseline vs the NEW snippet) with a live Apply button.
        // `navigate*`/`hideCodeViewer` already do this; opening fresh content must too.
        isShowingDiff = false
        originalCodeForDiff = nil
        logger.info("Code viewer content set for language: \(language ?? "nil")")
    }

    func hideCodeViewer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            codeViewerContent = nil
            isShowingDiff = false
            originalCodeForDiff = nil
            logger.info("Code viewer content cleared.")
        }
    }
    
    func navigateToNextSnippet() {
        guard var content = codeViewerContent, content.currentIndex < content.snippets.count - 1 else { return }
        content.currentIndex += 1
        codeViewerContent = content
        isShowingDiff = false
        originalCodeForDiff = nil
    }
    
    func navigateToPreviousSnippet() {
        guard var content = codeViewerContent, content.currentIndex > 0 else { return }
        content.currentIndex -= 1
        codeViewerContent = content
        isShowingDiff = false
        originalCodeForDiff = nil
    }
    
    func toggleDiffView(for snippet: CodeSnippet) {
        if isShowingDiff {
            withAnimation {
                isShowingDiff = false
                originalCodeForDiff = nil
            }
            logger.info("Diff view toggled off.")
            return
        }
        
        guard let sourceMessageID = snippet.sourceMessageID,
              let sourceFileID = snippet.sourceFileID else {
            logger.warning("Attempted to toggle diff view for a snippet that has no source file link.")
            return
        }
        
        guard let originalMessage = self.currentChatMessages.first(where: { $0.id == sourceMessageID }) else {
            logger.error("Could not find the original message with ID \(sourceMessageID.uuidString) in the currently loaded history for diffing.")
            return
        }
        
        guard let originalFile = originalMessage.attachedTextFiles?.first(where: { $0.id == sourceFileID }) else {
            logger.error("Could not find the original file with ID \(sourceFileID.uuidString) in message \(sourceMessageID.uuidString).")
            return
        }
        
        self.originalCodeForDiff = originalFile.content
        withAnimation {
            self.isShowingDiff = true
        }
        logger.info("Diff view toggled on for snippet derived from file '\(originalFile.name)'.")
    }

    // MARK: - Message Actions

    /// The exact bytes to write when applying `snippetCode`: the snippet's (extraction-
    /// normalised, i.e. whitespace-trimmed) code, re-adding the original file's trailing
    /// newline when it had one. Without this every apply strips the file's POSIX trailing
    /// newline and produces spurious "\ No newline at end of file" churn. Pure for testing.
    static func contentToApply(snippetCode: String, preservingTrailingNewlineOf baseline: String) -> String {
        (baseline.hasSuffix("\n") && !snippetCode.hasSuffix("\n")) ? snippetCode + "\n" : snippetCode
    }

    /// Fire-and-forget entry point for the Apply button. Delegates to the awaitable
    /// `performApplyChanges` (which tests can drive deterministically).
    func applyChanges(for snippet: CodeSnippet) {
        Task { await performApplyChanges(for: snippet) }
    }

    /// Writes `snippet` back to its source file. Surfaces every failure via `codeApplyError`
    /// instead of swallowing it (the old catch was log-only, so a failed write looked
    /// identical to a successful one). Guards against on-disk drift so applying a diff that
    /// was captured at attach time can't silently revert edits made to the file since.
    func performApplyChanges(for snippet: CodeSnippet) async {
        guard let sourceMessageID = snippet.sourceMessageID,
              let sourceFileID = snippet.sourceFileID else {
            logger.warning("Attempted to apply changes for a snippet with no source file link.")
            return
        }

        guard let originalMessage = self.currentChatMessages.first(where: { $0.id == sourceMessageID }),
              let sourceFile = originalMessage.attachedTextFiles?.first(where: { $0.id == sourceFileID }) else {
            logger.error("Could not find the source file to apply changes.")
            self.codeApplyError = CodeApplyError.sourceFileMissing.errorDescription
            return
        }

        let fileURL = sourceFile.url
        let baseline = sourceFile.content
        let newContent = Self.contentToApply(snippetCode: snippet.code, preservingTrailingNewlineOf: baseline)
        let fileName = sourceFile.name

        // The write/verify/replace below is blocking filesystem I/O and this class is
        // @MainActor — running it inline beach-balled the UI for the duration on any
        // sizeable file. It runs off-main inside `atomicallyWrite`; the state update
        // after the await is back on the main actor.
        do {
            try await Self.atomicallyWrite(newContent, to: fileURL, expectingBaseline: baseline, fileName: fileName)

            logger.info("✅ Successfully applied changes to file: \(fileURL.path)")
            withAnimation {
                self.isShowingDiff = false
                self.originalCodeForDiff = nil
                self.codeApplyError = nil
                if var content = self.codeViewerContent, content.snippets.indices.contains(content.currentIndex) {
                    let updatedSnippet = CodeSnippet(language: snippet.language, code: newContent, sourceMessageID: snippet.sourceMessageID, sourceFileID: snippet.sourceFileID)
                    content.snippets[content.currentIndex] = updatedSnippet
                    self.codeViewerContent = content
                }
            }
        } catch let error as CodeApplyError {
            logger.error("❌ Apply changes aborted for \(fileURL.path): \(error.localizedDescription ?? "?")")
            self.codeApplyError = error.errorDescription
        } catch {
            logger.error("❌ Failed to write changes to file: \(fileURL.path). Error: \(error.localizedDescription)")
            self.codeApplyError = CodeApplyError.writeFailed(fileName: fileName, underlying: error.localizedDescription).errorDescription
        }
    }

    /// Transaction-safe file write, off the main actor.
    ///
    /// Writes to a temp file in the same directory, reads it back to verify, then
    /// atomically replaces the original — so a crash or full disk mid-write can't
    /// corrupt the user's file (the original is only removed once the verified temp
    /// is in place). `nonisolated` + `Task.detached` keeps every blocking call off
    /// the main thread; security-scoped access is opened and balanced around the
    /// whole transaction.
    nonisolated private static func atomicallyWrite(
        _ content: String,
        to fileURL: URL,
        expectingBaseline baseline: String? = nil,
        fileName: String = ""
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let shouldAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if shouldAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            // Disk-drift guard: `baseline` is the file's content when it was attached —
            // the same content the on-screen diff was computed against. If the file on
            // disk no longer matches, it was edited since (e.g. in Xcode), and applying
            // would silently discard those edits. Refuse rather than destroy work. A read
            // failure (file deleted) falls through to the write, which recreates it —
            // the same outcome the pre-guard code produced.
            if let baseline,
               let onDisk = try? String(contentsOf: fileURL, encoding: .utf8),
               onDisk != baseline {
                throw CodeApplyError.diskDrift(fileName: fileName.isEmpty ? fileURL.lastPathComponent : fileName)
            }

            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".devgentic_tmp_\(UUID().uuidString)")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)

            // Verify the temp file was written correctly before replacing
            let verifyContent = try String(contentsOf: tempURL, encoding: .utf8)
            guard verifyContent == content else {
                try? FileManager.default.removeItem(at: tempURL)
                throw NSError(domain: "ChatHistoryViewModel", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Write verification failed — content mismatch"])
            }

            // Atomic replace: original is only removed after temp is in place
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        }.value
    }

    func copyMessageContentToClipboard(message: ChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // [Q9] Prefer the selected agent variant so Copy matches what's on screen for a
        // regenerated response; falls back to `content` (nil currentAgentContent) — no change
        // for user/non-regenerated messages.
        if let content = (message.currentAgentContent ?? message.content).textContent {
            pasteboard.setString(content, forType: .string)
            logger.info("Copied message \(message.id.uuidString) content to clipboard.")
        }
    }
    
    func openMessageInCodeViewer(message: ChatMessage, selectedSnippet: CodeSnippet? = nil) {
        var allSnippets: [CodeSnippet] = []

        switch message.content {
        case .codeBlock(let lang, let codeContent):
            allSnippets = [CodeSnippet(codeBlock: lang, content: codeContent)]

        case .markdownText(let text):
            let extractedInfos = CodeSnippetExtractor.extract(from: text)

            allSnippets = extractedInfos.map { info in
                var snippet = CodeSnippet(language: info.language, code: info.code)

                if let fileName = info.potentialFileName {
                    if let sourceMessage = self.findMessageWithSourceFile(named: fileName) {
                        if let sourceFile = sourceMessage.attachedTextFiles?.first(where: { $0.name == fileName }) {
                            snippet.sourceMessageID = sourceMessage.id
                            snippet.sourceFileID = sourceFile.id
                            logger.info("✅ Successfully linked snippet for '\(fileName)' to source file ID \(sourceFile.id.uuidString).")
                        }
                    } else {
                        logger.warning("⚠️ Could not find any user message with attached file named '\(fileName)'.")
                    }
                }
                return snippet
            }

        default:
            allSnippets = []
        }

        guard !allSnippets.isEmpty else {
            logger.info("No code snippets found in the message to open in viewer.")
            return
        }

        let largeSnippets = allSnippets.filter(\.isLarge)

        let snippetsToShow = !largeSnippets.isEmpty ? largeSnippets : allSnippets

        var initialIndex = 0
        if let selected = selectedSnippet,
           let index = snippetsToShow.firstIndex(where: { $0.denotesSameBlock(as: selected) }) {
            initialIndex = index
        }

        logger.info("Opening message in code viewer. Snippets to show: \(snippetsToShow.count), Selected index: \(initialIndex)")
        self.codeViewerContent = (snippets: snippetsToShow, currentIndex: initialIndex)
        // Reset any stale diff from a previously-viewed snippet (see showCodeInViewer):
        // switching content while `isShowingDiff` is true would diff the old baseline
        // against the new snippet and offer to Apply it.
        self.isShowingDiff = false
        self.originalCodeForDiff = nil
    }
    
    private func findMessageWithSourceFile(named fileName: String) -> ChatMessage? {
        for message in currentChatMessages {
            if message.sender == .user {
                if let files = message.attachedTextFiles, files.contains(where: { $0.name == fileName }) {
                    return message
                }
            }
        }
        logger.warning("File '\(fileName)' not found in any user messages in the currently loaded chat history.")
        return nil
    }


    // MARK: - Paginated Message Loading

    func loadConversation(id: UUID?) async {
        loadEpoch &+= 1
        let myEpoch = loadEpoch

        guard let selectedID = id else {
            currentChatMessages = []
            return
        }

        logger.debug("Loading conversation \(selectedID.uuidString), merging with active streams.")

        isInitiallyLoadingConversation = true
        await Task.yield()

        do {
            try Task.checkCancellation()

            // Fetch persisted messages (returns newest-to-oldest).
            let persistedMessages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)

            try Task.checkCancellation()

            // A newer load started while we awaited persistence — discard our
            // result so we don't overwrite the newer task's UI state.
            guard myEpoch == loadEpoch else {
                logger.info("Stale load discarded for \(selectedID.uuidString) (epoch \(myEpoch), current: \(self.loadEpoch)).")
                return
            }

            let activeStreamingMessages = activeStreamManager.activeStreams.values
                .filter { $0.conversationId == selectedID }

            var combinedMessages = activeStreamingMessages + persistedMessages
            let uniqueMessageIDs = Set(combinedMessages.map { $0.id })
            combinedMessages = uniqueMessageIDs.compactMap { id in
                combinedMessages.first { $0.id == id }
            }

            // Sort the combined list descending to ensure order.
            let sortedDescending = combinedMessages.sorted { $0.timestamp > $1.timestamp }

            // OPTIMIZATION: Keep messages in Descending Order (Newest -> Oldest).
            // We REMOVED .reversed() here. This aligns with the View's .reversed() loop.
            self.currentChatMessages = sortedDescending

            self.canLoadMorePages = persistedMessages.count >= initialPageSize

            logger.info("Successfully loaded and merged \(persistedMessages.count) persisted and \(activeStreamingMessages.count) active messages.")

            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
        } catch {
            logger.info("Conversation load for \(selectedID.uuidString) was cancelled.")
        }

        // Only the latest load gets to flip the loading flag off — prevents a
        // stale straggler from briefly clearing the spinner while a newer load
        // is still in flight.
        if myEpoch == loadEpoch {
            self.isInitiallyLoadingConversation = false
        }
    }


    func loadMoreMessages() async {
        guard !isLoadingPage, canLoadMorePages, let selectedID = currentChatMessages.first?.conversationId else {
            return
        }
        
        isLoadingPage = true
        
        let offset = currentChatMessages.count
        logger.debug("Loading page with offset \(offset) for conversation \(selectedID.uuidString).")
        
        // Fetches the next page of older messages, sorted newest-to-oldest.
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)
        
        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
            // OPTIMIZATION: Append to the end of the array (Newest...Oldest -> Append Older).
            // Since we are storing Descending, older messages go to the end (Index N).
            self.currentChatMessages.append(contentsOf: olderMessages)
            
            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
        }
        
        isLoadingPage = false
    }

    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        filterTask?.cancel()
        filterTask = Task {
            await loadConversation(id: currentChatMessages.first?.conversationId)
        }
    }
    
    private func applyUserMessagesFilter() {
        if isUserMessagesOnlyFilterActive {
            currentChatMessages = currentChatMessages.filter { $0.sender == .user }
        }
    }
    
    func resetSendingState() async {
        self.isSending = false
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }
}
