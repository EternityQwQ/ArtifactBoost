import SwiftUI
import UIKit

struct RepoListView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var repos: [GHRepo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    // 绝区零彩蛋：长按导航栏「我的仓库」标题触发，二次确认后才跳官网，不做后台静默下载
    @State private var showZzzEgg = false

    private var shownRepos: [GHRepo] {
        guard !searchText.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { ErrorBanner(text: errorMessage) }
            }

            if shownRepos.isEmpty && !isLoading {
                EmptyStateView(systemName: "square.stack.3d.up",
                               title: searchText.isEmpty ? "还没有仓库" : "本地没有匹配的仓库",
                               message: searchText.isEmpty
                                   ? "下拉刷新；想下载别人的公开仓库，去「搜索」Tab 直接搜"
                                   : "换个关键词，或去「搜索」Tab 搜全站")
            }

            if !shownRepos.isEmpty {
                Section {
                    ForEach(shownRepos) { repo in
                        NavigationLink(value: repo) {
                            RepoCardRow(repo: repo)
                        }
                    }
                } header: {
                    Text("共 \(shownRepos.count) 个仓库")
                }
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
        .navigationTitle("我的仓库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 彩蛋触发点放在导航栏标题上（与安卓端 TopAppBar 标题长按入口对齐）。
            ToolbarItem(placement: .principal) {
                Text("我的仓库")
                    .font(.headline)
                    .onLongPressGesture(minimumDuration: 0.6) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showZzzEgg = true
                    }
                    .accessibilityHint("长按发现彩蛋")
            }
        }
        .zzzEasterEggAlert(isPresented: $showZzzEgg)
        .searchable(text: $searchText, prompt: "筛选我的仓库")
        .navigationDestination(for: GHRepo.self) { repo in
            RepoDetailView(repo: repo)
        }
        .task { await loadRepos() }
        .refreshable { await loadRepos() }
    }

    private func loadRepos() async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var all: [GHRepo] = []
            for page in 1...3 {
                let batch = try await client.repos(page: page)
                all.append(contentsOf: batch)
                if batch.count < 100 { break }
            }
            repos = all
        } catch {
            errorMessage = session.message(for: error)
        }
    }
}

/// 仓库行：GitHub 移动端风格（owner/repo 双色标题 + 描述 + 语言/星标）
struct RepoCardRow: View {
    let repo: GHRepo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RepoAvatarView(owner: repo.owner, size: 34, isPrivate: repo.isPrivate)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(repo.owner + "/")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Text(repo.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.blue)
                }
                .lineLimit(1)

                if let description = repo.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if let language = repo.language {
                        LanguageLabel(language: language)
                    }
                    if let stars = repo.stargazersCount, stars > 0 {
                        StatLabel(systemName: "star.fill", text: formatCount(stars))
                    }
                    if let forks = repo.forksCount, forks > 0 {
                        StatLabel(systemName: "arrow.triangle.branch", text: formatCount(forks))
                    }
                }

                if let date = repo.updatedAt {
                    Text("更新于 \(formatRelative(date))")
                        .font(.caption2)
                        .foregroundStyle(Theme.subtle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}