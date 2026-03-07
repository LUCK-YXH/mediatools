//
//  ImageCompressor.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit
import CoreGraphics
import ImageIO

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
    nonisolated(unsafe) static let shared = ImageCompressor()
    private init() {}

    nonisolated func compress(_ image: NSImage, config: ImageCompressionConfig = .defaultConfig) -> ImageCompressionResult? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let originalSize = jpegDataSize(cgImage: cgImage, quality: config.initialQuality)
        guard originalSize > 0 else { return nil }

        if originalSize <= config.maxFileSize {
            guard let data = jpegData(cgImage: cgImage, quality: config.initialQuality) else { return nil }
            return ImageCompressionResult(
                data: data,
                originalSize: originalSize,
                compressedSize: data.count,
                scale: 1.0,
                quality: config.initialQuality
            )
        }

        // Phase 1: scale down dimensions
        var currentScale: CGFloat = 1.0
        var scaledCGImage = cgImage
        let quality = config.initialQuality

        while currentScale > config.minScale {
            currentScale *= config.scaleFactor
            guard let resized = cgImage.resized(toScale: currentScale) else { break }
            scaledCGImage = resized

            if let data = jpegData(cgImage: resized, quality: quality),
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

            if let data = jpegData(cgImage: scaledCGImage, quality: currentQuality),
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
        if let finalData = jpegData(cgImage: scaledCGImage, quality: config.minQuality) {
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

    nonisolated func compress(_ image: NSImage, maxFileSize: Int) -> Data? {
        compress(image, config: ImageCompressionConfig(maxFileSize: maxFileSize))?.data
    }

    // MARK: - Private helpers

    private func jpegData(cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func jpegDataSize(cgImage: CGImage, quality: CGFloat) -> Int {
        jpegData(cgImage: cgImage, quality: quality)?.count ?? 0
    }
}

// MARK: - CGImage helpers

private extension CGImage {
    /// 使用 vImage 高质量缩放，不产生屏幕渲染缓冲区
    func resized(toScale scale: CGFloat) -> CGImage? {
        let newWidth  = Int(CGFloat(width)  * scale)
        let newHeight = Int(CGFloat(height) * scale)
        guard newWidth > 0, newHeight > 0 else { return nil }

        let colorSpace = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
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
