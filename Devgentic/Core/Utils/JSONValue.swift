//
//  JSONValue.swift
//  Devgentic
//
//  Created by Antigravity on 09/03/26.
//

import Foundation

/// A type-safe, Sendable, and Codable representation of a JSON value.
/// Used to replace `Any` in structures that must conform to `Sendable`.
public enum JSONValue: Sendable, Hashable {
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

    public var intValue: Int? {
        if case .number(let v) = self { return Int(exactly: v) }
        return nil
    }

    // MARK: - AnyCodable Bridge (Phase 1B Migration)

    /// Serialize to Data for tool argument dispatch.
    public func toJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: - Custom Codable Implementation

extension JSONValue: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // 1. Intercept `null` explicitly before anything else fails
        if container.decodeNil() {
            self = .null
            return
        }
        
        // 2. Attempt decoding in order of strictness
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }
        
        if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
            return
        }
        
        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }
        
        if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
            return
        }
        
        if let dictVal = try? container.decode([String: JSONValue].self) {
            self = .object(dictVal)
            return
        }
        
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSONValue could not decode the payload into a recognized primitive, array, or object."
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let n):
            try container.encode(n)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}
