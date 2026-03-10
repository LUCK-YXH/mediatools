//
//  ContentView.swift
//  mediatools
//
//  Created by 郁旭辉 on 3/6/26.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTool: Tool? = Tool.allCases.first

    var body: some View {
        NavigationSplitView {
            List(Tool.allCases, selection: $selectedTool) { tool in
                Label(tool.rawValue, systemImage: tool.icon)
                    .tag(tool)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            switch selectedTool {
            case .imageCompressor:
                ImageCompressorView()
            case .batchImageCompressor:
                BatchImageCompressorView()
            case .imageConverter:
                ImageConverterView()
            case .videoCompressor:
                VideoCompressorView()
            case .batchVideoCompressor:
                BatchVideoCompressorView()
            case .videoToGif:
                VideoToGifView()
            case .batchVideoToAnimated:
                BatchAnimatedView()
            case .twoImageAnimator:
                TwoImageAnimatorView()
            case nil:
                Text("请选择工具").foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
