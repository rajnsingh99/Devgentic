//
//  ChatInputViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 21/07/25.
//

import SwiftUI
import Combine
import AVFoundation
import os
import WhisperKit
import AppKit
import Accelerate

// MARK: - Protocols for Dependency Injection

protocol RecognitionServiceProtocol {
    var loadingState: ModelLoadingState { get }
    var loadingStatePublisher: AnyPublisher<ModelLoadingState, Never> { get }
    func transcribe(audioArray: [Float]) async throws -> String?
}

protocol WebSearchServiceProtocol {
    func validate(apiKey: String) async -> (isValid: Bool, message: String)
}

protocol PromptServiceProtocol {
    func getAllPrompts() -> [DevPrompt]
}

// MARK: - Service Conformance Extensions

extension WhisperRecognitionService: RecognitionServiceProtocol {
    var loadingStatePublisher: AnyPublisher<ModelLoadingState, Never> {
        $loadingState.eraseToAnyPublisher()
    }
}

extension WebSearchService: WebSearchServiceProtocol {}
extension PromptService: PromptServiceProtocol {}

// MARK: - State Structures

struct PromptSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [DevPrompt] = []
    var triggerRange: NSRange? = nil
    var selectedID: DevPrompt.ID? = nil
}

struct FileSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [FileSystemItem] = []
    var triggerRange: NSRange? = nil
    var selectedID: FileSystemItem.ID? = nil
    var multiSelectedIDs: Set<FileSystemItem.ID> = []
}

enum ValidationState {
    case idle
    case validating
    case valid
    case invalid(String)
}

