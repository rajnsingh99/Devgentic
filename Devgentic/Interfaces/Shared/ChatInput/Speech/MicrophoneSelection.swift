// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MicrophoneSelection.swift
//  Devgentic
//
//  Which microphone dictation records from (2026-09-27). Before this every session opened macOS's
//  DEFAULT input: WhisperKit's `AudioStreamTranscriber` calls `startRecordingLive` with no device,
//  and nothing above it passed one — the only way to change it was System Settings → Sound.
//
//  ⚠️ Remembered by device UID, never by `AudioDeviceID`. The numeric id is assigned per boot and
//  per plug-in; the UID is stable. It is resolved to an id at the moment a session starts.
//
//  ⚠️ Orb is NOT covered, deliberately. Its echo-cancelling engine (voice processing) builds its
//  own aggregate over the system default input; forcing another device onto it is unreliable, and
//  that engine has already been seen to go silent without throwing (OrbAudioProcessor's dead-tap
//  watchdog). Only a session on WhisperKit's own engine — the composer, QuickAccess, and Orb when
//  its duplex engine is off — uses the choice.
//

import Foundation
import SwiftUI
import CoreAudio
import AVFoundation
import CoreML
import WhisperKit
import os

private let logger = DGLogger(category: "Microphone")

/// An input device, as the picker shows it.
struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    /// This boot's CoreAudio id — what the recorder takes. Not stable; never stored.
    let id: AudioDeviceID
    /// Stable across reboots and re-plugging — what is stored.
    let uid: String
    let name: String
}

/// What a session will actually record from.
enum MicrophoneResolution: Equatable {
    /// No choice made: macOS's default input.
    case systemDefault
    case device(MicrophoneDevice)
    /// The chosen microphone is not connected. Recording falls back to the system default — said,
    /// not silent.
    case unavailable(uid: String, name: String?)

    /// The device to hand the recorder, or nil for the system default.
    var deviceID: AudioDeviceID? {
        if case .device(let device) = self { return device.id }
        return nil
    }
}

enum MicrophoneCatalog {

    /// Pure: the stored choice against what is connected now.
    static func resolve(selectedUID: String?, savedName: String?, available: [MicrophoneDevice]) -> MicrophoneResolution {
        guard let selectedUID, !selectedUID.isEmpty else { return .systemDefault }
        if let device = available.first(where: { $0.uid == selectedUID }) { return .device(device) }
        return .unavailable(uid: selectedUID, name: savedName)
    }

    /// Whether a device belongs in the picker. Voice processing creates hidden aggregate devices
    /// over the default input while Orb listens; those are plumbing, not microphones.
    static func isListable(uid: String, isHidden: Bool, inputChannels: Int) -> Bool {
        inputChannels > 0 && !isHidden && !uid.hasPrefix("CADefaultDeviceAggregate")
    }

    /// Every connected input device, in CoreAudio's order.
    static func inputDevices() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            logger.error("[MIC] Could not size the device list. CONSEQUENCE: the picker offers only the system default.")
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            logger.error("[MIC] Could not read the device list. CONSEQUENCE: the picker offers only the system default.")
            return []
        }
        return ids.compactMap(device(for:))
    }

    static func defaultInputDevice() -> MicrophoneDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return device(for: id)
    }

    private static func device(for id: AudioDeviceID) -> MicrophoneDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              isListable(uid: uid, isHidden: uint32(id, kAudioDevicePropertyIsHidden) == 1,
                         inputChannels: inputChannelCount(id)) else { return nil }
        return MicrophoneDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The app-wide choice, observed by the pickers and read when a dictation session starts.
@MainActor @Observable
final class MicrophoneSelection {

    static let shared = MicrophoneSelection()

    static let uidKey = "voice.inputDeviceUID"
    static let nameKey = "voice.inputDeviceName"

