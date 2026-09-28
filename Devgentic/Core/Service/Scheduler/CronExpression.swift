// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CronExpression.swift
//  Devgentic
//
//  Lightweight 5-field cron expression parser.
//  Format: minute hour dayOfMonth month dayOfWeek
//  Supports: * (any), values (1,3,5), ranges (1-5), steps (*/5)
//
//  Semantics follow standard (Vixie) cron — Timeout inventory D-22, owner decision 2026-09-27:
//  - Day-of-month and day-of-week are ORed when BOTH are restricted (`0 9 1 * 1` = the 1st OR any
//    Monday); when either is `*` (or `*/n`) the other alone decides.
//  - Local wall-clock time. A time that does not exist (the spring-forward gap) runs at the moment
//    the clock jumps; a time that happens twice (fall-back) runs once, at its first occurrence.
//  - An expression that can never fire (`0 9 31 2 *`) is refused at parse time.
//

import Foundation

enum CronParseError: LocalizedError {
    case invalidFormat(String)
    case invalidField(String, position: Int)
    /// Parses, but names a date that never exists (e.g. 31 February), so it would never run.
    case neverFires(String)

    var errorDescription: String? {
        switch self {
        case .neverFires(let expr): return "'\(expr)' never runs: no month has that day."
        case .invalidFormat(let expr): return "Invalid cron format: '\(expr)'. Expected 5 space-separated fields."
        case .invalidField(let field, let pos): return "Invalid cron field '\(field)' at position \(pos)."
        }
    }
}

// MARK: - CronField

enum CronField: Equatable {
    case any
    case values([Int])
    case range(ClosedRange<Int>)
    case step(base: CronFieldBase, stepValue: Int)

    enum CronFieldBase: Equatable {
        case any
        case range(ClosedRange<Int>)
    }

    /// `*` or `*/n` — "unrestricted" in the standard cron sense, which decides whether the two day
    /// fields are ANDed or ORed. `*/2` counts as unrestricted there, exactly as in Vixie cron.
    var startsWithStar: Bool {
        switch self {
        case .any, .step(base: .any, _): return true
        default: return false
        }
    }

    func matches(_ value: Int) -> Bool {
        switch self {
        case .any:
            return true
        case .values(let vals):
            return vals.contains(value)
        case .range(let r):
            return r.contains(value)
        case .step(let base, let stepValue):
            switch base {
            case .any:
                return value % stepValue == 0
            case .range(let r):
                guard r.contains(value) else { return false }
                return (value - r.lowerBound) % stepValue == 0
            }
        }
    }

    static func parse(_ field: String, min: Int, max: Int) throws -> CronField {
        if field == "*" { return .any }

        // Step: */5 or 1-10/2
        if field.contains("/") {
            let parts = field.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let stepValue = Int(parts[1]), stepValue > 0 else {
                throw CronParseError.invalidField(field, position: -1)
            }
            let base = String(parts[0])
            if base == "*" {
                return .step(base: .any, stepValue: stepValue)
            } else if base.contains("-") {
                let rangeParts = base.split(separator: "-")
                guard rangeParts.count == 2,
                      let lo = Int(rangeParts[0]), let hi = Int(rangeParts[1]),
                      lo >= min, hi <= max, lo <= hi else {
                    throw CronParseError.invalidField(field, position: -1)
                }
                return .step(base: .range(lo...hi), stepValue: stepValue)
            }
            throw CronParseError.invalidField(field, position: -1)
        }

        // Range: 1-5
        if field.contains("-") {
            let parts = field.split(separator: "-")
            guard parts.count == 2,
                  let lo = Int(parts[0]), let hi = Int(parts[1]),
                  lo >= min, hi <= max, lo <= hi else {
                throw CronParseError.invalidField(field, position: -1)
            }
            return .range(lo...hi)
        }

        // List: 1,3,5
        if field.contains(",") {
            let vals = field.split(separator: ",").compactMap { Int($0) }
            guard !vals.isEmpty, vals.allSatisfy({ $0 >= min && $0 <= max }) else {
                throw CronParseError.invalidField(field, position: -1)
            }
            return .values(vals)
        }

        // Single value
        if let val = Int(field), val >= min, val <= max {
            return .values([val])
        }

        throw CronParseError.invalidField(field, position: -1)
    }
}

