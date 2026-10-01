import SwiftUI

enum RepoTab: String, CaseIterable, Identifiable {
    case builds
    case releases
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builds: return "构建"
        case .releases: return "正式版"
        case .source: return "源码"
        }
    }
}

/// 仓库详情：构建产物 / 正式版 / 源码，都能加速下载
struct RepoDetailView: View {
    let repo: GHRepo

    @EnvironmentObject private var session: SessionManager

    @State private var tab: RepoTab = .builds
    @State private var runs: [GHWorkflowRun] = []
    @State private var releases: [GHRelease] = []
    @State private var branches: [GHBranch] = []
    @State private var selectedRef = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                hero
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                Picker("内容", selection: $tab) {
                    ForEach(RepoTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            }

            if let errorMessage {
                Section { ErrorBanner(text: errorMessage) }
            }

            switch tab {
            case .builds: buildsSection
            case .releases: releasesSection
            case .source: sourceSection
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: tab) { await load(tab) }
        .refreshable { await load(tab) }
        .navigationDestination(for: GHWorkflowRun.self) { run in
            RunDetailView(repo: repo, run: run)
        }
        .navigationDestination(for: GHRelease.self) { release in
            ReleaseDetailView(repo: repo, release: release)
        }
    }

    // MARK: - 顶部卡片

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(repo.fullName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if repo.isPrivate {
                    StatusPill(text: "私有", color: .white)
                }
                if let language = repo.language {
                    StatusPill(text: language, color: .white)
                }
                if let stars = repo.stargazersCount, stars > 0 {
                    StatusPill(text: "★ \(stars)", color: .white)
                }
            }
            .opacity(0.95)

            if let date = repo.updatedAt {
                Text("最近更新 \(date.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    // MARK: - 各分页

    @ViewBuilder
    private var buildsSection: some View {
        if runs.isEmpty && !isLoading {
            EmptyStateView(systemName: "bolt.slash",
                           title: "还没有构建记录",
                           message: "该仓库最近没有 Actions 运行")
        } else if !runs.isEmpty {
            Section("工作流运行") {
                ForEach(runs) { run in
                    NavigationLink(value: run) {
                        RunRow(run: run)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var releasesSection: some View {
        if releases.isEmpty && !isLoading {
            EmptyStateView(systemName: "shippingbox",
                           title: "还没有正式版",
                           message: "该仓库没有发布过 Release")
        } else if !releases.isEmpty {
            Section("正式版") {
                ForEach(releases) { release in
                    NavigationLink(value: release) {
                        ReleaseRow(release: release)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Picker("分支 / 标签", selection: $selectedRef) {
                Text(repo.defaultBranch ?? "默认分支").tag("")
                ForEach(branches) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
        } header: {
            Text("选择分支")
        } footer: {
            Text("源码包由 GitHub 现场打包，不支持 Range 分段，只能单连接下载（依然会走最快通道）。")
        }

        Section("源码压缩包") {
            DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: selectedRef, format: .zip))
            DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: selectedRef, format: .tarball))
        }
    }

    // MARK: - 数据

    private func load(_ tab: RepoTab) async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch tab {
            case .builds:
                if runs.isEmpty { runs = try await client.workflowRuns(repo: repo) }
            case .releases:
                if releases.isEmpty { releases = try await client.releases(repo: repo) }
            case .source:
                if branches.isEmpty {
                    branches = try await client.branches(repo: repo)
                    if selectedRef.isEmpty, let first = branches.first {
                        selectedRef = first.name
                    }
                }
            }
        } catch {
            errorMessage = session.message(for: error)
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
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(run.headBranch ?? "-")
                    Text("·")
                    Text("#\(run.runNumber)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let date = run.createdAt {
                    Text(date.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            StatusPill(text: Theme.runText(conclusion: run.conclusion, status: run.status),
                       color: Theme.runColor(conclusion: run.conclusion, status: run.status))
        }
        .padding(.vertical, 2)
    }
}

private struct ReleaseRow: View {
    let release: GHRelease

    private var totalSize: Int64 {
        release.assets.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "shippingbox.fill", color: Theme.purple)

            VStack(alignment: .leading, spacing: 3) {
                Text(release.displayName)
                    .font(.subheadline.weight(.semibold))
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
                .foregroundStyle(.secondary)
                if let date = release.publishedAt {
                    Text(date.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if release.prerelease {
                StatusPill(text: "预发布", color: Theme.orange)
            } else if release.draft {
                StatusPill(text: "草稿", color: .gray)
            } else {
                StatusPill(text: "正式版", color: Theme.green)
            }
        }
        .padding(.vertical, 2)
    }
}