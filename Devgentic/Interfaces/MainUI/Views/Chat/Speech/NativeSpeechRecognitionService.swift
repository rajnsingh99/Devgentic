//
//  NativeSpeechRecognitionService.swift
//  Devgentic
//
//  Created by Raj Singh on 12/05/25.
//

// NativeSpeechRecognitionService.swift
import Speech
import AVFoundation // For AVAudioPCMBuffer
import os // For logging

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "NativeSpeechRecognitionService")

class NativeSpeechRecognitionService: NSObject, SFSpeechRecognizerDelegate {

    // MARK: - Properties
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    @Published var isRecognitionActive: Bool = false
    @Published var speechRecognizerAvailable: Bool = false

    // MARK: - Initialization
    override init() {
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        
        if self.speechRecognizer == nil {
            logger.error("SFSpeechRecognizer initialization failed for locale: \(Locale.current.identifier).")
        } else {
            logger.info("SFSpeechRecognizer initialized for locale: \(self.speechRecognizer!.locale.identifier)")
        }
        
        self.speechRecognizer?.delegate = self
        self.speechRecognizerAvailable = self.speechRecognizer?.isAvailable ?? false
        logger.info("Initial SFSpeechRecognizer availability: \(self.speechRecognizerAvailable)")
    }

    deinit {
        stopRecognition()
        logger.info("NativeSpeechRecognitionService deinitialized.")
    }
    
    // MARK: - SFSpeechRecognizerDelegate Methods
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async {
            self.speechRecognizerAvailable = available
            if available {
                logger.info("Speech recognizer availability changed: NOW AVAILABLE")
            } else {
                logger.warning("Speech recognizer availability changed: NOW UNAVAILABLE")
                if self.isRecognitionActive {
                    self.stopRecognition()
                }
            }
        }
    }

    // MARK: - Permission
    func requestSpeechRecognitionPermission(completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        logger.debug("Requesting speech recognition permission...")
        SFSpeechRecognizer.requestAuthorization { authStatus in
            logger.info("Speech recognition permission status: \(authStatus.rawValue)") // Raw value is Int
            DispatchQueue.main.async {
                completion(authStatus)
            }
        }
    }

    // MARK: - Recognition Control
    // MODIFIED: Removed unused 'audioEngine' parameter
    func startRecognition(recognitionHandler: @escaping (String, Bool, Error?) -> Void) throws {
        guard speechRecognizerAvailable else {
            logger.error("Cannot start recognition: Speech recognizer is not available.")
            throw SpeechRecognitionError.unavailable("Speech recognizer is not available.")
        }
        
        if recognitionTask != nil {
            logger.info("Recognition task already exists. Stopping previous task before starting new one.")
            stopRecognition()
        }

        logger.info("Starting speech recognition setup...")

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            logger.error("Failed to create SFSpeechAudioBufferRecognitionRequest.")
            throw SpeechRecognitionError.requestCreationFailed("Unable to create audio buffer recognition request.")
        }
        recognitionRequest.shouldReportPartialResults = true
        
        // On-device recognition can be configured here if needed and supported:
        // if #available(macOS 10.15, *) { recognitionRequest.requiresOnDeviceRecognition = true }

        guard let recognizer = self.speechRecognizer else {
             logger.error("Speech recognizer is nil, cannot start task.")
             throw SpeechRecognitionError.recognizerNotInitialized("Speech recognizer not initialized.")
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] (result, error) in
            guard let self = self else { return }
            
            var isFinal = false
            var currentTranscript = ""

            if let result = result {
                currentTranscript = result.bestTranscription.formattedString
                isFinal = result.isFinal
                logger.trace("Recognition result: '\(currentTranscript.prefix(30))', isFinal: \(isFinal)")
            }

            if error != nil || isFinal {
                logger.info("Recognition task processing ended. Error: \(error?.localizedDescription ?? "None"), Final: \(isFinal)")
                // This service only reports the end of this specific task.
                // The caller (ViewModel) is responsible for stopping the audio engine.
            }
            
            DispatchQueue.main.async {
                 recognitionHandler(currentTranscript, isFinal, error)
            }
            
            if error != nil || isFinal {
                // Clean up task and request objects as they are no longer needed for this session
                self.recognitionTask = nil
                self.recognitionRequest = nil
                self.isRecognitionActive = false // Mark as no longer actively processing new audio
            }
        }
        
        isRecognitionActive = true
        logger.info("Speech recognition task started successfully.")
    }
    
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecognitionActive, let request = self.recognitionRequest else {
            return
        }
        request.append(buffer)
    }

    func stopRecognition() {
        logger.info("Attempting to stop speech recognition (NativeSpeechRecognitionService)...")
        
        recognitionRequest?.endAudio()
        logger.debug("Signaled end of audio to recognition request.")

        recognitionTask?.cancel() // Cancel to stop immediately
        logger.debug("Recognition task cancelled.")
        
        recognitionRequest = nil
        recognitionTask = nil
        isRecognitionActive = false
        logger.info("Speech recognition stopped and resources cleared in NativeSpeechRecognitionService.")
    }
}

// MARK: - Error Enum
enum SpeechRecognitionError: Error, LocalizedError {
    case unavailable(String)
    case requestCreationFailed(String)
    case recognizerNotInitialized(String)
    // case recognitionFailed(String) // This might be too generic if errors are passed through

    var errorDescription: String? {
        switch self {
        case .unavailable(let message),
             .requestCreationFailed(let message),
             .recognizerNotInitialized(let message):
            return message
        }
    }
}