@MainActor
class ChatInputViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var userInput: String = ""
    @Published var voiceInputState: VoiceInputState = .idle
    @Published var recordingTime: TimeInterval = 0.0
    @Published var audioPowerLevels: [Float] = []
    @Published var showAPIKeyInputPopup: Bool = false
    @Published var apiKeyInput: String = ""
    @Published var validationState: ValidationState = .idle
    
    // MARK: - Published Properties (Suggestions)
    @Published var promptSuggestionState = PromptSuggestionState()
    @Published var fileSuggestionState = FileSuggestionState()
    @Published var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    // MARK: - Delegates
    var onFileSearchRequest: ((String) -> (candidates: [FileSystemItem], attached: [FileSystemItem]))?
    
    // MARK: - Services
    private var recognitionService: RecognitionServiceProtocol?
    private let webSearchService: WebSearchServiceProtocol
    private let promptService: PromptServiceProtocol
    
    // MARK: - Private State
    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatInputViewModel")
    private var recordingTimer: Timer?
    private let maxPowerLevelsToShow = 100
    
    // MARK: - Optimized Components (Phase 3)
    private let audioConverter = AudioConverter() // Persistent Actor
    
    // MARK: - Async Task Handles
    private var searchTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?
    
    // MARK: - Initialization
    init(
        recognitionService: RecognitionServiceProtocol? = nil,
        webSearchService: WebSearchServiceProtocol = WebSearchService(),
        promptService: PromptServiceProtocol = PromptService.shared
    ) {
        logger.info("ChatInputViewModel initialized.")
        
        self.webSearchService = webSearchService
        self.promptService = promptService
        
        if let injectedService = recognitionService {
            self.recognitionService = injectedService
        } else {
            self.recognitionService = WhisperRecognitionService()
        }
        
        setupSuggestionPipelines()
        
        Task {
            await checkMicPermissions()
            self.recognitionService?.loadingStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newState in
                    self?.handleModelLoadingState(newState)
                }
                .store(in: &cancellables)
        }
    }

    deinit {
        logger.info("ChatInputViewModel deinitialized.")
        recordingTimer?.invalidate()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        searchTask?.cancel()
        fileSearchTask?.cancel()
    }
    
    // MARK: - Suggestion Pipelines (Debounced)
    
    private func setupSuggestionPipelines() {
        $promptSuggestionState
            .map(\.query)
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] newQuery in
                self?.performAsyncPromptFilter(query: newQuery)
            }
            .store(in: &cancellables)
            
        $fileSuggestionState
            .map(\.query)
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] newQuery in
                self?.performFileSearch(query: newQuery)
            }
            .store(in: &cancellables)
    }
    
    private func performAsyncPromptFilter(query: String) {
        searchTask?.cancel()
        let service = self.promptService
        
        searchTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }
            
            let allPrompts = service.getAllPrompts()
            let filtered = allPrompts.filter {
                query.isEmpty || $0.title.lowercased().contains(query.lowercased())
            }
            
            if Task.isCancelled { return }
            
            await MainActor.run { [weak self] in
                self?.promptSuggestionState.filteredItems = filtered
                self?.ensurePromptSelection()
            }
        }
    }
    
    private func performFileSearch(query: String) {
        guard let context = onFileSearchRequest?(query) else { return }
        processFileCandidates(context.candidates, attachedFiles: context.attached)
    }
    
    func processFileCandidates(_ candidates: [FileSystemItem], attachedFiles: [FileSystemItem]) {
        fileSearchTask?.cancel()
        
        fileSearchTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }
            
            let attachedIDs = Set(attachedFiles.map { $0.id })
            let filtered = candidates.filter { !attachedIDs.contains($0.id) }
            
            if Task.isCancelled { return }
            
            await MainActor.run { [weak self] in
                self?.fileSuggestionState.filteredItems = filtered
                self?.ensureFileSelection()
            }
        }
    }
    
    // MARK: - Selection Helpers
    
    private func ensurePromptSelection() {
        if promptSuggestionState.selectedID == nil ||
            !promptSuggestionState.filteredItems.contains(where: { $0.id == promptSuggestionState.selectedID }) {
            promptSuggestionState.selectedID = promptSuggestionState.filteredItems.first?.id
        }
    }
    
    private func ensureFileSelection() {
        if fileSuggestionState.selectedID == nil ||
            !fileSuggestionState.filteredItems.contains(where: { $0.id == fileSuggestionState.selectedID }) {
            fileSuggestionState.selectedID = fileSuggestionState.filteredItems.first?.id
        }
    }
    
    // MARK: - Actions (View Triggers)
    
    func selectPrompt(_ prompt: DevPrompt) {
        guard let range = promptSuggestionState.triggerRange else { return }
        logger.log("Prompt selected: '\(prompt.title)'")
        
        let insertionText = NSAttributedString(string: prompt.text + " ", attributes: defaultTypingAttributes)
        self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)

        resetPromptState()
    }
    
    func selectFile(_ file: FileSystemItem) -> FileSystemItem {
        if let range = fileSuggestionState.triggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }
        resetFileState()
        return file
    }
    
    func selectMultipleFiles(_ files: [FileSystemItem]) {
        if let range = fileSuggestionState.triggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }
        resetFileState()
    }
    
    func navigateSuggestions(direction: ChatInputAreaView.SuggestionNavigationDirection, type: TextTriggerAnalyzer.TriggerType) {
        switch type {
        case .prompt:
            navigateGeneric(
                items: promptSuggestionState.filteredItems,
                selectedID: &promptSuggestionState.selectedID,
                direction: direction
            )
        case .file:
            navigateGeneric(
                items: fileSuggestionState.filteredItems,
                selectedID: &fileSuggestionState.selectedID,
                direction: direction
            )
        }
    }
    
    private func navigateGeneric<T: Identifiable>(items: [T], selectedID: inout T.ID?, direction: ChatInputAreaView.SuggestionNavigationDirection) {
        guard !items.isEmpty else { return }
        
        guard let currentId = selectedID,
              let currentIndex = items.firstIndex(where: { $0.id == currentId }) else {
            selectedID = items.first?.id
            return
        }
        
        var nextIndex: Int
        switch direction {
        case .up: nextIndex = currentIndex - 1 < 0 ? items.count - 1 : currentIndex - 1
        case .down: nextIndex = currentIndex + 1 >= items.count ? 0 : currentIndex + 1
        }
        selectedID = items[nextIndex].id
    }
    
    private func resetPromptState() {
        promptSuggestionState.isShowing = false
        promptSuggestionState.query = ""
        promptSuggestionState.triggerRange = nil
        promptSuggestionState.filteredItems = []
        searchTask?.cancel()
    }
    
    private func resetFileState() {
        fileSuggestionState.isShowing = false
        fileSuggestionState.query = ""
        fileSuggestionState.triggerRange = nil
        fileSuggestionState.filteredItems = []
        fileSuggestionState.multiSelectedIDs = []
        fileSearchTask?.cancel()
    }

    // MARK: - Typography Helpers
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }
    
    // MARK: - Voice Input Control
    func toggleVoiceInput() {
        if audioEngine.isRunning {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }
    
    func cancelRecording() {
        logger.log("Cancelling recording.")
        guard audioEngine.isRunning else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioBuffer = []
        recordingTime = 0.0
        audioPowerLevels = []
        userInput = ""
        voiceInputState = .available
    }

    // MARK: - State Management (Internal)
    private func handleModelLoadingState(_ state: ModelLoadingState) {
        switch state {
        case .idle: self.voiceInputState = .idle
        case .downloading: self.voiceInputState = .modelLoading
        case .preparing: self.voiceInputState = .modelPreparing
        case .loaded: if !audioEngine.isRunning { self.voiceInputState = .available }
        case .error(let message): self.voiceInputState = .error(message)
        }
    }
    
    private func checkMicPermissions() async {
        self.voiceInputState = .requestingPermissions
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Transcription Lifecycle
    private func startRecording() {
        logger.log("Attempting to start recording...")
        guard recognitionService?.loadingState == .loaded else {
            self.voiceInputState = .error("Model not ready.")
            return
        }
        
        self.voiceInputState = .recording
        self.userInput = ""
        self.audioBuffer = []
        self.audioPowerLevels = Array(repeating: 0.0, count: maxPowerLevelsToShow)
        self.recordingTime = 0.0

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try audioEngine.start()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.recordingTime += 0.1
            }
        } catch {
            self.voiceInputState = .error("Audio engine failed to start.")
            logger.error("Could not start audio engine: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard audioEngine.isRunning else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        guard !audioBuffer.isEmpty else {
            self.voiceInputState = .available
            return
        }
        
        self.voiceInputState = .processing
        let capturedAudio = audioBuffer
        let originalSampleRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        self.audioBuffer = []

        Task {
            do {
                // Using persistent actor for conversion
                guard let convertedAudio = await audioConverter.resample(audio: capturedAudio, from: originalSampleRate, to: 16000) else {
                    self.voiceInputState = .error("Audio conversion failed.")
                    return
                }
                
                if let transcript = try await recognitionService?.transcribe(audioArray: convertedAudio) {
                    self.userInput = transcript
                }
                self.voiceInputState = .available
            } catch {
                self.voiceInputState = .error("Transcription failed.")
            }
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let ptr = channelData[0]
        let count = Int(buffer.frameLength)
        
        let bufferPointer = UnsafeBufferPointer(start: ptr, count: count)
        self.audioBuffer.append(contentsOf: bufferPointer)
        
        // High-Performance vDSP
        var rms: Float = 0
        vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
        
        let avgPower = 20 * log10(rms)
        let normalizedPower = self.normalizePowerLevel(level: avgPower)
        
        DispatchQueue.main.async {
            self.audioPowerLevels.append(normalizedPower)
            if self.audioPowerLevels.count > self.maxPowerLevelsToShow {
                self.audioPowerLevels.removeFirst()
            }
        }
    }

    private func normalizePowerLevel(level: Float) -> Float {
        let minDb: Float = -60.0
        if level < minDb { return 0.0 }
        return min(1.0, level / abs(minDb) + 1.0)
    }
    
    // MARK: - API Key Validation
    func validateEnteredAPIKey() async {
        guard !apiKeyInput.isEmpty else { return }
        self.validationState = .validating
        let (isValid, message) = await webSearchService.validate(apiKey: self.apiKeyInput)
        if isValid { self.validationState = .valid }
        else { self.validationState = .invalid(message) }
    }
    
    func resetAPIKeyPopupState() {
        apiKeyInput = ""
        validationState = .idle
        showAPIKeyInputPopup = false
    }
}

// MARK: - Persistent Audio Converter Actor
actor AudioConverter {
    private var converter: AVAudioConverter?
    private var cachedInputSampleRate: Double?
    private var cachedOutputSampleRate: Double?

    func resample(audio: [Float], from inputSampleRate: Double, to outputSampleRate: Double) -> [Float]? {
        // Bypass if rates match
        if inputSampleRate == outputSampleRate { return audio }

        // Reuse converter if format hasn't changed
        if converter == nil || cachedInputSampleRate != inputSampleRate || cachedOutputSampleRate != outputSampleRate {
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false) else {
                return nil
            }
            
            // Expensive operation, now done only when necessary
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            
            self.converter = newConverter
            self.cachedInputSampleRate = inputSampleRate
            self.cachedOutputSampleRate = outputSampleRate
        }
        
        guard let converter = self.converter else { return nil }

        // Perform Conversion
        let inputFrameCount = AVAudioFrameCount(audio.count)
        
        // Note: Recreating these buffers is relatively cheap compared to the converter init
        // but could be optimized further if buffer sizes were constant.
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: inputFrameCount) else { return nil }
        inputBuffer.frameLength = inputFrameCount
        let channelData = inputBuffer.floatChannelData![0]
        channelData.initialize(from: audio, count: audio.count)

        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * (outputSampleRate / inputSampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil || (status != .endOfStream && status != .haveData) { return nil }
        
        return [Float](UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)))
    }
}
