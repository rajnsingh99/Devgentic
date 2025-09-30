//
//  EventSourceStream.swift
//  Devgentic
//
//  Created by Raj Singh on 11/09/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "EventSourceStream")

class EventSourceStream: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let payload: SingleAgentRequest
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init<Payload: Encodable>(url: URL, payload: Payload) {
        self.url = url
        self.payload = payload as! SingleAgentRequest
    }

    func stream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("keep-alive", forHTTPHeaderField: "Connection")
            
            do {
                request.httpBody = try JSONEncoder().encode(payload)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            
            let task = session.dataTask(with: request)
            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let stringData = String(data: data, encoding: .utf8) else { return }
        
        let lines = stringData.split(whereSeparator: \.isNewline)
        var eventType: String?
        var eventData: String?

        for line in lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                eventData = String(line.dropFirst("data: ".count))
            }
        }
        
        guard let type = eventType, let dataString = eventData else { return }

        switch type {
        case "agent", "action":
            // These are intermediate steps. We parse them to extract token-like content.
            if let content = parseStepOutput(dataString) {
                continuation?.yield(content)
            }
        case "state":
            // The 'state' event signifies the end of the stream.
            continuation?.finish()
        case "error":
            // Handle errors sent from the server.
            let error = NSError(domain: "AgentServerError", code: 1, userInfo: [NSLocalizedDescriptionKey: dataString])
            continuation?.finish(throwing: error)
        default:
            // Ignore unknown event types.
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
    
    /// Parses the JSON string from an intermediate step to find AI message content.
    private func parseStepOutput(_ jsonString: String) -> String? {
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // The structure from python is {"step_output": {"messages": [...]}}
                if let stepOutput = json["step_output"] as? [String: Any],
                   let messages = stepOutput["messages"] as? [[String: Any]],
                   let lastMessage = messages.last,
                   let content = lastMessage["content"] as? String {
                    return content
                }
            }
        } catch {
            logger.error("Failed to parse agent step JSON: \(error.localizedDescription)")
        }
        
        return nil
    }
}

