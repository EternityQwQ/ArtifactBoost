import Foundation

/// 通道的作用域：决定它能套在哪种 URL 上。
///
/// 这是新增 ghfast 后必须区分的一件事 ——
/// 常规镜像（gh-proxy 等）是「把已签名的真实地址塞进前缀」，任何地址都能中转；
/// 而 ghfast.top 只认 `github.com` 原始地址，套到 Azure 签名地址上会直接 400。
enum RouteScope: Sendable {
    /// 可用于任何地址（含 Azure 签名地址）
    case any
    /// 只能用于 github.com 的原始地址（发行版附件的稳定下载链接）
    case githubOnly
}

/// 下载通道：直连 Azure 签名地址，或经由镜像 / 自建反代中转（前缀 + 原始地址）
struct DownloadRoute: Hashable, Sendable {
    let name: String
    let prefix: String
    let scope: RouteScope

    init(name: String, prefix: String, scope: RouteScope = .any) {
        self.name = name
        self.prefix = prefix
        self.scope = scope
    }

    static let direct = DownloadRoute(name: "直连", prefix: "")

    var isDirect: Bool { prefix.isEmpty }

    /// 内置公共镜像。它们只是中转「已签名的产物地址」，不接触 Token；
    /// 但私有仓库的产物不应经过第三方，所以只在公开仓库且用户开启智能加速时使用。
    /// 不同节点往往落在不同的机房/线路上，多通道并行时带宽可以叠加。
    static let builtInMirrors: [DownloadRoute] = [
        DownloadRoute(name: "gh-proxy.com", prefix: "https://gh-proxy.com/"),
        DownloadRoute(name: "slink.ltd", prefix: "https://slink.ltd/"),
        DownloadRoute(name: "hk.gh-proxy.com", prefix: "https://hk.gh-proxy.com/"),
        DownloadRoute(name: "moeyy.xyz", prefix: "https://github.moeyy.xyz/"),
    ]

    /// ghfast.top —— **只能用于发行版**。
    ///
    /// 它的用法是 `https://ghfast.top/https://github.com/...`，
    /// 也就是必须给它一个 github.com 的原始地址；
    /// 构建产物 / 构建日志解析出来的是临时签名地址，套上去会被拒。
    /// 因此单独归类，只在下载发行版附件时参与候选。
    static let ghfast = DownloadRoute(
        name: "ghfast.top",
        prefix: "https://ghfast.top/",
        scope: .githubOnly
    )

    /// 给一次具体下载挑可用的镜像。
    ///
    /// - Parameter githubURL: 该下载在 github.com 上的稳定地址；只有发行版有，其余为 nil。
    ///   为 nil 时 `.githubOnly` 的通道会被剔除。
    static func mirrors(for githubURL: URL?) -> [DownloadRoute] {
        githubURL == nil ? builtInMirrors : builtInMirrors + [ghfast]
    }

    func apply(to url: URL) -> URL {
        guard !prefix.isEmpty, let mirrored = URL(string: prefix + url.absoluteString) else { return url }
        return mirrored
    }

    /// 补全并校验用户填的前缀，非法时返回空串
    static func normalizedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let url = URL(string: trimmed), url.scheme != nil else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}

/// 带实测速度的通道，用于按速度分配分块
struct ScoredRoute: Equatable, Sendable {
    let route: DownloadRoute
    let speed: Double
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

    var detail: String {
        switch self {
        case .direct: return "直接连 GitHub 存储，最安全，但国内通常很慢"
        case .smart: return "自动在直连与公共镜像之间测速，选最快的通道"
        case .custom: return "使用你自己搭建的中转（Cloudflare Worker / 反向代理）"
        }
    }
}

/// 持久化的加速设置：在「设置」页调好并保存，下载时直接套用
struct AccelerationSettings {
    var connections: Int = 16
    var mode: RouteMode = .smart
    var customPrefix: String = ""
    /// 「设置」页测速得到的最快通道
    var testedRoute: DownloadRoute?
    var testedSpeed: Double = 0
    var testedAt: Date?

    static let `default` = AccelerationSettings()
    static let connectionOptions = [8, 16, 32, 64]

    private enum Keys {
        static let connections = "ab.connections"
        static let mode = "ab.routeMode"
        static let customPrefix = "ab.customPrefix"
        static let testedName = "ab.testedRouteName"
        static let testedPrefix = "ab.testedRoutePrefix"
        static let testedSpeed = "ab.testedRouteSpeed"
        static let testedAt = "ab.testedRouteDate"
    }

    static func load() -> AccelerationSettings {
        let store = UserDefaults.standard
        var settings = AccelerationSettings()
        let stored = store.integer(forKey: Keys.connections)
        settings.connections = stored > 0 ? stored : 16
        settings.mode = RouteMode(rawValue: store.string(forKey: Keys.mode) ?? "") ?? .smart
        settings.customPrefix = store.string(forKey: Keys.customPrefix) ?? ""
        if let name = store.string(forKey: Keys.testedName) {
            settings.testedRoute = DownloadRoute(name: name, prefix: store.string(forKey: Keys.testedPrefix) ?? "")
            settings.testedSpeed = store.double(forKey: Keys.testedSpeed)
            settings.testedAt = store.object(forKey: Keys.testedAt) as? Date
        }
        return settings
    }

