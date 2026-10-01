import Foundation

/// 下载通道：直连 Azure 签名地址，或经由镜像 / 自建反代中转（前缀 + 原始地址）
struct DownloadRoute: Equatable, Sendable {
    let name: String
    let prefix: String

    static let direct = DownloadRoute(name: "直连", prefix: "")

    var isDirect: Bool { prefix.isEmpty }

    /// 内置公共镜像。它们只是中转「已签名的产物地址」，不接触 Token；
    /// 但私有仓库的产物不应经过第三方，所以只在公开仓库且用户开启智能加速时使用。
    static let builtInMirrors: [DownloadRoute] = [
        DownloadRoute(name: "gh-proxy.com", prefix: "https://gh-proxy.com/"),
        DownloadRoute(name: "hk.gh-proxy.com", prefix: "https://hk.gh-proxy.com/"),
        DownloadRoute(name: "moeyy.xyz", prefix: "https://github.moeyy.xyz/"),
    ]

    func apply(to url: URL) -> URL {
        guard !prefix.isEmpty, let mirrored = URL(string: prefix + url.absoluteString) else { return url }
        return mirrored
    }
}

enum RouteMode: String, CaseIterable, Identifiable {
    case direct
    case smart
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "直连"
        case .smart: return "智能加速"
        case .custom: return "自定义"
        }
    }
}

/// 通道测速：每个通道各拉一小段数据，取最快的那条
enum RouteProbe {
    /// 采样 512KB：快通道 0.1~0.5s 出结果，慢通道也不会拖太久
    static let sampleBytes: Int64 = 512 * 1024
    static let timeout: TimeInterval = 6

    /// 探测专用会话：限制总时长，防止某个通道不认 Range 时把整个文件都拉进内存
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    static func fastest(among routes: [DownloadRoute],
                        signedURL: URL,
                        sampleLimit: Int64 = sampleBytes) async -> (route: DownloadRoute, speed: Double)? {
        let limit = max(64 * 1024, min(sampleLimit, sampleBytes))
        return await withTaskGroup(of: (DownloadRoute, Double)?.self) { group in
            for route in routes {
                group.addTask { await measure(route: route, signedURL: signedURL, limit: limit) }
            }
            var best: (route: DownloadRoute, speed: Double)?
            for await result in group {
                guard let result else { continue }
                if best == nil || result.1 > best!.speed {
                    best = (result.0, result.1)
                }
            }
            return best
        }
    }

    static func measure(route: DownloadRoute, signedURL: URL, limit: Int64 = sampleBytes) async -> (DownloadRoute, Double)? {
        var request = URLRequest(url: route.apply(to: signedURL))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")

        let start = Date()
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              // 必须是 206：既确认这条通道支持分段，也避免拿到 200 时把整个文件读进内存
              http.statusCode == 206,
              !data.isEmpty else { return nil }
        let elapsed = max(Date().timeIntervalSince(start), 0.05)
        return (route, Double(data.count) / elapsed)
    }
}