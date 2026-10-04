import SwiftUI

/// 设置：账户 + 加速设置（并发 / 通道）+ 通道测速 + 关于
struct SettingsView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var settings = AccelerationSettings.load()
    @State private var isTesting = false
    @State private var testResults: [ScoredRoute] = []
    @State private var testTargetLabel: String?
    @State private var testMessage: String?
    @State private var testFailed = false

    var body: some View {
        List {
            accountSection
            accelerationSection
            speedTestSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .onAppear {
            // 下载过程中可能自动记录过测速结果，回到设置页时同步一下
            settings = AccelerationSettings.load()
        }
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                if let url = session.user?.avatarURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                } else {
                    IconBadge(systemName: "person.fill", color: Theme.accent, size: 46)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.user?.login ?? "已登录")
                        .font(.subheadline.weight(.semibold))
                    Text("Token 保存在本机钥匙串")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            Button(role: .destructive) {
                session.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("账户")
        }
    }

    // MARK: - 加速设置

    private var accelerationSection: some View {
        Section {
            Picker("并发连接数", selection: connectionsBinding) {
                ForEach(AccelerationSettings.connectionOptions, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)

            Picker("下载通道", selection: modeBinding) {
                ForEach(RouteMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if settings.mode == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("加速前缀")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://你的中转地址/", text: prefixBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
            }
        } header: {
            Text("加速设置")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.mode.detail)
                Text("并发数越大越能跑满带宽；绿色网络环境建议 32~64，一般 16 即可。设置会自动保存，下载时直接生效。")
                if settings.mode == .smart {
                    Text("智能加速会额外尝试 ghfast.top —— 它只认 github.com 原始地址，因此**仅对发行版（Release）附件生效**，构建产物与日志仍走其它镜像。")
                }
            }
        }
    }

    // MARK: - 测速

    private var speedTestSection: some View {
        Section {
            Button {
                Task { await runSpeedTest() }
            } label: {
                HStack {
                    Label("测速并保存最快通道", systemImage: "bolt.horizontal.circle.fill")
                    Spacer()
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isTesting)

            if let route = settings.testedRoute, let date = settings.testedAt {
                HStack(spacing: 10) {
                    IconBadge(systemName: route.isDirect ? "arrow.right" : "cloud.fill",
                              color: route.isDirect ? Theme.orange : Theme.green,
                              size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.isDirect ? "直连" : route.name)
                            .font(.subheadline.weight(.semibold))
                        Text("已保存 · \(formatSpeed(settings.testedSpeed)) · \(date.formatted(date: .numeric, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: "当前使用", color: Theme.green)
                }
                .padding(.vertical, 2)
            }

            if !testResults.isEmpty {
                ForEach(testResults, id: \.route) { result in
                    HStack(spacing: 10) {
                        IconBadge(systemName: result.route.isDirect ? "arrow.right" : "cloud.fill",
                                  color: result.route.isDirect ? Theme.orange : Theme.accent,
                                  size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.route.isDirect ? "直连" : result.route.name)
                                .font(.caption.weight(.semibold))
                            if let label = testTargetLabel {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(formatSpeed(result.speed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(result == testResults.first ? Theme.green : .secondary)
                    }
                }
            }

            if let testMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: testFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(testFailed ? Theme.orange : Theme.green)
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("通道测速")
        } footer: {
            Text("测速会拿一个真实的下载目标（优先用你自己仓库里最新的构建产物）分别测试每条通道，把最快的保存下来。之后所有下载都直接用它，不用每次现测。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "1.2")
            Link(destination: URL(string: "https://github.com/yitenchen123/ArtifactBoost")!) {
                Label("项目主页 / 自建中转教程", systemImage: "link")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("智能加速与自定义通道可能让产物数据经过第三方中转，私有仓库会自动强制走直连。Token 全程只在本机使用。")
        }
    }

    // MARK: - 绑定（改动即保存）

    private var connectionsBinding: Binding<Int> {
        Binding(get: { settings.connections },
                set: { settings.connections = $0; settings.save() })
    }

    private var modeBinding: Binding<RouteMode> {
        Binding(get: { settings.mode },
                set: {
                    settings.mode = $0
                    settings.save()
                    testResults = []
                    testMessage = nil
                })
    }

    private var prefixBinding: Binding<String> {
        Binding(get: { settings.customPrefix },
                set: { settings.customPrefix = $0; settings.save() })
    }

    // MARK: - 测速实现

    private func runSpeedTest() async {
        isTesting = true
        testResults = []
        testMessage = nil
        testFailed = false
        settings.save()
        defer { isTesting = false }

        guard let target = await downloads.findTestTarget() else {
            testFailed = true
            testMessage = "没找到可用的测速对象：至少需要一个跑过 Actions 的仓库（有产物或日志）。"
            return
        }

        testTargetLabel = target.label
        var candidates = settings.candidateRoutes(isPrivateRepo: target.isPrivate)
        if target.isPrivate {
            candidates = [.direct]
        }

        let measured = await RouteProbe.measureAll(among: candidates, signedURL: target.url, knownSize: target.size)
        testResults = measured

        guard let best = measured.first else {
            testFailed = true
            testMessage = "测速失败：所有通道都没取到数据，请检查网络后重试。"
            return
        }

        settings.record(route: best.route, speed: best.speed)
        var text = "已保存：\(best.route.isDirect ? "直连" : best.route.name) · \(formatSpeed(best.speed))"
        if target.isPrivate {
            text += "（测速对象来自私有仓库，只测了直连，不会把地址交给镜像）"
        }
        if measured.count < candidates.count {
            text += "（部分通道超时已跳过）"
        }
        testMessage = text
    }
}