//
//  Untitled.swift
//  Devgentic
//
//  Created by Raj Singh on 16/05/25.
//

enum VoiceInputState: Equatable {
    case idle
    case requestingPermissions
    case permissionsDeniedMic
    case permissionsDeniedSpeech
    case speechRecognitionUnavailable
    case available
    case recording
    case processing
    case error(String)
    
    var description: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermissions: return "requestingPermissions"
        case .permissionsDeniedMic: return "permissionsDeniedMic"
        case .permissionsDeniedSpeech: return "permissionsDeniedSpeech"
        case .speechRecognitionUnavailable: return "speechRecognitionUnavailable"
        case .available: return "available"
        case .recording: return "recording"
        case .processing: return "processing"
        case .error(let msg): return "error(\(msg.prefix(30)))"
        }
    }
    
    var isSessionActive: Bool {
        switch self {
        case .recording, .processing:
            return true
        default:
            return false
        }
    }
    
    var canTransitionToError: Bool {
        switch self {
        case .permissionsDeniedMic, .permissionsDeniedSpeech:
            return false
        default:
            return true
        }
    }
}
