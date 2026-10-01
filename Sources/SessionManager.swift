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
        return error.localizedDescription
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