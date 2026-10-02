import SwiftUI

enum RepoTab: String, CaseIterable, Identifiable {
    case overview
    case builds
    case releases
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .builds: return "构建"
        case .releases: return "发行版"
        case .source: return "源码"
        }
    }
}

/// 仓库详情：概览（README）/ 构建产物 / 发行版 / 源码，都能加速下载
struct RepoDetailView: View {
    let repo: GHRepo

    @EnvironmentObject private var session: SessionManager

    @State private var tab: RepoTab = .overview

    // 概览
    @State private var readme: GHReadme?
    @State private var readmeLoading = false
    @State private var readmeFailed = false

    // 构建
    @State private var runs: [GHWorkflowRun] = []
    @State private var runsLoaded = false

    // 发行版
    @State private var releases: [GHRelease] = []
    @State private var releasesLoaded = false

    // 源码
    @State private var branches: [GHBranch] = []
    @State private var branchesLoaded = false
    @State private var selectedRef = ""

    // 顶部统计（提交数 / 分支数）
    @State private var commitCount: Int?

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                RepoHeroCard(repo: repo, extraStats: heroStats)

                Section {
                    content
                        .padding(.vertical, 14)
                } header: {
                    GitHubTabBar(tabs: RepoTab.allCases,
                                 selection: $tab,
                                 title: { $0.title },
                                 badge: { badge(for: $0) })
                }
            }
        }
        .background(Theme.canvas)
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { repoMenu }
        }
        .task(id: tab) { await load(tab) }
        .task { await loadHeaderStats() }
        .refreshable {
            // 下拉刷新要「整页一起刷」：当前 tab 的内容 + 顶部统计。
            // 老实现只重跑 load(tab)，提交数这类 header 统计会一直挂着旧值，
            // 用户下拉后看到数字没变会以为刷新失效。
            async let content: Void = load(tab, force: true)
            async let stats: Void = loadHeaderStats()
            _ = await (content, stats)
        }
        .navigationDestination(for: GHWorkflowRun.self) { run in
            RunDetailView(repo: repo, run: run)
        }
        .navigationDestination(for: GHRelease.self) { release in
            ReleaseDetailView(repo: repo, release: release)
        }
    }

    // MARK: - 顶部小按钮（收藏 / 刷新 / 分享）

    private var repoMenu: some View {
        Menu {
            if let url = URL(string: "https://github.com/\(repo.fullName)") {
                Link(destination: url) {
                    Label("在 GitHub 打开", systemImage: "arrow.up.right.square")
                }
                ShareLink(item: url) {
                    Label("分享仓库", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                Task { await load(tab, force: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            InlineBanner(text: errorMessage,
                         color: Theme.orange,
                         systemImage: "exclamationmark.triangle.fill")
                .padding(.horizontal, 16)

            Button {
                Task { await load(tab, force: true) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }

        switch tab {
        case .overview: overviewTab
        case .builds: buildsTab
        case .releases: releasesTab
        case .source: sourceTab
        }
    }

    // MARK: - 概览（README）

    @ViewBuilder
    private var overviewTab: some View {
        if readmeLoading && readme == nil {
            card {
                SkeletonBlock(lines: 6)
            }
        } else if let readme {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                        Text(readme.path)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                        Spacer(minLength: 0)
                    }
                    Hairline()
                    MarkdownContentView(markdown: readme.text)
                }
            }
        } else if readmeFailed {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("README 读取失败", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text("跳过 README 直接看下面的构建 / 发行版 / 源码即可。")
                        .font(.caption)
                        .foregroundStyle(Theme.subtle)
                }
            }
        } else {
            card {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.subtle)
                    Text("这个仓库没有 README")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text("切到「构建」「发行版」「源码」开始加速下载。")
                        .font(.caption)
                        .foregroundStyle(Theme.subtle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - 构建

    @ViewBuilder
    private var buildsTab: some View {
        if isLoading && !runsLoaded {
            card { SkeletonBlock(lines: 5) }
        } else if runs.isEmpty && runsLoaded {
            card {
                emptyState(systemName: "bolt.slash",
                           title: "还没有构建记录",
                           message: "该仓库最近没有 Actions 运行")
            }
        } else {
            card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Hairline().padding(.leading, 58) }
                        NavigationLink(value: run) {
                            RunRow(run: run)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 发行版

    @ViewBuilder
    private var releasesTab: some View {
        if isLoading && !releasesLoaded {
            card { SkeletonBlock(lines: 5) }
        } else if releases.isEmpty && releasesLoaded {
            card {
                emptyState(systemName: "shippingbox",
                           title: "还没有发行版",
                           message: "该仓库没有发布过 Release")
            }
        } else {
            card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Hairline().padding(.leading, 58) }
                        NavigationLink(value: release) {
                            ReleaseRow(release: release)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 源码

    @ViewBuilder
    private var sourceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                        Text("分支 / 标签")
                            .font(.subheadline)
                            .foregroundStyle(Theme.strongText)
                        Spacer(minLength: 8)
                        if branchesLoaded && branches.isEmpty {
                            Text("默认分支").font(.subheadline).foregroundStyle(Theme.subtle)
                        } else {
                            Picker("", selection: $selectedRef) {
                                ForEach(branches) { branch in
                                    Text(branch.name).tag(branch.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(Theme.blue)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("源码压缩包", systemImage: "chevron.left.forwardslash.chevron.right")
                    DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: selectedRef, format: .zip))
                    Hairline()
                    DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: selectedRef, format: .tarball))
                }
            }

            Text("源码包由 GitHub 现场打包，不支持 Range 分段，只能单连接下载（依然会走最快通道）。")
                .font(.caption2)
                .foregroundStyle(Theme.subtle)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - 小组件

    private func card<C: View>(padding: CGFloat = Theme.Spacing.md, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(padding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
        .padding(.horizontal, Theme.screenPadding)
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.purple)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.strongText)
        }
    }

    private func emptyState(systemName: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.subtle)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var heroStats: [(systemName: String, text: String)] {
        var stats: [(String, String)] = []
        if let commitCount, commitCount > 0 {
            stats.append(("clock.arrow.circlepath", formatCount(commitCount)))
        }
        if branchesLoaded, branches.count > 0 {
            stats.append(("arrow.triangle.branch", "\(branches.count)"))
        }
        return stats
    }

    private func badge(for tab: RepoTab) -> String? {
        switch tab {
        case .overview: return nil
        case .builds: return runs.isEmpty ? nil : "\(runs.count)"
        case .releases: return releases.isEmpty ? nil : "\(releases.count)"
        case .source: return branches.isEmpty ? nil : "\(branches.count)"
        }
    }

    // MARK: - 数据

    private func load(_ tab: RepoTab, force: Bool = false) async {
        guard let client = session.client else { return }
        errorMessage = nil

        do {
            switch tab {
            case .overview:
                guard readme == nil || force else { return }
                readmeLoading = true
                defer { readmeLoading = false }
                readmeFailed = false
                readme = try await client.readme(repo: repo)

            case .builds:
                guard !runsLoaded || force else { return }
                isLoading = true
                defer { isLoading = false }
                runs = try await client.workflowRuns(repo: repo)
                runsLoaded = true

            case .releases:
                guard !releasesLoaded || force else { return }
                isLoading = true
                defer { isLoading = false }
                releases = try await client.releases(repo: repo)
                releasesLoaded = true

            case .source:
                guard !branchesLoaded || force else { return }
                isLoading = true
                defer { isLoading = false }
                branches = try await client.branches(repo: repo)
                branchesLoaded = true
                if selectedRef.isEmpty {
                    selectedRef = branches.first?.name ?? repo.defaultBranch ?? ""
                }
            }
        } catch {
            if tab == .overview { readmeFailed = true }
            errorMessage = session.message(for: error)
        }
    }

    /// 提交数：拿不到就静默跳过，不影响主内容
    private func loadHeaderStats() async {
        guard let client = session.client else { return }
        if let count = try? await client.commitCount(repo: repo) {
            commitCount = count
        }
    }
}

// MARK: - 内联提示条

struct InlineBanner: View {
    let text: String
    var color: Color = Theme.orange
    var systemImage: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .stroke(color.opacity(0.3), lineWidth: 1)
        }
    }
}

// MARK: - 行

private struct RunRow: View {
    let run: GHWorkflowRun

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: Theme.runIcon(conclusion: run.conclusion, status: run.status),
                      color: Theme.runColor(conclusion: run.conclusion, status: run.status))

            VStack(alignment: .leading, spacing: 3) {
                Text(run.displayTitle ?? run.name ?? "Workflow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.strongText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(run.headBranch ?? "-")
                    Text("·")
                    Text("#\(run.runNumber)")
                }
                .font(.caption2)
                .foregroundStyle(Theme.subtle)
                if let date = run.createdAt {
                    Text(formatRelative(date))
                        .font(.caption2)
                        .foregroundStyle(Theme.subtle)
                }
            }

            Spacer(minLength: 0)

            StatusPill(text: Theme.runText(conclusion: run.conclusion, status: run.status),
                       color: Theme.runColor(conclusion: run.conclusion, status: run.status))

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.subtle)
        }
        .contentShape(Rectangle())
    }
}

private struct ReleaseRow: View {
    let release: GHRelease

    private var totalSize: Int64 {
        release.assets.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "tag.fill", color: Theme.purple)

            VStack(alignment: .leading, spacing: 3) {
                Text(release.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.strongText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(release.tagName)
                    if !release.assets.isEmpty {
                        Text("·")
                        Text("\(release.assets.count) 个附件")
                        Text("·")
                        Text(formatBytes(totalSize))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.subtle)
                if let date = release.publishedAt {
                    Text(formatRelative(date))
                        .font(.caption2)
                        .foregroundStyle(Theme.subtle)
                }
            }

            Spacer(minLength: 0)

            if release.prerelease {
                StatusPill(text: "预发布", color: Theme.orange)
            } else if release.draft {
                StatusPill(text: "草稿", color: .gray)
            } else {
                StatusPill(text: "发行版", color: Theme.green)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.subtle)
        }
        .contentShape(Rectangle())
    }
}
