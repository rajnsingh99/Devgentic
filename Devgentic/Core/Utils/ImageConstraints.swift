//
//  ImageConstraints.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 2
//  Size guards for images sent to local models (MLX/Ollama).
//  Prevents OOM and ensures images fit within model context limits.
//
//  Created by Raj Singh on 15/03/26.
//

import Foundation
import CoreGraphics
import ImageIO

enum ImageConstraints {
    static let maxDimensionForLocalModels: Int = 1024
    static let maxBytesForLocalModels: Int = 2_097_152  // 2MB
    static let jpegCompressionQuality: CGFloat = 0.8

    /// Downscale and compress an image if it exceeds local model limits.
    /// Returns the original data if already within bounds.
    static func constrainForLocalModel(_ data: Data, mimeType: String) -> Data {
        guard data.count > maxBytesForLocalModels else { return data }

        // Attempt to downscale via CGImage
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }

        let width = cgImage.width
        let height = cgImage.height
        let maxDim = max(width, height)

        guard maxDim > maxDimensionForLocalModels else {
            // Image is small enough dimensionally — just re-compress as JPEG
            return recompressAsJPEG(cgImage) ?? data
        }

        let scale = Double(maxDimensionForLocalModels) / Double(maxDim)
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return data
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let scaledImage = context.makeImage() else { return data }

        return recompressAsJPEG(scaledImage) ?? data
    }

    private static func recompressAsJPEG(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