    func save() {
        let store = UserDefaults.standard
        store.set(clampedConnections, forKey: Keys.connections)
        store.set(mode.rawValue, forKey: Keys.mode)
        store.set(customPrefix, forKey: Keys.customPrefix)
        if let route = testedRoute {
            store.set(route.name, forKey: Keys.testedName)
            store.set(route.prefix, forKey: Keys.testedPrefix)
            store.set(testedSpeed, forKey: Keys.testedSpeed)
            store.set(testedAt ?? Date(), forKey: Keys.testedAt)
        } else {
            for key in [Keys.testedName, Keys.testedPrefix, Keys.testedSpeed, Keys.testedAt] {
                store.removeObject(forKey: key)
            }
        }
    }

    var clampedConnections: Int { max(1, min(connections, 64)) }

    /// 当前设置下的候选通道（直连永远保留兜底）
    ///
    /// - Parameter githubURL: 该下载在 github.com 上的稳定地址；只有发行版有。
    ///   非空时 ghfast 才会进入候选（它只认 github.com 原始地址）。
    func candidateRoutes(isPrivateRepo: Bool = false, githubURL: URL? = nil) -> [DownloadRoute] {
        switch mode {
        case .direct:
            return [.direct]
        case .custom:
            let prefix = DownloadRoute.normalizedPrefix(customPrefix)
            guard !prefix.isEmpty else { return [.direct] }
            return [DownloadRoute(name: "自定义加速", prefix: prefix), .direct]
        case .smart:
            guard !isPrivateRepo else { return [.direct] }
            return [.direct] + DownloadRoute.mirrors(for: githubURL)
        }
    }

    /// 下载开始时**直接沿用**测速结果的有效期。
    ///
    /// 老实现是 24 小时：一条早上测出来的「快通道」到了晚上可能早就被限流，
    /// 结果下载起步看着还行、很快掉到几十 KB。现在超过这个时长就重新测速。
    static let savedPlanValidInterval: TimeInterval = 4 * 3600

    /// 可以直接沿用的测速结果（有效期内、且不在私有仓库里用镜像）
    func savedPlan(isPrivateRepo: Bool, githubURL: URL? = nil) -> [ScoredRoute]? {
        guard let route = testedRoute, let testedAt else { return nil }
        guard Date().timeIntervalSince(testedAt) < Self.savedPlanValidInterval else { return nil }
        guard !(isPrivateRepo && !route.isDirect) else { return nil }
        guard candidateRoutes(isPrivateRepo: isPrivateRepo, githubURL: githubURL).contains(route) else { return nil }
        return [ScoredRoute(route: route, speed: max(testedSpeed, 0.01))]
    }

    /// 记录一次测速结果
    mutating func record(route: DownloadRoute, speed: Double) {
        testedRoute = route
        testedSpeed = speed
        testedAt = Date()
        save()
    }
}

/// 通道测速：每个通道各拉一小段数据，取最快的那条
enum RouteProbe {
    /// 采样 512KB，并从文件中部取样 —— 长链路上开头几个包要经历 TCP 慢启动，
    /// 只测开头会把所有通道都测成同一个烂数，选出来的「最快通道」等于抽签。
    static let sampleBytes: Int64 = 512 * 1024
    static let timeout: TimeInterval = 8

    /// 探测专用会话：限制总时长，防止某个通道不认 Range 时把整个文件都拉进内存
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    /// 并发测量所有通道，返回按速度从快到慢排序的结果（失败的通道会被丢掉）
    ///
    /// - Parameter knownSize: 已知体积时从文件中段取样，避开 TCP 慢启动
    /// - Parameter githubURL: ghfast 这类 `.githubOnly` 通道只能用它测
    static func measureAll(among routes: [DownloadRoute],
                           signedURL: URL,
                           githubURL: URL? = nil,
                           sampleLimit: Int64 = sampleBytes,
                           knownSize: Int64? = nil) async -> [ScoredRoute] {
        let limit = max(64 * 1024, min(sampleLimit, sampleBytes))
        let results = await withTaskGroup(of: ScoredRoute?.self) { group in
            for route in routes {
                let target: URL? = {
                    switch route.scope {
                    case .any: return signedURL
                    case .githubOnly: return githubURL
                    }
                }()
                guard let target else { continue }
                group.addTask { await measure(route: route, signedURL: target, limit: limit, knownSize: knownSize) }
            }
            var collected: [ScoredRoute] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }
        return results.sorted { $0.speed > $1.speed }
    }

    static func measure(route: DownloadRoute,
                        signedURL: URL,
                        limit: Int64 = sampleBytes,
                        knownSize: Int64? = nil) async -> ScoredRoute? {
        // 已知体积就从中间取样，避开慢启动
        let offset: Int64 = {
            guard let knownSize, knownSize > limit * 3 else { return 0 }
            return (knownSize - limit) / 2
        }()
        var request = URLRequest(url: route.apply(to: signedURL))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("bytes=\(offset)-\(offset + limit - 1)", forHTTPHeaderField: "Range")

        let start = Date()
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              // 206 = 支持分段；200 说明目标本身小于采样长度（比如日志包），按实际收到的字节算速度
              http.statusCode == 206 || http.statusCode == 200,
              !data.isEmpty else { return nil }
        let elapsed = max(Date().timeIntervalSince(start), 0.05)
        return ScoredRoute(route: route, speed: Double(data.count) / elapsed)
    }
}