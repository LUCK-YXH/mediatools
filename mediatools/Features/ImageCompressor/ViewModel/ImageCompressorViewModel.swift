//
//  ImageCompressorViewModel.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit
import Observation
import UniformTypeIdentifiers

enum CompressionPreset: String, CaseIterable, Identifiable {
    case small   = "200 KB"
    case medium  = "500 KB"
    case large   = "1 MB"
    case custom  = "自定义"

    var id: String { rawValue }

    var config: ImageCompressionConfig {
        switch self {
        case .small:  return .smallConfig
        case .medium: return .mediumConfig
        case .large:  return .defaultConfig
        case .custom: return .defaultConfig   // placeholder; effectiveConfig handles custom
        }
    }
}

@Observable
final class ImageCompressorViewModel {
    var selectedImage: NSImage?
    var originalFileSize: Int = 0
    var result: ImageCompressionResult?
    var selectedPreset: CompressionPreset = .large
    var customSizeKB: String = ""
    var errorMessage: String?

    var canCompress: Bool { selectedImage != nil }
    var canSave: Bool { result != nil }

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

    // MARK: - Image Loading

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(from: url)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self?.loadImage(from: url) }
            }
            return true
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { [weak self] object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async {
                    self?.selectedImage = image
                    self?.result = nil
                }
            }
            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "无法加载图片"
            return
        }
        selectedImage = image
        result = nil
        errorMessage = nil
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            originalFileSize = size
        } else {
            originalFileSize = image.tiffRepresentation?.count ?? 0
        }
    }

    // MARK: - Compression

    func compress() {
        guard let image = selectedImage else { return }
        errorMessage = nil
        result = ImageCompressor.shared.compress(image, config: effectiveConfig)
        if result == nil { errorMessage = "压缩失败，请检查图片格式" }
    }

    // MARK: - Export

    func saveResult() {
        guard let data = result?.data else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "compressed.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatting

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}
