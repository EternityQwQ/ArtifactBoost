import Foundation

struct DownloadProgress: Equatable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double = 0
    var speedBytesPerSecond: Double = 0
    /// 分段的实时明细，用于「详细信息」面板；未开始分段时为 nil
    var diagnostics: DownloadDiagnostics? = nil
}

/// 单个分段的连接状态
enum SegmentState: String, Equatable, Sendable {
    case pending
    case downloading
    case retrying
    case done
    case failed

    var label: String {
        switch self {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .retrying: return "重试中"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }
}

/// 一条「车道」的实时快照 —— 也就是一个 worker 当前正在啃的区间。
///
/// 这是「详细信息」面板的数据源：用户在界面上一眼能看到哪条连接在跑、
/// 跑到哪个区间、当前多快、有没有在重试、服务端回了什么状态码。
struct LaneSnapshot: Equatable, Identifiable, Sendable {
    let laneId: Int
    let routeName: String
    let url: String
    let start: Int64
    let end: Int64
    let downloaded: Int64
    let speedBytesPerSecond: Double
    let state: SegmentState
    let attempt: Int
    let lastStatus: Int?

    var id: Int { laneId }
    var length: Int64 { end - start + 1 }
    var fraction: Double {
        guard length > 0 else { return 0 }
        return min(max(Double(downloaded) / Double(length), 0), 1)
    }
}

/// 某条通道的实测速度与占用情况
struct RouteStats: Equatable, Identifiable, Sendable {
    let name: String
    let speedBytesPerSecond: Double
    let isActive: Bool
    var id: String { name }
}

/// 整次下载的诊断快照
struct DownloadDiagnostics: Equatable, Sendable {
    let lanes: [LaneSnapshot]
    let targetLanes: Int
    /// 已经完成的切片数 / 累计切出的切片总数
    let doneSlices: Int
    let totalSlices: Int
    let retries: Int
    let throttles: Int
    let splits: Int
    let routes: [RouteStats]
    /// 当前正在用的下载地址（可复制）
    let activeUrl: String
}

enum DownloadError: LocalizedError, Equatable {
    case badResponse
    case cancelled
    case incomplete
    /// 服务器明确要求我们慢一点（429 / 503 等），需要按 Retry-After 退避
    case throttled(code: Int, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "下载失败：服务器响应异常"
        case .cancelled: return "下载已取消"
        case .incomplete: return "下载失败：数据校验不通过（可能断流），请重试"
        case .throttled(let code, _): return "下载失败：服务器限流（\(code)）"
        }
    }

    static func == (lhs: DownloadError, rhs: DownloadError) -> Bool {
        switch (lhs, rhs) {
        case (.badResponse, .badResponse), (.cancelled, .cancelled), (.incomplete, .incomplete):
            return true
        case let (.throttled(a, _), .throttled(b, _)):
            return a == b
        default:
            return false
        }
    }
}

struct DownloadResult {
    let fileURL: URL
    let averageSpeed: Double
    /// 本次实际吃满的并发数
    let lanes: Int
}

/// 一个待下载的区间（左闭右闭）。区间只记 start/end，砍成两半不需要给任何 worker 重新编号。
private struct Chunk: Sendable {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }
}

/// 待下载区间的池子（滑动窗口）
private final class SlicePool: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Chunk] = []

    /// 每次「把末尾区间砍一刀」记一笔
    private(set) var splits = 0
    /// 已完成的字节数：用来估算剩余量、决定分片粒度
    private var completed: Int64 = 0
    private(set) var failures = 0
    private(set) var throttles = 0

    var backlog: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    init(total: Int64) {
        queue = [Chunk(start: 0, end: total - 1)]
    }

    func downloaded() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func recordDone(_ bytes: Int64) {
        lock.lock(); completed += bytes; lock.unlock()
    }

    func recordFailure() {
        lock.lock(); failures += 1; lock.unlock()
    }

    func recordThrottle() {
        lock.lock(); throttles += 1; lock.unlock()
    }

    /// 取一段活儿；没有就返回 nil，由调度循环决定要不要切分
    func take() -> Chunk? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// 把没下完的区间还回队列最前面
    func putBack(_ chunk: Chunk) {
        lock.lock(); queue.insert(chunk, at: 0); lock.unlock()
    }

    /// 池子空了、但还有连接闲着时调用：从队列末尾挑一段砍成两半
    func splitTail(live: Int, target: Int) -> Chunk? {
        guard live > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let victim = queue.popLast() else { return nil }
        guard victim.length > Int64(target) else {
            queue.append(victim)
            return nil
        }
        let half = victim.length / 2
        queue.append(Chunk(start: victim.start + half, end: victim.end))
        splits += 1
        return Chunk(start: victim.start, end: victim.start + half - 1)
    }
}

