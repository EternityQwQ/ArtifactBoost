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
                        TextField("owner/repo 或 Actions 链接", text: $directInput)
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
                    Text("直接打开仓库 / Actions")
                } footer: {
                    Text("贴仓库地址进仓库主页；贴 actions/runs 链接直达该次构建，例如 https://github.com/owner/repo/actions/runs/37171664473")
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
                                   message: "在顶部搜索框输入关键词后回车。公开仓库不需要你拥有它，能搜到就能下载它的产物、发行版和源码。")
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
            .navigationDestination(for: RunDestination.self) { dest in
                RunDetailView(repo: dest.repo, run: dest.run)
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
        guard let target = Self.parseDirectTarget(directInput) else {
            directError = "格式不对，示例：cli/cli 或 https://github.com/cli/cli/actions/runs/123456"
            return
        }
        isOpening = true
        directError = nil
        errorMessage = nil
        defer { isOpening = false }
        do {
            switch target {
            case .repo(let fullName):
                let repo = try await client.repo(fullName: fullName)
                directInput = ""
                path.append(repo)
            case .run(let fullName, let runID):
                // actions 链接：先拿仓库再拿单次运行，直跳构建详情而非仓库主页
                let repo = try await client.repo(fullName: fullName)
                let run = try await client.workflowRun(fullName: fullName, runID: runID)
                directInput = ""
                path.append(RunDestination(repo: repo, run: run))
            }
        } catch {
            directError = session.message(for: error)
        }
    }

    /// 直接打开的目标：仓库主页，或某次 Actions 运行（构建详情）。
    ///
    /// 支持：
    /// - owner/repo
    /// - https://github.com/owner/repo
    /// - https://github.com/owner/repo/actions/runs/37171664473
    ///   （后面再跟 /jobs/…、/attempts/…、?query、#fragment 都会被忽略，只取 runId）
    /// - 裸 owner/repo/actions/runs/37171664473（无 scheme 的简写同样识别）
    enum DirectTarget: Hashable {
        case repo(String)
        case run(fullName: String, runID: Int64)
    }

    /// NavigationStack 直达构建详情用：同时带上仓库与运行（RunDetailView 需要两者）。
    struct RunDestination: Hashable {
        let repo: GHRepo
        let run: GHWorkflowRun
    }

    static func parseDirectTarget(_ raw: String) -> DirectTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 从 Markdown 里复制时常见的 <https://github.com/owner/repo> 包裹
        if text.hasPrefix("<") && text.hasSuffix(">") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
        }

        let lower = text.lowercased()
        let looksLikeURL = text.contains("://") || lower.contains("github.com")
        if !looksLikeURL {
            // 裸 owner/repo 分支：之前实现强制要求 host 含 github.com，
            // 导致最常见的 "cli/cli" 输入永远返回 nil（与安卓端同因，安卓端已修复，此处同步）。
            let clean = text.split(separator: "?")[0].split(separator: "#")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = clean.split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2 else { return nil }
            let owner = String(parts[0])
            var repo = String(parts[1])
            if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            guard isValidRepoPart(owner) && isValidRepoPart(repo) else { return nil }
            let fullName = "\(owner)/\(repo)"
            // 裸 actions 简写：owner/repo/actions/runs/<runId>
            if parts.count >= 5,
               parts[2].lowercased() == "actions",
               parts[3].lowercased() == "runs",
               let runID = Int64(parts[4]), runID > 0 {
                return .run(fullName: fullName, runID: runID)
            }
            return .repo(fullName)
        }

        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme),
              let host = url.host?.lowercased(),
              host.contains("github.com") else {
            return nil
        }
        let pathParts = url.path.split(separator: "/").map(String.init)
        guard pathParts.count >= 2 else { return nil }
        var repo = pathParts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isValidRepoPart(pathParts[0]) && isValidRepoPart(repo) else { return nil }
        let fullName = "\(pathParts[0])/\(repo)"
        // actions 链接：…/owner/repo/actions/runs/<runId>[…]，大小写不敏感，多余后缀忽略
        for i in pathParts.indices {
            if pathParts[i].lowercased() == "actions",
               i + 2 < pathParts.count,
               pathParts[i + 1].lowercased() == "runs",
               let runID = Int64(pathParts[i + 2]), runID > 0 {
                return .run(fullName: fullName, runID: runID)
            }
        }
        return .repo(fullName)
    }

    /// 支持 owner/repo、github.com/owner/repo、完整链接（多余路径会被截掉）。
    /// actions/runs 链接会退化为仓库名（只取 owner/repo 部分）。
    static func parseFullName(_ raw: String) -> String? {
        switch parseDirectTarget(raw) {
        case .repo(let fullName): return fullName
        case .run(let fullName, _): return fullName
        case nil: return nil
        }
    }

    private static let repoNamePartRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+$")

    private static func isValidRepoPart(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return repoNamePartRegex.firstMatch(in: s, range: range) != nil
    }
}