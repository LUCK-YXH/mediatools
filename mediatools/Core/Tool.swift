import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case imageCompressor      = "图片压缩"
    case batchImageCompressor = "批量压缩"
    case imageConverter       = "格式转换"
    case videoCompressor      = "视频压缩"
    case batchVideoCompressor = "批量视频"
    case videoToGif           = "视频转动图"
    case batchVideoToAnimated = "批量转动图"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .imageCompressor:      return "rectangle.compress.vertical"
        case .batchImageCompressor: return "photo.stack"
        case .imageConverter:       return "photo.badge.arrow.down"
        case .videoCompressor:      return "film"
        case .batchVideoCompressor: return "film.stack"
        case .videoToGif:           return "play.rectangle.on.rectangle"
        case .batchVideoToAnimated: return "play.rectangle.on.rectangle.fill"
        }
    }
}
