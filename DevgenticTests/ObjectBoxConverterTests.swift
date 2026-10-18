// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ObjectBoxConverterTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ObjectBoxConverterTests: XCTestCase {

    // MARK: - UUIDConverter Tests

    func testUUIDConverter_Roundtrip() {
        let original = UUID()
        let dbValue = UUIDConverter.convert(original)
        let restored = UUIDConverter.convert(dbValue)

        XCTAssertEqual(original, restored)
    }

    func testUUIDConverter_EntityToDatabase_ProducesUUIDString() {
        let uuid = UUID()
        let dbValue = UUIDConverter.convert(uuid)
        XCTAssertEqual(dbValue, uuid.uuidString)
    }

    func testUUIDConverter_DatabaseToEntity_ValidString() {
        let knownString = "550E8400-E29B-41D4-A716-446655440000"
        let result = UUIDConverter.convert(knownString)
        XCTAssertEqual(result.uuidString.uppercased(), knownString.uppercased())
    }

    func testUUIDConverter_DatabaseToEntity_NilString_ReturnsNewUUID() {
        let result = UUIDConverter.convert(nil as String?)
        // Should not crash, should return a valid UUID
        XCTAssertFalse(result.uuidString.isEmpty)
    }

    func testUUIDConverter_DatabaseToEntity_InvalidString_ReturnsNewUUID() {
        let result = UUIDConverter.convert("not-a-valid-uuid")
        // Should return a fallback UUID (not crash)
        XCTAssertFalse(result.uuidString.isEmpty)
    }

    func testUUIDConverter_DatabaseToEntity_EmptyString_ReturnsNewUUID() {
        let result = UUIDConverter.convert("")
        XCTAssertFalse(result.uuidString.isEmpty)
    }

    func testUUIDConverter_MultipleRoundtrips_Stable() {
        let uuid = UUID()
        let firstConversion = UUIDConverter.convert(uuid)

        for _ in 0..<100 {
            let converted = UUIDConverter.convert(uuid)
            XCTAssertEqual(converted, firstConversion,
                           "UUID → String conversion should be deterministic")
        }
    }

    // MARK: - FloatArrayConverter Tests
    //
    // Note: FloatArrayConverter is no longer used for `ChildChunkEntity.embedding`.
    // As of Build 98, ObjectBox stores embeddings natively as `floatVector` via the HNSW
    // index (property type `[Float]?`). FloatArrayConverter remains available for other
    // use cases that require Data-backed Float storage.

    func testFloatArrayConverter_Roundtrip_SmallArray() {
        let original: [Float] = [1.0, 2.0, 3.0]
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(original, restored)
    }

    func testFloatArrayConverter_Roundtrip_384DimensionEmbedding() {
        // 384 is the output dimension of All-MiniLM-L6-v2
        let original = (0..<384).map { Float($0) * 0.001 }
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(original.count, restored.count)
        for i in 0..<original.count {
            XCTAssertEqual(original[i], restored[i], accuracy: 1e-7,
                           "Mismatch at index \(i)")
        }
    }

    func testFloatArrayConverter_EntityToDatabase_CorrectSize() {
        let array: [Float] = [1.0, 2.0, 3.0]
        let data = FloatArrayConverter.convert(array)
        let expectedSize = 3 * MemoryLayout<Float>.size // 3 * 4 = 12
        XCTAssertEqual(data.count, expectedSize)
    }

    func testFloatArrayConverter_DatabaseToEntity_NilData_ReturnsEmptyArray() {
        let result = FloatArrayConverter.convert(nil as Data?)
        XCTAssertEqual(result, [])
    }

    func testFloatArrayConverter_DatabaseToEntity_EmptyData_ReturnsEmptyArray() {
        let result = FloatArrayConverter.convert(Data())
        XCTAssertEqual(result, [])
    }

    func testFloatArrayConverter_Roundtrip_NegativeAndZeroValues() {
        let original: [Float] = [-1.5, 0.0, 3.14, -0.001]
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(original, restored)
    }

    func testFloatArrayConverter_Roundtrip_SpecialFloats() {
        let original: [Float] = [Float.infinity, -Float.infinity]
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(restored[0], Float.infinity)
        XCTAssertEqual(restored[1], -Float.infinity)
    }

    func testFloatArrayConverter_Roundtrip_NaN() {
        let original: [Float] = [Float.nan]
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].isNaN, "NaN should survive roundtrip")
    }

    func testFloatArrayConverter_DataIntegrity_ByteOrder() {
        let original: [Float] = [1.0]
        let data = FloatArrayConverter.convert(original)

        // Manually read the 4 bytes as a Float
        let manualFloat = data.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertEqual(manualFloat, 1.0)
    }

    func testFloatArrayConverter_Roundtrip_EmptyArray() {
        let original: [Float] = []
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(restored, [])
    }

    func testFloatArrayConverter_Roundtrip_LargeArray_1000Elements() {
        let original = (0..<1000).map { Float.random(in: -100...100) + Float($0) * 0.001 }
        let data = FloatArrayConverter.convert(original)
        let restored = FloatArrayConverter.convert(data)

        XCTAssertEqual(original.count, restored.count)
        for i in 0..<original.count {
            XCTAssertEqual(original[i], restored[i], accuracy: 1e-7)
        }
    }
}
