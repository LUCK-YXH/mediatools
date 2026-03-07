//
//  AnimatedConverter.swift
//  mediatools
//

import AVFoundation
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output Format

enum AnimatedFormat: String, CaseIterable, Identifiable {
    case gif   = "GIF"
    case heics = "HEICS"
    case webP  = "WebP"
    var id: String { rawValue }
}

// MARK: - Config

struct AnimatedConfig {
    var startTime: Double
    var endTime: Double
    var fps: Int
    var outputWidth: Int?       // nil = original size
    var format: AnimatedFormat
    var loopCount: Int?         // nil = no loop extension, 0 = infinite, N = repeat N times
    var quality: Float          // WebP quality factor 1–100 (GIF/HEICS 忽略此参数)
    var targetFileSize: Int?    // WebP only，nil = 不限制，单位 bytes
}

// MARK: - Result

struct AnimatedResult {
    let outputURL: URL
    let frameCount: Int
    let originalSize: Int
    let outputSize: Int

    var compressionRatioString: String {
        guard originalSize > 0 else { return "--" }
        return String(format: "%.1f%%", Double(outputSize) / Double(originalSize) * 100)
    }
}

// MARK: - Error

enum AnimatedConversionError: LocalizedError {
    case destinationCreationFailed
    case finalizeFailed
    case noFramesGenerated
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationCreationFailed: return "无法创建输出文件"
        case .finalizeFailed:            return "写入动图文件失败"
        case .noFramesGenerated:         return "未能提取到任何帧，请检查时间范围"
        case .ffmpegFailed(let msg):     return "ffmpeg 错误：\(msg)"
        }
    }
}

// MARK: - Converter

final class AnimatedConverter {
    static let shared = AnimatedConverter()
    private init() {}

    // bundle 内置 ffmpeg 路径
    private static let bundledFFmpeg: String? = {
        Bundle.main.path(forResource: "ffmpeg", ofType: nil)
    }()

