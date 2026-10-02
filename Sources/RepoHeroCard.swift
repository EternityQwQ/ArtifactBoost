import SwiftUI

/// 仓库详情页顶部信息卡（对齐 GitHub 移动端 App 的 header）
struct RepoHeroCard: View {
    let repo: GHRepo
    /// 额外统计（提交数 / 分支数等），加载到后展示
    var extraStats: [(systemName: String, text: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let description = repo.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Hairline().padding(.vertical, 13)

            stats
            actionRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    // MARK: - 图标 + owner/name

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RepoAvatarView(owner: repo.owner, size: 46, isPrivate: repo.isPrivate)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(repo.owner + "/")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text(repo.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.blue)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.65)

                HStack(spacing: 5) {
                    Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(repo.isPrivate ? Theme.yellow : Theme.subtle)
                    Text(repo.isPrivate ? "私有仓库" : "公开仓库")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(repo.isPrivate ? Theme.yellow : Theme.muted)

                    if let date = repo.updatedAt {
                        Text("·").font(.caption2).foregroundStyle(Theme.subtle)
                        Text(formatRelative(date))
                            .font(.caption2)
                            .foregroundStyle(Theme.subtle)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 语言 / 星标 / fork / 提交

    private var stats: some View {
        HStack(spacing: 16) {
            if let language = repo.language {
                LanguageLabel(language: language)
            }
            if let stars = repo.stargazersCount, stars > 0 {
                StatLabel(systemName: "star.fill", text: formatCount(stars))
            }
            if let forks = repo.forksCount, forks > 0 {
                StatLabel(systemName: "arrow.triangle.branch", text: formatCount(forks))
            }
            ForEach(Array(extraStats.enumerated()), id: \.offset) { _, stat in
                StatLabel(systemName: stat.systemName, text: stat.text)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 操作按钮

    private var actionRow: some View {
        HStack(spacing: 10) {
            if let url = URL(string: "https://github.com/\(repo.fullName)") {
                Link(destination: url) {
                    Label("在 GitHub 打开", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.muted)
                .controlSize(.regular)

                ShareLink(item: url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.muted)
                .controlSize(.regular)
            }
        }
        .padding(.top, 14)
    }
}

/// 仓库图标：私有仓库用锁，公开仓库用书籍（GitHub 移动端风格）
struct RepoAvatarView: View {
    let owner: String
    var size: CGFloat = 44
    var isPrivate: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.border.opacity(0.4))
            .frame(width: size, height: size)
            .overlay {
                if isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Theme.yellow)
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            }
    }
}
