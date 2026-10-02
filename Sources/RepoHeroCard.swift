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

/// 仓库图标：优先加载仓库所属 owner 的真实头像
/// （`https://github.com/{owner}.png`，GitHub 官方免鉴权端点），
/// 加载中/失败时退回「锁 / 书籍」占位图标。
///
/// 为什么不用 API 里的 `avatar_url`：那需要额外发一次 `GET /users/{owner}`
/// 请求，占配额也拖慢列表；而 `github.com/{owner}.png` 是纯 CDN 图片，
/// 既快又不消耗 API 配额，还能被 URLCache 命中。
struct RepoAvatarView: View {
    let owner: String
    var size: CGFloat = 44
    var isPrivate: Bool = false

    private var avatarURL: URL? {
        guard !owner.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner).png?size=200")
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.border.opacity(0.4))
            .frame(width: size, height: size)
            .overlay {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { phase in
                        // 加载中就画占位底色（已有底色），失败才退回图标
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        } else if case .failure = phase {
                            fallbackIcon
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                } else {
                    fallbackIcon
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 私有仓库额外盖一个小锁角标：头像本身看不出可见性
                if isPrivate {
                    Circle()
                        .fill(Theme.surface)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .overlay {
                            Image(systemName: "lock.fill")
                                .font(.system(size: size * 0.24, weight: .bold))
                                .foregroundStyle(Theme.yellow)
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            }
    }

    /// 拿不到头像时的占位图标（老数据 / 网络失败）
    private var fallbackIcon: some View {
        Image(systemName: isPrivate ? "lock.fill" : "book.closed.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(isPrivate ? Theme.yellow : Theme.muted)
    }
}
