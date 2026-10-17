// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAIImageGenService.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  OpenAI image generation using DALL-E and gpt-image APIs.
//  Supports Text-to-Image via /v1/images/generations
//  and Image-to-Image via /v1/images/edits (gpt-image-1 only).
//

import Foundation
import os

private let logger = DGLogger(category: "OpenAIImageGenService")

// MARK: - OpenAI Image Generation Service

struct OpenAIImageGenService: ImageGenProvider, Sendable {
    let apiKey: String
    let modelName: String
    let baseURL: String?

    /// ⚠️ register B21 — this was `URL(string: base)!` on a free-text endpoint field, i.e. a
    /// force-unwrap crash on the first generate for any value that isn't a parseable URL.
    private var apiBaseURL: URL {
        ProviderDefaults.resolvedBaseURL(configured: baseURL, fallback: ProviderDefaults.openAIBaseURL)
    }

    init(apiKey: String, modelName: String, baseURL: String? = nil) {
        self.apiKey = apiKey
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
        let url = apiBaseURL.appendingPathComponent("images/generations")
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build the full prompt (include negative prompt as guidance if available)
        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let shape = Self.requestShape(model: modelName, aspectRatio: options.aspectRatio, quality: options.quality)
        var body: [String: Any] = [
            "model": modelName,
            "prompt": fullPrompt,
            "n": 1,
            "size": shape.size
        ]
        if let quality = shape.quality { body["quality"] = quality }
        if shape.sendsResponseFormat { body["response_format"] = "b64_json" }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progressHandler?(0, 1)

        logger.info("OpenAI T2I request: model=\(modelName), size=\(shape.size)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenError.invalidResponse(detail: "Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseOpenAIError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw ImageGenError.providerError(underlying: errorMessage)
        }

        progressHandler?(1, 1)

        return try await parseImageResponse(data: data, conversationID: conversationID, prompt: prompt)
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
        // Only gpt-image-1 supports image editing
        guard modelName.lowercased().contains("gpt-image") else {
            throw ImageGenError.imageToImageNotSupported(modelName: modelName)
        }

        let url = apiBaseURL.appendingPathComponent("images/edits")

        // Build multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var bodyData = Data()

        // Model field
        bodyData.append(multipartField(name: "model", value: modelName, boundary: boundary))

        // Prompt field
        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }
        bodyData.append(multipartField(name: "prompt", value: fullPrompt, boundary: boundary))

        // Image file
        // Source is normalized to JPEG upstream (BackendOrchestrationService imageGen
        // path) so this fixed label is truthful — a raw HEIC/TIFF here would 400.
        bodyData.append(multipartFileField(name: "image", fileName: "input.jpg", mimeType: "image/jpeg", data: inputImage, boundary: boundary))

        // Size, and only the fields this model accepts (CR-24).
        let shape = Self.requestShape(model: modelName, aspectRatio: options.aspectRatio, quality: options.quality)
        bodyData.append(multipartField(name: "size", value: shape.size, boundary: boundary))
        if let quality = shape.quality { bodyData.append(multipartField(name: "quality", value: quality, boundary: boundary)) }
        if shape.sendsResponseFormat {
            bodyData.append(multipartField(name: "response_format", value: "b64_json", boundary: boundary))
        }

        // Close boundary
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = bodyData

        progressHandler?(0, 1)

        logger.info("OpenAI I2I request: model=\(modelName), inputSize=\(inputImage.count) bytes")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenError.invalidResponse(detail: "Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseOpenAIError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw ImageGenError.providerError(underlying: errorMessage)
        }

        progressHandler?(1, 1)

        return try await parseImageResponse(data: data, conversationID: conversationID, prompt: prompt)
    }

    // MARK: - Response Parsing

    private func parseImageResponse(data: Data, conversationID: UUID, prompt: String) async throws -> MediaArtifact {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstImage = dataArray.first,
              let b64String = firstImage["b64_json"] as? String,
              let imageData = Data(base64Encoded: b64String) else {
            throw ImageGenError.invalidResponse(detail: "Could not parse image data from OpenAI response")
        }

        // Store via MediaStore
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
                "provider": .string("openai")
            ],
            createdAt: Date()
        )
    }

    // MARK: - Helpers

    /// What one request may carry for `model`: a size it accepts, a quality value it accepts (or none),
    /// and whether `response_format` may be sent.
    ///
    /// ⚠️⚠️ READINESS CR-24 (2026-10-10). Every non-DALL-E-3 model was sent `size` built from the raw
    /// aspect ratio (`1024x576`, `1024x438`, `1024x768`…), which gpt-image accepts only as
    /// 1024x1024 / 1536x1024 / 1024x1536 / auto and dall-e-2 only as square — so any non-square ratio
    /// 400d, on generate AND edit. It was also sent `response_format` (gpt-image always returns base64
    /// and rejects the field) and `quality: "hd"` (gpt-image takes low/medium/high/auto). Sizes snap to
    /// the nearest allowed ORIENTATION; an unrecognised model is treated as gpt-image, the newest family.
    static func requestShape(model: String, aspectRatio: ImageAspectRatio, quality: ImageQuality)
        -> (size: String, quality: String?, sendsResponseFormat: Bool) {
        let name = model.lowercased()
        let dims = aspectRatio.dimensions()
        let orientation = dims.width == dims.height ? 0 : (dims.width > dims.height ? 1 : -1)
        if name.contains("dall-e-3") {
            let size = orientation == 0 ? "1024x1024" : (orientation > 0 ? "1792x1024" : "1024x1792")
            return (size, quality.rawValue, true)
        }
        if name.contains("dall-e-2") {
            // Square sizes only; no quality parameter.
            return ("1024x1024", nil, true)
        }
        let size = orientation == 0 ? "1024x1024" : (orientation > 0 ? "1536x1024" : "1024x1536")
        return (size, quality == .hd ? "high" : nil, false)
    }

    private func parseOpenAIError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }

        // Check for content policy violations
        if let code = error["code"] as? String, code.contains("content_policy") {
            return "Content policy violation: \(message)"
        }

        return message
    }

    private func multipartField(name: String, value: String, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        field.append("\(value)\r\n".data(using: .utf8)!)
        return field
    }

    private func multipartFileField(name: String, fileName: String, mimeType: String, data: Data, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        field.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        field.append(data)
        field.append("\r\n".data(using: .utf8)!)
        return field
    }
}
