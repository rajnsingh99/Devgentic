//
//  SpeechService.swift
//  Devgentic
//
//  Provides text-to-speech using AVSpeechSynthesizer.
//  Supports segment-based playback: speaks text, then opens code blocks
//  in the Code Viewer panel before continuing.
//

import AVFoundation
import os

private let logger = DGLogger(category: "SpeechService")

// MARK: - Notifications

extension Notification.Name {
    /// Fired when all segments for a message have finished speaking.
    static let speechDidFinish = Notification.Name("SpeechServiceDidFinish")

    /// Fired when speech encounters a code block and wants it opened in the Code Viewer.
    /// `userInfo` contains `"language"` (String?) and `"code"` (String).
    static let speechOpenCodeViewer = Notification.Name("SpeechServiceOpenCodeViewer")
}

// MARK: - Speech Segment

/// Represents a segment of agent response content for sequential speech playback.
enum SpeechSegment: Equatable {
    /// Cleaned prose text to be spoken.
    case text(String)
    /// A code block encountered in the response — language and code content.
    case codeBlock(language: String?, code: String)
}

// MARK: - Voice Info

/// A user-friendly representation of an available system voice.
struct VoiceInfo: Identifiable, Hashable {
    let id: String // AVSpeechSynthesisVoice.identifier
    let name: String
    let locale: String
}

// MARK: - SpeechService

