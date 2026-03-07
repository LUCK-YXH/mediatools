//
//  ImageCompressorView.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageCompressorView: View {
    @State private var vm = ImageCompressorViewModel()
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
            Text("原图").font(.headline)

            dropArea.frame(maxWidth: .infinity, maxHeight: .infinity)

            if vm.selectedImage != nil {
                Button("更换图片") { vm.pickImage() }
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

            if let image = vm.selectedImage {
                VStack(spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(8)
                        .padding(12)

                    Text(vm.sizeLabel(bytes: vm.originalFileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("拖入图片或点击选择")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.pickImage() }
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers)
        }
    }

    // MARK: - Right: output

    private var rightPanel: some View {
        VStack(spacing: 16) {
            Text("压缩结果").font(.headline)

            Picker("目标大小", selection: $vm.selectedPreset) {
                ForEach(CompressionPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.selectedPreset) { _, _ in vm.compress() }

            if vm.selectedPreset == .custom {
                HStack {
                    TextField("目标大小", text: $vm.customSizeKB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("KB")
                        .foregroundStyle(.secondary)
                }
            }

            resultPreview.frame(maxWidth: .infinity, maxHeight: .infinity)

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

    private var resultPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1, dash: [4]))

            if let result = vm.result {
                VStack(spacing: 8) {
                    if let nsImage = NSImage(data: result.data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .padding(12)
                    }
                    statsView(result: result)
                }
            } else {
                Text("压缩后的图片将在此显示").foregroundStyle(.secondary)
            }
        }
    }

    private func statsView(result: ImageCompressionResult) -> some View {
        HStack(spacing: 20) {
            statItem(label: "原始大小", value: vm.sizeLabel(bytes: result.originalSize))
            statItem(label: "压缩后",   value: vm.sizeLabel(bytes: result.compressedSize))
            statItem(label: "压缩率",   value: result.compressionRatioString)
            statItem(label: "缩放",     value: String(format: "%.0f%%", result.scale * 100))
            statItem(label: "质量",     value: String(format: "%.0f%%", result.quality * 100))
        }
        .padding(.bottom, 8)
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ImageCompressorView()
}
