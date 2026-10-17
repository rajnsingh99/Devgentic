// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserPersonalService.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import SwiftData
import os

/// Orchestrates the User Personal profile lifecycle:
/// 1. Gathers interaction patterns from recent conversations via pluggable sources.
/// 2. Merges new observations into the existing profile using the Intelligence Core.
/// 3. Persists the profile as a human-readable markdown file.
/// 4. Provides the profile for agent prompt injection.
///
/// Architecture mirrors `MorningBriefService` with the same gate-check,
/// gather, IC-merge, parse/save flow.
@Observable @MainActor
final class UserPersonalService {

    static let shared = UserPersonalService()

    @ObservationIgnored private let logger = DGLogger(category: "UserPersonalService")

    /// Registry of all available profile sources. Add new sources here.
    @ObservationIgnored private(set) var sourceRegistry: [any UserPersonalSource] = []

    /// The current profile markdown content.
    var profileMarkdown: String = ""

    /// Whether an analysis is currently in progress.
    var isAnalyzing: Bool = false

    /// When the profile was last updated by IC analysis.
    var lastUpdated: Date?

    /// Minimum time gap between analyses (2 hours).
    private let minimumAnalysisGap: TimeInterval = 2 * 60 * 60

    /// Maximum conversations to analyze per run.
    private let maxConversationsPerRun: Int = 5

    /// Total number of analyses since app launch.
    private var totalAnalysisCount: Int = 0

    // MARK: - File Path

    private let profileFileName = "UserPersonal.md"

