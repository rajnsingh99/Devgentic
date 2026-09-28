// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MicrophoneSelectionTests.swift
//  DevgenticTests
//
//  Choosing the dictation microphone (2026-09-27). Every session used to open macOS's default
//  input: WhisperKit's streaming transcriber never passes a device to its recorder.
//

import XCTest
import AVFoundation
import CoreML
import WhisperKit
@testable import devgentic

final class MicrophoneResolutionTests: XCTestCase {

    private let mac = MicrophoneDevice(id: 71, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = MicrophoneDevice(id: 92, uid: "AppleUSBAudioEngine:Shure:MV7:1", name: "Shure MV7")

    func testNoChoiceFollowsTheSystemDefault() {
        XCTAssertEqual(MicrophoneCatalog.resolve(selectedUID: nil, savedName: nil, available: [mac, usb]), .systemDefault)
        XCTAssertEqual(MicrophoneCatalog.resolve(selectedUID: "", savedName: nil, available: [mac, usb]), .systemDefault)
        XCTAssertNil(MicrophoneResolution.systemDefault.deviceID, "the default must reach the recorder as nil")
    }

    /// ⚠️ Matched by UID, and the recorder gets THIS BOOT's id for it.
    func testAChosenConnectedMicIsUsed() {
        let usbAfterReplug = MicrophoneDevice(id: 131, uid: usb.uid, name: usb.name)
        let resolution = MicrophoneCatalog.resolve(selectedUID: usb.uid, savedName: "Shure MV7", available: [mac, usbAfterReplug])
        XCTAssertEqual(resolution, .device(usbAfterReplug))
        XCTAssertEqual(resolution.deviceID, 131, "a stored numeric id would point at nothing after a replug")
    }

    /// Unplugged: record from the default — and say which mic is missing.
    func testAMissingMicFallsBackAndIsNamed() {
        let resolution = MicrophoneCatalog.resolve(selectedUID: usb.uid, savedName: "Shure MV7", available: [mac])
        XCTAssertEqual(resolution, .unavailable(uid: usb.uid, name: "Shure MV7"))
        XCTAssertNil(resolution.deviceID, "a missing mic must fall back to the default, not fail the session")
        XCTAssertEqual(MicrophoneMenu.unavailableLabel(name: "Shure MV7", fallback: mac),
                       "Shure MV7 — not connected, using MacBook Pro Microphone")
    }

    func testOnlyRealInputsAreListed() {
        XCTAssertTrue(MicrophoneCatalog.isListable(uid: "BuiltInMicrophoneDevice", isHidden: false, inputChannels: 1))
        XCTAssertFalse(MicrophoneCatalog.isListable(uid: "BuiltInSpeakerDevice", isHidden: false, inputChannels: 0),
                       "an output-only device is not a microphone")
        XCTAssertFalse(MicrophoneCatalog.isListable(uid: "x", isHidden: true, inputChannels: 2))
        XCTAssertFalse(MicrophoneCatalog.isListable(uid: "CADefaultDeviceAggregate-1234-5", isHidden: false, inputChannels: 1),
                       "voice processing's aggregate is plumbing Orb creates, not a microphone")
    }

    /// Reads the real machine: must not crash, and UIDs must be unique (they are the stored key).
    func testTheRealDeviceListIsWellFormed() {
        let devices = MicrophoneCatalog.inputDevices()
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)
        XCTAssertTrue(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
    }
}

@MainActor
final class MicrophoneSelectionPersistenceTests: XCTestCase {

    func testTheChoiceIsRememberedByUIDAndCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mic-\(UUID())"))
        let usb = MicrophoneDevice(id: 92, uid: "usb-uid", name: "Shure MV7")

        MicrophoneSelection(defaults: defaults).select(usb)
        let reopened = MicrophoneSelection(defaults: defaults)
        XCTAssertEqual(reopened.selectedUID, "usb-uid", "the choice did not survive a relaunch")
        XCTAssertEqual(reopened.selectedName, "Shure MV7", "a disconnected choice could not be named")

        reopened.select(nil)
        XCTAssertNil(MicrophoneSelection(defaults: defaults).selectedUID, "'System Default' did not clear the choice")
    }
}

