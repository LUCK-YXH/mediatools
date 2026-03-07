//
//  BatchAnimatedView.swift
//  mediatools
//

import SwiftUI
import UniformTypeIdentifiers

struct BatchAnimatedView: View {
    @State private var vm = BatchAnimatedViewModel()
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

            // 预设
            Picker("", selection: $vm.selectedPreset) {
                ForEach(AnimatedPreset.allCases) { p in Text(p.rawValue).tag(p) }
            }
            .fixedSize()
            .onChange(of: vm.selectedPreset) { _, v in vm.applyPreset(v) }

            Divider().frame(height: 20)

            // 格式
            Picker("", selection: $vm.selectedFormat) {
                ForEach(AnimatedFormat.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .fixedSize()

            // 帧率
            Picker("", selection: $vm.selectedFps) {
                ForEach([5, 10, 15, 24], id: \.self) { fps in Text("\(fps)fps").tag(fps) }
            }
            .fixedSize()

            // 宽度
            Picker("", selection: $vm.selectedWidthOption) {
                ForEach(AnimatedWidthOption.allCases) { opt in Text(opt.rawValue).tag(opt) }
            }
            .fixedSize()

            if vm.selectedWidthOption == .custom {
                TextField("像素", text: $vm.customWidthString)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
            }

            // WebP 质量 & 限制大小
            if vm.selectedFormat == .webP {
                Divider().frame(height: 20)
                Toggle("≤600KB", isOn: $vm.webpLimitSize)
                    .toggleStyle(.checkbox)
                    .help("自动压缩到 600 KB 以内")
                if !vm.webpLimitSize {
                    Text("Q").foregroundStyle(.secondary).font(.caption)
                    Slider(value: $vm.webpQuality, in: 1...100, step: 1)
                        .frame(width: 80)
                    Text("\(Int(vm.webpQuality))")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 24)
                }
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
                    BatchAnimatedItemRow(item: item, vm: vm)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .listStyle(.plain)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
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

// MARK: - BatchAnimatedItemRow

private struct BatchAnimatedItemRow: View {
    let item: BatchAnimatedItem
    let vm:   BatchAnimatedViewModel

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            infoView
            Spacer()
            statusView
        }
        .padding(.vertical, 4)
    }

    private var thumbnailView: some View {
        ZStack {
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipped()
        .cornerRadius(4)
        .background(Color.secondary.opacity(0.1))
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Group {
                if item.status == .done, let result = item.result {
                    let ratio = String(format: "%.0f%%", Double(result.outputSize) / Double(max(1, result.originalSize)) * 100)
                    Text("\(vm.sizeLabel(bytes: result.originalSize)) → \(vm.sizeLabel(bytes: result.outputSize))  (\(ratio))")
                } else if item.status == .compressing {
                    Text(String(format: "转换中 %.0f%%  ·  \(item.duration)", item.progress * 100))
                } else if item.status == .failed {
                    Text(item.errorMessage ?? "转换失败").foregroundStyle(.red)
                } else {
                    Text("\(vm.sizeLabel(bytes: item.originalSize))  ·  \(item.duration)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

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
                Button("预览") { vm.previewItem(item) }
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
    BatchAnimatedView()
        .frame(width: 800, height: 500)
}