    private var profileDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Devgentic", isDirectory: true)
    }

    var profileFileURL: URL {
        profileDirectoryURL.appendingPathComponent(profileFileName)
    }

    // MARK: - Init

    private init() {
        sourceRegistry = [
            ConversationPatternSource(),
            ToolUsageSource(),
            WorkflowPreferenceSource()
        ]
        loadProfile()
        logger.info("[User Personal] Service initialized with \(self.sourceRegistry.count) built-in sources.")
    }

    // MARK: - Gate Check

    /// Checks all conditions and returns whether analysis should proceed.
    func shouldAnalyze() -> Bool {
        let isICEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        let isFeatureEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey)
        let hasModel = !(UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? "").isEmpty

        guard isICEnabled, isFeatureEnabled, hasModel else {
            logger.info("[User Personal] Gate check FAILED — IC: \(isICEnabled), Feature: \(isFeatureEnabled), Model: \(hasModel)")
            return false
        }

        // Check cooldown
        if let lastAnalysis = UserDefaults.standard.object(forKey: AppSettings.lastUserPersonalAnalysisDateKey) as? Date {
            let elapsed = Date().timeIntervalSince(lastAnalysis)
            if elapsed < minimumAnalysisGap {
                let elapsedMin = Int(elapsed / 60)
                let gapMin = Int(minimumAnalysisGap / 60)
                logger.info("[User Personal] Gate check COOLDOWN — Last analysis \(elapsedMin)m ago (minimum: \(gapMin)m)")
                return false
            }
        }

        // Check for unanalyzed conversations
        let analyzedIDs = loadAnalyzedConversationIDs()
        let hasNewConversations = hasUnanalyzedConversations(excludingIDs: analyzedIDs)

        guard hasNewConversations else {
            logger.info("[User Personal] Gate check — No new conversations to analyze.")
            return false
        }

        logger.notice("[User Personal] Gate check PASSED — All conditions met.")
        return true
    }

    // MARK: - Public: Analysis

    /// Main analysis flow: Gather → IC Merge → Save.
    func analyzeRecentConversations() async {
        guard !isAnalyzing else {
            logger.warning("[User Personal] Analysis already in progress — skipping.")
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        totalAnalysisCount += 1
        let analysisNum = totalAnalysisCount
        let overallStart = CFAbsoluteTimeGetCurrent()

        logger.notice("[User Personal #\(analysisNum)] ═══ ANALYSIS START ═══")

        // Phase 1: Fetch conversation data from SwiftData
        let gatherStart = CFAbsoluteTimeGetCurrent()
        let conversationData = await fetchRecentConversationData()
        let gatherDuration = CFAbsoluteTimeGetCurrent() - gatherStart

        guard !conversationData.isEmpty else {
            logger.info("[User Personal #\(analysisNum)] No new conversation data to analyze — aborting.")
            return
        }

        logger.notice("[User Personal #\(analysisNum)] Phase 1 (Fetch) — \(String(format: "%.2f", gatherDuration))s, \(conversationData.count) conversations")

        // Phase 2: Gather observations from all sources
        let sourceStart = CFAbsoluteTimeGetCurrent()
        let fragments = await gatherAllFragments(from: conversationData)
        let sourceDuration = CFAbsoluteTimeGetCurrent() - sourceStart

        guard !fragments.isEmpty else {
            logger.info("[User Personal #\(analysisNum)] Sources produced no observations — aborting.")
            return
        }

        logger.notice("[User Personal #\(analysisNum)] Phase 2 (Sources) — \(String(format: "%.2f", sourceDuration))s, \(fragments.count) fragments from \(Set(fragments.map(\.sourceID)).count) sources")

        // Phase 3: IC merge into existing profile
        logger.notice("[User Personal #\(analysisNum)] Phase 3 (IC Merge) — Starting...")
        let mergeStart = CFAbsoluteTimeGetCurrent()
        let result = await mergeFragmentsIntoProfile(fragments: fragments, existingProfile: profileMarkdown)
        let mergeDuration = CFAbsoluteTimeGetCurrent() - mergeStart

        if let result = result {
            profileMarkdown = result.updatedMarkdown
            saveProfile(result.updatedMarkdown)
            lastUpdated = result.timestamp
            markAnalysisCompleted()
            markConversationsAnalyzed(conversationData.map(\.conversationID))

            logger.notice("[User Personal #\(analysisNum)] Phase 3 (IC Merge) — \(String(format: "%.2f", mergeDuration))s, profile updated")
        } else {
            logger.warning("[User Personal #\(analysisNum)] Phase 3 (IC Merge) — FAILED, profile unchanged")
        }

        let overallDuration = CFAbsoluteTimeGetCurrent() - overallStart
        logger.notice("[User Personal #\(analysisNum)] ═══ ANALYSIS COMPLETE — \(String(format: "%.2f", overallDuration))s total ═══")
    }

    // MARK: - Public: Profile Access

    /// Returns the profile for agent prompt injection. Returns nil if empty/placeholder.
    func getProfileForInjection() -> String? {
        guard !profileMarkdown.isEmpty,
              !profileMarkdown.contains("_No observations yet._") || profileMarkdown.components(separatedBy: "_No observations yet._").count <= UserProfileSection.allCases.count else {
            return nil
        }
        // Only inject if at least one section has real content
        let hasRealContent = UserProfileSection.allCases.contains { section in
            guard let range = profileMarkdown.range(of: "## \(section.rawValue)") else { return false }
            let afterHeader = profileMarkdown[range.upperBound...]
            let nextHeader = afterHeader.range(of: "\n## ")
            let sectionContent: Substring
            if let nextHeader = nextHeader {
                sectionContent = afterHeader[..<nextHeader.lowerBound]
            } else {
                sectionContent = afterHeader
            }
            return !sectionContent.contains("_No observations yet._") && sectionContent.trimmingCharacters(in: .whitespacesAndNewlines).count > 5
        }
        return hasRealContent ? profileMarkdown : nil
    }

    /// Updates the profile from user edits.
    func updateProfile(with newMarkdown: String) {
        profileMarkdown = newMarkdown
        saveProfile(newMarkdown)
        logger.info("[User Personal] Profile updated by user edit.")
    }

    /// Resets the profile to the default template.
    func resetProfile() {
        let template = UserProfileTemplate.defaultMarkdown()
        profileMarkdown = template
        saveProfile(template)
        lastUpdated = nil

        // Clear analyzed IDs so all conversations can be re-analyzed
        UserDefaults.standard.removeObject(forKey: AppSettings.userPersonalAnalyzedConversationIDsKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.lastUserPersonalAnalysisDateKey)

        logger.notice("[User Personal] Profile RESET to default template.")
    }

    // MARK: - File I/O

    /// Loads the profile from disk, or creates the default template.
    func loadProfile() {
        let fileURL = profileFileURL

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                profileMarkdown = content

                // Recover last-updated from file modification date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    lastUpdated = modDate
                }

                logger.info("[User Personal] Profile loaded from disk — \(content.count) chars")
            } catch {
                logger.error("[User Personal] Failed to read profile: \(error.localizedDescription)")
                profileMarkdown = UserProfileTemplate.defaultMarkdown()
            }
        } else {
            profileMarkdown = UserProfileTemplate.defaultMarkdown()
            saveProfile(profileMarkdown)
            logger.info("[User Personal] Default profile template created.")
        }
    }

    /// Writes the profile to disk atomically.
    func saveProfile(_ markdown: String) {
        let directoryURL = profileDirectoryURL
        let fileURL = profileFileURL

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.debug("[User Personal] Profile saved — \(markdown.count) chars")
        } catch {
            logger.error("[User Personal] Failed to save profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Data Fetching

    /// Fetches recent unanalyzed conversations from SwiftData and extracts enriched data.
    private func fetchRecentConversationData() async -> [UserPersonalConversationData] {
        guard let container = ChatPersistenceStore.shared.modelContainer else {
            logger.error("[User Personal] ChatPersistenceStore container not configured.")
            return []
        }

        let context = container.mainContext
        let analyzedIDs = loadAnalyzedConversationIDs()

        // Fetch recent conversations
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = maxConversationsPerRun + analyzedIDs.count // Over-fetch to filter

        guard let conversations = try? context.fetch(descriptor) else {
            return []
        }

        var results: [UserPersonalConversationData] = []

        for conversationSD in conversations {
            guard !analyzedIDs.contains(conversationSD.id) else { continue }
            guard results.count < maxConversationsPerRun else { break }

            let conv = conversationSD.toStruct()
            guard conv.messages.count >= 2 else { continue } // Need at least 1 exchange

            // Fetch messages
            let convID = conversationSD.id
            var msgDescriptor = FetchDescriptor<ChatMessageSD>(
                predicate: #Predicate { $0.conversationId == convID },
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            msgDescriptor.fetchLimit = 30

            let messageModels = (try? context.fetch(msgDescriptor)) ?? []
            let messages = messageModels.map { $0.toChatMessage() }

            // Build condensed content
            var condensedParts: [String] = []
            var userLengths: [Int] = []
            var agentLengths: [Int] = []
            var userTexts: [String] = []
            var toolExecutions: [ToolExecutionSummary] = []

            for msg in messages {
                guard let text = msg.content.textContent,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let role = msg.sender == .user ? "User" : "Assistant"
                condensedParts.append("\(role): \(String(text.prefix(200)))")

                if msg.sender == .user {
                    userLengths.append(text.count)
                    userTexts.append(text)
                } else {
                    agentLengths.append(text.count)

                    // Extract tool executions from timeline events
                    for event in msg.flattenedTimelineEvents {
                        if case .toolExecution(let data) = event, !data.isExecuting {
                            let success = data.isSuccess ?? false
                            let denied = data.output?.contains("denied") == true || data.output?.contains("User explicitly") == true
                            toolExecutions.append(ToolExecutionSummary(
                                toolName: data.name,
                                isSuccess: success && !denied,
                                isDenied: denied
                            ))
                        }
                    }
                }
            }

            guard !condensedParts.isEmpty else { continue }

            results.append(UserPersonalConversationData(
                conversationID: conv.id,
                title: conv.displayTitle,
                timestamp: conv.timestamp,
                messageCount: messages.count,
                condensedContent: condensedParts.joined(separator: "\n"),
                toolExecutions: toolExecutions,
                userMessageLengths: userLengths,
                agentMessageLengths: agentLengths,
                userMessageTexts: userTexts
            ))
        }

        logger.debug("[User Personal] Fetched \(results.count) unanalyzed conversations.")
        return results
    }

    // MARK: - Private: Source Gathering

    /// Collects fragments from all enabled sources concurrently.
    private func gatherAllFragments(from data: [UserPersonalConversationData]) async -> [ProfileFragment] {
        let enabledSources = sourceRegistry.filter { $0.isEnabled }
        logger.debug("[User Personal] Gathering from \(enabledSources.count) enabled sources...")

        return await withTaskGroup(of: [ProfileFragment].self, returning: [ProfileFragment].self) { group in
            for source in enabledSources {
                group.addTask {
                    await source.gather(from: data)
                }
            }

            var all: [ProfileFragment] = []
            for await fragments in group {
                all.append(contentsOf: fragments)
            }
            return all
        }
    }

    // MARK: - Private: IC Merge

    /// Sends existing profile + new observations to IC for intelligent merging.
    private func mergeFragmentsIntoProfile(fragments: [ProfileFragment], existingProfile: String) async -> ProfileUpdateResult? {

        // Group fragments by section
        let groupedObservations = Dictionary(grouping: fragments, by: \.section)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { section, frags in
                let obs = frags.map(\.observations).joined(separator: "\n")
                return "### \(section.rawValue)\n\(obs)"
            }
            .joined(separator: "\n\n")

        let systemPrompt = """
        You are a profile analyst. Your job is to merge NEW observations into an EXISTING user profile.

        Rules:
        1. UPDATE existing bullets with new data — do not create duplicates.
        2. REMOVE bullets that are contradicted by new observations.
        3. Keep 3–7 bullets per section. Prioritize the most consistent patterns.
        4. Preserve ALL six section headers exactly as: ## Section Name
        5. Use concise bullet points (start with "- ").
        6. Replace "_No observations yet._" with actual observations.
        7. Output the COMPLETE updated markdown profile (all sections, headers included).
        8. Do NOT add any preamble, greeting, explanation, or closing remarks.
        9. Keep the profile header line "# User Personal Profile" and the blockquote instructions.
        """

        let userPrompt = """
        EXISTING PROFILE:
        \(existingProfile)

        ---

        NEW OBSERVATIONS:
        \(groupedObservations)

        ---

        Output the complete updated profile markdown:
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        do {
            logger.notice("[User Personal] Calling IntelligenceCoreService for profile merge...")
            // A background feature: it waits for the local model like a run, at the lowest priority (D7).
            let result = try await LocalInferenceCoordinator.shared.runBackgroundIntelligence(feature: "User Personal") {
                try await IntelligenceCoreService.shared.generate(
                    messages: messages,
                    maxTokens: 800,
                    temperature: 0.2,
                    caller: .userPersonal
                )
            }

            logger.notice("[User Personal] IC unloading after profile merge...")
            await IntelligenceCoreService.shared.releaseHold(caller: .userPersonal)

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("[User Personal] Raw IC response: \(trimmed.count) chars")

            // Validate: all section headers must be present
            guard UserProfileTemplate.isValid(trimmed) else {
                logger.warning("[User Personal] IC output INVALID — missing section headers. Falling back to existing profile.")
                return nil
            }

            // Determine which sections were modified
            let modifiedSections = UserProfileSection.allCases.filter { section in
                let header = "## \(section.rawValue)"
                let oldSection = extractSection(header, from: existingProfile)
                let newSection = extractSection(header, from: trimmed)
                return oldSection != newSection
            }

            return ProfileUpdateResult(
                updatedMarkdown: trimmed,
                sectionsModified: modifiedSections
            )

        } catch {
            logger.error("[User Personal] IC merge FAILED: \(error.localizedDescription)")
            await IntelligenceCoreService.shared.releaseHold(caller: .userPersonal)
            return nil
        }
    }

    /// Extracts the content of a section between its header and the next `##` header.
    private func extractSection(_ header: String, from markdown: String) -> String {
        guard let headerRange = markdown.range(of: header) else { return "" }
        let afterHeader = markdown[headerRange.upperBound...]
        if let nextHeader = afterHeader.range(of: "\n## ") {
            return String(afterHeader[..<nextHeader.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterHeader).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Tracking

    private func loadAnalyzedConversationIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.userPersonalAnalyzedConversationIDsKey),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private func markConversationsAnalyzed(_ ids: [UUID]) {
        var existing = loadAnalyzedConversationIDs()
        ids.forEach { existing.insert($0) }

        // Cap at 200 to prevent unbounded growth
        let capped = Array(existing.suffix(200))
        let strings = capped.map(\.uuidString)

        if let data = try? JSONEncoder().encode(strings) {
            UserDefaults.standard.set(data, forKey: AppSettings.userPersonalAnalyzedConversationIDsKey)
        }
    }

    private func markAnalysisCompleted() {
        UserDefaults.standard.set(Date(), forKey: AppSettings.lastUserPersonalAnalysisDateKey)
        logger.debug("[User Personal] Marked analysis completed at \(Date())")
    }

    private func hasUnanalyzedConversations(excludingIDs: Set<UUID>) -> Bool {
        guard let container = ChatPersistenceStore.shared.modelContainer else { return false }
        let context = container.mainContext

        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = excludingIDs.count + 1

        guard let conversations = try? context.fetch(descriptor) else { return false }

        return conversations.contains { !excludingIDs.contains($0.id) && $0.messages.count >= 2 }
    }
}