// MARK: - CronExpression

struct CronExpression {
    let minute: CronField
    let hour: CronField
    let dayOfMonth: CronField
    let month: CronField
    let dayOfWeek: CronField

    let rawExpression: String

    init(expression: String) throws {
        self.rawExpression = expression
        let fields = expression.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count == 5 else {
            throw CronParseError.invalidFormat(expression)
        }

        self.minute     = try CronField.parse(String(fields[0]), min: 0, max: 59)
        self.hour       = try CronField.parse(String(fields[1]), min: 0, max: 23)
        self.dayOfMonth = try CronField.parse(String(fields[2]), min: 1, max: 31)
        self.month      = try CronField.parse(String(fields[3]), min: 1, max: 12)
        self.dayOfWeek  = try CronField.parse(String(fields[4]), min: 0, max: 7) // 0 and 7 = Sunday

        // ⚠️ Refused here so the editor rejects it on save; before, such a task saved fine and was
        // silently never armed.
        guard canEverFire else { throw CronParseError.neverFires(expression) }
    }

    /// Days searched ahead before giving up: eight years, so a 29 February schedule always finds its
    /// next leap day (the longest gap between two, across a skipped century year, is eight years).
    static let searchHorizonDays = 366 * 8 + 1

    /// The first fire time strictly after the minute containing `date`.
    ///
    /// ⚠️ Walks DAYS, not minutes. The old walk stepped minute by minute through a single year:
    /// 527,040 iterations on the main actor for an expression that never matched (the editor preview
    /// re-ran it on every keystroke), and a 29 February schedule failed whenever its leap day was more
    /// than a year away (D-22).
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let floorMinute = calendar.dateInterval(of: .minute, for: date)?.start,
              var day = calendar.dateInterval(of: .day, for: date)?.start else { return nil }

