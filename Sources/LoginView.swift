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
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accent, Theme.purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("ArtifactBoost")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("GitHub 产物 · 正式版 · 源码 · 构建日志\n多通道并发加速下载")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
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
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=ArtifactBoost")!) {
                        Label("创建 classic Token（勾选 repo）", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) {
                        Label("创建 fine-grained Token（Actions + Contents 只读）", systemImage: "arrow.up.right.square")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.accent)
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
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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