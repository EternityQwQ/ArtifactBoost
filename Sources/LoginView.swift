import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var tokenInput = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    tokenCard
                    if let errorMessage {
                        card { ErrorBanner(text: errorMessage) }
                    }
                    loginButton
                    hint
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            IconBadge(systemName: "bolt.horizontal.fill", color: Theme.blue, size: 64)
            Text("ArtifactBoost")
                .font(.system(size: 24, weight: .bold))
            Text("GitHub 产物 · 发行版 · 源码 · 构建日志\n多通道并发加速下载")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 22)
        .padding(.bottom, 2)
    }

    private var tokenCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Personal Access Token", systemImage: "key.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                SecureField("粘贴 Token（ghp_… 或 github_pat_…）", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=ArtifactBoost")!) {
                        Label("创建 classic Token（勾选 repo）", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) {
                        Label("创建 fine-grained Token（Actions + Contents 只读）", systemImage: "arrow.up.right.square")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.blue)

                Text("想下载别人的公开仓库：classic Token 勾 repo 即可；fine-grained Token 需要在 Account permissions 里允许读取公开仓库。")
                    .font(.caption2)
                    .foregroundStyle(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loginButton: some View {
        Button {
            login()
        } label: {
            HStack {
                Spacer()
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("验证并登录").font(.headline)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.green)
        .controlSize(.large)
        .disabled(!canSubmit)
    }

    private var hint: some View {
        Text("Token 只保存在本机钥匙串，不会上传到任何第三方服务器。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().card()
    }

    private func login() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await session.login(token: token)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}