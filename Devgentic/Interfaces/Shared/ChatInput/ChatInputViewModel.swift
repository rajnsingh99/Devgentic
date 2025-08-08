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

/// Represents the state of the API key validation process.
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
    
    // MARK - Services
    private var whisperRecognitionService: WhisperRecognitionService?
    private let webSearchService = WebSearchService()
    
    // MARK: - Private State
    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatInputViewModel")
    private var recordingTimer: Timer?
    private let maxPowerLevelsToShow = 100 // Controls how many bars are shown in the waveform

    // MARK: - Initialization
    init() {
        logger.info("ChatInputViewModel initialized. Service will be created asynchronously.")
        
        Task {
            self.whisperRecognitionService = WhisperRecognitionService()
            await checkMicPermissions()
            
            // Observe the loading state of the recognition service.
            whisperRecognitionService?.$loadingState
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
    }
    
    // MARK: - Voice Input Control
    
    /// Toggles the voice input state, starting or stopping transcription.
    func toggleVoiceInput() {
        if audioEngine.isRunning {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }
    
    /// Stops recording and discards the audio without transcribing.
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

    // MARK: - State Management
    
    /// Updates the view model's state based on the model loading progress.
    private func handleModelLoadingState(_ state: ModelLoadingState) {
        switch state {
        case .idle:
            self.voiceInputState = .idle
        case .downloading:
            self.voiceInputState = .modelLoading
        case .preparing:
            self.voiceInputState = .modelPreparing
        case .loaded:
            if !audioEngine.isRunning {
                self.voiceInputState = .available
            }
        case .error(let message):
            self.voiceInputState = .error(message)
        }
    }
    
    /// Checks for microphone permissions and updates the state accordingly.
    private func checkMicPermissions() async {
        self.voiceInputState = .requestingPermissions
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Transcription Lifecycle

    /// Starts recording audio and buffering it in memory.
    private func startRecording() {
        logger.log("Attempting to start recording...")
        guard whisperRecognitionService?.loadingState == .loaded else {
            self.voiceInputState = .error("Model not ready.")
            logger.error("startRecording failed: WhisperKit model is not in a loaded state.")
            return
        }
        
        self.voiceInputState = .recording
        self.userInput = ""
        self.audioBuffer = []
        self.audioPowerLevels = Array(repeating: 0.0, count: maxPowerLevelsToShow) // Start with a full bar of zeros
        self.recordingTime = 0.0

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        logger.log("Audio engine input format: \(inputFormat)")
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            self.processAudioBuffer(buffer)
        }
        
        do {
            try audioEngine.start()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.recordingTime += 0.1
            }
            logger.log("Audio engine and recording timer started successfully.")
        } catch {
            self.voiceInputState = .error("Audio engine failed to start.")
            logger.error("Could not start audio engine: \(error.localizedDescription)")
        }
    }

    /// Stops recording and sends the complete audio buffer for transcription.
    private func stopRecordingAndTranscribe() {
        logger.log("Stopping recording and initiating transcription...")
        guard audioEngine.isRunning else {
            logger.warning("stopRecordingAndTranscribe called but audio engine is not running.")
            return
        }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        guard !audioBuffer.isEmpty else {
            self.voiceInputState = .available
            logger.warning("stopRecordingAndTranscribe called with an empty audio buffer. No action taken.")
            return
        }
        
        self.voiceInputState = .processing
        
        let capturedAudio = audioBuffer
        let originalSampleRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        self.audioBuffer = [] // Clear buffer immediately

        Task {
            do {
                logger.log("Starting audio conversion from \(originalSampleRate)Hz to 16000Hz.")
                guard let convertedAudio = await AudioConverter.resample(audio: capturedAudio, from: originalSampleRate, to: 16000) else {
                    self.voiceInputState = .error("Audio conversion failed.")
                    logger.error("Failed to resample audio buffer.")
                    return
                }
                logger.log("Audio conversion successful. New sample count: \(convertedAudio.count).")
                
                logger.log("Passing converted audio to transcription service...")
                if let transcript = try await whisperRecognitionService?.transcribe(audioArray: convertedAudio) {
                    self.userInput = transcript
                    logger.log("Transcription successful. Result: '\(transcript)'")
                } else {
                    logger.warning("Transcription returned nil.")
                }
                self.voiceInputState = .available
            } catch {
                self.voiceInputState = .error("Transcription failed.")
                logger.error("Transcription service failed with error: \(error.localizedDescription)")
            }
        }
    }
    
    // --- ADDED: Helper methods for audio power calculation ---
    
    /// Processes the incoming audio buffer to extract power levels for the waveform and data for transcription.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        // Data for transcription
        let channelDataArray = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        self.audioBuffer.append(contentsOf: channelDataArray)
        
        // Calculate power for waveform
        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(rms)
        let normalizedPower = self.normalizePowerLevel(level: avgPower)
        
        // Update the power levels on the main thread
        DispatchQueue.main.async {
            self.audioPowerLevels.append(normalizedPower)
            // Keep the array at a fixed size to create a scrolling effect
            if self.audioPowerLevels.count > self.maxPowerLevelsToShow {
                self.audioPowerLevels.removeFirst()
            }
        }
    }

    /// Normalizes the audio power level (in dB) to a 0-1 range for the waveform view.
    private func normalizePowerLevel(level: Float) -> Float {
        let minDb: Float = -60.0 // The quietest sound we want to register, anything below is 0
        
        // If the level is below our minimum, return 0
        if level < minDb { return 0.0 }
        
        // Scale the decibel level to a 0-1 range.
        // We use a denominator of `abs(minDb)` because the loudest sound is 0 dB.
        return min(1.0, level / abs(minDb) + 1.0)
    }
    
    // MARK: - Web Search API Key Management (UI State)
    
    /// Initiates the validation process for the API key entered by the user.
    func validateEnteredAPIKey() async {
        guard !apiKeyInput.isEmpty else { return }
        
        logger.info("Starting validation for the entered API key.")
        self.validationState = .validating
        
        let (isValid, message) = await webSearchService.validate(apiKey: self.apiKeyInput)
        
        if isValid {
            self.validationState = .valid
            logger.info("API Key validation successful.")
        } else {
            self.validationState = .invalid(message)
            logger.warning("API Key validation failed: \(message)")
        }
    }
    
    /// Resets the state of the API key input popup, typically called on dismiss.
    func resetAPIKeyPopupState() {
        logger.debug("Resetting API key popup state.")
        apiKeyInput = ""
        validationState = .idle
        showAPIKeyInputPopup = false
    }
}

