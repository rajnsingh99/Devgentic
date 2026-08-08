//
//  JSONValue.swift
//  Devgentic
//
//  Created by Antigravity on 09/03/26.
//

import Foundation

/// A thin wrapper that asserts Sendable conformance for types that are
/// practically safe to send across isolation boundaries but can't formally conform
/// (e.g., `[String: Any]` dictionaries destined for MLX tokenizer APIs).
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

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
        } else if let number = value as? NSNumber {
            // ⚠️ NSNumber MUST be tested before `as? Bool`. `JSONSerialization` returns NSNumber
            // for booleans AND for every numeric, and an NSNumber holding 0 or 1 bridges to Swift
            // `Bool` successfully — so with the Bool branch first, this CFGetTypeID check (which
            // exists precisely to tell the two apart) was unreachable for exactly those values.
            //
            // The consequence was not cosmetic: every provider reads its options with
            // `if case .number(let val) = config.options?[...]`, so a `1.0` that arrived as
            // `.bool(true)` failed the pattern match and was DROPPED from the request. That hit
            // the shipped defaults hardest — Gemini's `topP: 1.0` and Anthropic's
            // `temperature: 1.0` never reached the wire at all.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        } else if let bool = value as? Bool {
            self = .bool(bool)
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

    // MARK: - Serialization

    /// Serialize to Data for tool argument dispatch.
    public func toJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    // MARK: - Structured Parsing (Workflow JSON passing)

    /// Parses a string as a *structured* JSON value (object or array only).
    ///
    /// Returns `nil` when the text is empty, not valid JSON, or decodes to a bare
    /// scalar (string / number / bool / null). The scalar rejection is deliberate:
    /// a node whose output is the plain text `"42"` or `"done"` should be treated as
    /// text, not as a structured payload — only objects/arrays unlock `{{ input.json.path }}`
    /// access.
    ///
    /// Detection handles three shapes, in order:
    ///   1. the whole string is JSON (optionally wrapped in one leading ``` fence),
    ///   2. JSON inside the first Markdown fenced block (```json … ```), so a chatty
    ///      model that explains *then* emits a payload is still detected,
    /// Only explicit fences are searched for embedded JSON — incidental `{ }` in
    /// prose is never scanned, avoiding false positives.
    public static func parseStructured(_ string: String) -> JSONValue? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Whole string is JSON, optionally wrapped in a single leading ``` fence.
        if let direct = decodeObjectOrArray(stripLeadingFence(trimmed)) {
            return direct
        }

        // 2. JSON embedded in prose inside a fenced block.
        if let fenced = firstFencedBlock(in: trimmed),
           let value = decodeObjectOrArray(fenced.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }

        return nil
    }

    /// Strips a single leading ```json/``` fence (and trailing ```), if present.
    private static func stripLeadingFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var t = s
        if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the inner text of the first ``` … ``` fenced block (optional language
    /// tag tolerated), or `nil` if there isn't a complete multi-line fenced block.
    private static func firstFencedBlock(in s: String) -> String? {
        guard let open = s.range(of: "```") else { return nil }
        let afterOpen = s[open.upperBound...]
        guard let nl = afterOpen.firstIndex(of: "\n") else { return nil }
        let bodyStart = afterOpen.index(after: nl)
        guard let close = afterOpen.range(of: "```", range: bodyStart..<afterOpen.endIndex) else { return nil }
        return String(afterOpen[bodyStart..<close.lowerBound])
    }

    /// Decodes `s` only if it is a JSON object or array (scalars → nil).
    private static func decodeObjectOrArray(_ s: String) -> JSONValue? {
        guard let first = s.first, first == "{" || first == "[" else { return nil }
        guard let data = s.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        switch value {
        case .object, .array: return value
        default: return nil
        }
    }

    // MARK: - Path Access

    /// Navigates a dot-style path into this value. Each component is an object key
    /// or, for arrays, a non-negative integer index (e.g. `["items", "0", "name"]`).
    /// Returns `nil` if any component is missing or the shape doesn't match.
    public func value(at path: [String]) -> JSONValue? {
        var current: JSONValue = self
        for key in path {
            switch current {
            case .object(let dict):
                guard let next = dict[key] else { return nil }
                current = next
            case .array(let arr):
                guard let idx = Int(key), idx >= 0, idx < arr.count else { return nil }
                current = arr[idx]
            default:
                return nil
            }
        }
        return current
    }

    /// Convenience for dot-separated string paths: `"items.0.name"`.
    public func value(atDotPath dotPath: String) -> JSONValue? {
        value(at: dotPath.split(separator: ".").map(String.init))
    }

    // MARK: - Template Rendering

    /// Renders this value for substitution into a text template.
    /// Scalars render as their natural text; objects/arrays render as compact JSON
    /// so a whole structured payload can still be interpolated as a string.
    public var templateString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .number(let n):
            // Render integers without a trailing ".0".
            if let i = Int(exactly: n) { return String(i) }
            return String(n)
        case .object, .array:
            if let data = try? JSONEncoder().encode(self),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        }
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
