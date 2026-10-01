import SwiftUI

/// 全局视觉元素：统一图标徽标、状态胶囊、空态、错误条，保证各页面观感一致
enum Theme {
    static let accent = Color(red: 0.24, green: 0.51, blue: 0.96)
    static let green = Color(red: 0.16, green: 0.70, blue: 0.42)
    static let orange = Color(red: 0.95, green: 0.61, blue: 0.16)
    static let red = Color(red: 0.92, green: 0.30, blue: 0.30)
    static let purple = Color(red: 0.56, green: 0.36, blue: 0.92)

    static func color(for source: DownloadSource) -> Color {
        switch source {
        case .artifact: return accent
        case .runLogs: return orange
        case .releaseAsset: return purple
        case .sourceArchive: return green
        }
    }

    static func runColor(conclusion: String?, status: String?) -> Color {
        guard status == "completed" else { return accent }
        switch conclusion {
        case "success": return green
        case "failure": return red
        case "cancelled", "skipped": return .gray
        default: return orange
        }
    }

    static func runIcon(conclusion: String?, status: String?) -> String {
        guard status == "completed" else { return "arrow.triangle.2.circlepath" }
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        case "cancelled": return "nosign"
        default: return "exclamationmark.circle.fill"
        }
    }

    static func runText(conclusion: String?, status: String?) -> String {
        guard status == "completed" else {
            switch status {
            case "in_progress": return "运行中"
            case "queued": return "排队中"
            default: return status ?? "进行中"
            }
        }
        switch conclusion {
        case "success": return "成功"
        case "failure": return "失败"
        case "cancelled": return "已取消"
        case "skipped": return "已跳过"
        case "timed_out": return "超时"
        default: return conclusion ?? "已完成"
        }
    }
}

/// 圆角方块图标（App Store 风格）
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(color)
            }
    }
}

/// 状态胶囊
struct StatusPill: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

/// 统一的空状态
struct EmptyStateView: View {
    let systemName: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 24)
        .listRowBackground(Color.clear)
    }
}

/// 统一的错误条
struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}