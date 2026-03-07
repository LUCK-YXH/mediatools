//
//  BatchVideoCompressorView.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct BatchVideoCompressorView: View {
    @State private var vm = BatchVideoCompressorViewModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers.map { $0 as NSItemProvider })
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("添加视频") { vm.addVideos() }

            Divider().frame(height: 20)

            Picker("", selection: $vm.selectedPreset) {
                ForEach(VideoCompressionPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .fixedSize()

            if vm.selectedPreset == .custom {
                TextField("MB", text: $vm.customSizeMB)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        Text("MB").foregroundStyle(.secondary).padding(.trailing, 6)
                    }
            }

            Spacer()

            Button("清空") { vm.clear() }
                .disabled(vm.items.isEmpty || vm.isCompressing)

            Button("全部压缩") { vm.compressAll() }
                .disabled(!vm.canCompress || !vm.isCustomSizeValid)
                .disabled(!vm.canCompress)
                .buttonStyle(.borderedProminent)

            Button("全部保存") { vm.saveAll() }
                .disabled(!vm.canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.items.isEmpty {
            dropZone
        } else {
            List {
                ForEach(vm.items) { item in
                    BatchVideoItemRow(item: item, vm: vm)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .listStyle(.plain)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("拖入视频或点击添加")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("选择视频") { vm.addVideos() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { vm.addVideos() }
    }
}

// MARK: - BatchVideoItemRow

private struct BatchVideoItemRow: View {
    let item: BatchVideoItem
    let vm: BatchVideoCompressorViewModel

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            info
            Spacer()
            statusView
        }
        .padding(.vertical, 4)
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        ZStack {
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipped()
        .cornerRadius(4)
        .background(Color.secondary.opacity(0.1))
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Group {
                if item.status == .done, let result = item.result {
                    let ratio = String(format: "%.0f%%", result.compressionRatio * 100)
                    Text("\(vm.sizeLabel(bytes: result.originalSize)) → \(vm.sizeLabel(bytes: result.compressedSize))  (\(ratio))")
                } else if item.status == .compressing {
                    Text(String(format: "压缩中 %.0f%%  ·  \(item.duration)", item.progress * 100))
                } else if item.status == .failed {
                    Text(item.errorMessage ?? "压缩失败").foregroundStyle(.red)
                } else {
                    Text("\(vm.sizeLabel(bytes: item.originalSize))  ·  \(item.duration)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusView: some View {
        HStack(spacing: 8) {
            switch item.status {
            case .idle:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .compressing:
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("预览") { vm.openPreview(for: item) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                Button("保存") { vm.saveItem(item) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Button {
                vm.remove(item)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.status == .compressing)
        }
    }
}

#Preview {
    BatchVideoCompressorView()
        .frame(width: 700, height: 500)
}
