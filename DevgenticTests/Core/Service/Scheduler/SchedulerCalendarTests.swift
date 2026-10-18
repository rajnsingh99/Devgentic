// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchedulerCalendarTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

final class SchedulerCalendarTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func cron(_ expr: String) throws -> CronExpression { try CronExpression(expression: expr) }

    // MARK: - Cron search

    func testFebruary29FindsALeapDayMoreThanAYearAway() throws {
        // From March 2026 the next Feb 29 is 2028 — the old one-year search returned nil.
        let next = try cron("0 9 29 2 *").nextFireDate(after: date(2026, 3, 1), calendar: calendar)
        XCTAssertEqual(next, date(2028, 2, 29, 9, 0))
        // Across the skipped century leap year: after Feb 29 2096 the next is 2104.
        let far = try cron("0 9 29 2 *").nextFireDate(after: date(2096, 3, 1), calendar: calendar)
        XCTAssertEqual(far, date(2104, 2, 29, 9, 0))
    }

    func testAnImpossibleDateIsRefusedAtParse() {
        for expr in ["0 9 31 2 *", "0 9 30 2 *", "0 9 31 4,6,9,11 *"] {
            XCTAssertThrowsError(try CronExpression(expression: expr), expr) { error in
                guard case CronParseError.neverFires = error else { return XCTFail("\(expr): \(error)") }
            }
        }
        // Still valid: some listed month has that day, or a weekday is ORed in.
        XCTAssertNoThrow(try CronExpression(expression: "0 9 31 2,3 *"))
        XCTAssertNoThrow(try CronExpression(expression: "0 9 31 2 1"))
    }

    func testBothDayFieldsSetMeansEitherDay() throws {
        // `0 9 1 * 1`: the 1st OR any Monday. Oct 1 2026 is a Thursday; Oct 5 a Monday.
        let expr = try cron("0 9 1 * 1")
        XCTAssertEqual(expr.nextFireDate(after: date(2026, 9, 30, 12), calendar: calendar), date(2026, 10, 1, 9, 0),
                       "the 1st must fire even though it is not a Monday")
        XCTAssertEqual(expr.nextFireDate(after: date(2026, 10, 1, 12), calendar: calendar), date(2026, 10, 5, 9, 0),
                       "a Monday must fire even though it is not the 1st")
    }

    func testAStarDayFieldKeepsTheOtherAlone() throws {
        // `*/2` counts as unrestricted (Vixie), so the fields are ANDed: a 1st/3rd/5th… day that is a
        // Monday. ⚠️ This used to assert an EVEN day, which pinned CR-31 itself: Vixie counts a
        // day-of-month step from the 1st, so `*/2` is days 1, 3, 5, … 31.
        let expr = try cron("0 9 */2 * 1")
        let next = try XCTUnwrap(expr.nextFireDate(after: date(2026, 10, 1), calendar: calendar))
        let comps = calendar.dateComponents([.day, .weekday], from: next)
        XCTAssertEqual(comps.weekday, 2, "must be a Monday")
        XCTAssertEqual((comps.day ?? 0) % 2, 1, "and an odd day (1, 3, 5…)")
        // Weekday only.
        XCTAssertEqual(try cron("0 9 * * 1").nextFireDate(after: date(2026, 10, 1), calendar: calendar),
                       date(2026, 10, 5, 9, 0))
    }

    func testSpringForwardRunsAtTheJumpAndFallBackRunsOnce() throws {
        // US DST 2026: Mar 8 02:00 → 03:00; Nov 1 02:00 → 01:00.
        let spring = try cron("30 2 * * *").nextFireDate(after: date(2026, 3, 8, 0), calendar: calendar)
        XCTAssertEqual(spring, date(2026, 3, 8, 3, 0), "2:30 does not exist that day — run at the jump")

        let fall = try cron("30 1 * * *")
        let first = try XCTUnwrap(fall.nextFireDate(after: date(2026, 11, 1, 0), calendar: calendar))
        XCTAssertEqual(first, date(2026, 11, 1, 1, 30), "the FIRST 1:30")
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: first), -4 * 3600, "EDT, before the clocks go back")
        let second = try XCTUnwrap(fall.nextFireDate(after: first, calendar: calendar))
        XCTAssertEqual(second, date(2026, 11, 2, 1, 30), "the repeated 1:30 must not fire again")
    }

    func testANeverMatchingDayIsFast() throws {
        // Weekday-free, day 31 only in months with 31 days: cheap either way, but the whole horizon
        // walk must be fast (the old walk was 527,040 minute steps on the main actor).
        let expr = try cron("0 9 31 1 *")
        let start = Date()
        _ = expr.nextFireDate(after: date(2026, 2, 1), calendar: calendar)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testTheDescriptionNamesTheDaysAndMonths() throws {
        XCTAssertEqual(try cron("0 9 * * *").humanReadable, "Daily at 9:00 AM")
        XCTAssertEqual(try cron("0 9 * * 1-5").humanReadable, "Weekdays at 9:00 AM")
        XCTAssertEqual(try cron("0 9 1 * *").humanReadable, "Monthly on day 1 at 9:00 AM")
        XCTAssertEqual(try cron("0 9 1 * 1").humanReadable, "Mon or monthly on day 1 at 9:00 AM")
        XCTAssertEqual(try cron("0 9 29 2 *").humanReadable, "Monthly on day 29 in Feb at 9:00 AM")
        XCTAssertEqual(try cron("0 9 * * 7").humanReadable, "Sun at 9:00 AM")
    }

    // MARK: - Due decision (missed = skipped, never run late)

    func testASlotWithinTheGraceRuns() throws {
        let slot = date(2026, 9, 27, 9, 0)
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: slot, cron: try cron("0 9 * * *"),
                                                    now: slot.addingTimeInterval(120), calendar: calendar),
                       .fire(missedBefore: 0))
    }

    func testSlotsPastTheGraceAreMissedAndCounted() throws {
        let stored = date(2026, 9, 24, 9, 0)     // closed for three days
        let now = date(2026, 9, 27, 12, 0)
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: stored, cron: try cron("0 9 * * *"),
                                                    now: now, calendar: calendar),
                       .missed(count: 4, lastMissed: date(2026, 9, 27, 9, 0), next: date(2026, 9, 28, 9, 0)))
    }

    func testOnlyTheLatestSlotRunsWhenItIsWithinTheGrace() throws {
        let stored = date(2026, 9, 25, 9, 0)
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: stored, cron: try cron("0 9 * * *"),
                                                    now: date(2026, 9, 27, 9, 3), calendar: calendar),
                       .fire(missedBefore: 2))
    }

    func testAOneShotPastTheGraceIsMissed() {
        let at = date(2026, 9, 27, 9, 0)
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: at, cron: nil, now: at.addingTimeInterval(3600)),
                       .missed(count: 1, lastMissed: at, next: nil))
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: at, cron: nil, now: at.addingTimeInterval(60)),
                       .fire(missedBefore: 0))
        XCTAssertEqual(SchedulerService.dueDecision(nextRunAt: at, cron: nil, now: at.addingTimeInterval(-60)),
                       .notDue)
    }

    func testAMinuteCronClosedForAMonthIsCappedNotWalked() throws {
        let start = Date()
        let decision = SchedulerService.dueDecision(nextRunAt: date(2026, 8, 27, 9, 0), cron: try cron("* * * * *"),
                                                    now: date(2026, 9, 27, 9, 0), calendar: calendar)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .fire(let missedBefore) = decision else { return XCTFail("\(decision)") }
        XCTAssertGreaterThanOrEqual(missedBefore, SchedulerService.missedCountCap - 1)
    }

    // MARK: - The service: missed and interrupted, recorded on the task

    @MainActor
    private func makeService(_ models: [ScheduledTaskModel]) throws -> (SchedulerService, ModelContainer) {
        let container = try ModelContainer(for: ScheduledTaskModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        models.forEach { container.mainContext.insert($0) }
        try container.mainContext.save()
        let service = SchedulerService()
        service.configureContainer(container)
        service.loadAllTasks()
        return (service, container)
    }

    @MainActor
    func testAMissedCronRunIsRecordedAndNotRun() throws {
        let id = UUID()
        // Twelve hours from now, so the latest passed slot is never inside the 5-minute grace.
        let hour = (Calendar.current.component(.hour, from: Date()) + 12) % 24
        let (service, _) = try makeService([ScheduledTaskModel(
            id: id, displayName: "daily", cronExpression: "0 \(hour) * * *",
            nextRunAt: Date().addingTimeInterval(-3 * 86_400))])
        let task = try XCTUnwrap(service.scheduledTasks.first)

        service.processDue(task, now: Date())

        let after = try XCTUnwrap(service.scheduledTasks.first { $0.id == id })
        XCTAssertEqual(after.status, .missed)
        XCTAssertEqual(after.runCount, 0, "a missed run must not be run late")
        XCTAssertTrue(after.lastRunSummary?.contains("Missed") == true, after.lastRunSummary ?? "nil")
        XCTAssertGreaterThan(try XCTUnwrap(after.nextRunAt), Date(), "the next slot is in the future")
        XCTAssertTrue(after.isEnabled)
        service.cancelTimer(for: id)
    }

    @MainActor
    func testAMissedOneShotIsRecordedAndDisabled() throws {
        let id = UUID()
        let at = Date().addingTimeInterval(-3600)
        let (service, _) = try makeService([ScheduledTaskModel(
            id: id, displayName: "once", scheduledAt: at, nextRunAt: at)])
        service.processDue(try XCTUnwrap(service.scheduledTasks.first), now: Date())

        let after = try XCTUnwrap(service.scheduledTasks.first { $0.id == id })
        XCTAssertEqual(after.status, .missed)
        XCTAssertFalse(after.isEnabled)
    }

    @MainActor
    func testARunInterruptedByQuitIsCancelledAndNotRerun() throws {
        let oneShot = UUID(), recurring = UUID()
        let slot = Date().addingTimeInterval(-2 * 86_400)
        let (service, _) = try makeService([
            ScheduledTaskModel(id: oneShot, displayName: "once", scheduledAt: slot, status: "running", nextRunAt: slot),
            ScheduledTaskModel(id: recurring, displayName: "daily", cronExpression: "0 9 * * *",
                               status: "running", nextRunAt: slot),
        ])

        let once = try XCTUnwrap(service.scheduledTasks.first { $0.id == oneShot })
        XCTAssertEqual(once.status, .cancelled)
        XCTAssertFalse(once.isEnabled, "an interrupted one-shot must not run again")
        XCTAssertTrue(once.lastRunSummary?.contains("quit") == true)

        let daily = try XCTUnwrap(service.scheduledTasks.first { $0.id == recurring })
        XCTAssertEqual(daily.status, .cancelled)
        XCTAssertTrue(daily.isEnabled)
        XCTAssertGreaterThan(try XCTUnwrap(daily.nextRunAt), slot,
                             "the interrupted slot RAN; the next is judged on its own")

        // Once per process: a second load (the sidebar reloads) does not touch a live run.
        service.loadAllTasks()
        XCTAssertEqual(service.scheduledTasks.first { $0.id == recurring }?.status, .cancelled)
        [oneShot, recurring].forEach(service.cancelTimer(for:))
    }

    // MARK: - Wiring (launch, timer, observers, post-run write)

    func testTheWiringDecidesPassedSlotsAndKeepsEditsMadeDuringARun() throws {
        let service = try source("Devgentic/Core/Service/Scheduler/SchedulerService.swift")
        guard let reschedule = service.range(of: "func rescheduleAll()") else { return XCTFail("rescheduleAll moved") }
        XCTAssertTrue(service[reschedule.lowerBound...].prefix(1800).contains("processDue(task, now: now)"),
                      "rescheduleAll arms timers before deciding passed slots — a missed cron run vanishes again")
        XCTAssertTrue(service.contains("timer.schedule(wallDeadline:"),
                      "the timer counts only awake time again — a sleeping Mac runs jobs late")
        XCTAssertTrue(service.contains("self.processDue(currentTask, now: Date())"),
                      "the timer fires the task directly, skipping the missed-run decision")
        guard let fire = service.range(of: "func fireTask(") else { return XCTFail("fireTask moved") }
        let body = service[fire.lowerBound...]
        guard let write = body.range(of: "updatedTask.runCount") else { return XCTFail("bookkeeping moved") }
        XCTAssertTrue(body[..<write.lowerBound].contains("updatedTask = current"),
                      "the post-run write uses the copy from the start of the run — user edits are reverted")

        let app = try source("Devgentic/DevgenticApp.swift")
        XCTAssertTrue(app.contains("SchedulerService.shared.startObservingSystemChanges()"),
                      "wake / clock / time-zone changes are no longer observed")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
