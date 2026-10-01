import Foundation

enum ArchiveFormat: String, Hashable, Sendable {
    case zip
    case tarball

    var path: String { self == .zip ? "zipball" : "tarball" }
    var fileExtension: String { self == .zip ? "zip" : "tar.gz" }
    var title: String { self == .zip ? "ZIP" : "TAR.GZ" }
}

/// 能加速下载的东西：构建产物 / 构建日志 / 正式版附件 / 源码包
enum DownloadSource: Hashable, Sendable {
    case artifact(repo: String, id: Int64)
    case runLogs(repo: String, runID: Int64)
    case releaseAsset(repo: String, assetID: Int64)
    case sourceArchive(repo: String, ref: String, format: ArchiveFormat)

    /// 源码包由 GitHub 现场打包，不支持 Range 分段，只能单连接下载
    var supportsChunkedDownload: Bool {
        if case .sourceArchive = self { return false }
        return true
    }

    var iconName: String {
        switch self {
        case .artifact: return "archivebox.fill"
        case .runLogs: return "doc.text.fill"
        case .releaseAsset: return "shippingbox.fill"
        case .sourceArchive: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var kindName: String {
        switch self {
        case .artifact: return "构建产物"
        case .runLogs: return "构建日志"
        case .releaseAsset: return "正式版附件"
        case .sourceArchive: return "源码包"
        }
    }
}

/// 界面上一行「可下载项」
struct DownloadItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let size: Int64?
    let isPrivate: Bool
    let source: DownloadSource

    var iconName: String { source.iconName }
    var kindName: String { source.kindName }

    /// 落盘文件名
    var fileName: String {
        switch source {
        case .artifact:
            return sanitize(title) + ".zip"
        case .runLogs:
            return sanitize(title) + "-logs.zip"
        case .releaseAsset:
            return sanitize(title)
        case .sourceArchive(_, let ref, let format):
            let base = ref.isEmpty ? "source" : sanitize(ref)
            return "\(sanitize(title))-\(base).\(format.fileExtension)"
        }
    }

    private func sanitize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 由接口数据构造下载项

extension DownloadItem {
    static func artifact(_ artifact: GHArtifact, repo: GHRepo) -> DownloadItem {
        DownloadItem(
            id: "artifact-\(artifact.id)",
            title: artifact.name,
            subtitle: "构建产物 · \(artifact.createdAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "时间未知")",
            size: artifact.sizeInBytes,
            isPrivate: repo.isPrivate,
            source: .artifact(repo: repo.fullName, id: artifact.id)
        )
    }

    static func runLogs(_ run: GHWorkflowRun, repo: GHRepo) -> DownloadItem {
        DownloadItem(
            id: "logs-\(run.id)",
            title: "\(run.name ?? "Workflow") #\(run.runNumber) 日志",
            subtitle: "构建日志 · \(run.headBranch ?? "-")",
            size: nil,
            isPrivate: repo.isPrivate,
            source: .runLogs(repo: repo.fullName, runID: run.id)
        )
    }

    static func releaseAsset(_ asset: GHReleaseAsset, release: GHRelease, repo: GHRepo) -> DownloadItem {
        DownloadItem(
            id: "asset-\(asset.id)",
            title: asset.name,
            subtitle: "\(release.displayName) · 下载 \(asset.downloadCount) 次",
            size: asset.size,
            isPrivate: repo.isPrivate,
            source: .releaseAsset(repo: repo.fullName, assetID: asset.id)
        )
    }

    static func sourceArchive(repo: GHRepo, ref: String, format: ArchiveFormat) -> DownloadItem {
        let label = ref.isEmpty ? (repo.defaultBranch ?? "默认分支") : ref
        return DownloadItem(
            id: "source-\(repo.fullName)-\(label)-\(format.rawValue)",
            title: "\(repo.name)-\(label)",
            subtitle: "源码包 · \(format.title)",
            size: nil,
            isPrivate: repo.isPrivate,
            source: .sourceArchive(repo: repo.fullName, ref: ref, format: format)
        )
    }
}