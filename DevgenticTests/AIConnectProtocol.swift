import Foundation

protocol AIConnectProtocol {
    func postToLocalServer(endpoint: String, payload: [String: Any]) async throws -> Data
}

// Make your existing AIConnect conform
// class AIConnect: AIConnectProtocol { ... }
