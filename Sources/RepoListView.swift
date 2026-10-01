import SwiftUI

struct RepoListView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var repos: [GHRepo] = []
    @State private var isLoading = false
    @State private var isSearchingRemote = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var shownRepos: [GHRepo] {
        guard !searchText.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { ErrorBanner(text: errorMessage) }
            }

            if shownRepos.isEmpty && !isLoading && !isSearchingRemote {
                EmptyStateView(systemName: "shippingbox",
                               title: searchText.isEmpty ? "还没有仓库" : "本地没有匹配的仓库",
                               message: searchText.isEmpty
                                   ? "下拉刷新试试，或在搜索框输入关键词后回车远程搜索"
                                   : "在搜索框回车可直接到 GitHub 上远程搜索")
            }

            if !shownRepos.isEmpty {
                Section {
                    ForEach(shownRepos) { repo in
                        NavigationLink(value: repo) {
                            RepoRow(repo: repo)
                        }
                    }
                } header: {
                    HStack {
                        Text("共 \(shownRepos.count) 个仓库")
                        Spacer()
                        if isSearchingRemote { ProgressView().controlSize(.mini) }
                    }
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
        .searchable(text: $searchText, prompt: "筛选仓库，回车远程搜索")
        .onSubmit(of: .search) {
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await loadRepos() }
            } else {
                Task { await remoteSearch() }
            }
        }
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

    private func remoteSearch() async {
        guard let client = session.client, !searchText.isEmpty else { return }
        isSearchingRemote = true
        errorMessage = nil
        defer { isSearchingRemote = false }
        do {
            repos = try await client.searchRepos(keyword: searchText)
        } catch {
            errorMessage = session.message(for: error)
        }
    }
}

private struct RepoRow: View {
    let repo: GHRepo

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: repo.isPrivate ? "lock.fill" : "book.closed.fill",
                      color: repo.isPrivate ? Theme.orange : Theme.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(repo.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let owner = repo.fullName.split(separator: "/").first {
                        Text(String(owner))
                    }
                    if let language = repo.language {
                        Text("·")
                        Text(language)
                    }
                    if let stars = repo.stargazersCount, stars > 0 {
                        Text("·")
                        Label("\(stars)", systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let date = repo.updatedAt {
                    Text("更新于 \(date.formatted(date: .numeric, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}