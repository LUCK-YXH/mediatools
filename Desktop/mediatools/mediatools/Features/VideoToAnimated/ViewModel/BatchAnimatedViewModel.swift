//
//  BatchAnimatedViewModel.swift
//  mediatools
//

import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

// MARK: - BatchAnimatedItem

@Observable final class BatchAnimatedItem: Identifiable {
    let id       = UUID()
    let filename: String
    let sourceURL: URL
    let originalSize: Int
    var thumbnail: NSImage?
    var duration: String = "--"
    var status: BatchItemStatus = .idle
    var progress: Float = 0
    var result: AnimatedResult?
    var errorMessage: String?

    init(filename: String, sourceURL: URL) {
        self.filename    = filename
        self.sourceURL   = sourceURL
        self.originalSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

// MARK: - ViewModel

@Observable
final class BatchAnimatedViewModel {

    var items: [BatchAnimatedItem] = []

    // 转换设置（全局共享，应用于所有 item）
    var selectedFormat:      AnimatedFormat      = .webP
    var selectedFps:         Int                 = 15
    var selectedWidthOption: AnimatedWidthOption = .w480
    var customWidthString:   String              = ""
    var selectedLoopOption:  AnimatedLoopOption  = .infinite
    var selectedPreset:      AnimatedPreset      = .coverImage
    var webpQuality:         Float               = 75
    var webpLimitSize:       Bool                = true

    var isConverting = false

    // MARK: - Computed

    var canConvert: Bool { !isConverting && items.contains { $0.status == .idle || $0.status == .failed } }
    var canSave:    Bool { items.contains { $0.status == .done } }

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

    private func makeConfig(duration: Double) -> AnimatedConfig {
        AnimatedConfig(
            startTime: 0,
            endTime: selectedPreset == .coverImage ? min(5.0, duration) : duration,
            fps: selectedFps,
            outputWidth: effectiveOutputWidth,
            format: selectedFormat,
            loopCount: selectedLoopOption.loopCount,
            quality: webpQuality,
            targetFileSize: (selectedFormat == .webP && webpLimitSize) ? 600 * 1024 : nil
        )
    }

    // MARK: - Preset

    func applyPreset(_ preset: AnimatedPreset) {
        selectedPreset = preset
        guard preset == .coverImage else { return }
        selectedFormat      = .webP
        selectedFps         = 15
        selectedWidthOption = .w480
        selectedLoopOption  = .infinite
        webpQuality         = 75
        webpLimitSize       = true
    }

    // MARK: - Item Management

    func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes  = [.mpeg4Movie, .movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFromURLs(panel.urls)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let data = item as? Data,
                      let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self?.addFromURLs([url]) }
            }
            handled = true
        }
        return handled
    }

    func remove(_ item: BatchAnimatedItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    // MARK: - Conversion

    func convertAll() {
        guard canConvert else { return }
        isConverting = true
        let pending = items.filter { $0.status == .idle || $0.status == .failed }

        Task.detached(priority: .userInitiated) { [weak self] in
            for item in pending {
                guard let self else { break }
                await MainActor.run { item.status = .compressing; item.progress = 0; item.errorMessage = nil }
                await Task.yield()

                // 获取实际视频时长以决定截取范围
                let dur = await AnimatedConverter.shared.videoDuration(for: item.sourceURL)
                let config = await self.makeConfig(duration: dur)

                do {
                    let result = try await AnimatedConverter.shared.convert(
                        url: item.sourceURL,
                        config: config
                    ) { p in
                        Task { @MainActor in item.progress = p }
                    }
                    await MainActor.run { item.result = result; item.status = .done }
                } catch {
                    await MainActor.run { item.status = .failed; item.errorMessage = error.localizedDescription }
                }
                await Task.yield()
            }
            await MainActor.run { [weak self] in self?.isConverting = false }
        }
    }

    // MARK: - Save

    func saveAll() {
        let done = items.filter { $0.status == .done }
        guard !done.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择保存目录"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let ext = fileExtension(for: selectedFormat)
        for item in done {
            guard let outputURL = item.result?.outputURL else { continue }
            let base = (item.filename as NSString).deletingPathExtension
            let dest = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    func saveItem(_ item: BatchAnimatedItem) {
        guard let outputURL = item.result?.outputURL else { return }
        let base = (item.filename as NSString).deletingPathExtension
        let ext  = fileExtension(for: selectedFormat)
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [self.contentType(for: self.selectedFormat)]
            panel.nameFieldStringValue = "\(base).\(ext)"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    // MARK: - Preview

    private static var previewWindows: [NSWindow] = []

    func previewItem(_ item: BatchAnimatedItem) {
        guard let outputURL = item.result?.outputURL else { return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        webView.loadFileURL(outputURL, allowingReadAccessTo: outputURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.filename
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        BatchAnimatedViewModel.previewWindows.append(window)
    }

    // MARK: - Helpers

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    private func fileExtension(for format: AnimatedFormat) -> String {
        switch format {
        case .gif:   return "gif"
        case .heics: return "heics"
        case .webP:  return "webp"
        }
    }

    private func contentType(for format: AnimatedFormat) -> UTType {
        switch format {
        case .gif:   return .gif
        case .heics: return UTType("public.heics") ?? .data
        case .webP:  return .webP
        }
    }

    // MARK: - Private

    private func addFromURLs(_ urls: [URL]) {
        let existing = Set(items.map { $0.sourceURL })
        for url in urls {
            guard !existing.contains(url) else { continue }
            let item = BatchAnimatedItem(filename: url.lastPathComponent, sourceURL: url)
            items.append(item)
            Task.detached(priority: .utility) { [item, url] in
                let thumb = await AnimatedConverter.shared.thumbnail(for: url, size: 80)
                let dur   = await AnimatedConverter.shared.videoDuration(for: url)
                let durStr = dur > 0 ? String(format: "%.1fs", dur) : "--"
                await MainActor.run {
                    item.thumbnail = thumb
                    item.duration  = durStr
                }
            }
        }
    }
}
