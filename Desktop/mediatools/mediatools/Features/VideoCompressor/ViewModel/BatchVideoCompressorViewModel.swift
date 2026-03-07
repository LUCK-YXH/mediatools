//
//  BatchVideoCompressorViewModel.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - BatchVideoItem

@Observable final class BatchVideoItem: Identifiable {
    let id = UUID()
    let filename: String
    let sourceURL: URL
    let originalSize: Int
    var thumbnail: NSImage?
    var duration: String = "--"
    var status: BatchItemStatus = .idle
    var progress: Float = 0
    var result: VideoCompressionResult?
    var errorMessage: String?

    init(filename: String, sourceURL: URL) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.originalSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

// MARK: - BatchVideoCompressorViewModel

@Observable final class BatchVideoCompressorViewModel {
    var items: [BatchVideoItem] = []
    var selectedPreset: VideoCompressionPreset = .p1080
    var customSizeMB: String = ""
    var isCompressing = false

    var canCompress: Bool {
        !isCompressing && items.contains { $0.status == .idle || $0.status == .failed }
    }
    var canSave: Bool { items.contains { $0.status == .done } }

    var isCustomSizeValid: Bool {
        selectedPreset != .custom || (Double(customSizeMB) != nil && Double(customSizeMB)! > 0)
    }

    private var effectiveFileLimitBytes: Int64? {
        guard selectedPreset == .custom, let mb = Double(customSizeMB), mb > 0 else { return nil }
        return Int64(mb * 1_048_576)
    }

    // MARK: - Item Management

    func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFromURLs(panel.urls)
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

    func remove(_ item: BatchVideoItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() { items.removeAll() }

    // MARK: - Compression

    func compressAll() {
        guard canCompress, isCustomSizeValid else { return }
        isCompressing = true
        let preset = selectedPreset
        let limitBytes = effectiveFileLimitBytes
        let pending = items.filter { $0.status == .idle || $0.status == .failed }
        Task.detached(priority: .userInitiated) { [weak self] in
            for item in pending {
                await MainActor.run { item.status = .compressing; item.progress = 0; item.errorMessage = nil }
                await Task.yield()
                do {
                    let result = try await VideoCompressor.shared.compress(
                        url: item.sourceURL,
                        preset: preset,
                        fileLimitBytes: limitBytes
                    ) { p in
                        Task { @MainActor in item.progress = p }
                    }
                    await MainActor.run { item.result = result; item.status = .done }
                } catch {
                    await MainActor.run { item.status = .failed; item.errorMessage = error.localizedDescription }
                }
                await Task.yield()
            }
            await MainActor.run { [weak self] in self?.isCompressing = false }
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
            guard let outputURL = item.result?.outputURL else { continue }
            let base = (item.filename as NSString).deletingPathExtension
            let dest = directory.appendingPathComponent("\(base)_compressed.mp4")
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    func saveItem(_ item: BatchVideoItem) {
        guard let outputURL = item.result?.outputURL else { return }
        let base = (item.filename as NSString).deletingPathExtension
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "\(base)_compressed.mp4"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    // MARK: - Preview

    private static var previewControllers: [NSWindowController] = []

    func openPreview(for item: BatchVideoItem) {
        guard let outputURL = item.result?.outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    // MARK: - Formatting

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    // MARK: - Private

    private func addFromURLs(_ urls: [URL]) {
        let existingURLs = Set(items.map { $0.sourceURL })
        for url in urls {
            guard !existingURLs.contains(url) else { continue }
            let item = BatchVideoItem(filename: url.lastPathComponent, sourceURL: url)
            items.append(item)
            Task.detached(priority: .utility) { [item, url] in
                let thumb = await VideoCompressor.shared.thumbnail(for: url, size: 80)
                let dur   = await VideoCompressor.shared.durationString(for: url)
                await MainActor.run {
                    item.thumbnail = thumb
                    item.duration  = dur
                }
            }
        }
    }
}
