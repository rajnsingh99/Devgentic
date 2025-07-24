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
    case available
    case recording
    case processing
    case modelLoading
    case modelPreparing     
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
        case .error(let msg): return "error(\(msg.prefix(30)))"
        }
    }
    
    var isSessionActive: Bool {
        switch self {
        case .recording, .processing, .modelLoading, .modelPreparing:
            return true
        default:
            return false
        }
    }
}
