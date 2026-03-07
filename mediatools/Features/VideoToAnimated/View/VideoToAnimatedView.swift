//
//  VideoToAnimatedView.swift
//  mediatools
//

import SwiftUI
import UniformTypeIdentifiers

struct VideoToGifView: View {
    @State private var vm = AnimatedViewModel()
    @State private var isTargeted = false

    var body: some View {
        HSplitView {
            leftPanel.frame(minWidth: 320)
            rightPanel.frame(minWidth: 320)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 16) {
            Text("原视频").font(.headline)
            dropArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.selectedURL != nil {
                timeRangeSection
                Button("更换视频") { vm.pickVideo() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if let thumbnail = vm.thumbnail {
                VStack(spacing: 8) {
                    ZStack {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .padding(12)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.8))
                            .shadow(radius: 4)
                    }
                    Text("\(vm.sizeLabel(bytes: vm.originalSize))  ·  \(String(format: "%.1fs", vm.videoDurationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("拖入视频或点击选择")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.pickVideo() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers)
        }
    }

    private var timeRangeSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("起始").font(.caption).foregroundStyle(.secondary)
                TextField("0", text: $vm.startTimeString)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Text("s").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("结束").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $vm.endTimeString)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Text("s").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("共 \(vm.clippedDurationString) 秒 / \(vm.estimatedFrameCount) 帧")
                    .font(.caption2).foregroundStyle(.secondary)
                if vm.selectedURL != nil && !vm.isTimeRangeValid {
                    Text("· 时间范围无效").font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 16) {
            Text("转换设置").font(.headline)

            pickerRow(label: "预设") {
                Picker("", selection: $vm.selectedPreset) {
                    ForEach(AnimatedPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.selectedPreset) { _, newValue in
                    vm.applyPreset(newValue)
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

            if vm.selectedFormat == .webP {
                VStack(alignment: .leading, spacing: 4) {
                    Text("质量").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Slider(value: $vm.webpQuality, in: 1...100, step: 1)
                            .disabled(vm.webpLimitSize)
                        Text("\(Int(vm.webpQuality))")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                            .foregroundStyle(vm.webpLimitSize ? .secondary : .primary)
                    }
                }
                Toggle("限制大小（≤ 600 KB）", isOn: $vm.webpLimitSize)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }

            pickerRow(label: "帧率") {
                Picker("", selection: $vm.selectedFps) {
                    ForEach([5, 10, 15, 24], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            }

            pickerRow(label: "宽度") {
                Picker("", selection: $vm.selectedWidthOption) {
                    ForEach(AnimatedWidthOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
            }

            if vm.selectedWidthOption == .custom {
                HStack {
                    TextField("像素", text: $vm.customWidthString)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
            }

            pickerRow(label: "循环") {
                Picker("", selection: $vm.selectedLoopOption) {
                    ForEach(AnimatedLoopOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
            }

            if vm.isConverting {
                VStack(spacing: 6) {
                    ProgressView(value: vm.progress).progressViewStyle(.linear)
                    Text(String(format: "转换中 %.0f%%", vm.progress * 100))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let result = vm.result {
                resultView(result: result).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            HStack(spacing: 12) {
                Button("转换") { vm.convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canConvert)
                Button("预览") { vm.previewResult() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canPreview)
                Button("保存") { vm.saveResult() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canSave)
            }

            if let error = vm.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
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

    private func resultView(result: AnimatedResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.green)
            Text("转换完成").font(.headline)
            HStack(spacing: 28) {
                statItem(label: "帧数",   value: "\(result.frameCount) 帧")
                statItem(label: "文件大小", value: vm.sizeLabel(bytes: result.outputSize))
                statItem(label: "相对视频", value: result.compressionRatioString)
            }
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    VideoToGifView()
}