/// 汇总各分块进度，节流后回调给 UI
private actor ProgressAccumulator {
    private var downloaded: Int64 = 0
    private let total: Int64
    private let handler: @Sendable (DownloadProgress) -> Void
    /// 快照来源：每拍现取一次车道看板，拿到的就是「此刻」而不是「启动时」的明细
    private let diagnostics: (@Sendable () -> DownloadDiagnostics?)?
    private var lastEmit = Date.distantPast
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var zeroStreak = 0

    init(total: Int64,
         handler: @escaping @Sendable (DownloadProgress) -> Void,
         diagnostics: (@Sendable () -> DownloadDiagnostics?)? = nil) {
        self.total = total
        self.handler = handler
        self.diagnostics = diagnostics
    }

    /// 速度用滑动平均避免数字乱跳；但连续几拍零增长时必须往下压，
    /// 否则界面会一直挂着峰值速度、而实际已经掉下去了。
    private func snapshot(_ current: Int64) -> DownloadProgress {
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt > 0.05 {
            let delta = current - lastSampleBytes
            if delta <= 0 {
                zeroStreak += 1
                // 连续 3 拍没涨（约 0.75s 零吞吐）：平滑值必须往下压
                if zeroStreak >= 3 { smoothedSpeed *= 0.4 }
            } else {
                zeroStreak = 0
                let instant = Double(delta) / dt
                smoothedSpeed = smoothedSpeed <= 0 ? instant : smoothedSpeed * 0.6 + instant * 0.4
            }
            lastSampleTime = now
            lastSampleBytes = current
        }
        return DownloadProgress(
            downloadedBytes: current,
            totalBytes: total,
            fraction: total > 0 ? min(Double(current) / Double(total), 1) : 0,
            speedBytesPerSecond: max(smoothedSpeed, 0),
            diagnostics: diagnostics?()
        )
    }

    func advance(_ bytes: Int64) {
        downloaded += bytes
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        lastEmit = now
        handler(snapshot(downloaded))
    }

    func finish(downloaded: Int64) {
        self.downloaded = downloaded
        var progress = snapshot(downloaded)
        progress.totalBytes = max(total, downloaded)
        progress.downloadedBytes = progress.totalBytes
        progress.fraction = 1
        handler(progress)
    }
}

/// 一次分片请求的结果
private struct SliceOutcome: Sendable {
    let data: Data
    let elapsed: TimeInterval
}

/// 通道列表的回填盒子：accumulator 的快照闭包要先于通道建好，
/// 于是先用一个盒子占位，通道一建好就塞进去。
private final class ChannelsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [RouteChannel] = []

    var value: [RouteChannel] {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ channels: [RouteChannel]) {
        lock.lock(); _value = channels; lock.unlock()
    }
}

/// 一个通道：独立 URLSession（独立连接池）+ 地址列表 + 实时吞吐
private final class RouteChannel: @unchecked Sendable {
    let session: URLSession
    /// 展示名（直连 / gh-proxy.com / …），用于诊断面板
    let name: String
    private let lock = NSLock()
    private var urls: [URL]
    private var speed: Double
    private var _throttled = false

    init(session: URLSession, urls: [URL], speedHint: Double, name: String) {
        self.session = session
        self.urls = urls
        self.speed = max(speedHint, 1)
        self.name = name
    }

    /// 是否本通道处于「被限流降额」状态
    var throttled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _throttled
    }

    func setThrottled(_ value: Bool) {
        lock.lock(); _throttled = value; lock.unlock()
    }

    var current: URL {
        lock.lock(); defer { lock.unlock() }
        return urls[0]
    }

    var measuredSpeed: Double {
        lock.lock(); defer { lock.unlock() }
        return speed
    }

    func demote() {
        lock.lock(); speed = max(speed * 0.5, 1); lock.unlock()
    }

    func rotate() {
        lock.lock()
        if urls.count > 1 { urls = Array(urls.dropFirst()) + [urls[0]] }
        lock.unlock()
    }

    func observe(elapsed: TimeInterval, bytes: Int64) {
        guard elapsed > 0.02, bytes > 0 else { return }
        let instant = Double(bytes) / elapsed
        lock.lock()
        speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3
        lock.unlock()
    }
}