/// A singleton wrapper around AVSpeechSynthesizer that speaks agent responses
/// segment by segment. When a code block is encountered, it announces it, opens the Code Viewer,
/// and continues (or pauses if `pauseOnCode` is enabled).
@MainActor @Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    /// [V5] Created per playback session and RELEASED at stop/finish — not held for the
    /// app's lifetime. A live AVSpeechSynthesizer keeps a CoreAudio output context open,
    /// which is exactly the pattern the Jarvis notes document as wedging the microphone
    /// (`JarvisVoiceOutput` releases per-utterance for the same reason). Releasing when
    /// idle costs one lazy re-creation on the next Read Aloud.
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?

    /// Returns the live synthesizer, creating one if this is a fresh session.
    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        logger.info("[TTS] Synthesizer created (playback session starting).")
        return synth
    }

    /// [V5] Drops the synthesizer (and its CoreAudio output context). Only when idle —
    /// callers release at session end (stop / natural finish), never mid-session.
    private func releaseSynthesizer(reason: String) {
        guard synthesizer != nil else { return }
        synthesizer?.delegate = nil
        synthesizer = nil
        logger.info("[TTS] Synthesizer released (\(reason)) — CoreAudio output context freed.")
    }

    /// Test seam: whether a synthesizer (and its audio context) is currently held.
    var isSynthesizerLoaded: Bool { synthesizer != nil }

    // MARK: - State

    /// Whether a speech session is currently active (speaking or paused).
    private(set) var isActive: Bool = false

    /// Whether speech is currently paused (via user action or pause-on-code).
    private(set) var isPaused: Bool = false

    /// The index of the segment currently being spoken (1-based for display).
    private(set) var currentSegmentIndex: Int = 0

    /// Total number of segments in the current playback session.
    private(set) var totalSegmentCount: Int = 0

    /// The current speech rate multiplier (0.5, 1.0, 1.5, 2.0).
    private(set) var currentRate: Float = 1.0

    /// The currently selected voice identifier.
    private(set) var selectedVoice: String?

    /// Whether to pause playback when a code block is encountered (instead of auto-resuming).
    private(set) var pauseOnCode: Bool = false

    /// The message ID currently being spoken.
    private(set) var currentMessageID: UUID?

    // MARK: - Internal State

    /// The full list of segments for the current session (preserved for skip-backward).
    @ObservationIgnored private var allSegments: [SpeechSegment] = []

    /// Tracks the in-flight delayed Task (e.g., code-block pause) so it can be cancelled on stop().
    @ObservationIgnored private var pendingDelayTask: Task<Void, Never>?

    /// The index into `allSegments` of the segment currently being spoken.
    @ObservationIgnored private var playbackIndex: Int = 0

    /// Temporarily holds a code block waiting to be opened after the announcement finishes.
    private var pendingCodeBlock: (language: String?, code: String)?

    /// Available speed presets.
    static let speedPresets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: - Rate Mapping

    /// Maps the user-facing multiplier (0.5–2.0) to AVSpeechUtteranceRate range.
    /// AVSpeechUtteranceDefaultSpeechRate is ~0.5, min is 0.0, max is 1.0.
    private func avRate(for multiplier: Float) -> Float {
        AVSpeechUtteranceDefaultSpeechRate * multiplier
    }

    // MARK: - Init

    private override init() {
        let savedRate = UserDefaults.standard.float(forKey: AppSettings.speechPlaybackRateKey)
        let savedVoice = UserDefaults.standard.string(forKey: AppSettings.speechPlaybackVoiceKey)
        let savedPauseOnCode = UserDefaults.standard.bool(forKey: AppSettings.speechPauseOnCodeKey)

        super.init()

        if savedRate > 0 {
            currentRate = savedRate
        }
        selectedVoice = savedVoice
        pauseOnCode = savedPauseOnCode
    }

    // MARK: - Public API

    /// Starts segment-based speech for the given raw markdown text.
    func speak(_ rawText: String, messageID: UUID) {
        stop()

        let segments = SpeechService.parseSegments(from: rawText)
        guard !segments.isEmpty else { return }

        allSegments = segments
        playbackIndex = 0
        currentMessageID = messageID
        totalSegmentCount = segments.count
        currentSegmentIndex = 1
        isActive = true
        isPaused = false

        logger.info("Started reading aloud message \(messageID.uuidString) (\(segments.count) segments)")
        speakCurrentSegment()
    }

    /// Stops all speech and resets state.
    func stop() {
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Cancel any in-flight delayed task (e.g., code-block auto-resume sleep)
        pendingDelayTask?.cancel()
        pendingDelayTask = nil

        let previousID = currentMessageID

        allSegments.removeAll()
        playbackIndex = 0
        pendingCodeBlock = nil
        isActive = false
        isPaused = false
        currentSegmentIndex = 0
        totalSegmentCount = 0
        currentMessageID = nil

        if let id = previousID {
            logger.info("Stopped reading aloud message \(id.uuidString)")
            NotificationCenter.default.post(name: .speechDidFinish, object: id)
        }

        releaseSynthesizer(reason: "stop")
    }

    /// Pauses speech at the next word boundary.
    func pauseSpeaking() {
        guard isActive, !isPaused else { return }
        synthesizer?.pauseSpeaking(at: .word)
        isPaused = true
        logger.info("Paused speech")
    }

    /// Resumes paused speech.
    func resumeSpeaking() {
        guard isActive, isPaused else { return }
        isPaused = false

        if synthesizer?.isPaused == true {
            synthesizer?.continueSpeaking()
        } else {
            speakCurrentSegment()
        }
        logger.info("Resumed speech")
    }

    /// Toggles between paused and speaking states.
    func togglePause() {
        if isPaused {
            resumeSpeaking()
        } else {
            pauseSpeaking()
        }
    }

    /// Skips to the next segment.
    func skipForward() {
        guard isActive else { return }

        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pendingCodeBlock = nil
        isPaused = false

        playbackIndex += 1
        if playbackIndex < allSegments.count {
            currentSegmentIndex = playbackIndex + 1
            speakCurrentSegment()
        } else {
            finishPlayback()
        }
    }

    /// Skips back to the previous segment.
    func skipBackward() {
        guard isActive else { return }

        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pendingCodeBlock = nil
        isPaused = false

        if playbackIndex > 0 {
            playbackIndex -= 1
        }
        currentSegmentIndex = playbackIndex + 1
        speakCurrentSegment()
    }

    /// Sets the speech rate multiplier and persists it.
    func setRate(_ rate: Float) {
        currentRate = rate
        UserDefaults.standard.set(rate, forKey: AppSettings.speechPlaybackRateKey)
        logger.info("Speech rate set to \(rate)×")
    }

    /// Sets the voice and persists it.
    func setVoice(_ voiceID: String) {
        selectedVoice = voiceID
        UserDefaults.standard.set(voiceID, forKey: AppSettings.speechPlaybackVoiceKey)
        logger.info("Speech voice set to \(voiceID)")
    }

    /// Toggles the pause-on-code preference and persists it.
    func togglePauseOnCode() {
        pauseOnCode.toggle()
        UserDefaults.standard.set(pauseOnCode, forKey: AppSettings.speechPauseOnCodeKey)
        logger.info("Pause on code: \(self.pauseOnCode)")
    }

    /// Returns the list of available system voices with user-friendly names.
    private static let _cachedVoices: [VoiceInfo] = {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceInfo(
                id: voice.identifier,
                name: voice.name,
                locale: voice.language
            )
        }
    }()

    static var availableVoices: [VoiceInfo] { _cachedVoices }

    /// Whether the synthesizer is currently speaking audio.
    var isSpeaking: Bool {
        synthesizer?.isSpeaking ?? false
    }

    // MARK: - Segment Playback

    private func speakCurrentSegment() {
        guard playbackIndex < allSegments.count else {
            finishPlayback()
            return
        }

        let segment = allSegments[playbackIndex]

        switch segment {
        case .text(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                playbackIndex += 1
                currentSegmentIndex = playbackIndex + 1
                speakCurrentSegment()
            } else {
                let utterance = makeUtterance(text)
                ensureSynthesizer().speak(utterance)
            }

        case .codeBlock(let language, let code):
            let announcement = "Here is the code in the panel view."
            pendingCodeBlock = (language: language, code: code)
            let utterance = makeUtterance(announcement)
            ensureSynthesizer().speak(utterance)
        }
    }

    /// Creates an AVSpeechUtterance with current rate and voice settings.
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = avRate(for: currentRate)

        if let voiceID = selectedVoice,
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }

        return utterance
    }

    private func finishPlayback() {
        let messageID = currentMessageID

        allSegments.removeAll()
        playbackIndex = 0
        pendingCodeBlock = nil
        isActive = false
        isPaused = false
        currentSegmentIndex = 0
        totalSegmentCount = 0
        currentMessageID = nil

        if let id = messageID {
            NotificationCenter.default.post(name: .speechDidFinish, object: id)
        }

        releaseSynthesizer(reason: "playback finished")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleUtteranceFinished()
        }
    }

    /// Handles utterance completion on the main actor where all state lives.
    private func handleUtteranceFinished() {
        guard isActive else { return }

        // If there's a pending code block, open it now
        if let codeBlock = pendingCodeBlock {
            pendingCodeBlock = nil
            NotificationCenter.default.post(
                name: .speechOpenCodeViewer,
                object: self.currentMessageID,
                userInfo: [
                    "language": codeBlock.language as Any,
                    "code": codeBlock.code
                ]
            )

            if pauseOnCode {
                isPaused = true
                playbackIndex += 1
                if playbackIndex < allSegments.count {
                    currentSegmentIndex = playbackIndex + 1
                }
            } else {
                pendingDelayTask = Task { [weak self] in
                    guard let self, self.isActive else { return }
                    try? await Task.sleep(for: .seconds(1.0))
                    guard !Task.isCancelled, self.isActive else { return }
                    self.pendingDelayTask = nil
                    self.playbackIndex += 1
                    if self.playbackIndex < self.allSegments.count {
                        self.currentSegmentIndex = self.playbackIndex + 1
                    }
                    self.speakCurrentSegment()
                }
            }
            return
        }

        // Normal text segment finished — advance to next
        playbackIndex += 1
        if playbackIndex < allSegments.count {
            currentSegmentIndex = playbackIndex + 1
            speakCurrentSegment()
        } else {
            finishPlayback()
        }
    }

    // MARK: - Segment Parsing

    /// Parses raw markdown text into an ordered list of speech segments.
    /// Text segments have markdown syntax stripped. Code blocks are preserved for the viewer.
    static func parseSegments(from text: String) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var currentText = ""
        var currentCodeLines: [String] = []
        var codeLanguage: String?
        var insideCodeBlock = false

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if insideCodeBlock {
                    let code = currentCodeLines.joined(separator: "\n")
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let cleaned = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            segments.append(.text(cleaned))
                            currentText = ""
                        }
                        segments.append(.codeBlock(language: codeLanguage, code: code))
                    }
                    currentCodeLines = []
                    codeLanguage = nil
                    insideCodeBlock = false
                } else {
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = lang.isEmpty ? nil : lang
                    insideCodeBlock = true
                }
                continue
            }

            if insideCodeBlock {
                currentCodeLines.append(line)
            } else {
                currentText += cleanLineForSpeech(line) + "\n"
            }
        }

        let remaining = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            segments.append(.text(remaining))
        }

        return segments
    }

    /// Strips markdown syntax from a single line for natural speech.
    private static func cleanLineForSpeech(_ line: String) -> String {
        var cleaned = line
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#") {
            cleaned = trimmed.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        }

        cleaned = cleaned.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        return cleaned
    }

    // MARK: - Legacy

    /// Strips code blocks from text, replacing them with spoken markers.
    static func stripCodeBlocks(from text: String) -> String {
        let segments = parseSegments(from: text)
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text + "\n"
            case .codeBlock:
                result += "Code block.\n"
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