        for _ in 0..<Self.searchHorizonDays {
            let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let year = comps.year, let mon = comps.month, let dom = comps.day, let weekday = comps.weekday,
               dayMatches(dayOfMonth: dom, month: mon, cronWeekday: weekday - 1) {
                for hr in 0...23 where hour.matches(hr) {
                    for min in 0...59 where minute.matches(min) {
                        guard let fire = Self.resolve(year: year, month: mon, day: dom, hour: hr, minute: min,
                                                      calendar: calendar) else { continue }
                        // Resolved times are non-decreasing in (hour, minute) order, so the first
                        // one past the floor is the answer.
                        if fire > floorMinute { return fire }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// Local (year, month, day, hour, minute) → an instant, with standard cron's clock-change rules.
    ///
    /// Foundation's default already picks the FIRST occurrence of a repeated (fall-back) time. For a
    /// time inside the spring-forward gap it moves forward by the gap (2:30 → 3:30); cron runs such a
    /// job at the jump instead, which `.nextTime` gives (2:30 → 3:00).
    private static func resolve(year: Int, month: Int, day: Int, hour: Int, minute: Int,
                                calendar: Calendar) -> Date? {
        let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: wanted) else { return nil }
        let got = calendar.dateComponents([.day, .hour, .minute], from: date)
        if got.day == day, got.hour == hour, got.minute == minute { return date }
        guard let dayStart = calendar.dateInterval(of: .day, for: date)?.start else { return date }
        return calendar.nextDate(after: dayStart.addingTimeInterval(-1),
                                 matching: DateComponents(hour: hour, minute: minute),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                 direction: .forward) ?? date
    }

    /// Standard cron day rule: ORed when both day fields are restricted, ANDed otherwise.
    func dayMatches(dayOfMonth dom: Int, month mon: Int, cronWeekday: Int) -> Bool {
        guard month.matches(mon) else { return false }
        if !dayOfMonth.startsWithStar && !dayOfWeek.startsWithStar {
            return dayOfMonth.matches(dom) || dayOfWeekMatches(cronWeekday)
        }
        return dayOfMonth.matches(dom) && dayOfWeekMatches(cronWeekday)
    }

    /// True when some real calendar day satisfies the day fields — decided from the fields alone, so
    /// it does not depend on today's date. Hours and minutes always match something once parsed.
    private var canEverFire: Bool {
        let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]  // 29: leap years exist
        let months = (1...12).filter { month.matches($0) }
        guard !months.isEmpty, (0...7).contains(where: dayOfWeekMatches) else { return false }
        // A restricted weekday ORed in, or no day-of-month restriction: every month has every weekday.
        if !dayOfWeek.startsWithStar && !dayOfMonth.startsWithStar { return true }
        if dayOfMonth.startsWithStar { return true }
        return months.contains { m in (1...daysInMonth[m - 1]).contains(where: dayOfMonth.matches) }
    }

    /// Handle the special case where both 0 and 7 represent Sunday.
    private func dayOfWeekMatches(_ cronDow: Int) -> Bool {
        if dayOfWeek.matches(cronDow) { return true }
        // If cronDow is 0 (Sunday), also check 7
        if cronDow == 0 && dayOfWeek.matches(7) { return true }
        return false
    }

    /// Human-readable description of the schedule.
    var humanReadable: String {
        // Common presets
        if rawExpression == "* * * * *" { return "Every minute" }
        if rawExpression == "0 * * * *" { return "Every hour" }

        var parts: [String] = []

        // Time
        let timeStr: String
        if case .values(let mins) = minute, mins.count == 1,
           case .values(let hrs) = hour, hrs.count == 1 {
            timeStr = String(format: "%d:%02d %@", hrs[0] > 12 ? hrs[0] - 12 : (hrs[0] == 0 ? 12 : hrs[0]), mins[0], hrs[0] >= 12 ? "PM" : "AM")
        } else {
            timeStr = ""
        }

        // Days. ⚠️ Day-of-month and month were ignored here, so `0 9 1 * *` read "at 9:00 AM" and
        // `0 9 29 2 *` read the same — the description hid when the task really runs.
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let weekdayText: String? = switch dayOfWeek {
        case .any: nil
        case .range(let r) where r == 1...5: "Weekdays"
        case .values(let vals): vals.map { dayNames[$0] }.joined(separator: ", ")
        default: "Custom weekdays"
        }
        let monthDayText: String? = switch dayOfMonth {
        case .any: nil
        case .values(let vals): "day " + vals.map(String.init).joined(separator: ", ")
        case .range(let r): "days \(r.lowerBound)–\(r.upperBound)"
        default: "custom days"
        }
        switch (weekdayText, monthDayText) {
        case (nil, nil): parts.append("Daily")
        case (let w?, nil): parts.append(w)
        case (nil, let d?): parts.append("Monthly on \(d)")
        case (let w?, let d?):
            // Either day only when BOTH fields are restricted (`*/n` counts as unrestricted).
            let either = !dayOfMonth.startsWithStar && !dayOfWeek.startsWithStar
            parts.append(either ? "\(w) or monthly on \(d)" : "\(w), \(d)")
        }
        if case .values(let months) = month {
            let names = Calendar.current.shortMonthSymbols   // carries the locale; a bare Calendar gives "M02"
            parts.append("in " + months.map { names[$0 - 1] }.joined(separator: ", "))
        } else if month != .any {
            parts.append("in some months")
        }

        if !timeStr.isEmpty {
            parts.append("at \(timeStr)")
        }

        return parts.isEmpty ? rawExpression : parts.joined(separator: " ")
    }
}