/// The wrapper that points WhisperKit's recorder at the chosen device.
final class InputDeviceAudioProcessorTests: XCTestCase {

    private final class FakeRecorder: AudioProcessing {
        var startedWith: [DeviceID?] = []
        var resumedWith: [DeviceID?] = []
        var stopped = 0
        var audioSamples: ContiguousArray<Float> = [1, 2, 3]
        var relativeEnergy: [Float] = [0.5]
        var relativeEnergyWindow = 20
        func purgeAudioSamples(keepingLast keep: Int) {}
        func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws { startedWith.append(inputDeviceID) }
        func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
            startedWith.append(inputDeviceID)
            return AsyncThrowingStream.makeStream()
        }
        func pauseRecording() {}
        func stopRecording() { stopped += 1 }
        func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws { resumedWith.append(inputDeviceID) }
        func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? { nil }
        static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer { fatalError() }
        static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] { [] }
        static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? { nil }
    }

    /// ⚠️ THE DEFECT: the transcriber passes no device, so the wrapper must supply the chosen one.
    func testTheChosenDeviceIsUsedWhenTheCallerGivesNone() throws {
        let fake = FakeRecorder()
        let wrapped = InputDeviceAudioProcessor(base: fake, deviceID: 92)
        try wrapped.startRecordingLive(inputDeviceID: nil, callback: nil)
        try wrapped.resumeRecordingLive(inputDeviceID: nil, callback: nil)
        _ = wrapped.startStreamingRecordingLive(inputDeviceID: nil)
        XCTAssertEqual(fake.startedWith, [92, 92])
        XCTAssertEqual(fake.resumedWith, [92])
    }

    func testAnExplicitDeviceFromTheCallerWins() throws {
        let fake = FakeRecorder()
        try InputDeviceAudioProcessor(base: fake, deviceID: 92).startRecordingLive(inputDeviceID: 7, callback: nil)
        XCTAssertEqual(fake.startedWith, [7])
    }

    /// Everything else is the real recorder's — a stub here yields a live mic and no transcript.
    func testEverythingElseIsForwarded() {
        let fake = FakeRecorder()
        var wrapped = InputDeviceAudioProcessor(base: fake, deviceID: 92) as any AudioProcessing
        XCTAssertEqual(wrapped.audioSamples, [1, 2, 3])
        XCTAssertEqual(wrapped.relativeEnergy, [0.5])
        wrapped.relativeEnergyWindow = 40
        XCTAssertEqual(fake.relativeEnergyWindow, 40)
        wrapped.stopRecording()
        XCTAssertEqual(fake.stopped, 1)
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The service must hand the transcriber the wrapper — and Orb's duplex engine must win over
    /// it, since that engine keeps the system default for echo cancellation.
    func testDictationRecordsFromTheChoice() throws {
        let code = try source("Devgentic/Interfaces/Shared/ChatInput/Speech/WhisperRecognitionService.swift")
        XCTAssertTrue(code.contains("MicrophoneSelection.shared.deviceIDForSession(session.shortID)"), "the choice is never read")
        XCTAssertTrue(code.contains("InputDeviceAudioProcessor(base: whisperKit.audioProcessor, deviceID: deviceID)"),
                      "the chosen device never reaches the recorder")
        XCTAssertTrue(code.contains("audioProcessor: recorder,"), "the transcriber is not given the chosen recorder")
        guard let duplex = code.range(of: "if let duplexProcessor {"),
              let chosen = code.range(of: "MicrophoneSelection.shared.deviceIDForSession") else {
            return XCTFail("the recorder choice is not ordered")
        }
        XCTAssertLessThan(duplex.lowerBound, chosen.lowerBound, "Orb's echo-cancelling engine must take precedence")
    }

    func testBothMicButtonsOfferTheMenu() throws {
        XCTAssertTrue(try source("Devgentic/Interfaces/Shared/ChatInput/DynamicActionButton.swift").contains("MicrophoneMenu()"),
                      "the main composer's mic has no microphone menu")
        XCTAssertTrue(try source("Devgentic/Interfaces/Shared/ChatInput/ComposerKit.swift").contains(".contextMenu { MicrophoneMenu() }"),
                      "QuickAccess's mic has no microphone menu")
    }
}
