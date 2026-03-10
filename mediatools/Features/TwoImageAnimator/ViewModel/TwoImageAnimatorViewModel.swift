//
//  TwoImageAnimatorViewModel.swift
//  mediatools
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@Observable
final class TwoImageAnimatorViewModel {
    // 图片状态
    var image1: NSImage?
    var image2: NSImage?
    
    // 转换参数
    var selectedTransition: TransitionType = .beforeAfterSlider
    var selectedFormat: AnimatedFormat = .gif
    var selectedFps: Int = 15
    var duration: Double = 3.0
    var durationString: String = "3.0"
    var selectedWidthOption: WidthOption = .w480
    var customWidthString: String = "640"
    var selectedLoopOption: LoopOption = .infinite
    var selectedDividerStyle: DividerStyle = .gradient
    
    // 转换状态
    var isConverting = false
    var progress: Float = 0.0
    var result: TwoImageAnimatorResult?
    var errorMessage: String?
    
    // MARK: - Computed Properties
    
    var canConvert: Bool {
        image1 != nil && image2 != nil && !isConverting
    }
    
    var canPreview: Bool {
        result != nil
    }
    
    var canSave: Bool {
        result != nil
    }
    
    var estimatedFrameCount: Int {
        max(1, Int(duration * Double(selectedFps)))
    }
    
    // MARK: - Image Selection
    
    func pickImage1() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择第一张图片"
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadImage(url: url, isFirst: true)
        }
    }
    
    func pickImage2() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择第二张图片"
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadImage(url: url, isFirst: false)
        }
    }
    
    func handleDrop1(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                self?.loadImage(url: url, isFirst: true)
            }
        }
        return true
    }
    
    func handleDrop2(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                self?.loadImage(url: url, isFirst: false)
            }
        }
        return true
    }
    
    private func loadImage(url: URL, isFirst: Bool) {
        guard let image = NSImage(contentsOf: url) else { return }
        if isFirst {
            image1 = image
        } else {
            image2 = image
        }
    }
    
    // MARK: - Conversion
    
    func convert() {
        guard let img1 = image1, let img2 = image2, !isConverting else { return }
        
        errorMessage = nil
        result = nil
        isConverting = true
        progress = 0.0
        
        // 解析时长
        if let d = Double(durationString), d > 0 {
            duration = d
        }
        
        let width: Int? = {
            switch selectedWidthOption {
            case .original: return nil
            case .w320: return 320
            case .w480: return 480
            case .w640: return 640
            case .custom:
                if let w = Int(customWidthString), w > 0 {
                    return w
                }
                return 480
            }
        }()
        
        let loopCount: Int? = {
            switch selectedLoopOption {
            case .once: return nil
            case .infinite: return 0
            }
        }()
        
        let config = TwoImageAnimatorConfig(
            image1: img1,
            image2: img2,
            transitionType: selectedTransition,
            fps: selectedFps,
            duration: duration,
            outputWidth: width,
            format: selectedFormat,
            loopCount: loopCount,
            quality: 85,
            dividerStyle: selectedDividerStyle
        )
        
        Task { @MainActor in
            do {
                let r = try await TwoImageAnimator.shared.createAnimated(config: config) { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                    }
                }
                self.result = r
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isConverting = false
        }
    }
    
    func previewResult() {
        guard let result = result else { return }
        NSWorkspace.shared.open(result.outputURL)
    }
    
    func saveResult() {
        guard let result = result else { return }
        
        let panel = NSSavePanel()
        let ext = selectedFormat == .gif ? "gif" : "heics"
        panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
        panel.nameFieldStringValue = "两图动画.\(ext)"
        
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.copyItem(at: result.outputURL, to: dest)
        }
    }
    
    func sizeLabel(bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Helper Enums

enum WidthOption: String, CaseIterable, Identifiable {
    case original = "原始"
    case w320 = "320px"
    case w480 = "480px"
    case w640 = "640px"
    case custom = "自定义"
    
    var id: String { rawValue }
}

enum LoopOption: String, CaseIterable, Identifiable {
    case once = "播放一次"
    case infinite = "无限循环"
    
    var id: String { rawValue }
}
