//
//  JSONValue.swift
//  Devgentic
//
//  Created by Antigravity on 09/03/26.
//

import Foundation

/// A type-safe, Sendable, and Codable representation of a JSON value.
/// Used to replace `Any` in structures that must conform to `Sendable`.
public enum JSONValue: Sendable, Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // MARK: - Initializers

    /// Attempts to create a JSONValue from a raw Any value.
    public init?(_ value: Any) {
        if let string = value as? String {
            self = .string(string)
        } else if let bool = value as? Bool {
            self = .bool(bool)
        } else if let number = value as? NSNumber {
            // Check if it's a boolean packaged as an NSNumber (common in ObjC/JSON)
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        } else if let double = value as? Double {
            self = .number(double)
        } else if let int = value as? Int {
            self = .number(Double(int))
        } else if let dict = value as? [String: Any] {
            var newDict: [String: JSONValue] = [:]
            for (key, val) in dict {
                if let mapped = JSONValue(val) {
                    newDict[key] = mapped
                } else {
                    newDict[key] = .null
                }
            }
            self = .object(newDict)
        } else if let array = value as? [Any] {
            self = .array(array.compactMap { JSONValue($0) })
        } else if value is NSNull {
            self = .null
        } else {
            return nil
        }
    }

    // MARK: - Raw Access

    /// Returns the underlying value as a standard Swift type (Any).
    public var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.rawValue }
        case .array(let v): return v.map { $0.rawValue }
        case .null: return NSNull()
        }
    }

    // MARK: - Convenience Accessors

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}
