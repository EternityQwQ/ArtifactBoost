import Foundation

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file) + "/s"
}

/// 1200 → 1.2k，34000 → 34k（GitHub 的数字缩写风格）
func formatCount(_ count: Int) -> String {
    switch count {
    case ..<1000:
        return "\(count)"
    case ..<10_000:
        return String(format: "%.1fk", Double(count) / 1000)
    case ..<1_000_000:
        return "\(count / 1000)k"
    default:
        return String(format: "%.1fm", Double(count) / 1_000_000)
    }
}
