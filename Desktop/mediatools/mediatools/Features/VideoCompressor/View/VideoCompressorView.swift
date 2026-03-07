//
//  VideoCompressorView.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct VideoCompressorView: View {
    @State private var vm = VideoCompressorViewModel()
    @State private var isTargeted = false

    var body: some View {
        HSplitView {
            leftPanel.frame(minWidth: 320)
            rightPanel.frame(minWidth: 320)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    // MARK: - Left: input

    private var leftPanel: some View {
        VStack(spacing: 16) {
            Text("原视频").font(.headline)
            dropArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.selectedURL != nil {
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
                    Text("\(vm.sizeLabel(bytes: vm.originalSize))  ·  \(vm.duration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
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

    // MARK: - Right: output

    private var rightPanel: some View {
        VStack(spacing: 16) {
            Text("压缩结果").font(.headline)

            Picker("质量", selection: $vm.selectedPreset) {
                ForEach(VideoCompressionPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if vm.selectedPreset == .custom {
                HStack {
                    TextField("目标大小", text: $vm.customSizeMB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("MB").foregroundStyle(.secondary)
                }
            }

            if vm.isCompressing {
                VStack(spacing: 6) {
                    ProgressView(value: vm.progress)
                        .progressViewStyle(.linear)
                    Text(String(format: "压缩中 %.0f%%", vm.progress * 100))
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
                Button("压缩") { vm.compress() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canCompress || !vm.isCustomSizeValid)

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

    private func resultView(result: VideoCompressionResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("压缩完成").font(.headline)
            HStack(spacing: 28) {
                statItem(label: "原始大小", value: vm.sizeLabel(bytes: result.originalSize))
                statItem(label: "压缩后",   value: vm.sizeLabel(bytes: result.compressedSize))
                statItem(label: "压缩率",   value: result.compressionRatioString)
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
    VideoCompressorView()
}
