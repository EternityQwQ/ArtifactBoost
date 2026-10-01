import SwiftUI

/// 搜索全站仓库：自己的、别人的公开仓库，只要能搜到就能进去下载
struct SearchView: View {
    @EnvironmentObject private var session: SessionManager

    @State private var path = NavigationPath()
    @State private var keyword = ""
    @State private var sort: RepoSort = .bestMatch
    @State private var results: [GHRepo] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    @State private var directInput = ""
    @State private var directError: String?
    @State private var isOpening = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(Theme.muted)
                        TextField("owner/repo 或 GitHub 链接", text: $directInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { Task { await openDirect() } }
                        if isOpening {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("打开") { Task { await openDirect() } }
                                .font(.subheadline.weight(.semibold))
                                .disabled(directInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let directError {
                        ErrorBanner(text: directError)
                    }
                } header: {
                    Text("直接打开仓库")
                } footer: {
                    Text("贴一个仓库地址就能进去下载，例如 cli/cli 或 https://github.com/cli/cli")
                }

                if let errorMessage {
                    Section { ErrorBanner(text: errorMessage) }
                }

                Section {
                    Picker("排序", selection: sortBinding) {
                        ForEach(RepoSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if results.isEmpty {
                    EmptyStateView(systemName: "magnifyingglass",
                                   title: keyword.isEmpty ? "搜索全站仓库" : "没有搜到「\(keyword)」",
                                   message: "在顶部搜索框输入关键词后回车。公开仓库不需要你拥有它，能搜到就能下载它的产物、正式版和源码。")
                } else {
                    Section {
                        ForEach(results) { repo in
                            Button {
                                path.append(repo)
                            } label: {
                                RepoCardRow(repo: repo)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(results.count) 个结果")
                    } footer: {
                        Text("公开仓库同样支持多通道加速；私有仓库需要你的 Token 有对应权限。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .searchable(text: $keyword, prompt: "搜索 GitHub 仓库")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationDestination(for: GHRepo.self) { repo in
                RepoDetailView(repo: repo)
            }
        }
    }

    /// 改动排序后自动重搜（用 Binding 包一层，避免 iOS 16 的 onChange 兼容问题）
    private var sortBinding: Binding<RepoSort> {
        Binding(get: { sort }, set: { newValue in
            sort = newValue
            if !keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await search() }
            }
        })
    }

    private func search() async {
        guard let client = session.client else { return }
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        directError = nil
        defer { isSearching = false }
        do {
            results = try await client.searchRepos(keyword: text, sort: sort)
        } catch {
            errorMessage = session.message(for: error)
        }
    }

    private func openDirect() async {
        guard let client = session.client else { return }
        guard let fullName = Self.parseFullName(directInput) else {
            directError = "格式不对，示例：cli/cli 或 https://github.com/cli/cli"
            return
        }
        isOpening = true
        directError = nil
        errorMessage = nil
        defer { isOpening = false }
        do {
            let repo = try await client.repo(fullName: fullName)
            directInput = ""
            path.append(repo)
        } catch {
            directError = session.message(for: error)
        }
    }

    /// 支持 owner/repo、github.com/owner/repo、完整链接（多余路径会被截掉）
    static func parseFullName(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host?.lowercased(), host.contains("github.com") else {
            return nil
        }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        parts = Array(parts.prefix(2))
        let fullName = parts.joined(separator: "/")
        return fullName.isEmpty ? nil : fullName
    }
}