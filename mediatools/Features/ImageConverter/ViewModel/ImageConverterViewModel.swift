//
//  ImageConverterViewModel.swift
//  mediatools
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ConvertItem

@Observable final class ConvertItem: Identifiable {
    let id          = UUID()
    let filename:     String
    let sourceURL:    URL
    let originalSize: Int
    var thumbnail:    NSImage?
    var status:       BatchItemStatus = .idle
    var result:       ImageConversionResult?
    var errorMessage: String?

    init(filename: String, sourceURL: URL) {
        self.filename    = filename
        self.sourceURL   = sourceURL
        self.originalSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

// MARK: - ViewModel

@Observable
final class ImageConverterViewModel {

    var items:          [ConvertItem]      = []
    var targetFormat:   ImageConvertFormat = .jpeg
    var quality:        Double             = 0.85   // 0.0–1.0，JPEG/WebP 有效
    var isConverting:   Bool               = false

    // MARK: - Computed

    var canConvert: Bool {
        !isConverting && items.contains { $0.status == .idle || $0.status == .failed }
    }
    var canSave: Bool { items.contains { $0.status == .done } }

    // MARK: - Item Management

    func addImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes  = [.jpeg, .png, .webP, .heic,
                                       UTType("public.tiff") ?? .tiff,
                                       UTType("com.microsoft.bmp") ?? .image,
                                       .gif]
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

    func remove(_ item: ConvertItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    // MARK: - Conversion

    func convertAll() {
        guard canConvert else { return }
        isConverting = true
        let fmt     = targetFormat
        let quality = self.quality
        let pending = items.filter { $0.status == .idle || $0.status == .failed }

        Task.detached(priority: .userInitiated) { [weak self] in
            for item in pending {
                await MainActor.run { item.status = .compressing; item.errorMessage = nil }
                await Task.yield()
                do {
                    let result = try ImageConverter.shared.convert(
                        url: item.sourceURL, to: fmt, quality: quality
                    )
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

        for item in done {
            guard let outputURL = item.result?.outputURL else { continue }
            let base = (item.filename as NSString).deletingPathExtension
            let ext  = targetFormat.fileExtension
            let dest = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    func saveItem(_ item: ConvertItem) {
        guard let outputURL = item.result?.outputURL else { return }
        let base = (item.filename as NSString).deletingPathExtension
        let fmt  = targetFormat
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [fmt.utType]
            panel.nameFieldStringValue = "\(base).\(fmt.fileExtension)"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    // MARK: - Preview

    private static var previewControllers: [NSWindowController] = []

    func openPreview(for item: ConvertItem) {
        guard let outputURL = item.result?.outputURL,
              let image = NSImage(contentsOf: outputURL) else { return }
        let view = Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: view)
        let ratio   = image.size.width / max(image.size.height, 1)
        let w: CGFloat = 800
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: w / ratio),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title       = "\(item.filename) → \(targetFormat.rawValue)"
        window.contentView = hosting
        window.center()
        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        Self.previewControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak controller] _ in
            Self.previewControllers.removeAll { $0 === controller }
        }
    }

    // MARK: - Helpers

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    // MARK: - Private

    private func addFromURLs(_ urls: [URL]) {
        let existing = Set(items.map { $0.sourceURL })
        for url in urls {
            guard !existing.contains(url) else { continue }
            let item = ConvertItem(filename: url.lastPathComponent, sourceURL: url)
            items.append(item)
            // 异步加载缩略图
            Task.detached(priority: .utility) { [item, url] in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 80,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                else { return }
                let thumb = NSImage(cgImage: cgThumb, size: .zero)
                await MainActor.run { item.thumbnail = thumb }
            }
        }
    }
}
