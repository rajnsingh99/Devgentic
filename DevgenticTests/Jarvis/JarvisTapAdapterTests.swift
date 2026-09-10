// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisTapAdapterTests.swift
//  DevgenticTests
//
//  Pins the behaviour that the first duplex device run proved was missing. That session logged
//  `tap: 16000 Hz / 3 ch` from a healthy-looking engine and then `audio: NONE, heard 0 word(s)` —
//  a three-channel mic array reaching a converter that had been pinned to a pre-start format.
//  These run entirely on in-memory buffers: no device, no permission prompt.
//

import XCTest
import AVFoundation
@testable import devgentic

final class JarvisTapAdapterTests: XCTestCase {

    private let logger = DGLogger(category: "JarvisTapAdapterTests")

    /// ⚠️ NOT `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`. That initializer
    /// returns nil above two channels, so the three-channel mic-array cases — the whole reason
    /// this file exists — silently turned into `XCTSkip` and proved nothing. Multichannel needs an
    /// explicit layout; `DiscreteInOrder | N` is what a voice-processing tap actually reports.
    private func format(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
        ) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }

    /// A buffer of audible, non-constant audio — silence would make "delivered" ambiguous.
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 1600) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = sin(Float(frame) * 0.05) * 0.5
            }
        }
        return buffer
    }

    private func adapter(predicted: AVAudioFormat, target: AVAudioFormat) -> JarvisTapAdapter {
        JarvisTapAdapter(predicted: predicted, target: target, tag: "[TEST]", logger: logger)
    }

    // MARK: - The observed failure

    /// THE REGRESSION. A three-channel built-in mic array must reach WhisperKit as 16 kHz mono.
    func testThreeChannelMicArrayIsDownmixedAndDelivered() throws {
        guard let source = format(16_000, 3), let target = format(16_000, 1) else {
            throw XCTSkip("This machine cannot describe a 3-channel format.")
        }
        let adapter = adapter(predicted: source, target: target)

        let out = adapter.adapt(buffer(source))

        let converted = try XCTUnwrap(out, "A 3-channel array buffer must survive downmixing — dropping it is the dead-microphone bug.")
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertEqual(adapter.snapshot.delivered, 1)
        XCTAssertTrue(adapter.snapshot.drops.isEmpty)
    }

    /// THE ROOT CAUSE. The pre-start format is a hint for logging only. If conversion were still
    /// derived from it, this buffer would be silently dropped — exactly what shipped.
    func testAWrongPredictedFormatDoesNotMakeTheSessionDeaf() throws {
        guard let predicted = format(48_000, 1),      // what the node claimed before start
              let actual = format(16_000, 3),          // what voice processing actually delivered
              let target = format(16_000, 1) else { throw XCTSkip("Unsupported formats.") }
        let adapter = adapter(predicted: predicted, target: target)

        let converted = try XCTUnwrap(adapter.adapt(buffer(actual)),
                                      "The converter must come from the real buffer, never from the pre-start read.")
        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(adapter.snapshot.delivered, 1)
    }

    // MARK: - Renegotiation

    /// Voice processing renegotiates mid-session. That must cost buffers, not the session.
    func testFormatChangeMidSessionRebuildsTheConverter() throws {
        guard let first = format(48_000, 2), let second = format(16_000, 3), let target = format(16_000, 1) else {
            throw XCTSkip("Unsupported formats.")
        }
        let adapter = adapter(predicted: first, target: target)

        XCTAssertNotNil(adapter.adapt(buffer(first)))
        XCTAssertNotNil(adapter.adapt(buffer(second)), "A renegotiated format must rebuild the converter, not go deaf.")

        XCTAssertEqual(adapter.snapshot.delivered, 2)
        XCTAssertEqual(adapter.snapshot.formatChanges, 1)
    }

    func testResamplingUpAndDownBothProduceAudio() throws {
        guard let target = format(16_000, 1) else { throw XCTSkip("Unsupported format.") }
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0] {
            guard let source = format(rate, 1) else { continue }
            let adapter = adapter(predicted: source, target: target)
            let converted = try XCTUnwrap(adapter.adapt(buffer(source)), "\(rate) Hz must resample to 16 kHz.")
            XCTAssertGreaterThan(converted.frameLength, 0, "\(rate) Hz produced an empty buffer.")
        }
    }

    // MARK: - Diagnosis

    /// The distinction the first device run could not make: nothing arrived at all (device-level)
    /// versus buffers arrived and were dropped (format-level). They have different fixes, so the
    /// summary must not blur them.
    func testSummaryDistinguishesNoBuffersFromDroppedBuffers() throws {
        guard let source = format(16_000, 1), let target = format(16_000, 1) else { throw XCTSkip("Unsupported.") }

        let silent = adapter(predicted: source, target: target)
        let noBuffers = silent.summary()
        XCTAssertTrue(noBuffers.contains("0 times"), "Summary must say the tap never fired: \(noBuffers)")
        XCTAssertTrue(noBuffers.lowercased().contains("not a format"),
                      "A tap that never fired must be steered away from format debugging: \(noBuffers)")
        XCTAssertFalse(silent.snapshot.sawAudio)

        let live = adapter(predicted: source, target: target)
        _ = live.adapt(buffer(source))
        let ran = live.summary()
        XCTAssertTrue(ran.contains("tap fired 1×"), "Summary must report real callback counts: \(ran)")
        XCTAssertTrue(ran.contains("16000 Hz / 1 ch"), "Summary must report the ACTUAL first-buffer format: \(ran)")
        XCTAssertTrue(live.snapshot.sawAudio)
    }

    func testCallbacksAreCountedEvenWhenEveryBufferIsDropped() throws {
        guard let source = format(16_000, 1), let target = format(16_000, 1) else { throw XCTSkip("Unsupported.") }
        let adapter = adapter(predicted: source, target: target)

        // A zero-frame buffer converts to nothing — the "engine alive, recognizer starved" shape.
        let empty = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1600)!
        empty.frameLength = 0
        _ = adapter.adapt(empty)

        let stats = adapter.snapshot
        XCTAssertEqual(stats.callbacks, 1, "A dropped buffer is still a callback — otherwise a starving tap looks like a dead device.")
        XCTAssertEqual(stats.delivered, 0)
        XCTAssertTrue(stats.sawAudio, "Buffers arrived; the problem is downstream of CoreAudio.")
    }
}
