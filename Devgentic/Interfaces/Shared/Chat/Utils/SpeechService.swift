//
//  SpeechService.swift
//  Devgentic
//
//  Provides text-to-speech using macOS NSSpeechSynthesizer.
//  Supports segment-based playback: speaks text, then opens code blocks
//  in the Code Viewer panel before continuing.
//

import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SpeechService")

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

/// A user-friendly representation of an available macOS voice.
struct VoiceInfo: Identifiable, Hashable {
    let id: String // NSSpeechSynthesizer.VoiceName raw value
    let name: String
    let locale: String
}

// MARK: - SpeechService

/// A singleton ObservableObject wrapper around NSSpeechSynthesizer that speaks agent responses
/// segment by segment. When a code block is encountered, it announces it, opens the Code Viewer,
/// and continues (or pauses if `pauseOnCode` is enabled).
@Observable
final class SpeechService: NSObject, NSSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    @ObservationIgnored private lazy var synthesizer: NSSpeechSynthesizer = {
        let synth = NSSpeechSynthesizer()
        synth.delegate = self
        synth.rate = baseRate * currentRate
        if let voice = selectedVoice {
            synth.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
        }
        return synth
    }()

    /// Whether the synthesizer has been lazily initialized.
    private var synthesizerInitialized: Bool = false

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

    /// The index into `allSegments` of the segment currently being spoken.
    @ObservationIgnored private var playbackIndex: Int = 0

    /// Temporarily holds a code block waiting to be opened after the announcement finishes.
    private var pendingCodeBlock: (language: String?, code: String)?

    /// The base rate from NSSpeechSynthesizer (words per minute) for 1× speed.
    private var baseRate: Float = 175

    /// Available speed presets.
    static let speedPresets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: - Init

    private override init() {
        // Load persisted preferences before calling super — do NOT touch synthesizer here
        let savedRate = UserDefaults.standard.float(forKey: AppSettings.speechPlaybackRateKey)
        let savedVoice = UserDefaults.standard.string(forKey: AppSettings.speechPlaybackVoiceKey)
        let savedPauseOnCode = UserDefaults.standard.bool(forKey: AppSettings.speechPauseOnCodeKey)

        super.init()

        // Store preferences (synthesizer is lazy — these are applied when it's first accessed)
        if savedRate > 0 {
            currentRate = savedRate
        }
        baseRate = 175
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

        // Apply current rate
        synthesizer.rate = baseRate * currentRate

        logger.info("Started reading aloud message \(messageID.uuidString) (\(segments.count) segments)")
        speakCurrentSegment()
    }

    /// Stops all speech and resets state.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }

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
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .speechDidFinish, object: id)
            }
        }
    }

    /// Pauses speech at the next sentence boundary.
    func pauseSpeaking() {
        guard isActive, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .sentenceBoundary)
        isPaused = true
        logger.info("Paused speech")
    }

    /// Resumes paused speech.
    func resumeSpeaking() {
        guard isActive, isPaused else { return }
        isPaused = false

        if synthesizer.isSpeaking {
            // Paused mid-sentence — continue from where we left off
            synthesizer.continueSpeaking()
        } else {
            // Paused between segments (e.g., pause-on-code) — speak next segment
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

        // Stop current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        pendingCodeBlock = nil
        isPaused = false

        // Advance to next segment
        playbackIndex += 1
        if playbackIndex < allSegments.count {
            currentSegmentIndex = playbackIndex + 1
            speakCurrentSegment()
        } else {
            // No more segments
            finishPlayback()
        }
    }

    /// Skips back to the previous segment.
    func skipBackward() {
        guard isActive else { return }

        // Stop current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        pendingCodeBlock = nil
        isPaused = false

        // Go back one segment (minimum index 0)
        if playbackIndex > 0 {
            playbackIndex -= 1
        }
        currentSegmentIndex = playbackIndex + 1
        speakCurrentSegment()
    }

    /// Sets the speech rate multiplier and persists it.
    func setRate(_ rate: Float) {
        currentRate = rate
        synthesizer.rate = baseRate * rate
        UserDefaults.standard.set(rate, forKey: AppSettings.speechPlaybackRateKey)
        logger.info("Speech rate set to \(rate)×")
    }

    /// Sets the voice and persists it.
    func setVoice(_ voiceID: String) {
        selectedVoice = voiceID
        synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceID))
        UserDefaults.standard.set(voiceID, forKey: AppSettings.speechPlaybackVoiceKey)
        logger.info("Speech voice set to \(voiceID)")
    }

    /// Toggles the pause-on-code preference and persists it.
    func togglePauseOnCode() {
        pauseOnCode.toggle()
        UserDefaults.standard.set(pauseOnCode, forKey: AppSettings.speechPauseOnCodeKey)
        logger.info("Pause on code: \(self.pauseOnCode)")
    }

    /// Returns the list of available macOS voices with user-friendly names.
    /// Cached voice list — queried from the system only once to avoid repeated AFLocalization warnings.
    private static let _cachedVoices: [VoiceInfo] = {
        NSSpeechSynthesizer.availableVoices.compactMap { voiceName in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceName)
            guard let name = attrs[.name] as? String else { return nil }
            let locale = (attrs[.localeIdentifier] as? String) ?? "unknown"
            return VoiceInfo(id: voiceName.rawValue, name: name, locale: locale)
        }
    }()

    static var availableVoices: [VoiceInfo] { _cachedVoices }

    /// Whether the synthesizer is currently speaking audio.
    var isSpeaking: Bool {
        synthesizer.isSpeaking
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
                // Skip empty text segments
                playbackIndex += 1
                currentSegmentIndex = playbackIndex + 1
                speakCurrentSegment()
            } else {
                synthesizer.startSpeaking(text)
            }

        case .codeBlock(let language, let code):
            // Announce the code block, then open it in the viewer
            let announcement = "Here is the code in the panel view."
            pendingCodeBlock = (language: language, code: code)
            synthesizer.startSpeaking(announcement)
        }
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
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .speechDidFinish, object: id)
            }
        }
    }

    // MARK: - NSSpeechSynthesizerDelegate

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard isActive else { return }

        // If there's a pending code block, open it now
        if let codeBlock = pendingCodeBlock {
            pendingCodeBlock = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .speechOpenCodeViewer,
                    object: self.currentMessageID,
                    userInfo: [
                        "language": codeBlock.language as Any,
                        "code": codeBlock.code
                    ]
                )
            }

            if pauseOnCode {
                // Pause and let the user resume manually
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPaused = true
                    // Advance index so resume goes to next segment
                    self.playbackIndex += 1
                    if self.playbackIndex < self.allSegments.count {
                        self.currentSegmentIndex = self.playbackIndex + 1
                    }
                }
            } else {
                // Brief pause before continuing (let the panel animate open)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.isActive else { return }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.playbackIndex += 1
            if self.playbackIndex < self.allSegments.count {
                self.currentSegmentIndex = self.playbackIndex + 1
                self.speakCurrentSegment()
            } else {
                self.finishPlayback()
            }
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
                    // Closing fence — flush the code block
                    let code = currentCodeLines.joined(separator: "\n")
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Flush any preceding text first
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
                    // Opening fence — extract language hint
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

        // Flush any remaining text
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

        // Strip heading markers
        if trimmed.hasPrefix("#") {
            cleaned = trimmed.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        }

        // Strip bold/italic markers
        cleaned = cleaned.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}", with: "$1", options: .regularExpression)

        // Strip inline code backticks
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        // Strip link syntax [text](url) -> text
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
