//
//  AnimatedViewModel.swift
//  mediatools
//

import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

// MARK: - Supporting Enums

enum AnimatedLoopOption: String, CaseIterable, Identifiable {
    case infinite = "无限"
    case once     = "一次"
    case noLoop   = "不循环"

    var id: String { rawValue }

    var loopCount: Int? {
        switch self {
        case .infinite: return 0
        case .once:     return 1
        case .noLoop:   return nil
        }
    }
}

enum AnimatedWidthOption: String, CaseIterable, Identifiable {
    case original = "原始"
    case w640     = "640px"
    case w480     = "480px"
    case w320     = "320px"
    case custom   = "自定义"

    var id: String { rawValue }
}

enum AnimatedPreset: String, CaseIterable, Identifiable {
    case none      = "无"
    case coverImage = "封面图"

    var id: String { rawValue }
}

// MARK: - ViewModel

@Observable
final class AnimatedViewModel {
    var selectedURL: URL?
    var thumbnail: NSImage?
    var originalSize: Int = 0
    var videoDurationSeconds: Double = 0

    var startTimeString: String = "0"
    var endTimeString: String = ""

    var selectedFormat: AnimatedFormat = .gif
    var selectedFps: Int = 10
    var selectedWidthOption: AnimatedWidthOption = .original
    var customWidthString: String = ""
    var selectedLoopOption: AnimatedLoopOption = .infinite
    var selectedPreset: AnimatedPreset = .none
    var webpQuality: Float = 85   // WebP only, 1–100
    var webpLimitSize = false     // 开启后目标 600 KB

    var isConverting = false
    var progress: Float = 0
    var result: AnimatedResult?
    var errorMessage: String?

    // MARK: - Computed

    var startTime: Double { Double(startTimeString) ?? 0 }
    var endTime: Double   { Double(endTimeString) ?? videoDurationSeconds }

    var clippedDuration: Double       { max(0, endTime - startTime) }
    var clippedDurationString: String { String(format: "%.1f", clippedDuration) }
    var estimatedFrameCount: Int      { max(0, Int(clippedDuration * Double(selectedFps)) + 1) }

    var isTimeRangeValid: Bool {
        videoDurationSeconds > 0 &&
        startTime >= 0 &&
        endTime > startTime &&
        endTime <= videoDurationSeconds + 0.1
    }

    var effectiveOutputWidth: Int? {
        switch selectedWidthOption {
        case .original: return nil
        case .w640:     return 640
        case .w480:     return 480
        case .w320:     return 320
        case .custom:
            guard let w = Int(customWidthString), w > 0 else { return nil }
            return w
        }
    }

    // 应用预设：封面图模式 = WebP / 15fps / 480px / 无限循环 / 前5秒 / 质量75
    func applyPreset(_ preset: AnimatedPreset) {
        selectedPreset = preset
        guard preset == .coverImage else { return }
        selectedFormat      = .webP
        selectedFps         = 15
        selectedWidthOption = .w480
        selectedLoopOption  = .infinite
        webpQuality         = 75
        webpLimitSize       = true
        // 若视频时长已知，截取前5秒；否则等加载完再说
        if videoDurationSeconds > 0 {
            startTimeString = "0"
            endTimeString   = String(format: "%.1f", min(5.0, videoDurationSeconds))
        }
    }

    var canConvert: Bool { selectedURL != nil && !isConverting && isTimeRangeValid }
    var canSave: Bool    { result != nil }
    var canPreview: Bool { result != nil }

    // MARK: - Video Loading

    func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { self?.load(from: url) }
        }
        return true
    }

    private func load(from url: URL) {
        selectedURL = url
        result = nil
        errorMessage = nil
        progress = 0
        thumbnail = nil
        videoDurationSeconds = 0
        originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        startTimeString = "0"
        endTimeString = ""

        Task.detached(priority: .utility) { [weak self, url] in
            let thumb = await AnimatedConverter.shared.thumbnail(for: url)
            let dur   = await AnimatedConverter.shared.videoDuration(for: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                thumbnail = thumb
                videoDurationSeconds = dur
                if endTimeString.isEmpty {
                    endTimeString = String(format: "%.1f", dur)
                }
            }
        }
    }

    // MARK: - Conversion

    func convert() {
        guard canConvert, let url = selectedURL else { return }
        let config = AnimatedConfig(
            startTime: startTime,
            endTime: endTime,
            fps: selectedFps,
            outputWidth: effectiveOutputWidth,
            format: selectedFormat,
            loopCount: selectedLoopOption.loopCount,
            quality: webpQuality,
            targetFileSize: (selectedFormat == .webP && webpLimitSize) ? 600 * 1024 : nil
        )
        isConverting = true
        result = nil
        errorMessage = nil
        progress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await AnimatedConverter.shared.convert(
                    url: url, config: config
                ) { [weak self] p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    result = r
                    isConverting = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    errorMessage = error.localizedDescription
                    isConverting = false
                }
            }
        }
    }

    // MARK: - Save

    func saveResult() {
        guard let outputURL = result?.outputURL else { return }
        let baseName = ((selectedURL?.lastPathComponent ?? "video") as NSString).deletingPathExtension
        let (ext, contentType): (String, UTType) = switch selectedFormat {
        case .gif:   ("gif",   .gif)
        case .heics: ("heics", UTType("public.heics") ?? .data)
        case .webP:  ("webp",  .webP)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try? FileManager.default.copyItem(at: outputURL, to: dest)
    }

    // MARK: - Preview

    // 持有预览窗口，防止 ARC 提前释放
    private static var previewWindows: [NSWindow] = []

    func previewResult() {
        guard let outputURL = result?.outputURL else { return }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        webView.loadFileURL(outputURL, allowingReadAccessTo: outputURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "预览"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        AnimatedViewModel.previewWindows.append(window)
    }

    // MARK: - Helpers

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}
