//
//  TwoImageAnimator.swift
//  mediatools
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

// MARK: - Transition Type

enum TransitionType: String, CaseIterable, Identifiable {
    case beforeAfterSlider = "对比滑动"
    case fade = "淡入淡出"
    case slide = "滑动"
    case zoom = "缩放"
    
    var id: String { rawValue }
}

// MARK: - Divider Style

enum DividerStyle: String, CaseIterable, Identifiable {
    case solid = "白色直线"
    case gradient = "渐变色"
    case glow = "发光"
    case none = "无"
    
    var id: String { rawValue }
}

// MARK: - Config

struct TwoImageAnimatorConfig {
    var image1: NSImage
    var image2: NSImage
    var transitionType: TransitionType
    var fps: Int
    var duration: Double          // 总时长（秒）
    var outputWidth: Int?         // nil = 使用原始尺寸
    var format: AnimatedFormat
    var loopCount: Int?           // nil = no loop, 0 = infinite
    var quality: Float            // WebP quality 1-100
    var dividerStyle: DividerStyle
}

// MARK: - Result

struct TwoImageAnimatorResult {
    let outputURL: URL
    let previewURL: URL   // 始终为 GIF，用于预览播放
    let frameCount: Int
    let outputSize: Int
    
    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(outputSize))
    }
}

// MARK: - Error

enum TwoImageAnimatorError: LocalizedError {
    case invalidImage
    case destinationCreationFailed
    case finalizeFailed
    case colorExtractionFailed
    case ffmpegFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法处理图片"
        case .destinationCreationFailed: return "无法创建输出文件"
        case .finalizeFailed: return "写入动图文件失败"
        case .colorExtractionFailed: return "无法提取图片颜色"
        case .ffmpegFailed(let msg): return "ffmpeg 错误：\(msg)"
        }
    }
}

// MARK: - Animator

final class TwoImageAnimator {
    static let shared = TwoImageAnimator()
    private init() {}
    
