import Foundation
import UIKit

/// 加速设置（由界面上的 @AppStorage 传入）
struct DownloadSettings {
    var connections: Int = 16
    var mode: RouteMode = .smart
    var customPrefix: String = ""

    static let `default` = DownloadSettings()
}

@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case idle
        case resolving
        case downloading(DownloadProgress)
        case finished(URL)
        case failed(String)
    }

    @Published var states: [Int64: State] = [:]
    /// 本次下载实际使用的通道与实测速度，用于给用户一个明确的反馈
    @Published var routeSummary: [Int64: String] = [:]

    private var engines: [Int64: DownloadEngine] = [:]
    private var backgroundTasks: [Int64: UIBackgroundTaskIdentifier] = [:]
    /// 本次运行内测速选出的通道组合（含实测速度），后续下载直接复用，不必每次等测速
    private static var cachedPlan: [ScoredRoute]?
    let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    func state(for artifact: GHArtifact) -> State {
        states[artifact.id] ?? .idle
    }

    func start(artifact: GHArtifact, repo: GHRepo, settings: DownloadSettings = .default) {
        switch state(for: artifact) {
        case .resolving, .downloading:
            return
        default:
            break
        }

        let artifactID = artifact.id
        states[artifactID] = .resolving
        routeSummary[artifactID] = nil

        let engine = DownloadEngine()
        engines[artifactID] = engine
        let safeName = artifact.name.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName)-\(artifactID).zip"
        beginBackgroundTask(for: artifactID)

        let progressHandler: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.states[artifactID] {
                case .resolving?, .downloading?, .none:
                    self.states[artifactID] = .downloading(progress)
                default:
                    break
                }
            }
        }

        Task {
            do {
                let url = try await performDownload(
                    artifact: artifact,
                    repo: repo,
                    engine: engine,
                    fileName: fileName,
                    settings: settings,
                    onProgress: progressHandler
                )
                states[artifactID] = .finished(url)
            } catch {
                if Self.isCancellation(error) {
                    states[artifactID] = .idle
                } else {
                    states[artifactID] = .failed(error.localizedDescription)
                }
            }
            engines[artifactID] = nil
            endBackgroundTask(for: artifactID)
        }
    }

    func cancel(artifact: GHArtifact) {
        engines[artifact.id]?.cancel()
    }

    /// 解析签名地址 → 选通道 → 下载。签名地址有时效，整体失败后重新解析再试一次。
    private func performDownload(artifact: GHArtifact,
                                 repo: GHRepo,
                                 engine: DownloadEngine,
                                 fileName: String,
                                 settings: DownloadSettings,
                                 onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<2 {
            do {
                let signed = try await client.resolveDownloadURL(repo: repo, artifact: artifact)
                return try await download(artifact: artifact,
                                          engine: engine,
                                          signedURL: signed,
                                          fileName: fileName,
                                          settings: settings,
                                          isPrivateRepo: repo.isPrivate,
                                          onProgress: onProgress)
            } catch {
                if !Self.shouldRetry(error) { throw error }
                lastError = error
                if attempt == 0 { states[artifact.id] = .resolving }
            }
        }
        throw lastError
    }

    private func download(artifact: GHArtifact,
                          engine: DownloadEngine,
                          signedURL: URL,
                          fileName: String,
                          settings: DownloadSettings,
                          isPrivateRepo: Bool,
                          onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let artifactID = artifact.id
        let candidates = Self.candidateRoutes(settings: settings, isPrivateRepo: isPrivateRepo)

        var plan: [ScoredRoute]
        var note: String
        if candidates.count > 1 {
            if let cached = Self.cachedPlan {
                // 同一台手机的网络环境短时间内不会变，测速过一次就复用，避免每次都等测速
                plan = cached
                note = Self.describe(plan).appending("（沿用已测速结果）")
            } else {
                routeSummary[artifactID] = "正在测速选通道…"
                let measured = await RouteProbe.measureAll(among: candidates,
                                                           signedURL: signedURL,
                                                           sampleLimit: artifact.sizeInBytes)
                // 慢得多的通道不参与并行，否则它那块会拖住整个下载
                let fastest = measured.first?.speed ?? 0
                let viable = measured.filter { $0.speed >= fastest * 0.4 }
                if viable.isEmpty {
                    plan = [ScoredRoute(route: .direct, speed: 1)]
                    note = "直连（测速失败）"
                } else {
                    plan = viable
                    Self.cachedPlan = plan
                    note = Self.describe(plan).appending("（实测 \(formatSpeed(fastest))）")
                }
            }
        } else if isPrivateRepo, settings.mode == .smart {
            plan = [ScoredRoute(route: .direct, speed: 1)]
            note = "直连（私有仓库不走镜像）"
        } else {
            plan = [ScoredRoute(route: candidates[0], speed: 1)]
            note = candidates[0].isDirect ? "直连" : candidates[0].name
        }

        let connections = max(1, min(settings.connections, 64))
        do {
            let result = try await engine.download(signedURL: signedURL,
                                                   routes: plan,
                                                   fileName: fileName,
                                                   connections: connections,
                                                   progress: onProgress)
            routeSummary[artifactID] = "\(note) · 平均 \(formatSpeed(result.averageSpeed))"
            return result.fileURL
        } catch {
            // 通道可能失效/被限流，清掉缓存后整体回退直连再试一次
            guard Self.shouldRetry(error), plan.contains(where: { !$0.route.isDirect }) else { throw error }
            Self.cachedPlan = nil
            let result = try await engine.download(signedURL: signedURL,
                                                   routes: [ScoredRoute(route: .direct, speed: 1)],
                                                   fileName: fileName,
                                                   connections: connections,
                                                   progress: onProgress)
            routeSummary[artifactID] = "直连（\(note) 失败已回退） · 平均 \(formatSpeed(result.averageSpeed))"
            return result.fileURL
        }
    }

    /// 通道描述，例如「多通道 gh-proxy.com + slink.ltd」
    private static func describe(_ plan: [ScoredRoute]) -> String {
        let names = plan.map { $0.route.isDirect ? "直连" : $0.route.name }
        return plan.count > 1 ? "多通道 " + names.joined(separator: " + ") : names[0]
    }

    /// 候选通道：直连永远保留兜底
    private static func candidateRoutes(settings: DownloadSettings, isPrivateRepo: Bool) -> [DownloadRoute] {
        switch settings.mode {
        case .direct:
            return [.direct]
        case .custom:
            let prefix = normalizedPrefix(settings.customPrefix)
            guard !prefix.isEmpty else { return [.direct] }
            return [DownloadRoute(name: "自定义加速", prefix: prefix), .direct]
        case .smart:
            // 私有仓库的产物不该经过第三方镜像，直接走直连
            guard !isPrivateRepo else { return [.direct] }
            return [.direct] + DownloadRoute.builtInMirrors
        }
    }

    private static func normalizedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let url = URL(string: trimmed), url.scheme != nil else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? DownloadError) == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }

    /// 只有网络类错误才值得重试；权限、产物已删除等错误直接抛出
    private static func shouldRetry(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        guard let ghError = error as? GitHubError else { return true }
        switch ghError {
        case .badResponse:
            return true
        case .http(let code, _):
            return code >= 500 || code == 429
        case .artifactExpired, .downloadURLNotFound, .badURL:
            return false
        }
    }

    // MARK: - 后台任务申请，避免切到后台后下载被立即挂起

    private func beginBackgroundTask(for id: Int64) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "ArtifactBoost-\(id)") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTask(for: id)
            }
        }
        if task != .invalid {
            backgroundTasks[id] = task
        }
    }

    private func endBackgroundTask(for id: Int64) {
        guard let task = backgroundTasks.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}