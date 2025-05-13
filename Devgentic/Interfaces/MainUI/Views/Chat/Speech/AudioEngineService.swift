//
//  AudioEngineService.swift
//  Devgentic
//
//  Created by Raj Singh on 12/05/25.
//

import AVFoundation
import os // For logging

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AudioEngineService")

class AudioEngineService {

    // MARK: - Properties
    var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    @Published var isRecording: Bool = false

    // MARK: - Initialization
    init() {
        logger.info("AudioEngineService initialized.")
    }

    deinit {
        stopStreamingAudio() // Ensure engine is stopped on deinit
        logger.info("AudioEngineService deinitialized.")
    }

    // MARK: - Microphone Permission
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        logger.debug("Requesting microphone permission...")
        if #available(macOS 14.0, *) {
            // For macOS 14.0 and later, AVAudioApplication.requestRecordPermission shows the new style prompt.
            AVAudioApplication.requestRecordPermission { granted in
                logger.info("Microphone permission via AVAudioApplication (macOS 14+) granted: \(granted)")
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            // For macOS versions older than 14.0:
            // We check the current status. If .notDetermined, the system will prompt upon first actual use
            // of the microphone by AVAudioEngine. We cannot programmatically trigger that prompt here
            // and get its result in this completion handler in the same way as the newer API.
            logger.info("For macOS < 14.0, checking current AVCaptureDevice authorization status for .audio.")
            let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            var canProceedToPromptOrIsGranted = false

            switch currentStatus {
            case .authorized:
                logger.info("Microphone permission already .authorized on macOS < 14.")
                canProceedToPromptOrIsGranted = true
            case .notDetermined:
                // The system will prompt upon first actual use.
                // This function signals that the app can attempt to use the mic,
                // which will then trigger the OS-level prompt.
                logger.info("Microphone permission is .notDetermined on macOS < 14. System will prompt on first audio use. Allowing attempt.")
                canProceedToPromptOrIsGranted = true
            case .denied:
                logger.warning("Microphone permission .denied on macOS < 14.")
                canProceedToPromptOrIsGranted = false
            case .restricted:
                logger.warning("Microphone permission .restricted on macOS < 14.")
                canProceedToPromptOrIsGranted = false
            @unknown default:
                logger.error("Unknown microphone permission status on macOS < 14: \(currentStatus.rawValue)")
                canProceedToPromptOrIsGranted = false
            }
            DispatchQueue.main.async {
                completion(canProceedToPromptOrIsGranted)
            }
        }
    }

    // MARK: - Audio Streaming
    func startStreamingAudio(tapInstallHandler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRecording else {
            logger.warning("Audio streaming requested but already in progress.")
            return
        }

        logger.info("Starting audio streaming setup...")
        
        // Create a new audio engine instance each time we start, to ensure a clean state.
        let tempAudioEngine = AVAudioEngine()
        self.audioEngine = tempAudioEngine   // Assign to the class property
        
        inputNode = tempAudioEngine.inputNode
        guard let inputNode = inputNode else {
            logger.error("Audio engine has no input node.")
            self.audioEngine = nil // Clean up if input node is missing
            throw AudioEngineError.inputNodeMissing("Audio engine has no input node.")
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Ensure the recording format is valid (e.g., sample rate > 0)
        guard recordingFormat.sampleRate > 0 else {
            logger.error("Input node recording format has invalid sample rate: \(recordingFormat.sampleRate)")
            self.audioEngine = nil
            self.inputNode = nil
            throw AudioEngineError.invalidFormat("Input node has invalid recording format (sample rate: \(recordingFormat.sampleRate)).")
        }
        logger.debug("Input node recording format: \(recordingFormat)")

        // Install a tap on the input node to process audio buffers
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            tapInstallHandler(buffer, when)
        }
        logger.debug("Installed tap on input node.")

        tempAudioEngine.prepare() // Prepare the audio engine
        try tempAudioEngine.start() // Start the audio engine
        
        isRecording = true
        logger.info("Audio engine started successfully and is streaming.")
    }

    func stopStreamingAudio() {
        // Ensure we are recording and the engine/node are available
        guard isRecording, let currentAudioEngine = audioEngine, let inputNode = self.inputNode else {
            // logger.debug("Stop streaming audio called but not recording or engine/node nil.")
            return
        }
        
        logger.info("Stopping audio streaming...")
        
        currentAudioEngine.stop()
        inputNode.removeTap(onBus: 0) // Remove the tap
        
        // Release the audio engine instance and input node
        self.audioEngine = nil
        self.inputNode = nil
        
        isRecording = false
        logger.info("Audio streaming stopped and resources released.")
    }
}

// MARK: - Error Enum
enum AudioEngineError: Error, LocalizedError {
    case engineCreationFailure(String)
    case inputNodeMissing(String)
    case invalidFormat(String)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineCreationFailure(let message),
             .inputNodeMissing(let message),
             .invalidFormat(let message),
             .recordingFailed(let message):
            return message
        }
    }
}
