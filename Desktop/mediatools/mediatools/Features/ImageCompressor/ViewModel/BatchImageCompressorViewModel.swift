//
//  BatchImageCompressorViewModel.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - BatchItem Status

enum BatchItemStatus: Equatable {
    case idle, compressing, done, failed
}

// MARK: - BatchItem

@Observable final class BatchItem: Identifiable {
    let id = UUID()
    let filename: String
    let sourceURL: URL?
    let image: NSImage
    var status: BatchItemStatus = .idle
    var result: ImageCompressionResult?
    let originalSize: Int

    init(filename: String, sourceURL: URL?, image: NSImage) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.image = image
        if let url = sourceURL,
           let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            self.originalSize = size
        } else {
            self.originalSize = image.tiffRepresentation?.count ?? 0
        }
    }
}

// MARK: - BatchImageCompressorViewModel

@Observable final class BatchImageCompressorViewModel {
    var items: [BatchItem] = []
    var selectedPreset: CompressionPreset = .large
    var customSizeKB: String = ""
    var isCompressing = false

    var canCompress: Bool {
        !isCompressing && items.contains { $0.status == .idle || $0.status == .failed }
    }

    var canSave: Bool {
        items.contains { $0.status == .done }
    }

    var effectiveConfig: ImageCompressionConfig {
        if selectedPreset == .custom {
            let kb = max(1, Int(customSizeKB) ?? 1024)
            return ImageCompressionConfig(maxFileSize: kb * 1024)
        }
        return selectedPreset.config
    }

    var isCustomSizeValid: Bool {
        selectedPreset != .custom || (Int(customSizeKB) != nil && Int(customSizeKB)! > 0)
    }

    // MARK: - Image Management

    func addImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        addFromURLs(urls)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { self?.addFromURLs([url]) }
                }
                handled = true
            }
        }
        return handled
    }

    func remove(_ item: BatchItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    // MARK: - Compression

    func compressAll() {
        guard canCompress, isCustomSizeValid else { return }
        isCompressing = true
        let config = effectiveConfig
        let pending = items.filter { $0.status == .idle || $0.status == .failed }
        Task {
            for item in pending {
                item.status = .compressing
                await Task.yield()
                let result = ImageCompressor.shared.compress(item.image, config: config)
                item.result = result
                item.status = result != nil ? .done : .failed
                await Task.yield()
            }
            isCompressing = false
        }
    }

    // MARK: - Export

    func saveAll() {
        let doneItems = items.filter { $0.status == .done }
        guard !doneItems.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择保存目录"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        for item in doneItems {
            guard let data = item.result?.data else { continue }
            let baseName = (item.filename as NSString).deletingPathExtension
            let destURL = directory.appendingPathComponent("\(baseName)_compressed.jpg")
            try? data.write(to: destURL)
        }
    }

    func saveItem(_ item: BatchItem) {
        guard let data = item.result?.data else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let baseName = (item.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName)_compressed.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    // MARK: - Preview

    private static var previewControllers: [NSWindowController] = []

    func openPreview(for item: BatchItem) {
        guard let data = item.result?.data, let image = NSImage(data: data) else { return }
        let content = Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: content)
        let aspectRatio = image.size.width / max(image.size.height, 1)
        let winWidth: CGFloat = 800
        let winHeight = winWidth / aspectRatio
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.filename
        window.contentView = hosting
        window.center()
        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        Self.previewControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak controller] _ in
            Self.previewControllers.removeAll { $0 === controller }
        }
    }

    // MARK: - Formatting

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    // MARK: - Private

    private func addFromURLs(_ urls: [URL]) {
        let existingURLs = Set(items.compactMap { $0.sourceURL })
        for url in urls {
            guard !existingURLs.contains(url),
                  let image = NSImage(contentsOf: url) else { continue }
            let item = BatchItem(filename: url.lastPathComponent, sourceURL: url, image: image)
            items.append(item)
        }
    }
}