    private(set) var devices: [MicrophoneDevice] = []
    private(set) var systemDefault: MicrophoneDevice?
    private(set) var selectedUID: String?
    /// The chosen device's name, kept so "not connected" can still name it.
    private(set) var selectedName: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listening = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedUID = defaults.string(forKey: Self.uidKey)
        selectedName = defaults.string(forKey: Self.nameKey)
    }

    var resolution: MicrophoneResolution {
        MicrophoneCatalog.resolve(selectedUID: selectedUID, savedName: selectedName, available: devices)
    }

    /// `nil` = follow the system default.
    func select(_ device: MicrophoneDevice?) {
        selectedUID = device?.uid
        selectedName = device?.name
        if let device {
            defaults.set(device.uid, forKey: Self.uidKey)
            defaults.set(device.name, forKey: Self.nameKey)
        } else {
            defaults.removeObject(forKey: Self.uidKey)
            defaults.removeObject(forKey: Self.nameKey)
        }
        logger.notice("[MIC] Dictation input set to \(device.map { "'\($0.name)'" } ?? "the system default"). CONSEQUENCE: the next composer / QuickAccess session records from it; Orb's echo-cancelling engine still uses the system default.")
    }

    /// Re-reads the device list, and starts following plug/unplug and default changes the first
    /// time it is asked — so a mic connected while a menu is closed is there when it opens.
    func refresh() {
        devices = MicrophoneCatalog.inputDevices()
        systemDefault = MicrophoneCatalog.defaultInputDevice()
        startListeningIfNeeded()
    }

    /// The device for a session starting now, or nil for the system default. Logged with what it
    /// means, because "it recorded from the wrong mic" is otherwise unanswerable.
    func deviceIDForSession(_ tag: String) -> AudioDeviceID? {
        refresh()
        switch resolution {
        case .systemDefault:
            logger.info("[MIC] Session \(tag) records from the system default (\(self.systemDefault?.name ?? "unknown")).")
            return nil
        case .device(let device):
            logger.info("[MIC] Session \(tag) records from '\(device.name)'.")
            return device.id
        case .unavailable(_, let name):
            logger.notice("[MIC] Session \(tag): the chosen microphone '\(name ?? "?")' is not connected. CONSEQUENCE: recording from the system default (\(self.systemDefault?.name ?? "unknown")) instead; the choice is kept for when it returns.")
            return nil
        }
    }

    private func startListeningIfNeeded() {
        guard !listening else { return }
        listening = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.devices = MicrophoneCatalog.inputDevices()
                    self.systemDefault = MicrophoneCatalog.defaultInputDevice()
                }
            }
            if status != noErr {
                logger.error("[MIC] Could not follow device changes (\(status)). CONSEQUENCE: the list refreshes only when a menu opens or a session starts.")
            }
        }
    }
}

/// WhisperKit's recorder, pointed at a chosen input device.
///
/// ⚠️ Why a wrapper and not a fork: `AudioStreamTranscriber` calls `startRecordingLive` WITHOUT a
/// device, so the default input is baked in above the recorder. `AudioProcessing` is WhisperKit's
/// public seam (Orb's duplex engine uses it too); this forwards everything to the real recorder
/// and supplies the device only where the caller gave none.
final class InputDeviceAudioProcessor: AudioProcessing {

    private var base: any AudioProcessing
    let deviceID: DeviceID

    init(base: any AudioProcessing, deviceID: DeviceID) {
        self.base = base
        self.deviceID = deviceID
    }

    var audioSamples: ContiguousArray<Float> { base.audioSamples }
    var relativeEnergy: [Float] { base.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { base.relativeEnergyWindow }
        set { base.relativeEnergyWindow = newValue }
    }

    func purgeAudioSamples(keepingLast keep: Int) { base.purgeAudioSamples(keepingLast: keep) }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try base.startRecordingLive(inputDeviceID: inputDeviceID ?? deviceID, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        base.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? deviceID)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try base.resumeRecordingLive(inputDeviceID: inputDeviceID ?? deviceID, callback: callback)
    }

    func pauseRecording() { base.pauseRecording() }
    func stopRecording() { base.stopRecording() }

    // ⚠️ On the transcription HOT PATH (see OrbAudioProcessor): forwarded, never stubbed.
    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        base.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }
}

/// "Microphone ›" for a mic button's right-click menu. Shared by the main composer and every
/// `ComposerMicButton` surface so they cannot offer different lists.
struct MicrophoneMenu: View {
    @State private var selection = MicrophoneSelection.shared

    var body: some View {
        Menu("Microphone") {
            Toggle(isOn: Binding(get: { selection.selectedUID == nil },
                                 set: { if $0 { selection.select(nil) } })) {
                Text(Self.systemDefaultLabel(selection.systemDefault))
            }
            if !selection.devices.isEmpty { Divider() }
            ForEach(selection.devices) { device in
                Toggle(isOn: Binding(get: { selection.selectedUID == device.uid },
                                     set: { if $0 { selection.select(device) } })) {
                    Text(device.name)
                }
            }
            if case .unavailable(_, let name) = selection.resolution {
                Divider()
                Text(Self.unavailableLabel(name: name, fallback: selection.systemDefault))
            }
            Divider()
            Text("Orb with echo cancellation uses the system default")
        }
    }

    static func systemDefaultLabel(_ device: MicrophoneDevice?) -> String {
        device.map { "System Default (\($0.name))" } ?? "System Default"
    }

    static func unavailableLabel(name: String?, fallback: MicrophoneDevice?) -> String {
        "\(name ?? "Chosen microphone") — not connected, using \(fallback?.name ?? "the system default")"
    }
}
