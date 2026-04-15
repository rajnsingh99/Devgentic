//
//  MorningBriefService.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

/// Orchestrates Morning Brief generation by collecting conversation context
/// from pluggable sources and running the Intelligence Core to produce
/// per-conversation AI summaries with actionable suggestions.
///
/// Architecture:
/// 1. Checks gate conditions (feature enabled, model selected, cooldown).
/// 2. Gathers raw conversation content from sources.
/// 3. Feeds all context to `IntelligenceCoreService` in a single call.
/// 4. Parses structured per-conversation insights from the AI response.
/// 5. Returns a `MorningBrief` ready for display.
@Observable @MainActor
final class MorningBriefService {

    static let shared = MorningBriefService()

    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "MorningBriefService")

    /// Registry of all available brief sources. Add new sources here.
    @ObservationIgnored private(set) var sourceRegistry: [any MorningBriefSource] = []

    /// The most recently generated brief, cached for re-display.
    var currentBrief: MorningBrief?

    /// Whether the brief is currently being generated.
    var isGenerating: Bool = false

    /// Minimum time gap between briefs (4 hours).
    private let minimumBriefGap: TimeInterval = 4 * 60 * 60

    /// Total number of briefs generated since app launch.
    private var totalBriefCount: Int = 0

    private init() {
        sourceRegistry = [
            RecentConversationSource(),
            SystemHealthSource(),
            UserPersonalBriefSource()
        ]
        logger.info("[Morning Brief] Service initialized with \(self.sourceRegistry.count) built-in sources.")
    }

    // MARK: - Public API

    /// Checks all gate conditions and returns whether a brief should be shown.
    func shouldShowBrief() -> Bool {
        let isICEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        let isBriefEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureMorningBriefKey)
        let hasModel = !(UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? "").isEmpty

        guard isICEnabled, isBriefEnabled, hasModel else {
            logger.info("[Morning Brief] Gate check FAILED — IC enabled: \(isICEnabled), Brief enabled: \(isBriefEnabled), Model selected: \(hasModel)")
            return false
        }

        // Check minimum time gap
        if let lastShown = UserDefaults.standard.object(forKey: AppSettings.lastMorningBriefDateKey) as? Date {
            let elapsed = Date().timeIntervalSince(lastShown)
            if elapsed < minimumBriefGap {
                let elapsedMin = Int(elapsed / 60)
                let gapMin = Int(minimumBriefGap / 60)
                logger.info("[Morning Brief] Gate check COOLDOWN — Last shown \(elapsedMin)m ago (minimum: \(gapMin)m)")
                return false
            }
        }

        logger.notice("[Morning Brief] Gate check PASSED — All conditions met.")
        return true
    }

    /// Generates a new Morning Brief by gathering context and running IC.
    func generateBrief() async -> MorningBrief? {
        guard !isGenerating else {
            logger.warning("[Morning Brief] Generation already in progress — returning cached brief.")
            return currentBrief
        }

        isGenerating = true
        defer { isGenerating = false }

        totalBriefCount += 1
        let briefNum = totalBriefCount
        let overallStart = CFAbsoluteTimeGetCurrent()

        logger.notice("[Morning Brief #\(briefNum)] ═══ GENERATION START ═══")

        // Phase 1: Gather raw context from all sources
        let gatherStart = CFAbsoluteTimeGetCurrent()
        let allFragments = await gatherAllFragments()
        let gatherDuration = CFAbsoluteTimeGetCurrent() - gatherStart

        let conversationFragments = allFragments.filter { $0.sourceID == "recent_conversations" }
        let systemFragments = allFragments.filter { $0.sourceID == "system_health" }

        logger.notice("[Morning Brief #\(briefNum)] Phase 1 (Gather) — \(String(format: "%.2f", gatherDuration))s, \(conversationFragments.count) conversations, \(systemFragments.count) system fragments")

        guard !conversationFragments.isEmpty else {
            logger.info("[Morning Brief #\(briefNum)] No conversation context to summarize — aborting.")
            return nil
        }

        // Phase 2: Run IC to generate per-conversation insights
        logger.notice("[Morning Brief #\(briefNum)] Phase 2 (AI Insights) — IC inference starting...")
        let aiStart = CFAbsoluteTimeGetCurrent()
        let insights = await generateInsights(from: conversationFragments)
        let aiDuration = CFAbsoluteTimeGetCurrent() - aiStart
        logger.notice("[Morning Brief #\(briefNum)] Phase 2 (AI Insights) — \(String(format: "%.2f", aiDuration))s, \(insights.count) insights generated")

        guard !insights.isEmpty else {
            logger.warning("[Morning Brief #\(briefNum)] IC returned no usable insights — aborting.")
            return nil
        }

        // Phase 3: Build the brief
        let systemStatus = systemFragments.first.map { "\($0.title) — \($0.detail)" }

        let brief = MorningBrief(
            insights: insights,
            systemStatus: systemStatus
        )
        self.currentBrief = brief
        markBriefShown()

        let overallDuration = CFAbsoluteTimeGetCurrent() - overallStart
        logger.notice("[Morning Brief #\(briefNum)] ═══ GENERATION COMPLETE — \(String(format: "%.2f", overallDuration))s total, \(insights.count) insights ═══")

        return brief
    }

    /// Clears the cached brief (e.g. when user dismisses the card).
    func dismissBrief() {
        logger.info("[Morning Brief] Brief dismissed by user.")
        currentBrief = nil
    }

    // MARK: - Source Registration

    /// Register a custom source at runtime.
    func registerSource(_ source: any MorningBriefSource) {
        sourceRegistry.append(source)
        logger.notice("[Morning Brief] Source registered: \(source.displayName) (id: \(source.id)). Total sources: \(self.sourceRegistry.count)")
    }

    // MARK: - Private: Gather

    /// Collects fragments from all enabled sources concurrently.
    private func gatherAllFragments() async -> [BriefFragment] {
        let enabledSources = sourceRegistry.filter { $0.isEnabled }
        logger.debug("[Morning Brief] Gathering from \(enabledSources.count) enabled sources...")

        return await withTaskGroup(of: [BriefFragment].self, returning: [BriefFragment].self) { group in
            for source in enabledSources {
                group.addTask {
                    await source.gather()
                }
            }

            var all: [BriefFragment] = []
            for await fragments in group {
                all.append(contentsOf: fragments)
            }
            return all
        }
    }

    // MARK: - Private: AI Insight Generation

    /// Sends all conversation context to IC in a single prompt and parses
    /// per-conversation summaries + suggestions from the response.
    private func generateInsights(from fragments: [BriefFragment]) async -> [ConversationInsight] {
        // Build the context block for the prompt
        var conversationBlocks: [(fragment: BriefFragment, index: Int)] = []
        for (i, fragment) in fragments.enumerated() {
            conversationBlocks.append((fragment, i + 1))
        }

        let contextBlock = conversationBlocks.map { item in
            """
            --- Conversation \(item.index): "\(item.fragment.title)" (\(item.fragment.detail)) ---
            \(item.fragment.rawContext)
            """
        }.joined(separator: "\n\n")

        let conversationCount = fragments.count

        logger.info("[Morning Brief] AI prompt — \(conversationCount) conversations, \(contextBlock.count) chars of context")

        let systemPrompt = """
        You are a concise assistant generating a morning session brief for a developer.
        You will receive content from the user's recent conversations.

        For EACH conversation, output exactly this format (one block per conversation):

        [CONVERSATION <number>]
        SUMMARY: <1-2 sentence summary of what was discussed or accomplished>
        SUGGESTION: <1 short actionable suggestion, or "none" if nothing obvious>

        Rules:
        - Be specific about what was worked on (mention file names, features, bugs if visible).
        - Suggestions should be concrete next steps, not generic advice.
        - If a conversation has minimal content, keep the summary brief.
        - Do NOT add any preamble, greeting, or closing remarks.
        - Output ONLY the formatted blocks.
        """

        let userPrompt = """
        Here are my \(conversationCount) most recent conversations:

        \(contextBlock)

        Generate summaries and suggestions for each.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        do {
            logger.notice("[Morning Brief] Calling IntelligenceCoreService for insights...")
            let result = try await IntelligenceCoreService.shared.generate(
                messages: messages,
                maxTokens: 500,
                temperature: 0.3,
                caller: .morningBrief
            )

            logger.notice("[Morning Brief] IC unloading after insight generation...")
            await IntelligenceCoreService.shared.unload(caller: .morningBrief)

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("[Morning Brief] Raw AI response: \(trimmed.count) chars")

            // Parse the structured response
            let insights = parseInsights(from: trimmed, fragments: fragments)
            return insights

        } catch {
            logger.error("[Morning Brief] AI insight generation FAILED: \(error.localizedDescription)")
            await IntelligenceCoreService.shared.unload(caller: .morningBrief)
            return []
        }
    }

    // MARK: - Private: Response Parsing

    /// Parses the IC response into `ConversationInsight` objects.
    /// Uses a lenient parser that handles formatting variations.
    private func parseInsights(from response: String, fragments: [BriefFragment]) -> [ConversationInsight] {
        var insights: [ConversationInsight] = []

        // Split by [CONVERSATION N] markers
        let blocks = response.components(separatedBy: "[CONVERSATION")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for block in blocks {
            // Extract the conversation number
            guard let numberEnd = block.firstIndex(of: "]") else { continue }
            let numberStr = block[block.startIndex..<numberEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Int(numberStr), number >= 1, number <= fragments.count else { continue }

            let fragment = fragments[number - 1]
            let content = String(block[block.index(after: numberEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract SUMMARY line
            let summary = extractField("SUMMARY", from: content) ?? "Session activity recorded."

            // Extract SUGGESTION line
            var suggestion = extractField("SUGGESTION", from: content)
            if let s = suggestion, s.lowercased() == "none" || s.isEmpty {
                suggestion = nil
            }

            let insight = ConversationInsight(
                conversationID: fragment.destination.flatMap {
                    if case .conversation(let id) = $0 { return id }
                    return nil
                } ?? UUID(),
                title: fragment.title,
                timeAgo: fragment.detail.components(separatedBy: " — ").last ?? "",
                summary: summary,
                suggestion: suggestion
            )
            insights.append(insight)

            logger.debug("[Morning Brief] Parsed insight for \"\(fragment.title)\": \(summary.prefix(60))...")
        }

        // If parsing failed entirely, create a fallback single insight from the raw response
        if insights.isEmpty && !response.isEmpty && !fragments.isEmpty {
            logger.warning("[Morning Brief] Structured parsing failed — creating fallback insight from raw response.")
            let fragment = fragments[0]
            insights.append(ConversationInsight(
                conversationID: fragment.destination.flatMap {
                    if case .conversation(let id) = $0 { return id }
                    return nil
                } ?? UUID(),
                title: fragment.title,
                timeAgo: fragment.detail.components(separatedBy: " — ").last ?? "",
                summary: String(response.prefix(200)),
                suggestion: nil
            ))
        }

        return insights
    }

    /// Extracts a named field value from a text block.
    /// Handles "SUMMARY: some text" and "SUMMARY: some text\nSUGGESTION: ..."
    private func extractField(_ name: String, from text: String) -> String? {
        let pattern = "\(name):\\s*(.+?)(?:\\n[A-Z]+:|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Timestamp

    private func markBriefShown() {
        UserDefaults.standard.set(Date(), forKey: AppSettings.lastMorningBriefDateKey)
        logger.debug("[Morning Brief] Marked as shown at \(Date())")
    }
}