    nonisolated func createAnimated(
        config: TwoImageAnimatorConfig,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> TwoImageAnimatorResult {
        let frameCount = max(1, Int(config.duration * Double(config.fps)))
        
        // 准备两张图片
        guard let cgImage1 = config.image1.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgImage2 = config.image2.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw TwoImageAnimatorError.invalidImage
        }
        
        // 统一尺寸
        let targetWidth = config.outputWidth ?? max(cgImage1.width, cgImage2.width)
        let img1 = resizeImage(cgImage1, toWidth: targetWidth)
        let img2 = resizeImage(cgImage2, toWidth: targetWidth)
        
        // 生成帧
        let frames = try await generateFrames(
            image1: img1,
            image2: img2,
            frameCount: frameCount,
            transitionType: config.transitionType,
            dividerStyle: config.dividerStyle,
            onProgress: onProgress
        )
        
        // 先生成 GIF（用于预览，也作为 WebP 的中间格式）
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gif")
        
        try writeGIF(frames: frames, fps: config.fps, loopCount: config.loopCount, to: gifURL)
        
        let outputURL: URL
        
        switch config.format {
        case .gif:
            outputURL = gifURL
            
        case .heics:
            outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".heics")
            try writeHEICS(frames: frames, fps: config.fps, loopCount: config.loopCount, to: outputURL)
            
        case .webP:
            guard let ffmpeg = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
                throw TwoImageAnimatorError.ffmpegFailed("bundle 中未找到 ffmpeg")
            }
            outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".webp")
            let loopCount = config.loopCount ?? 1
            try runFFmpeg(ffmpeg: ffmpeg, arguments: [
                "-y", "-i", gifURL.path,
                "-c:v", "libwebp_anim",
                "-quality", String(Int(config.quality)),
                "-loop", String(loopCount),
                "-an", outputURL.path
            ])
        }
        
        onProgress(1.0)
        
        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return TwoImageAnimatorResult(
            outputURL: outputURL,
            previewURL: gifURL,
            frameCount: frames.count,
            outputSize: outputSize
        )
    }
    
    // MARK: - Write GIF
    
    private nonisolated func writeGIF(frames: [CGImage], fps: Int, loopCount: Int?, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil
        ) else {
            throw TwoImageAnimatorError.destinationCreationFailed
        }
        
        if let loopCount {
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: loopCount]
            ] as CFDictionary)
        }
        
        let delayTime = 1.0 / Double(fps)
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delayTime,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delayTime
                ]
            ] as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(dest) else {
            throw TwoImageAnimatorError.finalizeFailed
        }
    }
    
    // MARK: - Write HEICS
    
    private nonisolated func writeHEICS(frames: [CGImage], fps: Int, loopCount: Int?, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.heics" as CFString, frames.count, nil
        ) else {
            throw TwoImageAnimatorError.destinationCreationFailed
        }
        
        if let loopCount {
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyHEICSDictionary as String: [kCGImagePropertyHEICSLoopCount as String: loopCount]
            ] as CFDictionary)
        }
        
        let delayTime = 1.0 / Double(fps)
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, [
                kCGImagePropertyHEICSDictionary as String: [
                    kCGImagePropertyHEICSDelayTime as String: delayTime,
                    kCGImagePropertyHEICSUnclampedDelayTime as String: delayTime
                ]
            ] as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(dest) else {
            throw TwoImageAnimatorError.finalizeFailed
        }
    }
    
    // MARK: - FFmpeg
    
    private nonisolated func runFFmpeg(ffmpeg: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.suffix(300) ?? "未知错误"
            throw TwoImageAnimatorError.ffmpegFailed(String(msg))
        }
    }
    
    // MARK: - Frame Generation
    
    private nonisolated func generateFrames(
        image1: CGImage,
        image2: CGImage,
        frameCount: Int,
        transitionType: TransitionType,
        dividerStyle: DividerStyle,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        
        switch transitionType {
        case .beforeAfterSlider:
            frames = try await generateBeforeAfterSliderFrames(image1: image1, image2: image2, frameCount: frameCount, dividerStyle: dividerStyle, onProgress: onProgress)
        case .fade:
            frames = try await generateFadeFrames(image1: image1, image2: image2, frameCount: frameCount, onProgress: onProgress)
        case .slide:
            frames = try await generateSlideFrames(image1: image1, image2: image2, frameCount: frameCount, onProgress: onProgress)
        case .zoom:
            frames = try await generateZoomFrames(image1: image1, image2: image2, frameCount: frameCount, onProgress: onProgress)
        }
        
        return frames
    }
    
    // 缓动函数：使动画更自然
    private nonisolated func easeInOutCubic(_ t: Float) -> Float {
        let t = Double(t)
        if t < 0.5 {
            return Float(4 * t * t * t)
        } else {
            let f = 2 * t - 2
            return Float(1 + f * f * f / 2)
        }
    }
    
    // MARK: - Before-After Slider Transition
    
    private nonisolated func generateBeforeAfterSliderFrames(
        image1: CGImage,
        image2: CGImage,
        frameCount: Int,
        dividerStyle: DividerStyle,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        
        let width = image1.width
        let height = image1.height
        
        // 为渐变分割线预计算两张图片的主题色
        let color1 = dividerStyle == .gradient ? extractDominantColor(from: image1) : .white
        let color2 = dividerStyle == .gradient ? extractDominantColor(from: image2) : .white
        
        for i in 0..<frameCount {
            let progress = Float(i) / Float(max(1, frameCount - 1))
            
            // 前半程从左到右（0→1），后半程从右到左（1→0）
            let sliderProgress: Float
            if progress < 0.5 {
                sliderProgress = easeInOutCubic(progress * 2)
            } else {
                sliderProgress = easeInOutCubic((1.0 - progress) * 2)
            }
            
            if let frame = createBeforeAfterSliderFrame(
                image1: image1,
                image2: image2,
                width: width,
                height: height,
                progress: sliderProgress,
                dividerStyle: dividerStyle,
                themeColor1: color1,
                themeColor2: color2
            ) {
                frames.append(frame)
            }
            
            onProgress(Float(i + 1) / Float(frameCount))
        }
        
        return frames
    }
    
    /// 创建 Before-After 滑动对比帧：左侧显示图1，右侧显示图2，中间有分割线
    private nonisolated func createBeforeAfterSliderFrame(
        image1: CGImage,
        image2: CGImage,
        width: Int,
        height: Int,
        progress: Float,
        dividerStyle: DividerStyle,
        themeColor1: NSColor,
        themeColor2: NSColor
    ) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        let dividerX = CGFloat(progress) * CGFloat(width)
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        
        if dividerStyle == .gradient {
            // 渐变滤镜扫描效果：彩色滤镜波扫过，经过处显现图2
            let bandWidth: CGFloat = 150.0
            // 扩展范围，确保过渡带能完全滚入和滚出画面
            let extendedDividerX = CGFloat(progress) * (CGFloat(width) + bandWidth)
            let bandLeft = extendedDividerX - bandWidth
            let bandRight = extendedDividerX
            
            // 底层：图2
            ctx.draw(image2, in: fullRect)
            
            // 创建灰度遮罩：白色=显示图1，黑色=显示图2
            if let mask = createGradientMask(width: width, height: height, bandLeft: bandLeft, bandRight: bandRight) {
                // 用遮罩裁剪后绘制图1
                ctx.saveGState()
                ctx.clip(to: fullRect, mask: mask)
                ctx.draw(image1, in: fullRect)
                ctx.restoreGState()
                
                // 叠加主题色滤镜（过渡带区域，中间浓两边淡）
                if let filterMask = createFilterMask(width: width, height: height, bandLeft: bandLeft, bandRight: bandRight) {
                    ctx.saveGState()
                    ctx.clip(to: fullRect, mask: filterMask)
                    ctx.setFillColor(themeColor2.withAlphaComponent(0.5).cgColor)
                    ctx.fill(fullRect)
                    ctx.restoreGState()
                }
            }
        } else {
            // 其他样式：标准硬切分割
            ctx.draw(image2, in: fullRect)
            
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: dividerX, height: CGFloat(height)))
            ctx.draw(image1, in: fullRect)
            ctx.restoreGState()
            
            switch dividerStyle {
            case .solid:
                drawSolidDivider(ctx: ctx, dividerX: dividerX, width: width, height: height)
            case .glow:
                drawGlowDivider(ctx: ctx, dividerX: dividerX, width: width, height: height, progress: progress)
            case .none:
                break
            case .gradient:
                break // handled above
            }
            
            if dividerStyle == .solid {
                drawSliderHandle(ctx: ctx, dividerX: dividerX, height: height)
            }
        }
        
        return ctx.makeImage()
    }
    
    // MARK: - Divider Styles
    
    /// 白色直线分割线
    private nonisolated func drawSolidDivider(ctx: CGContext, dividerX: CGFloat, width: Int, height: Int) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(3.0)
        ctx.setShadow(offset: CGSize(width: 1, height: 0), blur: 4, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        ctx.move(to: CGPoint(x: dividerX, y: 0))
        ctx.addLine(to: CGPoint(x: dividerX, y: CGFloat(height)))
        ctx.strokePath()
        ctx.restoreGState()
    }
    
    /// 发光分割线
    private nonisolated func drawGlowDivider(ctx: CGContext, dividerX: CGFloat, width: Int, height: Int, progress: Float) {
        // 外层发光（宽模糊）
        ctx.saveGState()
        let glowColor = NSColor(hue: 0.58, saturation: 0.6, brightness: 1.0, alpha: 0.4)
        ctx.setStrokeColor(glowColor.cgColor)
        ctx.setLineWidth(12.0)
        ctx.setShadow(offset: .zero, blur: 16, color: NSColor(hue: 0.58, saturation: 0.8, brightness: 1.0, alpha: 0.6).cgColor)
        ctx.move(to: CGPoint(x: dividerX, y: 0))
        ctx.addLine(to: CGPoint(x: dividerX, y: CGFloat(height)))
        ctx.strokePath()
        ctx.restoreGState()
        
        // 中层发光
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 0.7))
        ctx.setLineWidth(4.0)
        ctx.move(to: CGPoint(x: dividerX, y: 0))
        ctx.addLine(to: CGPoint(x: dividerX, y: CGFloat(height)))
        ctx.strokePath()
        ctx.restoreGState()
        
        // 核心亮线
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: dividerX, y: 0))
        ctx.addLine(to: CGPoint(x: dividerX, y: CGFloat(height)))
        ctx.strokePath()
        ctx.restoreGState()
    }
    
    /// 创建灰度遮罩：左侧白色(显示图2)，过渡带渐变，右侧黑色(显示图1)
    private nonisolated func createGradientMask(width: Int, height: Int, bandLeft: CGFloat, bandRight: CGFloat) -> CGImage? {
        guard let maskCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: 0
        ) else { return nil }
        
        // 已扫过区域：白色
        if bandLeft > 0 {
            maskCtx.setFillColor(gray: 1.0, alpha: 1.0)
            maskCtx.fill(CGRect(x: 0, y: 0, width: bandLeft, height: CGFloat(height)))
        }
        
        // 过渡带：白→黑渐变
        let clipLeft = max(0, bandLeft)
        let clipRight = min(CGFloat(width), bandRight)
        if clipRight > clipLeft {
            let colors = [CGColor(gray: 1.0, alpha: 1.0), CGColor(gray: 0.0, alpha: 1.0)]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0.0, 1.0]) {
                maskCtx.saveGState()
                maskCtx.clip(to: CGRect(x: clipLeft, y: 0, width: clipRight - clipLeft, height: CGFloat(height)))
                maskCtx.drawLinearGradient(gradient, start: CGPoint(x: clipLeft, y: 0), end: CGPoint(x: clipRight, y: 0), options: [])
                maskCtx.restoreGState()
            }
        }
        
        return maskCtx.makeImage()
    }
    
    /// 创建滤镜遮罩：过渡带中间浓两边淡（sin 曲线）
    private nonisolated func createFilterMask(width: Int, height: Int, bandLeft: CGFloat, bandRight: CGFloat) -> CGImage? {
        guard let maskCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: 0
        ) else { return nil }
        
        // 整体黑色（不显示滤镜），仅过渡带有值
        let clipLeft = max(0, bandLeft)
        let clipRight = min(CGFloat(width), bandRight)
        if clipRight > clipLeft {
            // sin 曲线：两端0，中间1
            let colors = [
                CGColor(gray: 0.0, alpha: 1.0),
                CGColor(gray: 1.0, alpha: 1.0),
                CGColor(gray: 0.0, alpha: 1.0)
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0.0, 0.5, 1.0]) {
                maskCtx.saveGState()
                maskCtx.clip(to: CGRect(x: clipLeft, y: 0, width: clipRight - clipLeft, height: CGFloat(height)))
                maskCtx.drawLinearGradient(gradient, start: CGPoint(x: clipLeft, y: 0), end: CGPoint(x: clipRight, y: 0), options: [])
                maskCtx.restoreGState()
            }
        }
        
        return maskCtx.makeImage()
    }
    
    /// 滑块手柄
    private nonisolated func drawSliderHandle(ctx: CGContext, dividerX: CGFloat, height: Int) {
        let handleRadius: CGFloat = 16
        let handleCenterY = CGFloat(height) / 2.0
        
        // 手柄背景圆
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(
            x: dividerX - handleRadius,
            y: handleCenterY - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        ))
        ctx.restoreGState()
        
        // 手柄上的左右箭头
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0))
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        
        let arrowSize: CGFloat = 6
        // 左箭头 <
        let leftArrowX = dividerX - arrowSize
        ctx.move(to: CGPoint(x: leftArrowX + arrowSize * 0.6, y: handleCenterY - arrowSize))
        ctx.addLine(to: CGPoint(x: leftArrowX, y: handleCenterY))
        ctx.addLine(to: CGPoint(x: leftArrowX + arrowSize * 0.6, y: handleCenterY + arrowSize))
        ctx.strokePath()
        
        // 右箭头 >
        let rightArrowX = dividerX + arrowSize
        ctx.move(to: CGPoint(x: rightArrowX - arrowSize * 0.6, y: handleCenterY - arrowSize))
        ctx.addLine(to: CGPoint(x: rightArrowX, y: handleCenterY))
        ctx.addLine(to: CGPoint(x: rightArrowX - arrowSize * 0.6, y: handleCenterY + arrowSize))
        ctx.strokePath()
        ctx.restoreGState()
    }
    
    // MARK: - Fade Transition
    
    private nonisolated func generateFadeFrames(
        image1: CGImage,
        image2: CGImage,
        frameCount: Int,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        
        for i in 0..<frameCount {
            let progress = Float(i) / Float(max(1, frameCount - 1))
            let easedProgress = easeInOutCubic(progress)
            
            if let frame = blendImages(image1, image2, alpha: easedProgress) {
                frames.append(frame)
            }
            onProgress(Float(i + 1) / Float(frameCount))
        }
        
        return frames
    }
    
    // MARK: - Slide Transition
    
    private nonisolated func generateSlideFrames(
        image1: CGImage,
        image2: CGImage,
        frameCount: Int,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        let width = image1.width
        let height = image1.height
        
        for i in 0..<frameCount {
            let progress = Float(i) / Float(max(1, frameCount - 1))
            let easedProgress = easeInOutCubic(progress)
            
            if let frame = createSlideFrame(image1: image1, image2: image2, width: width, height: height, progress: easedProgress) {
                frames.append(frame)
            }
            onProgress(Float(i + 1) / Float(frameCount))
        }
        
        return frames
    }
    
    // MARK: - Zoom Transition
    
    private nonisolated func generateZoomFrames(
        image1: CGImage,
        image2: CGImage,
        frameCount: Int,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        let width = image1.width
        let height = image1.height
        
        for i in 0..<frameCount {
            let progress = Float(i) / Float(max(1, frameCount - 1))
            let easedProgress = easeInOutCubic(progress)
            
            if let frame = createZoomFrame(image1: image1, image2: image2, width: width, height: height, progress: easedProgress) {
                frames.append(frame)
            }
            onProgress(Float(i + 1) / Float(frameCount))
        }
        
        return frames
    }
    
    // MARK: - Helper Functions
    
    private nonisolated func blendImages(_ img1: CGImage, _ img2: CGImage, alpha: Float) -> CGImage? {
        let width = img1.width
        let height = img1.height
        
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        ctx.setAlpha(CGFloat(1.0 - alpha))
        ctx.draw(img1, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        ctx.setAlpha(CGFloat(alpha))
        ctx.draw(img2, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return ctx.makeImage()
    }
    
    private nonisolated func createSlideFrame(image1: CGImage, image2: CGImage, width: Int, height: Int, progress: Float) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        let offset = CGFloat(progress) * CGFloat(width)
        
        ctx.draw(image1, in: CGRect(x: -offset, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.draw(image2, in: CGRect(x: CGFloat(width) - offset, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        return ctx.makeImage()
    }
    
    private nonisolated func createZoomFrame(image1: CGImage, image2: CGImage, width: Int, height: Int, progress: Float) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        // 第一张图放大并淡出
        let scale1 = 1.0 + CGFloat(progress) * 0.8
        let w1 = CGFloat(width) * scale1
        let h1 = CGFloat(height) * scale1
        let x1 = (CGFloat(width) - w1) / 2
        let y1 = (CGFloat(height) - h1) / 2
        
        // 使用平方曲线使淡出更快
        let alpha1 = pow(1.0 - CGFloat(progress), 2.0)
        ctx.setAlpha(alpha1)
        ctx.draw(image1, in: CGRect(x: x1, y: y1, width: w1, height: h1))
        
        // 第二张图从小缩放进入
        let scale2 = 0.3 + CGFloat(progress) * 0.7
        let w2 = CGFloat(width) * scale2
        let h2 = CGFloat(height) * scale2
        let x2 = (CGFloat(width) - w2) / 2
        let y2 = (CGFloat(height) - h2) / 2
        
        // 使用平方根曲线使淡入更平滑
        let alpha2 = sqrt(CGFloat(progress))
        ctx.setAlpha(alpha2)
        ctx.draw(image2, in: CGRect(x: x2, y: y2, width: w2, height: h2))
        
        return ctx.makeImage()
    }
    
    private nonisolated func resizeImage(_ image: CGImage, toWidth targetWidth: Int) -> CGImage {
        if image.width == targetWidth {
            return image
        }
        
        let aspectRatio = Double(image.height) / Double(image.width)
        let targetHeight = max(1, Int(Double(targetWidth) * aspectRatio))
        
        guard let ctx = CGContext(
            data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        return ctx.makeImage() ?? image
    }
    
    /// 提取图片主题色
    private nonisolated func extractDominantColor(from image: CGImage) -> NSColor {
        let sampleSize = 40
        guard let ctx = CGContext(
            data: nil, width: sampleSize, height: sampleSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return .gray }
        
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        
        guard let smallImage = ctx.makeImage(),
              let data = smallImage.dataProvider?.data as Data? else {
            return .gray
        }
        
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        var count = 0
        let bytesPerPixel = 4
        let bytesPerRow = smallImage.bytesPerRow
        
        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if offset + 3 < data.count {
                    // BGRA layout (byteOrder32Little + premultipliedFirst)
                    b += CGFloat(data[offset]) / 255.0
                    g += CGFloat(data[offset + 1]) / 255.0
                    r += CGFloat(data[offset + 2]) / 255.0
                    count += 1
                }
            }
        }
        
        guard count > 0 else { return .gray }
        return NSColor(
            red: r / CGFloat(count),
            green: g / CGFloat(count),
            blue: b / CGFloat(count),
            alpha: 1.0
        )
    }
}
