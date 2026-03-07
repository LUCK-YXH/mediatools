//
//  ImageConverter.swift
//  mediatools
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Target Format

enum ImageConvertFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case png  = "PNG"
    case webP = "WebP"
    case heic = "HEIC"
    case tiff = "TIFF"
    case bmp  = "BMP"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .webP: return "webp"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .bmp:  return "bmp"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png:  return .png
        case .webP: return .webP
        case .heic: return UTType("public.heic") ?? .image
        case .tiff: return .tiff
        case .bmp:  return .bmp
        }
    }

    // ImageIO destination UTI（WebP 走 ffmpeg，此值不用于 WebP）
    var imageIOIdentifier: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png:  return "public.png"
        case .webP: return "org.webmproject.webp"  // ImageIO 写入不支持，仅占位
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp:  return "com.microsoft.bmp"
        }
    }

    /// 支持质量参数（0.0–1.0）
    var supportsQuality: Bool {
        switch self {
        case .jpeg, .webP: return true
        default:           return false
        }
    }

    /// 支持透明通道
    var supportsAlpha: Bool {
        switch self {
        case .png, .webP, .heic, .tiff: return true
        default:                         return false
        }
    }
}

// MARK: - Result

struct ImageConversionResult {
    let outputURL: URL
    let originalSize: Int
    let outputSize: Int
    let format: ImageConvertFormat

    var compressionRatioString: String {
        guard originalSize > 0 else { return "--" }
        return String(format: "%.1f%%", Double(outputSize) / Double(originalSize) * 100)
    }
}

// MARK: - Error

enum ImageConversionError: LocalizedError {
    case unreadableSource
    case encodingFailed
    case ffmpegNotFound
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource:      return "无法读取图片"
        case .encodingFailed:        return "编码失败"
        case .ffmpegNotFound:        return "bundle 中未找到 ffmpeg"
        case .ffmpegFailed(let msg): return "ffmpeg 错误：\(msg)"
        }
    }
}

// MARK: - Converter

final class ImageConverter {
    static let shared = ImageConverter()
    private init() {}

    private static let bundledFFmpeg: String? =
        Bundle.main.path(forResource: "ffmpeg", ofType: nil)

    /// 转换单张图片，返回结果
    nonisolated func convert(
        url: URL,
        to format: ImageConvertFormat,
        quality: Double    // 0.0–1.0，仅 JPEG / WebP 有效
    ) throws -> ImageConversionResult {
        let originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + format.fileExtension)

        if format == .webP {
            try convertViaFFmpeg(input: url, output: outputURL, quality: Int(quality * 100))
        } else {
            try convertViaImageIO(input: url, output: outputURL, format: format, quality: quality)
        }

        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ImageConversionResult(
            outputURL: outputURL,
            originalSize: originalSize,
            outputSize: outputSize,
            format: format
        )
    }

    // MARK: - ImageIO path

    private nonisolated func convertViaImageIO(
        input: URL,
        output: URL,
        format: ImageConvertFormat,
        quality: Double
    ) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageConversionError.unreadableSource }

        guard let dest = CGImageDestinationCreateWithURL(
            output as CFURL,
            format.imageIOIdentifier as CFString,
            1, nil
        ) else { throw ImageConversionError.encodingFailed }

        var props: [CFString: Any] = [:]
        if format.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // HEIC/HEIF 深度位标志
        if format == .heic {
            props[kCGImageDestinationEmbedThumbnail] = true
        }

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageConversionError.encodingFailed
        }
    }

    // MARK: - ffmpeg path（WebP 输出）

    private nonisolated func convertViaFFmpeg(input: URL, output: URL, quality: Int) throws {
        guard let ffmpeg = ImageConverter.bundledFFmpeg else {
            throw ImageConversionError.ffmpegNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-i", input.path,
            "-c:v", "libwebp",
            "-quality", String(max(1, min(100, quality))),
            "-frames:v", "1",        // 静态图，只取第一帧
            output.path
        ]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError  = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.suffix(300) ?? "未知错误"
            throw ImageConversionError.ffmpegFailed(String(msg))
        }
    }
}
