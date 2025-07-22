//
//  ChatInputViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 21/07/25.
//

import SwiftUI
import Combine
import Speech
import AVFoundation
import os

@MainActor
class ChatInputViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var userInput: String = ""
    @Published var voiceInputState: VoiceInputState = .idle

    // MARK: - Services
    private let audioEngineService: AudioEngineService
    private let speechRecognitionService: NativeSpeechRecognitionService
    
    // MARK: - Private State
    private var prefixForCurrentUtterance: String = ""
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatInputViewModel")

    // MARK: - Initialization
    init(audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService()
    ) {
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        logger.info("ChatInputViewModel initialized.")
        
        // Asynchronously check permissions when the view model is created.
        Task {
            await checkVoiceInputPermissionsAndAvailability()
        }
    }

    deinit {
        logger.info("ChatInputViewModel deinitialized.")
        // Ensure audio services are stopped when the view model is destroyed.
        if audioEngineService.isRecording || speechRecognitionService.isRecognitionActive {
            Task {
                await self.stopVoiceCaptureAndFinalize(customError: "ViewModel deinitializing")
            }
        }
    }
    
    // MARK: - Voice Input Control
    
    func toggleVoiceInput() {
        switch self.voiceInputState {
        case .idle, .available:
            if userInput.isEmpty { Task { await startVoiceCapture() } }
        case .recording, .processing:
             Task { await stopVoiceCaptureAndFinalize(customError: nil) }
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            Task { await checkVoiceInputPermissionsAndAvailability() }
        case .requestingPermissions:
            // Do nothing while permissions are being requested.
            break
        }
    }

    // MARK: - Voice Permission and Availability
    
    private func checkVoiceInputPermissionsAndAvailability() async {
        self.voiceInputState = .requestingPermissions
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            // --- FIXED: Bridged completion handler to async ---
            let granted = await withCheckedContinuation { continuation in
                audioEngineService.requestMicrophonePermission { result in
                    continuation.resume(returning: result)
                }
            }
            
            if granted {
                await checkSpeechRecognitionPermission()
            } else {
                self.voiceInputState = .permissionsDeniedMic
            }
        } else if micStatus == .authorized {
            await checkSpeechRecognitionPermission()
        } else {
            self.voiceInputState = .permissionsDeniedMic
        }
    }

    private func checkSpeechRecognitionPermission() async {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            // --- FIXED: Bridged completion handler to async ---
            let status = await withCheckedContinuation { continuation in
                speechRecognitionService.requestSpeechRecognitionPermission { result in
                    continuation.resume(returning: result)
                }
            }
            await updateStateAfterPermissionRequest(status: status)
        } else {
            await updateStateAfterPermissionRequest(status: speechStatus)
        }
    }
    
    private func updateStateAfterPermissionRequest(status: SFSpeechRecognizerAuthorizationStatus) async {
        switch status {
        case .authorized:
            self.voiceInputState = speechRecognitionService.speechRecognizerAvailable ? .available : .speechRecognitionUnavailable
        case .denied:
            self.voiceInputState = .permissionsDeniedSpeech
        case .restricted:
            self.voiceInputState = .error("Speech recognition restricted.")
        default:
            self.voiceInputState = .error("Could not determine speech permission.")
        }
    }

    // MARK: - Voice Capture Lifecycle

    private func startVoiceCapture() async {
        guard userInput.isEmpty, voiceInputState == .available else {
            await checkVoiceInputPermissionsAndAvailability()
            return
        }
        
        self.prefixForCurrentUtterance = self.userInput
        do {
            try audioEngineService.startStreamingAudio { [weak self] (buffer, _) in
                self?.speechRecognitionService.processAudioBuffer(buffer)
            }
            try speechRecognitionService.startRecognition(recognitionHandler: { [weak self] (transcript, isFinal, error) in
                self?.handleRecognitionUpdate(transcript: transcript, isFinal: isFinal, error: error)
            })
            voiceInputState = .recording
        } catch {
            voiceInputState = .error("Start capture error: \(error.localizedDescription.prefix(50))")
            audioEngineService.stopStreamingAudio()
        }
    }
    
    private func handleRecognitionUpdate(transcript: String, isFinal: Bool, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                let nsError = error as NSError
                // Filter out common, non-fatal errors like cancellation or no-speech timeouts.
                let isCancellationError = nsError.domain == SFSpeechErrorDomain || (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107)
                let noSpeechError = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                
                let finalActionErrorString = isCancellationError ? nil : (noSpeechError ? "No speech detected." : "Recognition error: \(error.localizedDescription.prefix(50))")
                Task { await self.stopVoiceCaptureAndFinalize(customError: finalActionErrorString) }
                return
            }

            let separator = self.prefixForCurrentUtterance.isEmpty || self.prefixForCurrentUtterance.last?.isWhitespace == true ? "" : " "
            self.userInput = self.prefixForCurrentUtterance + separator + transcript
            
            if isFinal {
                Task { await self.stopVoiceCaptureAndFinalize(customError: nil) }
            }
        }
    }

    private func stopVoiceCaptureAndFinalize(customError: String?) async {
        let previousState = self.voiceInputState
        if previousState.isSessionActive {
            audioEngineService.stopStreamingAudio()
            speechRecognitionService.stopRecognition()
        }

        if let explicitError = customError, !explicitError.isEmpty {
            self.voiceInputState = .error(explicitError)
        } else {
            await updateStateAfterPermissionRequest(status: SFSpeechRecognizer.authorizationStatus())
        }
        
        logger.info("stopVoiceCaptureAndFinalize: State transitioned from \(previousState.description) to \(self.voiceInputState.description).")
    }
}
