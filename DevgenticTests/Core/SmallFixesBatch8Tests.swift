// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SmallFixesBatch8Tests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SmallFixesBatch8Tests: XCTestCase {

    // MARK: - CR-31

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func next(_ expr: String, after: Date) throws -> Date? {
        try CronExpression(expression: expr).nextFireDate(after: after, calendar: calendar)
    }

    /// "Quarterly" must be Jan / Apr / Jul / Oct, as in every standard cron.
    func testCR31_QuarterlyFiresInJanuaryAprilJulyOctober() throws {
        XCTAssertEqual(try next("0 0 1 */3 *", after: date(2026, 12, 15)), date(2027, 1, 1), "after mid-December: 1 January")
        XCTAssertEqual(try next("0 0 1 */3 *", after: date(2027, 1, 2)), date(2027, 4, 1), "after 2 January: 1 April, not 1 March")
        XCTAssertEqual(try next("0 0 1 */3 *", after: date(2027, 4, 2)), date(2027, 7, 1))
    }

    /// Every other day starts on the 1st: 1, 3, 5 … 31.
    func testCR31_EveryOtherDayStartsOnTheFirst() throws {
        XCTAssertEqual(try next("0 9 */2 * *", after: date(2026, 9, 30, 12)), date(2026, 10, 1, 9))
        XCTAssertEqual(try next("0 9 */2 * *", after: date(2026, 10, 1, 12)), date(2026, 10, 3, 9))
        XCTAssertEqual(try next("0 9 */2 * *", after: date(2026, 10, 30, 12)), date(2026, 10, 31, 9))
    }

    /// The fields that start at 0 are unchanged.
    func testCR31_ZeroBasedFieldsAreUnchanged() throws {
        XCTAssertEqual(try next("*/15 * * * *", after: date(2026, 10, 1, 9, 1)), date(2026, 10, 1, 9, 15))
        XCTAssertEqual(try next("0 */6 * * *", after: date(2026, 10, 1, 1)), date(2026, 10, 1, 6))
        // 1 Oct 2026 is a Thursday (4): `*/2` weekday = Sun, Tue, Thu, Sat.
        XCTAssertEqual(try next("0 9 * * */2", after: date(2026, 10, 1, 12)), date(2026, 10, 3, 9), "Saturday")
    }

    // MARK: - CR-57

    private func appRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Devgentic")
        // ⚠️ Fails, never skips: a guard that cannot see the sources must not read as a pass.
        guard FileManager.default.fileExists(atPath: root.path) else {
            XCTFail("app sources not reachable at \(root.path)")
            throw CancellationError()
        }
        return root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: try appRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The INVARIANT, for the layer that only ever holds model output: no log line at a persisted
    /// level (info and above — DGLogger writes those to the unified log store) quotes a snippet of
    /// it. Snippets belong at debug, which is never persisted.
    func testCR57_ParsersQuoteNoModelOutputAtPersistedLevels() throws {
        let dir = try appRoot().appendingPathComponent("Core/Backends/TextGen/ReAct/Parsing")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "precondition: the parsers were found")
        let persisted = try NSRegularExpression(pattern: #"logger\.(info|notice|warning|error|log)\("#)
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard persisted.firstMatch(in: line, range: range) != nil, line.contains(".prefix(") else { continue }
                // An id prefix is an identifier, not content.
                guard !line.contains("uuidString.prefix(") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "model output quoted at a persisted log level")
    }

    /// The three sites the row named.
    func testCR57_TheNamedSitesLogSizesNotBodies() throws {
        let chat = try source("Core/Backends/TextGen/ChatExecutor.swift")
        XCTAssertFalse(chat.contains(#"logger.info("Final Response: \(fullResponse)")"#), "the whole bot reply at info")
        let factory = try source("Core/Backends/TextGen/AgentToolFactory.swift")
        XCTAssertFalse(factory.contains("Raw Payload: \\(rawJSON)"), "the raw argument JSON (file contents) at error")
        XCTAssertTrue(factory.contains("Received: \\(rawJSON)"), "the MODEL must still be shown what it sent")
        let connect = try source("Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertFalse(connect.contains("instructions?.prefix("), "system instructions at notice")
    }

    // MARK: - CR-60

    private var tempDir: URL!
    private var lockedDirs: [URL] = []

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("b8-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for dir in lockedDirs { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A skill whose `reference/` folder cannot be listed.
    private func skillWithLockedFolder(_ name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("reference"), withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Does a thing.\n---\n\n# \(name)\nRead reference/guide.md.\n"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "the guide".write(to: dir.appendingPathComponent("reference/guide.md"), atomically: true, encoding: .utf8)
        let locked = dir.appendingPathComponent("reference")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        lockedDirs.append(locked)
        // Precondition: this process really cannot list it (not root, not a permissive volume).
        if (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) != nil {
            throw XCTSkip("this environment can list a 000 folder, so an unreadable folder cannot be simulated")
        }
        return dir
    }

    func testCR60_AnUnreadableSubfolderRefusesTheSkill() throws {
        let dir = try skillWithLockedFolder("locked-skill")
        XCTAssertThrowsError(try SkillIngest.readSkillDirectory(at: dir)) { error in
            guard case .unreadable(let detail) = error as? SkillIngestError else { return XCTFail("expected .unreadable, got \(error)") }
            XCTAssertTrue(detail.contains("reference"), "the folder must be named: \(detail)")
        }
    }

    /// The wiring: a multi-skill import REPORTS the skill instead of storing it without its files,
    /// and the other skills still import.
    func testCR60_AnImportReportsTheSkillAndKeepsTheOthers() throws {
        _ = try skillWithLockedFolder("locked-skill")
        let good = tempDir.appendingPathComponent("good-skill")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try "---\nname: good-skill\ndescription: Fine.\n---\n\n# good\n".write(to: good.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = SkillIngest.readTree(at: tempDir)

        XCTAssertEqual(outcome.skills.map(\.name), ["good-skill"], "the locked skill must not be stored without its folder")
        XCTAssertEqual(outcome.rejected.count, 1, "and it must be reported: \(outcome.rejected)")
    }
}
