//
//  VideoCompressorViewModel.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class VideoCompressorViewModel {
    var selectedURL: URL?
    var thumbnail: NSImage?
    var originalSize: Int = 0
    var duration: String = "--"
    var selectedPreset: VideoCompressionPreset = .p1080
    var customSizeMB: String = ""
    var result: VideoCompressionResult?
    var progress: Float = 0
    var isCompressing = false
    var errorMessage: String?

    var canCompress: Bool { selectedURL != nil && !isCompressing }
    var canSave: Bool { result != nil }

    var isCustomSizeValid: Bool {
        selectedPreset != .custom || (Double(customSizeMB) != nil && Double(customSizeMB)! > 0)
    }

    private var effectiveFileLimitBytes: Int64? {
        guard selectedPreset == .custom, let mb = Double(customSizeMB), mb > 0 else { return nil }
        return Int64(mb * 1_048_576)
    }

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
        originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        thumbnail = nil
        duration = "--"
        Task.detached(priority: .utility) { [weak self, url] in
            let thumb = await VideoCompressor.shared.thumbnail(for: url)
            let dur   = await VideoCompressor.shared.durationString(for: url)
            await MainActor.run {
                self?.thumbnail = thumb
                self?.duration  = dur
            }
        }
    }

    // MARK: - Compression

    func compress() {
        guard let url = selectedURL, isCustomSizeValid else { return }
        isCompressing = true
        result = nil
        errorMessage = nil
        progress = 0
        let preset = selectedPreset
        let limitBytes = effectiveFileLimitBytes
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await VideoCompressor.shared.compress(
                    url: url, preset: preset, fileLimitBytes: limitBytes
                ) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                await MainActor.run { [weak self] in
                    self?.result = r
                    self?.isCompressing = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isCompressing = false
                }
            }
        }
    }

    // MARK: - Export

    func saveResult() {
        guard let outputURL = result?.outputURL else { return }
        let name = ((selectedURL?.lastPathComponent ?? "video") as NSString).deletingPathExtension
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "\(name)_compressed.mp4"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.copyItem(at: outputURL, to: dest)
        }
    }

    // MARK: - Formatting

    func sizeLabel(bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}
