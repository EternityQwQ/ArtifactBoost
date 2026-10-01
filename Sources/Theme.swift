import SwiftUI

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    /// 跟随浅色 / 深色模式自动切换（对齐 GitHub Primer 配色）
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// 视觉规范：配色与控件都对齐 GitHub 移动端
enum Theme {
    // MARK: - Primer 调色板
    static let blue = Color.adaptive(light: 0x0969DA, dark: 0x2F81F7)
    static let green = Color.adaptive(light: 0x1F883D, dark: 0x3FB950)
    static let red = Color.adaptive(light: 0xCF222E, dark: 0xF85149)
    static let purple = Color.adaptive(light: 0x8250DF, dark: 0xA371F7)
    static let orange = Color.adaptive(light: 0xBC4C00, dark: 0xDB6D28)
    static let yellow = Color.adaptive(light: 0x9A6700, dark: 0xD29922)

    static let muted = Color.adaptive(light: 0x656D76, dark: 0x8B949E)
    static let subtle = Color.adaptive(light: 0x8C959F, dark: 0x6E7681)
    static let canvas = Color.adaptive(light: 0xF6F8FA, dark: 0x0D1117)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x161B22)
    static let border = Color.adaptive(light: 0xD0D7DE, dark: 0x30363D)

    static let accent = blue

    // MARK: - 语义色

    static func color(for source: DownloadSource) -> Color {
        switch source {
        case .artifact: return blue
        case .runLogs: return orange
        case .releaseAsset: return purple
        case .sourceArchive: return green
        }
    }

    static func runColor(conclusion: String?, status: String?) -> Color {
        guard status == "completed" else { return yellow }
        switch conclusion {
        case "success": return green
        case "failure": return red
        case "cancelled", "skipped": return muted
        default: return orange
        }
    }

    static func runIcon(conclusion: String?, status: String?) -> String {
        guard status == "completed" else { return "clock.fill" }
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        case "cancelled": return "slash.circle.fill"
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

    /// GitHub 语言色（linguist 配色，取常用的几十种）
    static func languageColor(_ language: String?) -> Color {
        switch language {
        case "Swift": return Color(hex: 0xF05138)
        case "Objective-C": return Color(hex: 0x438EFF)
        case "C": return Color(hex: 0x555555)
        case "C++": return Color(hex: 0xF34B7D)
        case "C#": return Color(hex: 0x178600)
        case "Java": return Color(hex: 0xB07219)
        case "Kotlin": return Color(hex: 0xA97BFF)
        case "JavaScript": return Color(hex: 0xF1E05A)
        case "TypeScript": return Color(hex: 0x3178C6)
        case "Python": return Color(hex: 0x3572A5)
        case "Go": return Color(hex: 0x00ADD8)
        case "Rust": return Color(hex: 0xDEA584)
        case "Ruby": return Color(hex: 0x701516)
        case "PHP": return Color(hex: 0x4F5D95)
        case "Shell": return Color(hex: 0x89E051)
        case "HTML": return Color(hex: 0xE34C26)
        case "CSS": return Color(hex: 0x563D7C)
        case "Vue": return Color(hex: 0x41B883)
        case "Dart": return Color(hex: 0x00B4AB)
        case "Jupyter Notebook": return Color(hex: 0xDA5B0B)
        case "Markdown": return Color(hex: 0x083FA1)
        default: return muted
        }
    }
}

// MARK: - 通用控件

/// 圆角图标（GitHub 移动端的仓库 / 文件图标风格）
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(color)
            }
    }
}

/// 灰底小胶囊（GitHub 的 label / badge 风格）
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
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

/// 语言色点 + 名称
struct LanguageLabel: View {
    let language: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.languageColor(language))
                .frame(width: 9, height: 9)
            Text(language)
        }
        .font(.caption2)
        .foregroundStyle(Theme.muted)
    }
}

/// 星标 / fork 之类的小统计
struct StatLabel: View {
    let systemName: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName).font(.system(size: 10, weight: .semibold))
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Theme.muted)
    }
}

struct EmptyStateView: View {
    let systemName: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.subtle)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .listRowBackground(Color.clear)
    }
}

/// 卡片容器：浅色/深色下都有清晰边界（GitHub 的 box 风格）
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
    }
}

extension View {
    func card() -> some View {
        modifier(CardBackground())
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}