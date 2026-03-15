//
//  OllamaImageGenService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Ollama image generation for experimental diffusion models.
//  T2I only — I2I is not supported via standard Ollama API endpoints.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaImageGenService")

// MARK: - Ollama Image Generation Service

/// Experimental image generation via Ollama's local diffusion models.
/// Only supports Text-to-Image; Image-to-Image is not available.
struct OllamaImageGenService: ImageGenProvider, Sendable {
    let modelName: String
    let baseURL: String

    init(modelName: String, baseURL: String = "http://localhost:11434") {
        self.modelName = modelName
        self.baseURL = baseURL
    }

    // MARK: - Text-to-Image

    func generateImage(
        prompt: String,
        negativePrompt: String?,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw ImageGenError.providerError(underlying: "Invalid Ollama base URL: \(baseURL)")
        }

        var request = URLRequest(url: url, timeoutInterval: 300) // Longer timeout for local generation
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let body: [String: Any] = [
            "model": modelName,
            "prompt": fullPrompt,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progressHandler?(0, 1)

        logger.info("Ollama T2I request: model=\(modelName)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenError.invalidResponse(detail: "Invalid HTTP response from Ollama")
        }

        guard httpResponse.statusCode == 200 else {
            throw ImageGenError.providerError(underlying: "Ollama returned HTTP \(httpResponse.statusCode)")
        }

        progressHandler?(1, 1)

        // Parse the response — Ollama image models return base64 image data in the response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageGenError.invalidResponse(detail: "Could not parse Ollama response")
        }

        // Look for image data in the response
        // Ollama experimental image models may return images in various formats
        if let images = json["images"] as? [String], let b64String = images.first,
           let imageData = Data(base64Encoded: b64String) {

            let reference = try await MediaStore.shared.store(
                data: imageData,
                mimeType: "image/png",
                conversationID: conversationID
            )

            return MediaArtifact(
                id: UUID(),
                kind: .image,
                reference: reference,
                mimeType: "image/png",
                label: String(prompt.prefix(60)),
                metadata: [
                    "prompt": .string(prompt),
                    "model": .string(modelName),
                    "provider": .string("ollama")
                ],
                createdAt: Date()
            )
        }

        // Fallback: try "response" field which may contain base64 data
        if let responseString = json["response"] as? String,
           let imageData = Data(base64Encoded: responseString) {

            let reference = try await MediaStore.shared.store(
                data: imageData,
                mimeType: "image/png",
                conversationID: conversationID
            )

            return MediaArtifact(
                id: UUID(),
                kind: .image,
                reference: reference,
                mimeType: "image/png",
                label: String(prompt.prefix(60)),
                metadata: [
                    "prompt": .string(prompt),
                    "model": .string(modelName),
                    "provider": .string("ollama")
                ],
                createdAt: Date()
            )
        }

        throw ImageGenError.invalidResponse(detail: "No image data found in Ollama response. Ensure the model supports image generation.")
    }

    // MARK: - Image-to-Image (Not Supported)

    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        throw ImageGenError.imageToImageNotSupported(modelName: modelName)
    }
}
