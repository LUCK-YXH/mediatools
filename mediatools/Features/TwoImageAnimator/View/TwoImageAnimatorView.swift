//
//  TwoImageAnimatorView.swift
//  mediatools
//

import SwiftUI
import UniformTypeIdentifiers

struct TwoImageAnimatorView: View {
    @State private var vm = TwoImageAnimatorViewModel()
    @State private var isTargeted1 = false
    @State private var isTargeted2 = false
    @State private var showPreviewWindow = false
    
    var body: some View {
        HSplitView {
            leftPanel.frame(minWidth: 400)
            rightPanel.frame(minWidth: 320)
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showPreviewWindow) {
            if let result = vm.result {
                AnimatedPreviewWindow(result: result)
            }
        }
    }
    
    // MARK: - Left Panel
    
    private var leftPanel: some View {
        VStack(spacing: 16) {
            Text("选择图片").font(.headline)
            
            HStack(spacing: 16) {
                imageDropArea(
                    image: vm.image1,
                    isTargeted: $isTargeted1,
                    label: "第一张图片",
                    onTap: { vm.pickImage1() },
                    onDrop: { vm.handleDrop1($0) }
                )
                
                Image(systemName: "arrow.right")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                
                imageDropArea(
                    image: vm.image2,
                    isTargeted: $isTargeted2,
                    label: "第二张图片",
                    onTap: { vm.pickImage2() },
                    onDrop: { vm.handleDrop2($0) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
    
    @ViewBuilder
    private func imageDropArea(
        image: NSImage?,
        isTargeted: Binding<Bool>,
        label: String,
        onTap: @escaping () -> Void,
        onDrop: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted.wrappedValue ? Color.accentColor.opacity(0.08) : Color.clear)
                )
            
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(8)
                    .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("点击或拖入图片")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            onDrop(providers)
        }
    }
    
    // MARK: - Right Panel
    
    private var rightPanel: some View {
        VStack(spacing: 16) {
            Text("转换设置").font(.headline)
            
            pickerRow(label: "过渡效果") {
                Picker("", selection: $vm.selectedTransition) {
                    ForEach(TransitionType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            if vm.selectedTransition == .beforeAfterSlider {
                pickerRow(label: "分割线样式") {
                    Picker("", selection: $vm.selectedDividerStyle) {
                        ForEach(DividerStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            
            pickerRow(label: "格式") {
                Picker("", selection: $vm.selectedFormat) {
                    ForEach(AnimatedFormat.allCases) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            pickerRow(label: "帧率") {
                Picker("", selection: $vm.selectedFps) {
                    ForEach([5, 10, 15, 24], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            pickerRow(label: "时长") {
                Picker("", selection: $vm.durationString) {
                    Text("1.5秒").tag("1.5")
                    Text("2秒").tag("2.0")
                    Text("3秒").tag("3.0")
                    Text("4秒").tag("4.0")
                    Text("5秒").tag("5.0")
                }
                .pickerStyle(.segmented)
            }
            
            HStack {
                Spacer()
                Text("约 \(vm.estimatedFrameCount) 帧")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            pickerRow(label: "宽度") {
                Picker("", selection: $vm.selectedWidthOption) {
                    ForEach(WidthOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            if vm.selectedWidthOption == .custom {
                HStack {
                    TextField("像素", text: $vm.customWidthString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            
            pickerRow(label: "循环") {
                Picker("", selection: $vm.selectedLoopOption) {
                    ForEach(LoopOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            if vm.isConverting {
                VStack(spacing: 6) {
                    ProgressView(value: vm.progress).progressViewStyle(.linear)
                    Text(String(format: "生成中 %.0f%%", vm.progress * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let result = vm.result {
                resultView(result: result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            
            HStack(spacing: 12) {
                Button("生成动图") { vm.convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canConvert)
                Button("预览") { showPreviewWindow = true }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canPreview)
                Button("保存") { vm.saveResult() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canSave)
            }
            
            if let error = vm.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
    }
    
    @ViewBuilder
    private func pickerRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
    
    private func resultView(result: TwoImageAnimatorResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("生成完成").font(.headline)
            HStack(spacing: 28) {
                statItem(label: "帧数", value: "\(result.frameCount) 帧")
                statItem(label: "文件大小", value: result.sizeString)
            }
        }
    }
    
    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Animated Preview Window

struct AnimatedPreviewWindow: View {
    let result: TwoImageAnimatorResult
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("动图预览")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            
            AnimatedImageView(url: result.previewURL)
                .frame(maxWidth: 800, maxHeight: 600)
            
            HStack(spacing: 16) {
                statItem(label: "帧数", value: "\(result.frameCount)")
                statItem(label: "文件大小", value: result.sizeString)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    
    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .bold()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 使用 NSImageView 播放动图的 NSViewRepresentable 包装
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.canDrawSubviewsIntoLayer = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let image = NSImage(contentsOf: url) {
            imageView.image = image
        }
        return imageView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        if let image = NSImage(contentsOf: url) {
            nsView.image = image
            nsView.animates = true
        }
    }
}

#Preview {
    TwoImageAnimatorView()
}
