//
//  ExecutionSuspensionService.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ExecutionSuspensionService")

/// Manages the "Pause/Resume" state of Agent execution.
/// Uses Swift Concurrency continuations to bridge the gap between
/// the synchronous-feeling Agent Loop and the asynchronous User Interaction.
actor ExecutionSuspensionService {
    
    static let shared = ExecutionSuspensionService()
    
    // Maps ConversationID -> The mechanism to resume the paused code (permission gates)
    private var activeContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Maps ConversationID -> The mechanism to resume with user input (clarification gates)
    private var clarificationContinuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    // Maps ConversationID -> The Task handling the timeout
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    
    // Config: How long to wait before auto-denying (Seconds)
    private let suspensionTimeout: TimeInterval = 300 // 5 Minutes
    
    private init() {}
    
    /// Pauses execution for the specific conversation until `resume` is called or timeout occurs.
    /// - Parameter conversationID: The ID of the chat session.
    /// - Returns: `true` if the user approved the action, `false` if denied or timed out.
    func suspend(for conversationID: UUID) async -> Bool {
        // Safety: If we somehow suspend twice without resuming, auto-deny the previous one to prevent leaks.
        if let existing = activeContinuations[conversationID] {
            logger.warning("[Suspension] Overwriting existing suspension for \(conversationID). Auto-denying previous.")
            existing.resume(returning: false)
            activeContinuations.removeValue(forKey: conversationID)
            timeoutTasks[conversationID]?.cancel()
        }
        
        logger.info("[Suspension] Suspending execution for conversation: \(conversationID). Waiting for user approval (Timeout: \(self.suspensionTimeout)s).")
        
        // Start the Watchdog Timer
        let timeoutTask = Task { [weak self] in
            // FIX: Ensure correct precedence for nanosecond calculation
            // (300 seconds * 1 billion)
            let seconds = self?.suspensionTimeout ?? 300
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            // Timeout fired
            await self?.handleTimeout(for: conversationID)
        }
        timeoutTasks[conversationID] = timeoutTask
        
        return await withCheckedContinuation { continuation in
            activeContinuations[conversationID] = continuation
        }
    }
    
    /// Resumes execution for a suspended conversation.
    /// - Parameters:
    ///   - conversationID: The ID of the chat session.
    ///   - approved: Whether the user clicked "Allow" (true) or "Deny" (false).
    func resume(for conversationID: UUID, approved: Bool) {
        // Cancel the watchdog since user responded
        timeoutTasks[conversationID]?.cancel()
        timeoutTasks.removeValue(forKey: conversationID)
        
        guard let continuation = activeContinuations.removeValue(forKey: conversationID) else {
            logger.warning("[Suspension] Attempted to resume non-existent suspension for conversation: \(conversationID)")
            return
        }
        
        logger.info("[Suspension] Resuming execution for conversation: \(conversationID) with approval: \(approved)")
        continuation.resume(returning: approved)
    }
    
    // MARK: - Clarification Suspension (ask_user)

    /// Pauses execution until the user provides a text answer or the timeout fires.
    /// - Parameter conversationID: The ID of the chat session.
    /// - Returns: The user's text response, or `nil` if timed out / cancelled.
    func suspendForClarification(for conversationID: UUID) async -> String? {
        // Safety: prevent double-suspension leaks
        if let existing = clarificationContinuations[conversationID] {
            logger.warning("[Clarification] Overwriting existing clarification for \(conversationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            clarificationContinuations.removeValue(forKey: conversationID)
        }

        logger.info("[Clarification] Suspending for user input on conversation: \(conversationID).")

        let timeoutKey = UUID() // unique key to avoid collision with permission timeouts
        let timeoutTask = Task { [weak self] in
            let seconds = self?.suspensionTimeout ?? 300
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleClarificationTimeout(for: conversationID)
        }
        timeoutTasks[conversationID] = timeoutTask
        _ = timeoutKey // suppress unused warning

        return await withCheckedContinuation { continuation in
            clarificationContinuations[conversationID] = continuation
        }
    }

    /// Resumes a clarification suspension with the user's text input.
    func resumeClarification(for conversationID: UUID, userInput: String?) {
        timeoutTasks[conversationID]?.cancel()
        timeoutTasks.removeValue(forKey: conversationID)

        guard let continuation = clarificationContinuations.removeValue(forKey: conversationID) else {
            logger.warning("[Clarification] Attempted to resume non-existent clarification for conversation: \(conversationID)")
            return
        }

        logger.info("[Clarification] Resuming with user input for conversation: \(conversationID)")
        continuation.resume(returning: userInput)
    }

    private func handleClarificationTimeout(for conversationID: UUID) {
        logger.notice("[Clarification] ⏰ TIMEOUT for conversation: \(conversationID). Returning nil.")
        timeoutTasks.removeValue(forKey: conversationID)
        guard let continuation = clarificationContinuations.removeValue(forKey: conversationID) else { return }
        continuation.resume(returning: nil)
    }

    // MARK: - Cancellation & Status

    /// Force-cancels a suspension (e.g., if the user stops the stream or closes the app).
    /// Resumes with `false` (Denied) for permissions, `nil` for clarifications.
    func cancel(for conversationID: UUID) {
        timeoutTasks[conversationID]?.cancel()
        timeoutTasks.removeValue(forKey: conversationID)

        if let continuation = activeContinuations.removeValue(forKey: conversationID) {
            logger.info("[Suspension] Force-cancelling permission suspension for conversation: \(conversationID)")
            continuation.resume(returning: false)
        }

        if let continuation = clarificationContinuations.removeValue(forKey: conversationID) {
            logger.info("[Suspension] Force-cancelling clarification suspension for conversation: \(conversationID)")
            continuation.resume(returning: nil)
        }
    }

    /// Internal handler for auto-denial
    private func handleTimeout(for conversationID: UUID) {
        logger.notice("[Suspension] ⏰ TIMEOUT reached for conversation: \(conversationID). Auto-denying permission.")

        // Remove the task reference (it's already executing)
        timeoutTasks.removeValue(forKey: conversationID)

        guard let continuation = activeContinuations.removeValue(forKey: conversationID) else { return }
        continuation.resume(returning: false)
    }

    /// Checks if a conversation is currently waiting for any suspension type.
    func isSuspended(for conversationID: UUID) -> Bool {
        return activeContinuations[conversationID] != nil || clarificationContinuations[conversationID] != nil
    }
}
