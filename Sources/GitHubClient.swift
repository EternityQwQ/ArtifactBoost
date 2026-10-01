import Foundation

enum GitHubError: LocalizedError {
    case badURL
    case badResponse
    case http(Int, String)
    case artifactExpired
    case downloadURLNotFound

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的请求地址"
        case .badResponse: return "服务器响应异常"
        case .http(let code, let message):
            switch code {
            case 401: return "Token 无效或已过期（401），请重新登录"
            case 403: return "权限不足或触发限流（403）\(message)"
            case 404: return "未找到资源，请检查 Token 权限（404）"
            default: return "请求失败（\(code)）\(message)"
            }
        case .artifactExpired: return "该产物已过期，GitHub 已将其删除"
        case .downloadURLNotFound: return "未能获取产物下载地址"
        }
    }
}

private struct GHErrorMessage: Codable {
    let message: String?
}

final class GitHubClient {
    let token: String

    init(token: String) {
        self.token = token
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var comps = URLComponents(string: "https://api.github.com")
        comps?.path = "/" + path
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw GitHubError.badURL }
        return url
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = try makeURL(path, query: query)
        let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(GHErrorMessage.self, from: data))?.message ?? ""
            if http.statusCode == 410 { throw GitHubError.artifactExpired }
            throw GitHubError.http(http.statusCode, msg)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// 验证 Token 并返回当前用户
    func validateToken() async throws -> GHUser {
        try await get("user")
    }

    /// 当前用户可见的仓库（自己 + 协作 + 组织）
    func repos(page: Int) async throws -> [GHRepo] {
        try await get("user/repos", query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ])
    }

    /// 远程搜索仓库
    func searchRepos(keyword: String) async throws -> [GHRepo] {
        let resp: RepoSearchResponse = try await get("search/repositories", query: [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "per_page", value: "30"),
        ])
        return resp.items
    }

    /// 仓库最近的 workflow 运行记录
    func workflowRuns(repo: GHRepo) async throws -> [GHWorkflowRun] {
        let resp: RunsResponse = try await get(
            "repos/\(repo.fullName)/actions/runs",
            query: [URLQueryItem(name: "per_page", value: "30")]
        )
        return resp.workflowRuns
    }

    /// 某次运行产生的产物列表
    func artifacts(repo: GHRepo, run: GHWorkflowRun) async throws -> [GHArtifact] {
        let resp: ArtifactsResponse = try await get(
            "repos/\(repo.fullName)/actions/runs/\(run.id)/artifacts",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        return resp.artifacts
    }

    /// 某个仓库的正式版（Release）
    func releases(repo: GHRepo) async throws -> [GHRelease] {
        try await get("repos/\(repo.fullName)/releases", query: [
            URLQueryItem(name: "per_page", value: "50"),
        ])
    }

    /// 仓库分支（用于下载任意分支的源码包）
    func branches(repo: GHRepo) async throws -> [GHBranch] {
        try await get("repos/\(repo.fullName)/branches", query: [
            URLQueryItem(name: "per_page", value: "100"),
        ])
    }

    /// 解析任意下载项的签名地址。
    /// GitHub 对这些接口都会 302 跳转到带签名的真实地址（产物/日志在 Azure Blob，
    /// 源码包在 codeload），这里拦下跳转拿到真实地址，后续分段下载直接打这个地址
    /// （不再需要 Token，也不再经过 api.github.com）。
    func resolveDownloadURL(for source: DownloadSource) async throws -> URL {
        var extraHeaders: [String: String] = [:]
        let path: String
        switch source {
        case .artifact(let repo, let id):
            path = "repos/\(repo)/actions/artifacts/\(id)/zip"
        case .runLogs(let repo, let runID):
            path = "repos/\(repo)/actions/runs/\(runID)/logs"
        case .releaseAsset(let repo, let assetID):
            path = "repos/\(repo)/releases/assets/\(assetID)"
            // 附件接口默认返回 JSON 元数据，必须显式要二进制才会 302
            extraHeaders["Accept"] = "application/octet-stream"
        case .sourceArchive(let repo, let ref, let format):
            let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
            path = encoded.isEmpty ? "repos/\(repo)/\(format.path)" : "repos/\(repo)/\(format.path)/\(encoded)"
        }

        let url = try makeURL(path)
        var request = authorizedRequest(url)
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .ephemeral, delegate: RedirectCatcher(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.badResponse }
        if http.statusCode == 410 { throw GitHubError.artifactExpired }
        if http.statusCode == 302 || http.statusCode == 303,
           let location = http.value(forHTTPHeaderField: "Location"),
           let signed = URL(string: location) {
            return signed
        }
        if !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(GHErrorMessage.self, from: data))?.message ?? ""
            throw GitHubError.http(http.statusCode, message)
        }
        throw GitHubError.downloadURLNotFound
    }
}

/// 阻止 URLSession 自动跟随 302，把跳转响应原样返回
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
