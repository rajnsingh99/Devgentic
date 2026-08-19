//
//  GeminiImageGenService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Google Gemini image generation using generateContent with responseModalities.
//  Supports T2I and I2I via inline image parts.
//

import Foundation
import os

private let logger = DGLogger(category: "GeminiImageGenService")

// MARK: - Gemini Image Generation Service

struct GeminiImageGenService: ImageGenProvider, Sendable {
    let apiKey: String
    let modelName: String

    /// ⚠️ register B21 — this type had no endpoint at all: both request builders hardcoded
    /// `ProviderDefaults.geminiBaseURL`, so an imageGen profile configured against a corporate
    /// gateway sent its gateway-scoped key straight to Google. `OpenAIImageGenService` and
    /// `OllamaImageGenService` both took a `baseURL`; this one was the odd one out.
    let baseURL: String?

    private var apiBaseURL: URL {
        ProviderDefaults.resolvedBaseURL(configured: baseURL, fallback: ProviderDefaults.geminiBaseURL)
    }

    init(apiKey: String, modelName: String, baseURL: String? = nil) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.baseURL = baseURL
    }

    /// The `models/<name>:generateContent` URL both generators post to.
    private var generateContentURL: URL {
        apiBaseURL.appendingPathComponent("models/\(modelName):generateContent")
    }

    // MARK: - Text-to-Image

    func generateImage(
        prompt: String,
        negativePrompt: String?,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        var request = URLRequest(url: generateContentURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⚠️ Header, never the query string — see the note in `GeminiService.verifyAndFetchModels`.
        // A key in the URL is written to URLSession's on-disk cache and to every proxy access log
        // on the path.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": fullPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progressHandler?(0, 1)

        logger.info("Gemini T2I request: model=\(modelName)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenError.invalidResponse(detail: "Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseGeminiError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw ImageGenError.providerError(underlying: errorMessage)
        }

        progressHandler?(1, 1)

        return try await parseGeminiImageResponse(data: data, conversationID: conversationID, prompt: prompt)
    }

    // MARK: - Image-to-Image

    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        var request = URLRequest(url: generateContentURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⚠️ Header, never the query string — see the note in `GeminiService.verifyAndFetchModels`.
        // A key in the URL is written to URLSession's on-disk cache and to every proxy access log
        // on the path.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let b64Image = inputImage.base64EncodedString()

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": fullPrompt],
                        [
                            // Source normalized to JPEG upstream (imageGen path), so this
                            // fixed label is truthful — a raw HEIC/etc. here would 400.
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": b64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progressHandler?(0, 1)

        logger.info("Gemini I2I request: model=\(modelName), inputSize=\(inputImage.count) bytes")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenError.invalidResponse(detail: "Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseGeminiError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw ImageGenError.providerError(underlying: errorMessage)
        }

        progressHandler?(1, 1)

        return try await parseGeminiImageResponse(data: data, conversationID: conversationID, prompt: prompt)
    }

    // MARK: - Response Parsing

    private func parseGeminiImageResponse(data: Data, conversationID: UUID, prompt: String) async throws -> MediaArtifact {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ImageGenError.invalidResponse(detail: "Could not parse Gemini response structure")
        }

        // Find the image part in the response
        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let mimeType = inlineData["mimeType"] as? String,
               let b64String = inlineData["data"] as? String,
               let imageData = Data(base64Encoded: b64String),
               mimeType.hasPrefix("image/") {

                let reference = try await MediaStore.shared.store(
                    data: imageData,
                    mimeType: mimeType,
                    conversationID: conversationID
                )

                return MediaArtifact(
                    id: UUID(),
                    kind: .image,
                    reference: reference,
                    mimeType: mimeType,
                    label: String(prompt.prefix(60)),
                    metadata: [
                        "prompt": .string(prompt),
                        "model": .string(modelName),
                        "provider": .string("gemini")
                    ],
                    createdAt: Date()
                )
            }
        }

        throw ImageGenError.invalidResponse(detail: "No image data found in Gemini response")
    }

    private func parseGeminiError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
