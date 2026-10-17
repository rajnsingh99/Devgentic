// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SendPathHistoryBenchmarkTests.swift
//  devgenticTests
//
//  RAG-6 / RAG-7 measurement harness — NOT a regression test. Skipped unless RAG_BENCH=1:
//    TEST_RUNNER_RAG_BENCH=1 xcodebuild test-without-building ... \
//      -only-testing:devgenticTests/SendPathHistoryBenchmarkTests
//
//  Seeds an ON-DISK SwiftData store with a 300-message conversation, reopens it COLD (a new
//  container, as after an app launch), and times `fetchMessages(limit: 300)` — the call the request
//  path (`BackendHistoryResolver.resolve`) and the context gauge both make, on the main actor —
//  then splits the cost by blob.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SendPathHistoryBenchmarkTests: XCTestCase {

    private var storeURL: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RAG_BENCH"] == "1",
            "RAG-6/7 benchmark — opt-in via TEST_RUNNER_RAG_BENCH=1."
        )
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sendpath-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("bench.store")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    // MARK: - Fixtures

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func filler(_ n: Int, _ rng: inout SplitMix64) -> String {
        let words = ["func", "let", "return", "error", "build", "swift", "module", "warning", "path", "value",
                     "the", "and", "result", "test", "passed", "failed", "Sources", "import", "struct", "case"]
        var out = ""
        out.reserveCapacity(n + 16)
        var length = 0
        while length < n {
            let w = words.randomElement(using: &rng)!
            out += w
            out += Int.random(in: 0..<8, using: &rng) == 0 ? "\n" : " "
            length += w.count + 1
        }
        return out
    }

    struct Shape {
        let name: String
        let toolsPerAgentTurn: Int
        let imageEveryNthUser: Int   // 0 = no images
        let imageBytes: Int
    }

    /// 150 user + 150 agent turns, oldest first.
    private func seed(_ shape: Shape, conversationID: UUID) async throws -> (blobBytes: [String: Int], imageCount: Int) {
        let c = try container()
        let store = ChatPersistenceStore.shared
        store.configureContainer(c)
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: Date(),
                                                 userDefinedTitle: shape.name, isPinned: false, backendEntityId: nil))
        var rng = SplitMix64(state: 42)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var images = 0
        var batch: [ChatMessage] = []
        for turn in 0..<150 {
            var imageFiles: [AttachedImageFile]? = nil
            if shape.imageEveryNthUser > 0, turn % shape.imageEveryNthUser == 0 {
                var bytes = Data(count: shape.imageBytes)
                bytes.withUnsafeMutableBytes { raw in
                    for i in stride(from: 0, to: raw.count, by: 8) { raw[i] = UInt8(truncatingIfNeeded: rng.next()) }
                }
                imageFiles = [AttachedImageFile(name: "shot\(turn).png", url: URL(fileURLWithPath: "/tmp/shot\(turn).png"),
                                                fileExtension: "png", binaryData: bytes, size: Int64(bytes.count))]
                images += 1
            }
            let user = ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(Double(turn * 2)),
                                   sender: .user, content: .markdownText(filler(240, &rng)), attachedImageFiles: imageFiles)
            let agent = ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(Double(turn * 2 + 1)),
                                    sender: .agent, content: .markdownText(filler(1_500, &rng)))
            var events: [TimelineEvent] = []
            for step in 0..<shape.toolsPerAgentTurn {
                events.append(.reasoning(id: UUID(), text: filler(400, &rng)))
                // Tool output: mostly a few KB, 1 in 20 at the 32 KB persisted cap (a build log, a file dump).
                let outputSize = Int.random(in: 0..<20, using: &rng) == 0 ? ToolExecutionData.maxPersistedOutputLength
                                                                          : Int.random(in: 300...5_000, using: &rng)
                events.append(.toolExecution(ToolExecutionData(
                    id: UUID(), name: "fs_read_file", params: "{\"path\":\"Sources/App/\(filler(30, &rng))\"}",
                    output: filler(outputSize, &rng), isSuccess: true, durationMs: 40, isExecuting: false, stepId: step)))
            }
            agent.timelineEvents = events
            agent.tokenUsage = TokenUsage(inputTokens: 12_000, outputTokens: 900)
            batch.append(contentsOf: [user, agent])
        }
        await store.addMessages(batch, toConversation: conversationID)
        try c.mainContext.save()

        let rows = try c.mainContext.fetch(FetchDescriptor<ChatMessageSD>())
        var bytes: [String: Int] = ["content": 0, "agentResponse": 0, "timeline": 0, "tokenUsage": 0]
        for r in rows {
            bytes["content"]! += r.contentData.count
            bytes["agentResponse"]! += r.agentResponseData?.count ?? 0
            bytes["timeline"]! += r.timelineEventsData?.count ?? 0
            bytes["tokenUsage"]! += r.tokenUsageData?.count ?? 0
        }
        return (bytes, images)
    }

    private func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func run(_ shape: Shape) async throws {
        let conversationID = UUID()
        let seeded = try await seed(shape, conversationID: conversationID)
        let mb = { (n: Int) in String(format: "%.1f MB", Double(n) / 1_048_576) }
        print("[BENCH] ===== \(shape.name): 300 messages, \(shape.toolsPerAgentTurn) tools/agent turn, \(seeded.imageCount) image(s) × \(mb(shape.imageBytes))")
        print("[BENCH] stored blobs — content \(mb(seeded.blobBytes["content"]!)), agentResponse \(mb(seeded.blobBytes["agentResponse"]!)), timeline \(mb(seeded.blobBytes["timeline"]!)), tokenUsage \(mb(seeded.blobBytes["tokenUsage"]!))")

        // COLD: a fresh container is a fresh row cache, as after launch / on first open.
        for pass in ["cold", "warm", "warm"] {
            if pass == "cold" { ChatPersistenceStore.shared.configureContainer(try container()) }
            let t0 = ContinuousClock.now
            let messages = await ChatPersistenceStore.shared.fetchMessages(for: conversationID, offset: 0, limit: 300)
            print("[BENCH] \(pass) fetchMessages(limit: 300) → \(messages.count) msgs in \(String(format: "%.1f", ms(t0))) ms (MAIN ACTOR)")
        }

        // Phase split on a fresh container.
        let c = try container()
        let ctx = c.mainContext
        var descriptor = FetchDescriptor<ChatMessageSD>(predicate: #Predicate { $0.conversationId == conversationID },
                                                       sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 300
        var t = ContinuousClock.now
        let rows = try ctx.fetch(descriptor)
        print("[BENCH]   fetch rows: \(String(format: "%.1f", ms(t))) ms")
        t = ContinuousClock.now
        var touched = 0
        for r in rows { touched &+= r.contentData.count &+ (r.agentResponseData?.count ?? 0) &+ (r.timelineEventsData?.count ?? 0) &+ (r.tokenUsageData?.count ?? 0) }
        print("[BENCH]   fault blob columns: \(String(format: "%.1f", ms(t))) ms (\(touched) bytes)")
        t = ContinuousClock.now
        for r in rows { _ = try? JSONDecoder().decode(MessageContent.self, from: r.contentData) }
        print("[BENCH]   decode content: \(String(format: "%.1f", ms(t))) ms")
        t = ContinuousClock.now
        for r in rows { if let d = r.agentResponseData { _ = try? JSONDecoder().decode(AgentResponse.self, from: d) } }
        print("[BENCH]   decode agentResponse: \(String(format: "%.1f", ms(t))) ms")
        t = ContinuousClock.now
        for r in rows { if let d = r.timelineEventsData { _ = try? ChatMessageSD.decodeTimeline(from: d) } }
        print("[BENCH]   decode timeline: \(String(format: "%.1f", ms(t))) ms")
        t = ContinuousClock.now
        var imageBytes = 0
        for r in rows { for f in r.attachedImageFiles { imageBytes += f.binaryData.count } }
        print("[BENCH]   load image bytes: \(String(format: "%.1f", ms(t))) ms (\(mb(imageBytes)))")
        t = ContinuousClock.now
        let projected = rows.map { $0.toChatMessage(omittingImageBytes: true) }
        print("[BENCH]   toChatMessage(omittingImageBytes) on warm rows: \(String(format: "%.1f", ms(t))) ms (\(projected.count))")
    }

    /// RAG-26: the background-task pill's history scan on conversation open — every row's timeline
    /// blob, byte-searched, on the main actor, unbounded.
    func testBackgroundTaskScanOnOpen() async throws {
        for (tools, label) in [(15, "code-agent"), (40, "code-agent-heavy")] {
            let conversationID = UUID()
            _ = try await seed(Shape(name: label, toolsPerAgentTurn: tools, imageEveryNthUser: 0, imageBytes: 0),
                               conversationID: conversationID)
            ChatPersistenceStore.shared.configureContainer(try container())
            for pass in ["cold", "warm"] {
                let t0 = ContinuousClock.now
                let rows = await ChatPersistenceStore.shared.fetchBackgroundTaskRows(for: conversationID)
                print("[BENCH] \(label) \(pass) fetchBackgroundTaskRows over 300 msgs → \(rows.count) rows in \(String(format: "%.1f", ms(t0))) ms (MAIN ACTOR)")
            }
        }
    }

    /// RAG-29: one agent run's flushes. Each tool completion bumps `timelineRevision`, so the next
    /// upsert re-encodes the WHOLE timeline and saves it — quadratic over the run.
    func testFlushCostOverOneRun() async throws {
        let conversationID = UUID()
        let c = try container()
        let store = ChatPersistenceStore.shared
        store.configureContainer(c)
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: Date(),
                                                 userDefinedTitle: "flush", isPinned: false, backendEntityId: nil))
        var rng = SplitMix64(state: 9)
        let agent = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(""))
        var encodeMs = 0.0, upsertMs = 0.0, worstUpsert = 0.0
        let tools = 50
        for step in 0..<tools {
            agent.timelineEvents.append(.reasoning(id: UUID(), text: filler(400, &rng)))
            let size = Int.random(in: 0..<20, using: &rng) == 0 ? ToolExecutionData.maxPersistedOutputLength
                                                              : Int.random(in: 300...5_000, using: &rng)
            agent.timelineEvents.append(.toolExecution(ToolExecutionData(
                id: UUID(), name: "fs_read_file", params: "{\"path\":\"x\"}", output: filler(size, &rng),
                isSuccess: true, durationMs: 40, isExecuting: false, stepId: step)))
            agent.content = .markdownText(filler(40 * (step + 1), &rng))
            var t = ContinuousClock.now
            _ = try JSONEncoder().encode(agent.timelineEvents)
            encodeMs += ms(t)
            t = ContinuousClock.now
            await store.addMessages([agent], toConversation: conversationID)
            let u = ms(t)
            upsertMs += u
            worstUpsert = max(worstUpsert, u)
        }
        let finalBytes = try JSONEncoder().encode(agent.timelineEvents).count
        print("[BENCH] \(tools)-tool run: final timeline \(finalBytes / 1024) KB; timeline encodes total \(String(format: "%.1f", encodeMs)) ms; upserts (encode+save) total \(String(format: "%.1f", upsertMs)) ms, worst single \(String(format: "%.1f", worstUpsert)) ms (MAIN ACTOR)")
    }

    func testCodeConversation() async throws {
        try await run(Shape(name: "code-agent", toolsPerAgentTurn: 15, imageEveryNthUser: 0, imageBytes: 0))
    }

    func testHeavyCodeConversation() async throws {
        try await run(Shape(name: "code-agent-heavy", toolsPerAgentTurn: 40, imageEveryNthUser: 0, imageBytes: 0))
    }

    func testChatWithScreenshots() async throws {
        try await run(Shape(name: "chat-screenshots", toolsPerAgentTurn: 0, imageEveryNthUser: 5, imageBytes: 1_500_000))
    }
}
