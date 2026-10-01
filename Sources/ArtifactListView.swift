import SwiftUI

struct ArtifactListView: View {
    let repo: GHRepo
    let run: GHWorkflowRun

    @EnvironmentObject private var session: SessionManager
    @StateObject private var dm: DownloadManager
    @State private var artifacts: [GHArtifact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @AppStorage("ab.connections") private var connections = 16
    @AppStorage("ab.routeMode") private var routeMode: RouteMode = .smart
    @AppStorage("ab.customPrefix") private var customPrefix = ""

    init(repo: GHRepo, run: GHWorkflowRun, client: GitHubClient) {
        self.repo = repo
        self.run = run
        _dm = StateObject(wrappedValue: DownloadManager(client: client))
    }

    private var settings: DownloadSettings {
        DownloadSettings(connections: connections, mode: routeMode, customPrefix: customPrefix)
    }

    var body: some View {
        List {
            Section {
                Stepper("并发连接数：\(connections)", value: $connections, in: 1...32)
                Picker("下载通道", selection: $routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if routeMode == .custom {
                    TextField("加速前缀，如 https://xxx.workers.dev/", text: $customPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("加速设置")
            } footer: {
                Text("并发数默认 16：产物只有几 MB 时也能把连接开满。\n「智能加速」会先给直连和公共镜像测速，自动选最快的一条；镜像只中转已签名的产物地址、不接触你的 Token，但私有仓库请保持「直连」。")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if artifacts.isEmpty && !isLoading {
                Section {
                    Text("该运行没有可下载的产物（可能已过期）")
                        .foregroundStyle(.secondary)
                }
            }

            Section("产物") {
                ForEach(artifacts) { artifact in
                    artifactRow(artifact)
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
        .navigationTitle("运行 #\(run.runNumber)")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func artifactRow(_ artifact: GHArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name).font(.headline)
                    Text("\(formatBytes(artifact.sizeInBytes)) · \(artifact.createdAt?.formatted(date: .numeric, time: .omitted) ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if artifact.expired {
                    Text("已过期")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            switch dm.state(for: artifact) {
            case .idle:
                Button {
                    dm.start(artifact: artifact, repo: repo, settings: settings)
                } label: {
                    Label("加速下载", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(artifact.expired)

            case .resolving:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(dm.routeSummary[artifact.id] ?? "正在获取下载地址…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text("\(formatBytes(progress.downloadedBytes)) / \(formatBytes(progress.totalBytes))（\(Int(progress.fraction * 100))%）")
                        Spacer()
                        Text(formatSpeed(progress.speedBytesPerSecond))
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let summary = dm.routeSummary[artifact.id] {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("取消", role: .destructive) {
                        dm.cancel(artifact: artifact)
                    }
                    .font(.caption)
                }

            case .finished(let url):
                VStack(alignment: .leading, spacing: 6) {
                    Label("下载完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    if let summary = dm.routeSummary[artifact.id] {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        ShareLink(item: url) {
                            Label("导出 / 保存到文件", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("重新下载") {
                            dm.start(artifact: artifact, repo: repo, settings: settings)
                        }
                        .font(.caption)
                    }
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试") {
                        dm.start(artifact: artifact, repo: repo, settings: settings)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            artifacts = try await dm.client.artifacts(repo: repo, run: run)
        } catch {
            errorMessage = session.message(for: error)
        }
    }
}
