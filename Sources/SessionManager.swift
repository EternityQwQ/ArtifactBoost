import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var user: GHUser?
    @Published private(set) var client: GitHubClient?

    var isLoggedIn: Bool { client != nil }

    init() {
        if let token = KeychainHelper.read() {
            client = GitHubClient(token: token)
            // 上次登录的 Token 还在，异步补拉一次用户信息
            Task { await refreshUser() }
        }
    }

    func login(token: String) async throws {
        let newClient = GitHubClient(token: token)
        let user = try await newClient.validateToken()
        KeychainHelper.save(token: token)
        self.client = newClient
        self.user = user
    }

    func logout() {
        KeychainHelper.delete()
        client = nil
        user = nil
    }

    /// 统一把错误转成给用户看的文案：Token 失效时自动登出，回到登录页
    func message(for error: Error) -> String {
        if case GitHubError.http(let code, _) = error, code == 401 {
            logout()
            return "登录已失效（401），请重新输入 Token"
        }
        if let hint = Self.networkHint(for: error) {
            return hint
        }
        return error.localizedDescription
    }

    /// 网络层错误的中文映射（与安卓端同步）：
    /// URLSession 透出的都是英文原文。解析阶段永远直连 api.github.com，
    /// 所以超时文案里点名，免得用户去折腾通道设置。
    /// 注：GitHubError.requestTimeout 自带中文描述，走 localizedDescription，不经过这里。
    private static func networkHint(for error: Error) -> String? {
        // URLSession 的异步接口直接抛 URLError；个别路径包了 NSError，同样按 code 认
        let code: Int?
        if let urlError = error as? URLError {
            code = urlError.code.rawValue
        } else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return nil }
            code = nsError.code
        }
        switch code {
        case NSURLErrorTimedOut:
            return "连接 GitHub 超时，请检查网络后重试（解析下载地址时永远直连 api.github.com，换通道也救不了这一段）"
        case NSURLErrorCannotFindHost:
            return "无法解析 GitHub 域名，请检查网络 / DNS 后重试"
        case NSURLErrorCannotConnectToHost:
            return "连不上 GitHub，请检查网络或代理后重试"
        case NSURLErrorNotConnectedToInternet:
            return "当前无网络连接，请联网后重试"
        default:
            return nil
        }
    }

    private func refreshUser() async {
        guard let client else { return }
        do {
            user = try await client.validateToken()
        } catch {
            // Token 被撤销 / 过期：直接退出登录，避免停在“假登录”状态里
            if case GitHubError.http(let code, _) = error, code == 401 {
                logout()
            }
        }
    }
}