// MARK: - Audio Converter Helper

/// A helper struct to handle audio resampling.
struct AudioConverter {
    /// Resamples an array of audio floats from an input sample rate to an output sample rate.
    static func resample(audio: [Float], from inputSampleRate: Double, to outputSamplerate: Double) async -> [Float]? {
        guard inputSampleRate != outputSamplerate else {
            return audio
        }

        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSamplerate, channels: 1, interleaved: false) else {
            print("Error: Could not create AVAudioFormat instances.")
            return nil
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("Error: Could not create AVAudioConverter.")
            return nil
        }

        let inputFrameCount = AVAudioFrameCount(audio.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            print("Error: Could not create input AVAudioPCMBuffer.")
            return nil
        }
        inputBuffer.frameLength = inputFrameCount
        let channelData = inputBuffer.floatChannelData![0]
        channelData.initialize(from: audio, count: audio.count)

        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * (outputSamplerate / inputSampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            print("Error: Could not create output AVAudioPCMBuffer.")
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("Audio conversion failed with error: \(error.localizedDescription)")
            return nil
        }
        
        guard status == .endOfStream || status == .haveData else {
            print("Audio conversion did not complete as expected. Status: \(status.rawValue)")
            return nil
        }

        let resampledData = [Float](UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)))
        
        return resampledData
    }
}
