//
//  VoiceInputState.swift
//  Devgentic
//
//  Created by Raj Singh on 16/05/25.
//

enum VoiceInputState: Equatable {
    case idle
    case requestingPermissions
    case permissionsDeniedMic
    case available
    case recording
    case processing
    case modelLoading
    case modelPreparing
    case finalizingSilence
    case error(String)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermissions: return "requestingPermissions"
        case .permissionsDeniedMic: return "permissionsDeniedMic"
        case .available: return "available"
        case .recording: return "recording"
        case .processing: return "processing"
        case .modelLoading: return "modelLoading"
        case .modelPreparing: return "modelPreparing"
        case .finalizingSilence: return "finalizingSilence"
        case .error(let msg): return "error(\(msg.prefix(30)))"
        }
    }

    var isSessionActive: Bool {
        switch self {
        case .recording, .processing, .modelLoading, .modelPreparing, .finalizingSilence:
            return true
        default:
            return false
        }
    }

    /// Returns true when the state indicates a model-related error (not permission errors).
    var isErrorState: Bool {
        if case .error = self { return true }
        return false
    }

    /// Returns true when no model is available and the user should be prompted to select one.
    var needsModelSelection: Bool {
        switch self {
        case .idle: return true
        case .error: return true
        default: return false
        }
    }
}
