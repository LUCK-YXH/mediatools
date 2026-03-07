//
//  ImageConverterView.swift
//  mediatools
//

import SwiftUI
import UniformTypeIdentifiers

struct ImageConverterView: View {
    @State private var vm = ImageConverterViewModel()
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
            Button("添加图片") { vm.addImages() }

            Divider().frame(height: 20)

            Text("转换为").font(.caption).foregroundStyle(.secondary)

            Picker("", selection: $vm.targetFormat) {
                ForEach(ImageConvertFormat.allCases) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            .fixedSize()

            if vm.targetFormat.supportsQuality {
                Divider().frame(height: 20)
                Text("质量").font(.caption).foregroundStyle(.secondary)
                Slider(value: $vm.quality, in: 0.1...1.0, step: 0.05)
                    .frame(width: 90)
                Text("\(Int(vm.quality * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }

            if !vm.targetFormat.supportsAlpha {
                Divider().frame(height: 20)
                Label("不支持透明", systemImage: "checkerboard.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("目标格式不支持透明通道，透明区域将填充为白色")
            }

            Spacer()

            Button("清空") { vm.clear() }
                .disabled(vm.items.isEmpty || vm.isConverting)

            Button("全部转换") { vm.convertAll() }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canConvert)

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
                    ConvertItemRow(item: item, vm: vm)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .listStyle(.plain)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("拖入图片或点击添加")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("支持 JPEG · PNG · WebP · HEIC · TIFF · BMP · GIF")
                .font(.caption)
                .foregroundStyle(Color.secondary.opacity(0.7))
            Button("选择图片") { vm.addImages() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { vm.addImages() }
    }
}

// MARK: - ConvertItemRow

private struct ConvertItemRow: View {
    let item: ConvertItem
    let vm:   ImageConverterViewModel

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            infoView
            Spacer()
            statusView
        }
        .padding(.vertical, 4)
    }

    // MARK: Thumbnail

    private var thumbnailView: some View {
        Group {
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipped()
        .cornerRadius(4)
        .background(Color.secondary.opacity(0.1))
    }

    // MARK: Info

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Group {
                if item.status == .done, let result = item.result {
                    Text("\(vm.sizeLabel(bytes: result.originalSize)) → \(vm.sizeLabel(bytes: result.outputSize))  (\(result.compressionRatioString))")
                } else if item.status == .failed {
                    Text(item.errorMessage ?? "转换失败").foregroundStyle(.red)
                } else {
                    Text(vm.sizeLabel(bytes: item.originalSize))
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
                ProgressView()
                    .controlSize(.small)
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
    ImageConverterView()
        .frame(width: 700, height: 500)
}
