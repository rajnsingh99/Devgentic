//
//  JarvisTapAdapter.swift
//  Devgentic
//
//  [Phase 4b] Turns raw microphone tap buffers into the format a recognizer wants, and — the
//  reason this type exists — NAMES the reason whenever it cannot.
//
//  WHY THIS EXISTS. The first duplex device run produced a perfectly healthy-looking session that
//  heard nothing:
//
//      [JARVIS_AUDIO] Duplex engine STARTED — voiceProcessing: true, tap: 16000 Hz / 3 ch
//      [JARVIS_ASR]   Mic session closed — audio: NONE, heard 0 word(s).
//
//  Nothing in between said whether the tap fired at all. Both recognizers dropped buffers through
//  bare `try?` / `guard … else { return }` on a real-time thread, so "engine running, zero
//  samples" had at least four indistinguishable causes. Every drop is now counted and the first of
//  each kind is logged with its consequence.
//
//  THE TWO SUBSTANTIVE FIXES, both aimed at what that run actually showed:
//
//   1. THE FORMAT IS READ FROM THE BUFFER, NOT PREDICTED. The old code read
//      `inputNode.outputFormat(forBus: 0)` before `engine.start()` and built both the tap and the
//      converter from it. The CoreAudio log shows voice processing still renegotiating AFTER that
//      read — `AUVPAggregate: Timeout waiting for streams`, then `AUHalStreamFormats are invalid`
//      with the channel count flapping 3 → 2 → 1 across successive attempts. A converter built
//      from a stale format silently produces nothing. Here the converter is built lazily from the
//      FIRST REAL BUFFER and rebuilt if the format ever changes mid-session, so renegotiation is
//      survivable instead of fatal.
//
//   2. MULTICHANNEL IS DOWNMIXED EXPLICITLY. That machine's voice-processing tap delivers THREE
//      channels (a built-in mic array). `AVAudioConverter` will happily be constructed for an
//      exotic 3-channel layout and then produce zero frames, which is indistinguishable from a
//      dead microphone. Anything above mono is folded down with WhisperKit's own `convertToMono`
//      first, so the converter only ever sees mono → target.
//
//  ⚠️ `adapt(_:)` runs on the real-time audio thread. It takes a lock and logs, both of which are
//  technically forbidden there. This is deliberate and bounded: the lock is uncontended in steady
//  state, and logging is rate-limited to the first occurrence of each cause plus every 500th
//  after. A dropped audio frame is recoverable; a subsystem that cannot say why it is deaf is not.
//

import Foundation
import AVFoundation
import WhisperKit

final class JarvisTapAdapter {

    /// Why a buffer did not reach the recognizer. Each case is counted separately because they
    /// have completely different fixes.
    enum Drop: String {
        case downmixFailed = "multichannel downmix returned nil"
        case noConverter = "no converter could be built for this format"
        case conversionFailed = "sample-rate conversion failed"
        case emptyResult = "conversion produced zero frames"
    }

    struct Stats {
        var callbacks = 0
        var delivered = 0
        var drops: [Drop: Int] = [:]
        var firstBufferFormat = "none"
        var formatChanges = 0

        var sawAudio: Bool { callbacks > 0 }
    }

    /// Log the first occurrence of a cause, then one in every 500 — enough to show a drop is
    /// ongoing without flooding a real-time thread.
    private static let repeatLogInterval = 500

    private let target: AVAudioFormat
    private let predicted: AVAudioFormat
    private let tag: String
    private let logger: DGLogger

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var stats = Stats()

    /// - Parameters:
    ///   - predicted: the format read before the engine started. Kept ONLY so the first real
    ///     buffer can be compared against it — a mismatch is the signature of fix #1 above.
    ///   - target: what the recognizer needs.
    init(predicted: AVAudioFormat, target: AVAudioFormat, tag: String, logger: DGLogger) {
        self.predicted = predicted
        self.target = target
        self.tag = tag
        self.logger = logger
    }

