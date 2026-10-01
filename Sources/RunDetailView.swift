import SwiftUI

/// 单次构建：构建日志 + 所有产物，都能加速下载
struct RunDetailView: View {
    let repo: GHRepo
    let run: GHWorkflowRun

    @EnvironmentObject private var session: SessionManager

    @State private var artifacts: [GHArtifact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var downloadableArtifacts: [GHArtifact] {
        artifacts.filter { !$0.expired }
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            if let errorMessage {
                Section { ErrorBanner(text: errorMessage) }
            }

            Section {
                DownloadItemRow(item: DownloadItem.runLogs(run, repo: repo))
            } header: {
                Text("构建日志")
            } footer: {
                Text("日志为 GitHub 打包好的 zip，体积一般很小。")
            }

            Section {
                if downloadableArtifacts.isEmpty && !isLoading {
                    EmptyStateView(systemName: "archivebox",
                                   title: "没有可下载的产物",
                                   message: "这次运行没有产物，或者产物已经过期被 GitHub 删除")
                } else {
                    ForEach(downloadableArtifacts) { artifact in
                        DownloadItemRow(item: DownloadItem.artifact(artifact, repo: repo))
                    }
                }
            } header: {
                Text("构建产物")
            } footer: {
                if !artifacts.isEmpty && downloadableArtifacts.count < artifacts.count {
                    Text("有 \(artifacts.count - downloadableArtifacts.count) 个产物已过期，无法下载。")
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
        .navigationTitle("构建 #\(run.runNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(systemName: Theme.runIcon(conclusion: run.conclusion, status: run.status),
                          color: .white,
                          size: 40)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(run.displayTitle ?? run.name ?? "Workflow")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(repo.name) · #\(run.runNumber)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                StatusPill(text: Theme.runText(conclusion: run.conclusion, status: run.status),
                           color: .white)
                StatusPill(text: run.headBranch ?? "-", color: .white, systemImage: "arrow.triangle.branch")
                if let event = run.event {
                    StatusPill(text: event, color: .white)
                }
            }

            if let date = run.createdAt {
                Text(date.formatted(date: .complete, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.95), Theme.purple.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            artifacts = try await client.artifacts(repo: repo, run: run)
        } catch {
            errorMessage = session.message(for: error)
        }
    }
}