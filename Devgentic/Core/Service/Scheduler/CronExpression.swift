// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CronExpression.swift
//  Devgentic
//
//  Lightweight 5-field cron expression parser.
//  Format: minute hour dayOfMonth month dayOfWeek
//  Supports: * (any), values (1,3,5), ranges (1-5), steps (*/5)
//

import Foundation

enum CronParseError: LocalizedError {
    case invalidFormat(String)
    case invalidField(String, position: Int)

    var errorDescription: String? {
        switch self {
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
    }

    /// Calculate the next fire date after the given date.
    /// Iterates minute-by-minute, capped at 366 days to prevent infinite loops.
    func nextFireDate(after date: Date) -> Date? {
        let calendar = Calendar.current
        let maxIterations = 366 * 24 * 60 // 1 year of minutes

        // Start from the next minute
        guard var candidate = calendar.date(byAdding: .minute, value: 1, to: date) else { return nil }
        // Normalize to start of minute
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
        guard let normalized = calendar.date(from: components) else { return nil }
        candidate = normalized

        for _ in 0..<maxIterations {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard let min = comps.minute, let hr = comps.hour,
                  let dom = comps.day, let mon = comps.month, let dow = comps.weekday else {
                return nil
            }

            // Calendar.weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
            // Cron dayOfWeek: 0=Sunday, 1=Monday, ..., 6=Saturday, 7=Sunday
            let cronDow = dow - 1 // Convert Calendar weekday to cron weekday

            if month.matches(mon) && dayOfMonth.matches(dom) &&
               dayOfWeekMatches(cronDow) && hour.matches(hr) && minute.matches(min) {
                return candidate
            }

            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
        }

        return nil
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

        // Day of week
        switch dayOfWeek {
        case .any:
            if case .any = dayOfMonth {
                parts.append("Daily")
            }
        case .range(let r) where r == 1...5:
            parts.append("Weekdays")
        case .values(let vals):
            let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let names = vals.compactMap { $0 >= 0 && $0 < 7 ? dayNames[$0] : nil }
            parts.append(names.joined(separator: ", "))
        default:
            parts.append("Custom schedule")
        }

        if !timeStr.isEmpty {
            parts.append("at \(timeStr)")
        }

        return parts.isEmpty ? rawExpression : parts.joined(separator: " ")
    }
}