/// 车道状态看板：所有 worker 把自己的实时状态登记在这里，
/// 由进度回调按既有的 250ms 节流节奏取走 —— 不额外起轮询、不加网络开销。
///
/// 同时兼任「通道级并发配额」的计数：命中 429/503 的通道会被临时降额，
/// 免得在同一根被限流的线路上继续加压、越限越死。
private final class LaneBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var lanes: [Int: LaneSnapshot] = [:]
    private var penalties: [String: Int] = [:]

    let target: Int

    private(set) var doneSlices = 0
    private(set) var totalSlices = 0
    private(set) var retries = 0
    private(set) var throttles = 0
    private(set) var splits = 0
    private var _activeUrl = ""

    init(target: Int) { self.target = target }

    var activeUrl: String {
        get { lock.lock(); defer { lock.unlock() }; return _activeUrl }
        set { lock.lock(); _activeUrl = newValue; lock.unlock() }
    }

    func update(_ snapshot: LaneSnapshot) {
        lock.lock(); lanes[snapshot.laneId] = snapshot; lock.unlock()
    }

    func remove(_ laneId: Int) {
        lock.lock(); lanes.removeValue(forKey: laneId); lock.unlock()
    }

    func bumpDoneSlice() { lock.lock(); doneSlices += 1; lock.unlock() }
    func bumpTotalSlice() { lock.lock(); totalSlices += 1; lock.unlock() }
    func bumpRetry() { lock.lock(); retries += 1; lock.unlock() }
    func bumpThrottle() { lock.lock(); throttles += 1; lock.unlock() }
    func bumpSplit() { lock.lock(); splits += 1; lock.unlock() }

    /// 通道被限流：记一笔惩罚，通道跑顺后再衰减回去
    func penalize(_ routeName: String) {
        lock.lock(); penalties[routeName, default: 0] += 1; lock.unlock()
    }

    func reward(_ routeName: String) {
        lock.lock()
        if let value = penalties[routeName], value > 0 { penalties[routeName] = value - 1 }
        lock.unlock()
    }

    func penalty(of routeName: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return penalties[routeName] ?? 0
    }

    /// 只取在跑的车道（供「哪条通道正在干活」判断用）
    func liveLanes() -> [LaneSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return Array(lanes.values)
    }

    func snapshot(routes: [RouteStats]) -> DownloadDiagnostics {
        lock.lock()
        let laneValues = lanes.values.sorted { $0.start < $1.start }
        let d = doneSlices, t = totalSlices, r = retries, th = throttles, sp = splits, url = _activeUrl
        lock.unlock()
        return DownloadDiagnostics(lanes: laneValues,
                                   targetLanes: target,
                                   doneSlices: d,
                                   totalSlices: t,
                                   retries: r,
                                   throttles: th,
                                   splits: sp,
                                   routes: routes,
                                   activeUrl: url)
    }
}

