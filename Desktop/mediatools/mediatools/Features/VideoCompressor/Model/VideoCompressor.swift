//
//  VideoCompressor.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AVFoundation
import AppKit
import Foundation

// MARK: - Preset

enum VideoCompressionPreset: String, CaseIterable, Identifiable {
    case p2160  = "4K"
    case p1080  = "1080p"
    case p720   = "720p"
    case p540   = "540p"
    case p360   = "360p"
    case custom = "自定义"

    var id: String { rawValue }

    // 目标短边像素（-2 保持偶数）；nil 表示不缩放
    var scaleHeight: Int? {
        switch self {
        case .p2160:  return 2160
        case .p1080:  return 1080
        case .p720:   return 720
        case .p540:   return 540
        case .p360:   return 360
        case .custom: return nil
        }
    }

    // CRF：数值越低质量越高（H.264 推荐 18–28）
    var crf: Int {
        switch self {
        case .p2160:  return 22
        case .p1080:  return 23
        case .p720:   return 24
        case .p540:   return 26
        case .p360:   return 28
        case .custom: return 23
        }
    }
}

// MARK: - Result

struct VideoCompressionResult {
    let outputURL: URL
    let originalSize: Int
    let compressedSize: Int

    var compressionRatio: Double {
        originalSize > 0 ? Double(compressedSize) / Double(originalSize) : 1.0
    }

    var compressionRatioString: String {
        String(format: "%.1f%%", compressionRatio * 100)
    }
}

// MARK: - Error

enum VideoCompressionError: LocalizedError {
    case exportSessionFailed
    case exportError(String?)
    case ffmpegNotFound
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportSessionFailed:   return "无法创建导出会话，请检查视频格式"
        case .exportError(let msg):  return msg ?? "导出失败"
        case .ffmpegNotFound:        return "bundle 中未找到 ffmpeg"
        case .ffmpegFailed(let msg): return "ffmpeg 错误：\(msg)"
        }
    }
}

// MARK: - Compressor

final class VideoCompressor {
    static let shared = VideoCompressor()
    private init() {}

    private static let bundledFFmpeg: String? =
        Bundle.main.path(forResource: "ffmpeg", ofType: nil)

    // MARK: - Thumbnail / Duration（保持 AVFoundation）

    /// 生成缩略图（可在后台调用）
    nonisolated func thumbnail(for url: URL, size: CGFloat = 240) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    /// 格式化时长（可在后台调用）
    nonisolated func durationString(for url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return "--" }
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite && secs > 0 else { return "--" }
        let h = Int(secs) / 3600
        let m = Int(secs) % 3600 / 60
        let s = Int(secs) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: - Compress via ffmpeg

    /// 异步压缩，onProgress 在调用方上下文中回调
    nonisolated func compress(
        url: URL,
        preset: VideoCompressionPreset,
        fileLimitBytes: Int64? = nil,
        onProgress: @escaping (Float) -> Void
    ) async throws -> VideoCompressionResult {
        guard let ffmpeg = VideoCompressor.bundledFFmpeg else {
            throw VideoCompressionError.ffmpegNotFound
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        let duration = await videoDurationSeconds(for: url)

        // 进度轮询：每 300ms 报告一次线性估算进度（ffmpeg 单进程无法实时读取）
        let progressTask = Task {
            guard duration > 0 else { return }
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let elapsed = Date().timeIntervalSince(start)
                // 假设速度约为 3× 实时速，限制在 0.9 以内
                let estimated = Float(min(elapsed / (duration / 3.0), 0.9))
                onProgress(estimated)
            }
        }
        defer { progressTask.cancel() }

        // 构建 vf 滤镜
        let vfScale: String? = preset.scaleHeight.map { "scale=-2:\($0):flags=lanczos" }

        if let limitBytes = fileLimitBytes, duration > 0 {
            // 目标文件大小 → 目标视频码率（两遍式，libx264）
            let videoBitrate = max(100_000, Int(Double(limitBytes * 8) / duration) - 128_000)
            let passLog = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).path

            var baseArgs: [String] = ["-y", "-i", url.path]
            if let vf = vfScale { baseArgs += ["-vf", vf] }

            // 第一遍（分析）
            try runFFmpeg(ffmpeg: ffmpeg, arguments: baseArgs + [
                "-c:v", "libx264", "-b:v", "\(videoBitrate)",
                "-pass", "1", "-passlogfile", passLog,
                "-an", "-f", "null", "/dev/null"
            ])
            // 第二遍（编码输出）
            try runFFmpeg(ffmpeg: ffmpeg, arguments: baseArgs + [
                "-c:v", "libx264", "-b:v", "\(videoBitrate)",
                "-pass", "2", "-passlogfile", passLog,
                "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart",
                outputURL.path
            ])
            // 清理 passlog 临时文件
            try? FileManager.default.removeItem(atPath: passLog + "-0.log")
            try? FileManager.default.removeItem(atPath: passLog + "-0.log.mbtree")
        } else {
            // 无大小限制：VideoToolbox 硬件加速 H.264，quality 映射到 1-100
            // VideoToolbox -q:v: 越高质量越好（与 CRF 相反），范围 0–100
            let vtQuality = max(1, 100 - preset.crf * 2)   // crf 18→64, 28→44
            var args: [String] = ["-y", "-i", url.path]
            if let vf = vfScale { args += ["-vf", vf] }
            args += [
                "-c:v", "h264_videotoolbox",
                "-q:v", String(vtQuality),
                "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart",
                outputURL.path
            ]
            try runFFmpeg(ffmpeg: ffmpeg, arguments: args)
        }

        onProgress(1.0)

        let originalSize   = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let compressedSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        return VideoCompressionResult(
            outputURL: outputURL,
            originalSize: originalSize,
            compressedSize: compressedSize
        )
    }

    // MARK: - Private helpers

    private nonisolated func videoDurationSeconds(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return 0 }
        let secs = CMTimeGetSeconds(dur)
        return secs.isFinite && secs > 0 ? secs : 0
    }

    private nonisolated func runFFmpeg(ffmpeg: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError  = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.suffix(300) ?? "未知错误"
            throw VideoCompressionError.ffmpegFailed(String(msg))
        }
    }
}
