//
//  WhisperRecognitionService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/07/25.
//

import Foundation
import AVFoundation
import WhisperKit
import os

/// An error enum for the WhisperRecognitionService.
enum RecognitionError: Error {
    case modelNotLoaded
    case transcriptionFailed(Error)
}

/// The different states of the model loading process.
enum ModelLoadingState: Equatable {
    case idle
    case downloading
    case preparing
    case loaded
    case error(String)
}

/// A service to manage audio transcription using WhisperKit with on-demand model downloading.
@MainActor
class WhisperRecognitionService: ObservableObject {

    private var whisperKit: WhisperKit?

    @Published private(set) var loadingState: ModelLoadingState = .idle
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WhisperRecognitionService")

    init() {
        Task {
            await loadModel()
        }
    }
    
    /// Asynchronously loads the WhisperKit model. It will download the model on first run.
    private func loadModel() async {
        guard whisperKit == nil else {
            logger.info("Model already initialized.")
            return
        }
        
        do {
            logger.log("Starting on-demand model loading for 'base.en'.")
            loadingState = .downloading
            
            // This initializer triggers on-demand download and caching.
            // UPDATED: Removed the 'progress' argument as it's not supported by this initializer.
            whisperKit = try await WhisperKit(model: "base.en")
            
            logger.log("Model download complete. Beginning prewarming (one-time specialization)...")
            loadingState = .preparing
            
            // Prewarming triggers the one-time model specialization for the device's hardware.
            try await whisperKit?.prewarmModels()
            
            loadingState = .loaded
            logger.log("Model loaded and prewarmed successfully.")
        } catch {
            let errorMessage = "Error loading model: \(error.localizedDescription)"
            loadingState = .error(errorMessage)
            logger.error("\(errorMessage)")
        }
    }

    /// Transcribes a complete array of audio samples.
    /// - Parameter audioArray: An array of audio samples in 16kHz, 32-bit float format.
    /// - Returns: The full transcribed text as a single string.
    func transcribe(audioArray: [Float]) async throws -> String? {
        guard let whisperKit = whisperKit, loadingState == .loaded else {
            logger.error("transcribe called but model is not in a loaded state.")
            throw RecognitionError.modelNotLoaded
        }

        do {
            logger.log("Beginning transcription of \(audioArray.count) audio samples.")
            let options = DecodingOptions() // Using default options
            let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioArray, decodeOptions: options)
            
            let transcript = results.map { $0.text }.joined()
            logger.log("Transcription finished successfully.")
            return transcript
        } catch {
            logger.error("Transcription failed with error: \(error.localizedDescription)")
            throw RecognitionError.transcriptionFailed(error)
        }
    }
}