/// 多线程分段下载引擎（滑动窗口 + 分片续做）。
///
/// 产物实际托管在 Azure Blob Storage，支持 Range 请求；单连接被限速时，
/// 多并发能显著提升总速度——这正是本引擎存在的意义。
///
/// 与「一次性切块 + 固定分配给各连接」的老做法相比，这里的调度是自适应的：
///
///  1. **滑动窗口**：并发跑满 `connections` 个任务，每个任务只取「一小片」；
///     而不是开 N 个协程去啃又大又不均匀的一大块。
///  2. **分片续做（steal）**：任何时刻若只剩少量区间在跑、而空闲 worker 还很多，
///     就把末尾那段区间再砍一半。下载最后阶段不再是「一个慢连接收尾、
///     其它连接全部闲着」，而是所有连接一起把剩下的数据吃完。
///  3. **动态分片大小**：剩余数据多就取大一点（少发请求），接近尾声就取小一点
///     （让所有连接都能分到收尾的活儿）。
///  4. **区间即偏移**：区间只记 (start, end)，砍分时不需要重编号，写盘可以乱序并发。
///  5. **指数退避 + Retry-After**：命中 Azure 的 503 ServerBusy / 429 时限速时按官方
///     建议退避，而不是火上浇油地硬重试，否则会被越限越死。
///  6. **实时吞吐反馈**：某个通道早就慢下来了，就少给它派活
///     （旧的「一次性按测速结果分配」正是慢通道拖死整体进度的原因之一）。
final class DownloadEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    private let cancelledFlag = CancelledFlag()

    /// 在飞的下载任务：取消时必须逐个 cancel，否则挂起的 `await` 会一直等下去
    private let inflight = TaskRegistry()

    /// 取消下载。
    ///
    /// 「点了就停」需要三件事一起做：置标志位 → 取消每个在飞的 URLSessionDataTask
    /// → 让上层 actor 里的等待被唤醒。只置标志位是不够的：
    /// 已经挂起的 `await session.data(for:)` 不会自己返回，得靠 task.cancel() 打断。
    func cancel() {
        cancelledFlag.set()
        inflight.cancelAll()
        lock.lock()
        let current = sessions
        lock.unlock()
        current.forEach { $0.invalidateAndCancel() }
    }

    private var isCancelled: Bool { cancelledFlag.value }

    /// 可取消的一次请求。
    ///
    /// `URLSession.data(for:)` 挂起时，协程取消不会让它返回；必须拿到 task 调 `cancel()`。
    /// 这里用 continuation 自己控制，把 task 登记进 [inflight]，
    /// 这样 `engine.cancel()` 和「上层 Task 取消」两条路径都能立刻掐断等待。
    private func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }

        let holder = TaskHolder()
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    let task = session.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: DownloadError.badResponse)
                        }
                    }
                    holder.task = task
                    inflight.register(task)
                    // 注册后立刻再查一次：取消可能恰好发生在这两步之间
                    if isCancelled || inflight.isCancelling {
                        task.cancel()
                    } else {
                        task.resume()
                    }
                }
            } onCancel: {
                holder.task?.cancel()
            }
            if let task = holder.task { inflight.release(task) }
            return result
        } catch {
            if let task = holder.task { inflight.release(task) }
            throw error
        }
    }

    private func setSessions(_ newValue: [URLSession]) {
        lock.lock()
        sessions = newValue
        lock.unlock()
    }

    /// 多通道并行下载。
    ///
    /// - Parameters:
    ///   - routeURLs: 每条通道 **各自** 要请求的地址（顺序与 `routes` 一一对应）。
    ///     之所以逐条传进来而不是统一套一个签名地址：ghfast 这类镜像只认
    ///     `github.com` 原始地址，套签名地址会被拒。
    ///   - plans: 已按实测速度排序的通道，第一条同时作为其它通道失败时的兜底
    ///   - allowChunking: 目标是否可能支持分段；为 false 时先走单连接，
    ///     但读到 206 之后依旧会自动升级为分段下载
    func download(routeURLs: [URL],
                  routes: [ScoredRoute],
                  fileName: String,
                  connections: Int,
                  allowChunking: Bool = true,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        cancelledFlag.reset()
        inflight.reset()
        let startedAt = Date()
        let plan = routes.isEmpty ? [ScoredRoute(route: .direct, speed: 1)] : routes
        let urls = routeURLs.isEmpty
            ? plan.map { $0.route.apply(to: URL(string: "https://example.invalid")!) }
            : routeURLs
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let outDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artifacts", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var outURL = outDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: outURL.path) {
            outURL = outDir.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(fileName)")
        }

        let lanes = max(1, min(connections, 64))

        // 先探测体积 + 确认服务器是否真的支持 Range
        let probe = allowChunking ? try await probeSize(urls: urls) : nil
        let total: Int64? = probe?.total

        guard let total, total > 0 else {
            // 探测不到体积（不少接口不回 Content-Length）：
            // 先单连接跑，只要响应是 206 就现场升级成多线程分段
            let single = try await downloadSingle(url: urls[0],
                                                 into: outURL,
                                                 lanes: lanes,
                                                 progress: progress)
            return DownloadResult(fileURL: single.url,
                                  averageSpeed: Self.speed(bytes: single.bytes, since: startedAt),
                                  lanes: single.lanes)
        }

        guard probe?.chunked == true, total >= Self.minChunkedTotal else {
            // 服务器忽略了 Range（返回 200 全量），或者文件太小不值得分段
            let single = try await downloadSingle(url: urls[0],
                                                 into: outURL,
                                                 lanes: lanes,
                                                 progress: progress)
            return DownloadResult(fileURL: single.url,
                                  averageSpeed: Self.speed(bytes: single.bytes, since: startedAt),
                                  lanes: single.lanes)
        }

        let fileURL = try await segmentDownload(urls: urls,
                                                total: total,
                                                outURL: outURL,
                                                lanes: lanes,
                                                plan: plan,
                                                progress: progress)
        return DownloadResult(fileURL: fileURL,
                              averageSpeed: Self.speed(bytes: total, since: startedAt),
                              lanes: lanes)
    }

    private static func speed(bytes: Int64, since start: Date) -> Double {
        Double(bytes) / max(Date().timeIntervalSince(start), 0.05)
    }

    // MARK: - 分段下载主循环

    /// 滑动窗口 + 分片续做（work stealing）的调度器。
    ///
    /// `lanes` 是目标并发数，同时也是「同时在跑的区间数」上限。
    /// 每个区间按 `sliceTarget` 的粒度取数据，写完一片就接着取下一片；
    /// 一旦池子里没活儿而还有连接闲着，就从末尾区间切一刀 —— 空闲连接立刻有活干。
    ///
    /// 这样就不会再出现「刚开始很快、到后面掉到几十 KB」：
    /// 那正是老实现里「一条慢连接独自收尾，其余连接全部空转」造成的。
    private func segmentDownload(urls: [URL],
                                 total: Int64,
                                 outURL: URL,
                                 lanes: Int,
                                 plan: [ScoredRoute],
                                 progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        // 车道状态看板：worker 实时登记，进度回调每拍取走一份快照。
        // 先于 accumulator 建好，因为 accumulator 的快照闭包要读它。
        let board = LaneBoard(target: lanes)
        // 通道列表要等 session 建好才有，这里先留一个可回填的盒子。
        let channelsBox = ChannelsBox()

        let accumulator = ProgressAccumulator(total: total, handler: progress) {
            let active = Set(board.liveLanes().map { $0.routeName })
            return board.snapshot(routes: channelsBox.value.map {
                RouteStats(name: $0.name,
                           speedBytesPerSecond: $0.measuredSpeed,
                           isActive: active.contains($0.name))
            })
        }

        // 关键：Cloudflare 这类 CDN 会协商 HTTP/2，所有请求被多路复用到同一条 TCP 连接上，
        // 长链路下单连接带宽就是天花板，开再多"连接"也没用。
        // 每个 URLSession 有独立的连接池，拆成多个会话才能真正拿到多条并行连接。
        let sessionCount = min(4, max(1, lanes / 8))
        let perSessionLimit = max(1, lanes / sessionCount)
        var sessions: [URLSession] = []
        for _ in 0..<sessionCount {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            config.httpMaximumConnectionsPerHost = perSessionLimit
            sessions.append(URLSession(configuration: config))
        }
        setSessions(sessions)
        defer {
            sessions.forEach { $0.invalidateAndCancel() }
            setSessions([])
        }

        let direct = urls[0]
        let channels: [RouteChannel] = plan.enumerated().map { index, scored in
            let primary = urls[min(index, urls.count - 1)]
            // 镜像挂掉/被限流时自动退回直连
            let endpoints = primary == direct ? [primary] : [primary, direct]
            return RouteChannel(session: sessions[index % sessions.count],
                                urls: endpoints,
                                speedHint: max(scored.speed, 1),
                                name: scored.route.name)
        }
        channelsBox.set(channels)

        // 每条通道分到的并发额度（单通道配额）：通道数少就给得多，
        // 免得 4 条镜像时每条只剩 4 个并发、根本压不满带宽。
        let perChannelQuota = max(1, lanes / max(channels.count, 1))
        // 车道编号只增不减：worker 收工后编号不复用，
        // 这样诊断面板上「车道 #7 干了什么」不会因为复用而张冠李戴。
        let laneCounter = Counter()

        let fm = FileManager.default
        try? fm.removeItem(at: outURL)
        guard fm.createFile(atPath: outURL.path, contents: nil) else { throw DownloadError.badResponse }
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(total))

        let pool = SlicePool(total: total)
        let sink = WriteSink(handle: handle)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            var roundRobin = 0

            // 渐进建连：不再一上来就把 lanes 顶满。
            // 起步瞬间几百个请求同时砸过去，Azure/Cloudflare 会直接回 503 ServerBusy，
            // 一旦被限流就得指数退避，整段下载反而更慢。
            // 改成每 connectionRampInterval 秒放一档，跑到目标并发后再全速调度。
            var allowedLanes = min(Self.rampStep, lanes)
            var lastRampAt = Date()

            while true {
                // 取消后立刻退出调度循环，不再派新活儿
                if isCancelled || inflight.isCancelling { break }

                // 0) 建连爬坡：到点就放开一档并发
                let now = Date()
                if allowedLanes < lanes,
                   now.timeIntervalSince(lastRampAt) >= Self.connectionRampInterval {
                    allowedLanes = min(allowedLanes + Self.rampStep, lanes)
                    lastRampAt = now
                }

                // 1) 把并发顶到「当前允许值」；通道被限流时按配额收缩
                var assigned = false
                while active < allowedLanes {
                    // 此刻实际可用的并发额度：被限流的通道要临时降额，
                    // 免得在同一根已经饱和的线路上继续加压、越限越死。
                    let quota = channels.reduce(0) { partial, channel in
                        if channel.throttled || board.penalty(of: channel.name) > 0 {
                            return partial + max(1, perChannelQuota / 2)
                        }
                        return partial + perChannelQuota
                    }
                    if active >= quota { break }

                    guard let work = nextWork(pool: pool, live: active, lanes: lanes, total: total) else { break }
                    let channelIndex = pickChannel(channels, roundRobin: roundRobin)
                    let channel = channels[channelIndex]
                    roundRobin = (roundRobin + 1) % channels.count

                    let laneId = laneCounter.next()
                    board.bumpTotalSlice()
                    // 先登记一条 pending，让面板立刻能看到「这条车道已就位」
                    board.update(LaneSnapshot(laneId: laneId,
                                              routeName: channel.name,
                                              url: channel.current.absoluteString,
                                              start: work.start,
                                              end: work.end,
                                              downloaded: 0,
                                              speedBytesPerSecond: 0,
                                              state: .pending,
                                              attempt: 1,
                                              lastStatus: nil))

                    active += 1
                    assigned = true
                    group.addTask { [self] in
                        await runSlice(laneId: laneId,
                                       channel: channel,
                                       initial: work,
                                       pool: pool,
                                       lanes: lanes,
                                       total: total,
                                       sink: sink,
                                       accumulator: accumulator,
                                       board: board)
                        board.remove(laneId)
                    }
                }

                if active == 0 { break }

                // 2) 收一个完成的任务，腾出并发名额
                _ = try await group.next()
                active -= 1

                // 3) 没活儿可派：等一小会儿再评估，别忙等烧 CPU
                if !assigned {
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
            // 取消时把还在跑的子任务一起掐掉，别让它们继续占用连接
            if isCancelled || inflight.isCancelling { group.cancelAll() }
        }

        if isCancelled { throw DownloadError.cancelled }
        if sink.failed { throw DownloadError.incomplete }

        let size = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int64) ?? 0
        guard size == total else {
            try? fm.removeItem(at: outURL)
            throw DownloadError.incomplete
        }
        await accumulator.finish(downloaded: total)
        return outURL
    }

    // MARK: - 一个 worker 的生命周期

    /// 攥着一段区间，一小片一小片地取数据；取完就要新活儿，绝不空转。
    private func runSlice(laneId: Int,
                          channel: RouteChannel,
                          initial: Chunk,
                          pool: SlicePool,
                          lanes: Int,
                          total: Int64,
                          sink: WriteSink,
                          accumulator: ProgressAccumulator,
                          board: LaneBoard) async {
        var current = initial

        while !isCancelled {
            // 被取消就立刻收工，不再取新数据
            if Task.isCancelled { return }

            let remaining = max(total - pool.downloaded(), 0)
            let want = min(sliceTarget(lanes: lanes, total: total, remaining: remaining),
                           Int(current.length))
            let from = current.start
            let to = from + Int64(want) - 1

            if Int64(want) < current.length {
                // 手里这段太长：只取前一小片，剩下的还回去让别的连接分
                pool.putBack(Chunk(start: to + 1, end: current.end))
                board.bumpSplit()
            }

            // 派活前先更新看板：面板能立刻看到这条车道换到了哪一段
            board.update(LaneSnapshot(laneId: laneId,
                                      routeName: channel.name,
                                      url: channel.current.absoluteString,
                                      start: from,
                                      end: to,
                                      downloaded: 0,
                                      speedBytesPerSecond: channel.measuredSpeed,
                                      state: .downloading,
                                      attempt: 1,
                                      lastStatus: 206))
            board.activeUrl = channel.current.absoluteString

            do {
                let outcome = try await fetchSlice(chunk: Chunk(start: from, end: to),
                                                   pool: pool,
                                                   board: board,
                                                   laneId: laneId,
                                                   channel: channel)
                if !outcome.data.isEmpty {
                    sink.write(outcome.data, at: from)
                    pool.recordDone(Int64(outcome.data.count))
                    await accumulator.advance(Int64(outcome.data.count))
                    channel.observe(elapsed: outcome.elapsed, bytes: Int64(outcome.data.count))
                    board.bumpDoneSlice()
                    board.reward(channel.name)

                    let seconds = max(outcome.elapsed, 0.001)
                    board.update(LaneSnapshot(laneId: laneId,
                                              routeName: channel.name,
                                              url: channel.current.absoluteString,
                                              start: from,
                                              end: to,
                                              downloaded: Int64(outcome.data.count),
                                              speedBytesPerSecond: Double(outcome.data.count) / seconds,
                                              state: .done,
                                              attempt: 1,
                                              lastStatus: 206))
                }
                if outcome.data.count < want {
                    // 没取满（连接中途断了）：把缺的那一段还回池子重取，绝不丢数据
                    let missing = Chunk(start: from + Int64(outcome.data.count), end: to)
                    if missing.length > 0 { pool.putBack(missing) }
                }
            } catch {
                if isCancelled || Task.isCancelled { return }
                if (error as? DownloadError) == .cancelled { return }

                // 这一片彻底失败（重试耗尽）：在面板上标红
                board.update(LaneSnapshot(laneId: laneId,
                                          routeName: channel.name,
                                          url: channel.current.absoluteString,
                                          start: from,
                                          end: to,
                                          downloaded: 0,
                                          speedBytesPerSecond: 0,
                                          state: .failed,
                                          attempt: Self.maxAttempts,
                                          lastStatus: { if case let .throttled(code, _) = (error as? DownloadError) { return code }; return nil }()))
                // 失败的那一段必须还回池子，否则文件会缺一块
                pool.putBack(Chunk(start: from, end: current.end))

                sink.markFailed()
                return
            }

            if to >= current.end {
                // 手里这段干完了，再要一段；要不到就收工
                guard let next = nextWork(pool: pool, live: 0, lanes: lanes, total: total) else { return }
                current = next
            } else {
                current = Chunk(start: to + 1, end: current.end)
            }
        }
    }

    /// 分配下一段活儿：优先拿现成的；拿不到而连接还闲着，就从末尾切一刀。
    private func nextWork(pool: SlicePool, live: Int, lanes: Int, total: Int64) -> Chunk? {
        if let ready = pool.take() { return ready }
        guard live < lanes else { return nil }
        let remaining = max(total - pool.downloaded(), 0)
        return pool.splitTail(live: live, target: sliceTarget(lanes: lanes, total: total, remaining: remaining))
    }

    /// 一个区间一次取多少：剩余数据越多取越大（少发请求），
    /// 越接近尾声取越小（让所有连接都能分到收尾的活儿）。
    private func sliceTarget(lanes: Int, total: Int64, remaining: Int64) -> Int {
        let share = (max(remaining, 0) / Int64(lanes * 4)) * 2
        return Int(min(max(share, Self.minSliceTarget), Self.maxSliceTarget))
    }

    /// 按实时吞吐挑通道：快的多干活
    private func pickChannel(_ channels: [RouteChannel], roundRobin: Int) -> Int {
        guard channels.count > 1 else { return 0 }
        var best = roundRobin % channels.count
        var bestSpeed = -1.0
        for offset in channels.indices {
            let index = (roundRobin + offset) % channels.count
            let speed = channels[index].measuredSpeed
            if speed > bestSpeed {
                bestSpeed = speed
                best = index
            }
        }
        return best
    }

    // MARK: - 取一小片

    /// 真正发起 Range 请求，把这一小片读进内存。
    ///
    /// 失败时按指数退避重试；命中 429/503 时读 `Retry-After` 退避 ——
    /// Azure 单 Blob 有「约 60 MiB/s 或 500 请求/秒」的目标，超了就是 503 ServerBusy，
    /// 官方建议用指数退避而不是硬顶，否则会被越限越死。
    private func fetchSlice(chunk: Chunk,
                            pool: SlicePool,
                            board: LaneBoard,
                            laneId: Int,
                            channel: RouteChannel) async throws -> SliceOutcome {
        var lastError: Error = DownloadError.badResponse

        for attempt in 0..<Self.maxAttempts {
            // 每轮重试前先看有没有被取消
            try Task.checkCancellation()
            if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }

            var request = URLRequest(url: channel.current)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let startedAt = Date()
            do {
                let (data, response) = try await send(request, on: channel.session)
                guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }

                switch http.statusCode {
                case 200, 206:
                    channel.setThrottled(false)
                    guard !data.isEmpty else { throw DownloadError.incomplete }
                    return SliceOutcome(data: data, elapsed: Date().timeIntervalSince(startedAt))
                case 429, 503:
                    pool.recordThrottle()
                    board.bumpThrottle()
                    // 通道级降额：不是简单降权重，而是直接把它判为「被限流」，
                    // 调度器下一轮就会削它的并发，避免越限越死。
                    channel.setThrottled(true)
                    board.penalize(channel.name)
                    throw DownloadError.throttled(code: http.statusCode,
                                                  retryAfter: Self.retryAfter(http))
                default:
                    throw DownloadError.badResponse
                }
            } catch {
                // 取消优先级最高：无论是标志位还是 Task 取消，都直接向外抛
                if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }
                if error is CancellationError { throw error }
                if (error as? DownloadError) == .cancelled { throw DownloadError.cancelled }
                if (error as NSError).code == NSURLErrorCancelled { throw DownloadError.cancelled }

                lastError = error
                board.bumpRetry()
                if attempt >= Self.maxAttempts - 1 { break }

                if case .throttled(_, _) = (error as? DownloadError) {
                    // 被限流：把这条通道的权重降下来，让活儿分给别人
                    channel.demote()
                }
                if attempt >= 1 { channel.rotate() }

                // 重试状态同步到面板：用户能看到「车道 #3 正在第 2 次重试 / 上一次 503」
                board.update(LaneSnapshot(laneId: laneId,
                                          routeName: channel.name,
                                          url: channel.current.absoluteString,
                                          start: chunk.start,
                                          end: chunk.end,
                                          downloaded: 0,
                                          speedBytesPerSecond: 0,
                                          state: .retrying,
                                          attempt: attempt + 2,
                                          lastStatus: { if case let .throttled(code, _) = (error as? DownloadError) { return code }; return nil }()))

                // 退避期间也要能被取消打断
                try await Task.sleep(for: .milliseconds(Self.backoffMillis(attempt: attempt, error: error)))
            }
        }

        pool.recordFailure()
        throw lastError
    }

    // MARK: - 单连接下载（不支持分段 / 探测不到体积时）

    /// 单连接下载。会顺手看响应头：只要拿到 206，就说明服务端支持 Range，
    /// 立刻放弃单连接、改用多线程分段引擎重下 ——
    /// 很多「日志包只能单线程」其实是误判。
    private func downloadSingle(url: URL,
                                into outURL: URL,
                                lanes: Int,
                                progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (url: URL, bytes: Int64, lanes: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        lock.lock(); sessions.append(session); lock.unlock()
        defer {
            lock.lock(); sessions.removeAll { $0 === session }; lock.unlock()
            session.invalidateAndCancel()
        }

        // 先带 Range 试一小段：能拿到 206 就说明可以分段
        var probeRequest = URLRequest(url: url)
        probeRequest.cachePolicy = .reloadIgnoringLocalCacheData
        probeRequest.setValue("bytes=0-\(Self.singleProbeBytes - 1)", forHTTPHeaderField: "Range")
        probeRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        if let (_, probeResponse) = try? await send(probeRequest, on: session),
           let http = probeResponse as? HTTPURLResponse, http.statusCode == 206,
           let total = try await probeSize(urls: [url])?.total, total >= Self.minChunkedTotal {
            if isCancelled { throw DownloadError.cancelled }
            let upgradeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ab-up-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: upgradeDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: upgradeDir) }

            let fileURL = try await segmentDownload(urls: [url],
                                                    total: total,
                                                    outURL: outURL,
                                                    lanes: lanes,
                                                    plan: [ScoredRoute(route: .direct, speed: 1)],
                                                    progress: progress)
            return (fileURL, total, lanes)
        }

        if isCancelled { throw DownloadError.cancelled }
        let (tempURL, response) = try await session.download(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.badResponse
        }
        let fm = FileManager.default
        try? fm.removeItem(at: outURL)
        try fm.moveItem(at: tempURL, to: outURL)
        let size = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int64) ?? 0
        return (outURL, size, 1)
    }

    // MARK: - 探测

    private struct Probe {
        let total: Int64
        let chunked: Bool
    }

    /// 探测文件大小：优先用 `Range: bytes=0-0`（返回 206 + Content-Range 才确认支持分段），
    /// 失败再退回 HEAD。逐条通道尝试，任何一条成功即可。
    private func probeSize(urls: [URL]) async throws -> Probe? {
        var headFallback: Int64?
        for url in urls {
            guard let probe = await probeSize(url: url) else { continue }
            if probe.chunked, probe.total > 0 { return probe }
            if headFallback == nil, probe.total > 0 { headFallback = probe.total }
        }
        return headFallback.map { Probe(total: $0, chunked: false) }
    }

    private func probeSize(url: URL) async -> Probe? {
        if isCancelled { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var range = URLRequest(url: url)
        range.cachePolicy = .reloadIgnoringLocalCacheData
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        range.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await session.data(for: range),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let last = contentRange.split(separator: "/").last,
               let total = Int64(last.trimmingCharacters(in: .whitespaces)), total > 0 {
                return Probe(total: total, chunked: true)
            }
            // 返回 200 说明服务器忽略了 Range，不能分段
            if http.statusCode == 200 {
                let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
                return Probe(total: length, chunked: false)
            }
        }

        if isCancelled { return nil }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalCacheData
        head.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let len = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(len), total > 0 {
            return Probe(total: total, chunked: false)
        }
        return nil
    }

    // MARK: - 常量

    private static let minSliceTarget: Int64 = 128 * 1024
    private static let maxSliceTarget: Int64 = 4 * 1024 * 1024
    /// 小于这个体积不做分段：切来切去不如一条连接拉完
    private static let minChunkedTotal: Int64 = 4 * 1024 * 1024
    private static let singleProbeBytes: Int64 = 64 * 1024
    private static let maxAttempts = 3
    private static let userAgent = "ArtifactBoost"

    /// 渐进建连：每档放开多少条并发
    private static let rampStep = 8
    /// 渐进建连：每档之间间隔多久
    private static let connectionRampInterval: TimeInterval = 0.25

    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds >= 0, seconds <= 600 else { return nil }
        return seconds
    }

    /// 指数退避 + 抖动；限流时优先听服务端的 Retry-After
    private static func backoffMillis(attempt: Int, error: Error) -> Int {
        if case .throttled(_, let retryAfter) = (error as? DownloadError) {
            // 防雪崩：多个 worker 同时被限流时把退避时间错开
            let base = retryAfter ?? Double(1 << min(attempt, 4))
            return Int(min(max(base * (1 + Double.random(in: 0...0.25)), 0.25), 30) * 1000)
        }
        let base = Double(1 << min(attempt, 5)) * 250
        return Int(min(base * (1 + Double.random(in: 0...0.3)), 15_000))
    }
}

