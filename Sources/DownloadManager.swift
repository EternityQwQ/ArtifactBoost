import Foundation
import UIKit

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
    @Published var connections: Int = 8

    private var engines: [Int64: DownloadEngine] = [:]
    private var backgroundTasks: [Int64: UIBackgroundTaskIdentifier] = [:]
    let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    func state(for artifact: GHArtifact) -> State {
        states[artifact.id] ?? .idle
    }

    func start(artifact: GHArtifact, repo: GHRepo) {
        switch state(for: artifact) {
        case .resolving, .downloading:
            return
        default:
            break
        }

        let artifactID = artifact.id
        states[artifactID] = .resolving

        let engine = DownloadEngine()
        engines[artifactID] = engine
        let safeName = artifact.name.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName)-\(artifactID).zip"
        let connectionCount = connections
        beginBackgroundTask(for: artifactID)

        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
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
                    connections: connectionCount,
                    onProgress: onProgress
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

    /// 解析签名地址并下载。签名地址有时效，中途失效（403/断流）时重新解析一次再试，
    /// 避免大文件下到一半前功尽弃。
    private func performDownload(artifact: GHArtifact,
                                 repo: GHRepo,
                                 engine: DownloadEngine,
                                 fileName: String,
                                 connections: Int,
                                 onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<2 {
            do {
                let signed = try await client.resolveDownloadURL(repo: repo, artifact: artifact)
                return try await engine.download(
                    signedURL: signed,
                    fileName: fileName,
                    connections: connections,
                    progress: onProgress
                )
            } catch {
                if !Self.shouldRetry(error) { throw error }
                lastError = error
                if attempt == 0 { states[artifact.id] = .resolving }
            }
        }
        throw lastError
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? DownloadError) == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }

    /// 只有网络类错误才值得重新解析地址再试一次；权限、产物已删除等错误直接抛出
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