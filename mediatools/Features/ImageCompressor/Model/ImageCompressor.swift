//
//  ImageCompressor.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit

// MARK: - Config

struct ImageCompressionConfig {
    let maxFileSize: Int
    let scaleFactor: CGFloat
    let minScale: CGFloat
    let initialQuality: CGFloat
    let minQuality: CGFloat
    let qualityStep: CGFloat

    init(
        maxFileSize: Int,
        scaleFactor: CGFloat = 0.75,
        minScale: CGFloat = 0.25,
        initialQuality: CGFloat = 0.8,
        minQuality: CGFloat = 0.3,
        qualityStep: CGFloat = 0.1
    ) {
        self.maxFileSize = maxFileSize
        self.scaleFactor = scaleFactor
        self.minScale = minScale
        self.initialQuality = initialQuality
        self.minQuality = minQuality
        self.qualityStep = qualityStep
    }

    static let defaultConfig = ImageCompressionConfig(maxFileSize: 1 * 1024 * 1024)
    static let mediumConfig  = ImageCompressionConfig(maxFileSize: 500 * 1024)
    static let smallConfig   = ImageCompressionConfig(maxFileSize: 200 * 1024)
}

// MARK: - Result

struct ImageCompressionResult {
    let data: Data
    let originalSize: Int
    let compressedSize: Int
    let scale: CGFloat
    let quality: CGFloat

    var compressionRatio: Double {
        Double(compressedSize) / Double(originalSize)
    }

    var compressionRatioString: String {
        String(format: "%.1f%%", compressionRatio * 100)
    }
}

// MARK: - Compressor

final class ImageCompressor {
    static let shared = ImageCompressor()
    private init() {}

    func compress(_ image: NSImage, config: ImageCompressionConfig = .defaultConfig) -> ImageCompressionResult? {
        guard let originalData = image.jpegData(compressionQuality: config.initialQuality) else {
            return nil
        }

        let originalSize = originalData.count

        if originalSize <= config.maxFileSize {
            return ImageCompressionResult(
                data: originalData,
                originalSize: originalSize,
                compressedSize: originalSize,
                scale: 1.0,
                quality: config.initialQuality
            )
        }

        // Phase 1: scale down dimensions
        var currentScale: CGFloat = 1.0
        var scaledImage = image
        let quality = config.initialQuality

        while currentScale > config.minScale {
            currentScale *= config.scaleFactor

            let resized = image.resized(toScale: currentScale)
            scaledImage = resized

            if let data = resized.jpegData(compressionQuality: quality),
               data.count <= config.maxFileSize {
                return ImageCompressionResult(
                    data: data,
                    originalSize: originalSize,
                    compressedSize: data.count,
                    scale: currentScale,
                    quality: quality
                )
            }
        }

        // Phase 2: reduce quality on the smallest scaled image
        var currentQuality = quality
        while currentQuality > config.minQuality {
            currentQuality -= config.qualityStep

            if let data = scaledImage.jpegData(compressionQuality: currentQuality),
               data.count <= config.maxFileSize {
                return ImageCompressionResult(
                    data: data,
                    originalSize: originalSize,
                    compressedSize: data.count,
                    scale: currentScale,
                    quality: currentQuality
                )
            }
        }

        // Fallback: return minimum quality result
        if let finalData = scaledImage.jpegData(compressionQuality: config.minQuality) {
            return ImageCompressionResult(
                data: finalData,
                originalSize: originalSize,
                compressedSize: finalData.count,
                scale: currentScale,
                quality: config.minQuality
            )
        }

        return nil
    }

    func compress(_ image: NSImage, maxFileSize: Int) -> Data? {
        compress(image, config: ImageCompressionConfig(maxFileSize: maxFileSize))?.data
    }
}

// MARK: - NSImage helpers

private extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    func resized(toScale scale: CGFloat) -> NSImage {
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let result = NSImage(size: newSize)
        result.lockFocus()
        defer { result.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: newSize),
             from: CGRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        return result
    }
}

// MARK: - NSImage extension (public)

extension NSImage {
    func compressed(maxFileSize: Int) -> Data? {
        ImageCompressor.shared.compress(self, maxFileSize: maxFileSize)
    }

    func compressed(config: ImageCompressionConfig) -> ImageCompressionResult? {
        ImageCompressor.shared.compress(self, config: config)
    }
}