/// 落盘汇点：多个 worker 并发写同一个文件的不同偏移，用一把锁保护
private final class WriteSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private(set) var failed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data, at offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            failed = true
        }
    }

    func markFailed() {
        lock.lock(); failed = true; lock.unlock()
    }
}

/// 取消标志：URLSession 回调可能来自任意线程
private final class CancelledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}

/// 单调递增计数器（车道编号专用）。用锁而不是 `&+` 自增，
/// 免得并发调度时两条车道拿到同一个号。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// 在飞请求登记簿。
///
/// `URLSession.data(for:)` 挂起时协程取消并不会让它自动返回 ——
/// 必须拿到对应的 `URLSessionDataTask` 调 `cancel()`。
/// 取消时把登记簿里所有 task 一起 cancel，所有 worker 才会「同时」退出，
/// 而不是各自等读到超时（60s）才反应。
private final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var cancelling = false

    var isCancelling: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelling
    }

    func register(_ task: URLSessionDataTask) {
        lock.lock()
        if cancelling {
            lock.unlock()
            task.cancel()
            return
        }
        tasks[ObjectIdentifier(task)] = task
        lock.unlock()
    }

    func release(_ task: URLSessionDataTask) {
        lock.lock()
        tasks.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    /// 逐个 cancel 所有在飞 task，并让之后注册的 task 一进来就被取消
    func cancelAll() {
        lock.lock()
        cancelling = true
        let live = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    func reset() {
        lock.lock()
        cancelling = false
        tasks.removeAll()
        lock.unlock()
    }
}

/// 把 `session.dataTask` 创建的 task 从 continuation 闭包传到取消处理器手里。
/// 取消处理器可能在任何线程、任何时刻被调用，所以要有锁。
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLSessionDataTask?

    var task: URLSessionDataTask? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
