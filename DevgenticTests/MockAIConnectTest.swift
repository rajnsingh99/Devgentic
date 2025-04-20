import Foundation
@testable import devgentic // Import your app module

class MockAIConnect: AIConnectProtocol {
    enum MockError: Error {
        case simulatedError(String)
        case connectionError(URLError.Code)
    }

    var postToLocalServerHandler: ((String, [String: Any]) async throws -> Data)?
    var lastEndpointCalled: String?
    var lastPayloadSent: [String: Any]?

    func postToLocalServer(endpoint: String, payload: [String : Any]) async throws -> Data {
        lastEndpointCalled = endpoint
        lastPayloadSent = payload

        if let handler = postToLocalServerHandler {
            return try await handler(endpoint, payload)
        } else {
            // Default behavior or throw an error if no handler is set
            throw MockError.simulatedError("MockAIConnect.postToLocalServerHandler not set")
        }
    }

    // Helper to easily set up success responses
    func setSuccessResponse(json: [String: Any]) {
        postToLocalServerHandler = { _, _ in
            try JSONSerialization.data(withJSONObject: json, options: [])
        }
    }

    // Helper to easily set up plain text responses
    func setSuccessResponse(text: String) {
        postToLocalServerHandler = { _, _ in
            Data(text.utf8)
        }
    }

    // Helper to easily set up error responses
    func setErrorResponse(error: Error) {
        postToLocalServerHandler = { _, _ in
            throw error
        }
    }
}
