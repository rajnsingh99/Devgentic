//
//  AnyCodable.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation

/// A type-erased `Codable` value.
///
/// The `AnyCodable` type forwards encoding and decoding responsibilities
/// to an underlying value, hiding its specific underlying type.
///
/// This allows you to create structs with fields like `[String: AnyCodable]`,
/// effectively enabling "Dynamic JSON" support within Swift's strict type system.
@available(*, deprecated, message: "Use JSONValue instead")
public struct AnyCodable: Codable, Hashable, @unchecked Sendable {
    let value: Any
    init<T>(_ value: T?) { self.value = value ?? () }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ()
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is Void, is NSNull: // PATCH: Handle LLM returning "null" for properties
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let double as Double:
            try container.encode(double)
        case let int as Int:
            try container.encode(int)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded"))
        }
    }
    
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (is Void, is Void), (is NSNull, is NSNull): return true // PATCH: Handle NSNull equality
        case (let l as Bool, let r as Bool): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as String, let r as String): return l == r
        case (let l as [AnyHashable], let r as [AnyHashable]): return l == r
        case (let l as [String: AnyHashable], let r as [String: AnyHashable]): return l == r
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        if let hashable = value as? AnyHashable {
            hasher.combine(hashable)
        }
    }
}
