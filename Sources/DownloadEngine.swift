import Foundation

struct DownloadProgress: Equatable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double = 0
    var speedBytesPerSecond: Double = 0
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
    private var lastEmit = Date.distantPast
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var zeroStreak = 0

    init(total: Int64, handler: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.handler = handler
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
            speedBytesPerSecond: max(smoothedSpeed, 0)
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

/// 一个通道：独立 URLSession（独立连接池）+ 地址列表 + 实时吞吐
private final class RouteChannel: @unchecked Sendable {
    let session: URLSession
    private let lock = NSLock()
    private var urls: [URL]
    private var speed: Double

    init(session: URLSession, urls: [URL], speedHint: Double) {
        self.session = session
        self.urls = urls
        self.speed = max(speedHint, 1)
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

    func cancel() {
        cancelledFlag.set()
        lock.lock()
        let current = sessions
        lock.unlock()
        current.forEach { $0.invalidateAndCancel() }
    }

    private var isCancelled: Bool { cancelledFlag.value }

    private func setSessions(_ newValue: [URLSession]) {
        lock.lock()
        sessions = newValue
        lock.unlock()
    }

    /// 多通道并行下载。
    ///
    /// - Parameters:
    ///   - routes: 已按实测速度排序的通道，第一条同时作为其它通道失败时的兜底
    ///   - allowChunking: 目标是否可能支持分段；为 false 时先走单连接，
    ///     但读到 206 之后依旧会自动升级为分段下载
    func download(signedURL: URL,
                  routes: [ScoredRoute],
                  fileName: String,
                  connections: Int,
                  allowChunking: Bool = true,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        cancelledFlag.reset()
        let startedAt = Date()
        let plan = routes.isEmpty ? [ScoredRoute(route: .direct, speed: 1)] : routes
        let urls = plan.map { $0.route.apply(to: signedURL) }
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
        let accumulator = ProgressAccumulator(total: total, handler: progress)

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
                                speedHint: max(scored.speed, 1))
        }

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

            while true {
                // 1) 把并发顶到 lanes
                var assigned = false
                while active < lanes {
                    guard let work = nextWork(pool: pool, live: active, lanes: lanes, total: total) else { break }
                    let channel = channels[pickChannel(channels, roundRobin: roundRobin)]
                    roundRobin = (roundRobin + 1) % channels.count
                    active += 1
                    assigned = true
                    group.addTask { [self] in
                        await runSlice(channel: channel,
                                       initial: work,
                                       pool: pool,
                                       lanes: lanes,
                                       total: total,
                                       sink: sink,
                                       accumulator: accumulator)
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
    private func runSlice(channel: RouteChannel,
                          initial: Chunk,
                          pool: SlicePool,
                          lanes: Int,
                          total: Int64,
                          sink: WriteSink,
                          accumulator: ProgressAccumulator) async {
        var current = initial

        while !isCancelled {
            let remaining = max(total - pool.downloaded(), 0)
            let want = min(sliceTarget(lanes: lanes, total: total, remaining: remaining),
                           Int(current.length))
            let from = current.start
            let to = from + Int64(want) - 1

            if Int64(want) < current.length {
                // 手里这段太长：只取前一小片，剩下的还回去让别的连接分
                pool.putBack(Chunk(start: to + 1, end: current.end))
            }

            do {
                let outcome = try await fetchSlice(channel: channel,
                                                   chunk: Chunk(start: from, end: to),
                                                   pool: pool)
                if !outcome.data.isEmpty {
                    sink.write(outcome.data, at: from)
                    pool.recordDone(Int64(outcome.data.count))
                    await accumulator.advance(Int64(outcome.data.count))
                    channel.observe(elapsed: outcome.elapsed, bytes: Int64(outcome.data.count))
                }
                if outcome.data.count < want {
                    // 没取满（连接中途断了）：把缺的那一段还回池子重取，绝不丢数据
                    let missing = Chunk(start: from + Int64(outcome.data.count), end: to)
                    if missing.length > 0 { pool.putBack(missing) }
                }
            } catch {
                if isCancelled { return }
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
    private func fetchSlice(channel: RouteChannel,
                            chunk: Chunk,
                            pool: SlicePool) async throws -> SliceOutcome {
        var lastError: Error = DownloadError.badResponse

        for attempt in 0..<Self.maxAttempts {
            if isCancelled { throw DownloadError.cancelled }

            var request = URLRequest(url: channel.current)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let startedAt = Date()
            do {
                let (data, response) = try await channel.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }

                switch http.statusCode {
                case 200, 206:
                    guard !data.isEmpty else { throw DownloadError.incomplete }
                    return SliceOutcome(data: data, elapsed: Date().timeIntervalSince(startedAt))
                case 429, 503:
                    pool.recordThrottle()
                    throw DownloadError.throttled(code: http.statusCode,
                                                  retryAfter: Self.retryAfter(http))
                default:
                    throw DownloadError.badResponse
                }
            } catch {
                if isCancelled { throw DownloadError.cancelled }
                if (error as? DownloadError) == .cancelled { throw DownloadError.cancelled }
                lastError = error
                if attempt >= Self.maxAttempts - 1 { break }

                if case .throttled(_, _) = (error as? DownloadError) {
                    // 被限流：把这条通道的权重降下来，让活儿分给别人
                    channel.demote()
                }
                if attempt >= 1 { channel.rotate() }
                try? await Task.sleep(for: .milliseconds(Self.backoffMillis(attempt: attempt, error: error)))
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

        if let (_, probeResponse) = try? await session.data(for: probeRequest),
           let http = probeResponse as? HTTPURLResponse, http.statusCode == 206,
           let total = try await probeSize(urls: [url])?.total, total >= Self.minChunkedTotal {
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