    nonisolated func thumbnail(for url: URL, size: CGFloat = 240) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    nonisolated func videoDuration(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return 0 }
        let secs = CMTimeGetSeconds(dur)
        return secs.isFinite && secs > 0 ? secs : 0
    }

    nonisolated func convert(
        url: URL,
        config: AnimatedConfig,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> AnimatedResult {
        switch config.format {
        case .webP:
            return try await convertWebPFFmpeg(url: url, config: config, onProgress: onProgress)
        case .gif, .heics:
            return try await convertImageIO(url: url, config: config, onProgress: onProgress)
        }
    }

    // MARK: - WebP via ffmpeg

    private nonisolated func convertWebPFFmpeg(
        url: URL,
        config: AnimatedConfig,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> AnimatedResult {
        guard let ffmpeg = AnimatedConverter.bundledFFmpeg else {
            throw AnimatedConversionError.ffmpegFailed("bundle 中未找到 ffmpeg")
        }

        let duration   = config.endTime - config.startTime
        let frameCount = max(1, Int(duration * Double(config.fps)))
        let loopCount  = config.loopCount ?? 1

        // 构建 vf 滤镜
        var vfParts = ["fps=\(config.fps)"]
        if let w = config.outputWidth, w > 0 {
            vfParts.append("scale=\(w):-2:flags=lanczos")
        }
        let vf = vfParts.joined(separator: ",")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".webp")

        // 进度用时长估算（ffmpeg 没有简单的进度协议，用轮询输出文件大小近似）
        let progressTask = Task {
            var reported: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                reported = min(reported + 0.05, 0.95)
                onProgress(reported)
            }
        }
        defer { progressTask.cancel() }

        // 如果有目标大小限制，做二分搜索；否则直接用指定 quality 转换
        if let targetSize = config.targetFileSize {
            try await ffmpegBisect(
                ffmpeg: ffmpeg, input: url, outputURL: outputURL,
                ss: config.startTime, t: duration,
                vf: vf, loop: loopCount,
                initialQuality: config.quality, targetSize: targetSize
            )
        } else {
            try runFFmpeg(ffmpeg: ffmpeg, arguments: [
                "-y", "-ss", String(config.startTime), "-t", String(duration),
                "-i", url.path,
                "-vf", vf,
                "-c:v", "libwebp_anim",
                "-quality", String(Int(config.quality)),
                "-loop", String(loopCount),
                "-an", outputURL.path
            ])
        }

        onProgress(1.0)

        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return AnimatedResult(
            outputURL: outputURL,
            frameCount: frameCount,
            originalSize: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            outputSize: outputSize
        )
    }

    /// 二分搜索 quality，使输出文件不超过 targetSize
    private nonisolated func ffmpegBisect(
        ffmpeg: String,
        input: URL,
        outputURL: URL,
        ss: Double,
        t: Double,
        vf: String,
        loop: Int,
        initialQuality: Float,
        targetSize: Int
    ) throws {
        let minQ: Float = 10

        func run(quality: Float) throws -> Int {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".webp")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try runFFmpeg(ffmpeg: ffmpeg, arguments: [
                "-y", "-ss", String(ss), "-t", String(t),
                "-i", input.path,
                "-vf", vf,
                "-c:v", "libwebp_anim",
                "-quality", String(Int(quality)),
                "-loop", String(loop),
                "-an", tmp.path
            ])
            return (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        }

        // 先试初始质量
        let size = try run(quality: initialQuality)
        if size <= targetSize {
            // 直接用初始质量输出到最终路径
            try runFFmpeg(ffmpeg: ffmpeg, arguments: [
                "-y", "-ss", String(ss), "-t", String(t),
                "-i", input.path,
                "-vf", vf,
                "-c:v", "libwebp_anim",
                "-quality", String(Int(initialQuality)),
                "-loop", String(loop),
                "-an", outputURL.path
            ])
            return
        }

        // 二分，最多 7 次（精度约 1 质量单位）
        var lo = minQ, hi = initialQuality, bestQ = minQ
        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            let s = (try? run(quality: mid)) ?? Int.max
            if s <= targetSize {
                bestQ = mid
                lo = mid
            } else {
                hi = mid
            }
        }

        // 用 bestQ 输出到最终路径
        try runFFmpeg(ffmpeg: ffmpeg, arguments: [
            "-y", "-ss", String(ss), "-t", String(t),
            "-i", input.path,
            "-vf", vf,
            "-c:v", "libwebp_anim",
            "-quality", String(Int(bestQ)),
            "-loop", String(loop),
            "-an", outputURL.path
        ])
    }

    /// 同步执行 ffmpeg，失败时抛出错误
    private nonisolated func runFFmpeg(ffmpeg: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments

        let errPipe = Pipe()
        process.standardOutput = Pipe()   // 抑制 stdout
        process.standardError  = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.suffix(300) ?? "未知错误"
            throw AnimatedConversionError.ffmpegFailed(String(msg))
        }
    }

    // MARK: - GIF / HEICS (ImageIO)

    private nonisolated func convertImageIO(
        url: URL,
        config: AnimatedConfig,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> AnimatedResult {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.1, preferredTimescale: 600)

        let start = max(0.0, config.startTime)
        let step  = 1.0 / Double(config.fps)
        var times: [CMTime] = []
        var t = start
        while t <= config.endTime + 0.001 {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }
        guard !times.isEmpty else { throw AnimatedConversionError.noFramesGenerated }

        let isGif = config.format == .gif
        let uti   = isGif ? "com.compuserve.gif" : "public.heics"
        let ext   = isGif ? "gif" : "heics"

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL, uti as CFString, times.count, nil
        ) else { throw AnimatedConversionError.destinationCreationFailed }

        if let loopCount = config.loopCount {
            let dictKey = isGif ? (kCGImagePropertyGIFDictionary as String) : (kCGImagePropertyHEICSDictionary as String)
            let loopKey = isGif ? (kCGImagePropertyGIFLoopCount as String)  : (kCGImagePropertyHEICSLoopCount as String)
            CGImageDestinationSetProperties(dest, [dictKey: [loopKey: loopCount]] as CFDictionary)
        }

        let delayTime = 1.0 / Double(config.fps)
        let total     = times.count
        var frameCount = 0

        for (i, time) in times.enumerated() {
            try Task.checkCancellation()
            guard let (cgImage, _) = try? await generator.image(at: time) else {
                onProgress(Float(i + 1) / Float(total))
                continue
            }
            let img = config.outputWidth.flatMap { w in
                w > 0 && w < cgImage.width ? scaledImage(cgImage, toWidth: w) : nil
            } ?? cgImage

            let dictKey      = isGif ? (kCGImagePropertyGIFDictionary as String) : (kCGImagePropertyHEICSDictionary as String)
            let delayKey     = isGif ? (kCGImagePropertyGIFDelayTime as String)   : (kCGImagePropertyHEICSDelayTime as String)
            let unclampedKey = isGif ? (kCGImagePropertyGIFUnclampedDelayTime as String) : (kCGImagePropertyHEICSUnclampedDelayTime as String)
            CGImageDestinationAddImage(dest, img, [dictKey: [delayKey: delayTime, unclampedKey: delayTime]] as CFDictionary)

            frameCount += 1
            onProgress(Float(i + 1) / Float(total))
        }

        guard frameCount > 0 else { throw AnimatedConversionError.noFramesGenerated }
        guard CGImageDestinationFinalize(dest) else { throw AnimatedConversionError.finalizeFailed }

        return AnimatedResult(
            outputURL: outputURL,
            frameCount: frameCount,
            originalSize: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            outputSize:   (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )
    }

    // MARK: - Shared helper

    private nonisolated func scaledImage(_ src: CGImage, toWidth w: Int) -> CGImage {
        let h = max(1, Int(Double(src.height) * Double(w) / Double(src.width)))
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? src
    }
}