    var snapshot: Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Converts one tap buffer into `target`, or returns nil having recorded exactly why.
    func adapt(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        stats.callbacks += 1
        let isFirst = stats.callbacks == 1
        lock.unlock()

        if isFirst {
            let actual = "\(Int(buffer.format.sampleRate)) Hz / \(buffer.format.channelCount) ch"
            lock.lock(); stats.firstBufferFormat = actual; lock.unlock()
            let expected = "\(Int(predicted.sampleRate)) Hz / \(predicted.channelCount) ch"
            if actual == expected {
                logger.notice("\(self.tag) First tap buffer: \(actual) — matches the pre-start read. Converting to \(Int(self.target.sampleRate)) Hz / \(self.target.channelCount) ch.")
            } else {
                // The exact renegotiation this class was written for. Not an error: the lazy
                // converter below absorbs it. Logged loudly because a fixed-format tap would be
                // silently deaf right here.
                logger.notice("\(self.tag) First tap buffer: \(actual), but the pre-start read said \(expected). Voice processing renegotiated the device after the format was read; the converter is built from the buffer, so capture continues.")
            }
        }

        // Fold a mic array down before the converter ever sees it — an exotic channel layout is
        // where AVAudioConverter succeeds at construction and then yields zero frames.
        let mono: AVAudioPCMBuffer
        if buffer.format.channelCount > 1 {
            guard let folded = AudioProcessor.convertToMono(buffer, mode: .sumChannels(nil)) else {
                record(.downmixFailed)
                return nil
            }
            mono = folded
        } else {
            mono = buffer
        }

        guard let converter = converter(for: mono.format) else {
            record(.noConverter)
            return nil
        }

        guard let converted = try? AudioProcessor.resampleBuffer(mono, with: converter) else {
            record(.conversionFailed)
            return nil
        }
        guard converted.frameLength > 0 else {
            record(.emptyResult)
            return nil
        }

        lock.lock(); stats.delivered += 1; lock.unlock()
        return converted
    }

    /// One line describing what the tap actually did. Called at teardown so a session that heard
    /// nothing says which stage ate the audio.
    func summary() -> String {
        let s = snapshot
        guard s.callbacks > 0 else {
            return "tap fired 0 times — the engine started but CoreAudio delivered no buffers at all (device contention or a wedged coreaudiod, NOT a format problem)"
        }
        let dropText = s.drops.isEmpty
            ? "no drops"
            : s.drops.map { "\($0.value)× \($0.key.rawValue)" }.sorted().joined(separator: ", ")
        return "tap fired \(s.callbacks)×, delivered \(s.delivered), first buffer \(s.firstBufferFormat), format changes \(s.formatChanges) — \(dropText)"
    }

    // MARK: - Private

    /// Built lazily from a real buffer and rebuilt on any format change, so mid-session voice
    /// processing renegotiation costs one buffer instead of the whole session.
    private func converter(for input: AVAudioFormat) -> AVAudioConverter? {
        lock.lock(); defer { lock.unlock() }
        if let converter, converterInput == input { return converter }
        if converterInput != nil {
            stats.formatChanges += 1
            logger.notice("\(self.tag) Tap format changed mid-session to \(Int(input.sampleRate)) Hz / \(input.channelCount) ch — rebuilding the converter. CONSEQUENCE: one buffer is lost; capture continues.")
        }
        let built = AVAudioConverter(from: input, to: target)
        if built == nil {
            logger.error("\(self.tag) No AVAudioConverter from \(Int(input.sampleRate)) Hz / \(input.channelCount) ch to \(Int(self.target.sampleRate)) Hz / \(self.target.channelCount) ch. CONSEQUENCE: this session is permanently deaf — every buffer will be dropped.")
        }
        converter = built
        converterInput = built == nil ? nil : input
        return built
    }

    private func record(_ drop: Drop) {
        lock.lock()
        let count = (stats.drops[drop] ?? 0) + 1
        stats.drops[drop] = count
        let delivered = stats.delivered
        lock.unlock()

        guard count == 1 || count % Self.repeatLogInterval == 0 else { return }
        if count == 1 {
            logger.error("\(self.tag) Tap buffer dropped — \(drop.rawValue). CONSEQUENCE: this audio never reaches the recognizer; if it repeats the session hears nothing.")
        } else {
            logger.error("\(self.tag) Tap buffer dropped — \(drop.rawValue) (\(count)× so far, \(delivered) delivered). CONSEQUENCE: capture is degraded or dead.")
        }
    }
}
