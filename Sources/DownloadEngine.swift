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

    var errorDescription: String? {
        switch self {
        case .badResponse: return "下载失败：服务器响应异常"
        case .cancelled: return "下载已取消"
        case .incomplete: return "下载失败：数据校验不通过（可能断流），请重试"
        }
    }
}

struct DownloadResult {
    let fileURL: URL
    let averageSpeed: Double
}

private struct Chunk {
    let index: Int
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }
}

/// 汇总各分块进度，节流后回调给 UI
private actor ProgressAccumulator {
    private var chunkBytes: [Int: Int64] = [:]
    private let total: Int64
    private let handler: @Sendable (DownloadProgress) -> Void
    private var lastEmit = Date.distantPast
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0

    init(total: Int64, handler: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.handler = handler
    }

    /// 速度用滑动平均，避免瞬时抖动导致数字乱跳
    private func snapshot(downloaded: Int64) -> DownloadProgress {
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt > 0.05 {
            let instant = Double(downloaded - lastSampleBytes) / dt
            smoothedSpeed = smoothedSpeed <= 0 ? instant : smoothedSpeed * 0.6 + instant * 0.4
            lastSampleTime = now
            lastSampleBytes = downloaded
        }
        return DownloadProgress(
            downloadedBytes: downloaded,
            totalBytes: total,
            fraction: total > 0 ? min(Double(downloaded) / Double(total), 1) : 0,
            speedBytesPerSecond: max(smoothedSpeed, 0)
        )
    }

    func update(chunk: Int, bytes: Int64) {
        chunkBytes[chunk] = bytes
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        lastEmit = now
        handler(snapshot(downloaded: chunkBytes.values.reduce(0, +)))
    }

    func finish(downloaded: Int64) {
        var progress = snapshot(downloaded: downloaded)
        progress.totalBytes = max(total, downloaded)
        progress.downloadedBytes = progress.totalBytes
        progress.fraction = 1
        handler(progress)
    }
}

/// 接收每个分块任务的进度回调与完成事件
private final class ChunkDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var chunkForTask: [Int: Int] = [:]
    private var expectedLengths: [Int: Int64] = [:]
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var partURLs: [Int: URL] = [:]
    private var taskErrors: [Int: Error] = [:]
    private let accumulator: ProgressAccumulator
    private let tempDir: URL

    init(accumulator: ProgressAccumulator, tempDir: URL) {
        self.accumulator = accumulator
        self.tempDir = tempDir
    }

    func register(task: URLSessionDownloadTask, chunk: Chunk, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        chunkForTask[task.taskIdentifier] = chunk.index
        expectedLengths[chunk.index] = chunk.length
        continuations[task.taskIdentifier] = continuation
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let chunk = chunkForTask[downloadTask.taskIdentifier]
        lock.unlock()
        guard let chunk else { return }
        Task { await accumulator.update(chunk: chunk, bytes: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let chunk = chunkForTask[downloadTask.taskIdentifier] else { return }
        let dest = tempDir.appendingPathComponent("part-\(chunk)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            partURLs[downloadTask.taskIdentifier] = dest
        } catch {
            taskErrors[downloadTask.taskIdentifier] = error
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let id = task.taskIdentifier
        guard let continuation = continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let part = partURLs.removeValue(forKey: id)
        let storedError = taskErrors.removeValue(forKey: id)
        let chunkIndex = chunkForTask.removeValue(forKey: id)
        let expected = chunkIndex.flatMap { expectedLengths.removeValue(forKey: $0) }
        let response = task.response as? HTTPURLResponse
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
            return
        }
        if let storedError {
            continuation.resume(throwing: storedError)
            return
        }
        guard let response, response.statusCode == 200 || response.statusCode == 206 else {
            continuation.resume(throwing: DownloadError.badResponse)
            return
        }
        guard let part, let expected else {
            continuation.resume(throwing: DownloadError.badResponse)
            return
        }
        // 关键校验：服务器忽略 Range（返回 200 全量）或连接被截断时，
        // 分块体积会对不上，必须在这里拦下来，否则会合并出一个损坏的压缩包
        let actual = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0
        guard actual == expected else {
            try? FileManager.default.removeItem(at: part)
            continuation.resume(throwing: DownloadError.incomplete)
            return
        }
        continuation.resume(returning: part)
    }
}

/// 多线程分段下载引擎：
/// 先用 Range 探测文件大小并确认服务器支持分段，然后切成 N 段并发下载，最后按序合并。
/// 产物实际托管在 Azure Blob Storage，支持 Range 请求；
/// 单连接被限速时，多并发能显著提升总速度。
final class DownloadEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [URLSession] = []

    func cancel() {
        lock.lock()
        let current = sessions
        lock.unlock()
        current.forEach { $0.invalidateAndCancel() }
    }

    private func setSessions(_ newValue: [URLSession]) {
        lock.lock()
        sessions = newValue
        lock.unlock()
    }

    /// 多通道并行：把分块按实测速度分配给多条通道同时下载，带宽可以叠加；
    /// routes 需按速度从快到慢排列，第一条同时作为其它通道失败时的兜底
    func download(signedURL: URL,
                  routes: [ScoredRoute],
                  fileName: String,
                  connections: Int,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
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

        let total = try await probeSize(urls: urls)
        let accumulator = ProgressAccumulator(total: total ?? 0, handler: progress)

        // 服务器不支持分块（或探测不到体积）时，退化为单连接下载
        guard let total, total > 0 else {
            let (tmp, resp) = try await URLSession.shared.download(from: urls[0])
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.badResponse
            }
            try? fm.removeItem(at: outURL)
            try fm.moveItem(at: tmp, to: outURL)
            let size = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int64) ?? 0
            await accumulator.finish(downloaded: size)
            return DownloadResult(fileURL: outURL, averageSpeed: Self.speed(bytes: size, since: startedAt))
        }

        // 关键：Cloudflare 这类 CDN 会协商 HTTP/2，所有请求会被多路复用到同一条 TCP 连接上，
        // 长链路下单连接带宽就是天花板，开再多"连接"也没用。
        // 每个 URLSession 有独立的连接池，拆成多个会话才能真正拿到多条并行连接。
        let sessionCount = min(4, max(1, connections / 8))
        let perSessionLimit = max(1, connections / sessionCount)
        var sessions: [URLSession] = []
        var delegates: [ChunkDelegate] = []
        for _ in 0..<sessionCount {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 3600
            config.httpMaximumConnectionsPerHost = perSessionLimit
            let delegate = ChunkDelegate(accumulator: accumulator, tempDir: tempDir)
            sessions.append(URLSession(configuration: config, delegate: delegate, delegateQueue: nil))
            delegates.append(delegate)
        }
        setSessions(sessions)
        defer {
            sessions.forEach { $0.invalidateAndCancel() }
            setSessions([])
        }

        let chunks = makeChunks(total: total, connections: connections)
        let assignment = Self.assign(chunks: chunks, speeds: plan.map(\.speed))
        let fallbackURL = urls[0]
        var parts: [(Int, URL)] = []
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, chunk) in chunks.enumerated() {
                let url = urls[min(assignment[index], urls.count - 1)]
                let slot = index % sessions.count
                let session = sessions[slot]
                let delegate = delegates[slot]
                group.addTask {
                    try await self.downloadChunk(url: url,
                                                 fallbackURL: url == fallbackURL ? nil : fallbackURL,
                                                 chunk: chunk,
                                                 session: session,
                                                 delegate: delegate)
                }
            }
            for try await part in group {
                parts.append(part)
            }
        }

        try merge(parts: parts, into: outURL, total: total)
        await accumulator.finish(downloaded: total)
        return DownloadResult(fileURL: outURL, averageSpeed: Self.speed(bytes: total, since: startedAt))
    }

    private static func speed(bytes: Int64, since start: Date) -> Double {
        Double(bytes) / max(Date().timeIntervalSince(start), 0.05)
    }

    /// 按分块顺序合并，并校验最终体积，任何异常都会删掉半成品
    private func merge(parts: [(Int, URL)], into outURL: URL, total: Int64) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: outURL)
        guard fm.createFile(atPath: outURL.path, contents: nil) else { throw DownloadError.badResponse }
        let out = try FileHandle(forWritingTo: outURL)
        do {
            for (_, partURL) in parts.sorted(by: { $0.0 < $1.0 }) {
                let input = try FileHandle(forReadingFrom: partURL)
                while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
                    try out.write(contentsOf: data)
                }
                try? input.close()
            }
        } catch {
            try? out.close()
            try? fm.removeItem(at: outURL)
            throw error
        }
        try? out.close()

        let written = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int64) ?? 0
        guard written == total else {
            try? fm.removeItem(at: outURL)
            throw DownloadError.incomplete
        }
    }

    /// 按实测速度分配分块：谁快谁多分，避免慢通道拖住整体进度
    private static func assign(chunks: [Chunk], speeds: [Double]) -> [Int] {
        guard speeds.count > 1 else { return Array(repeating: 0, count: chunks.count) }
        var load = [Double](repeating: 0, count: speeds.count)
        var assignment: [Int] = []
        assignment.reserveCapacity(chunks.count)
        for chunk in chunks {
            var target = 0
            var bestScore = Double.greatestFiniteMagnitude
            for index in speeds.indices {
                let score = load[index] / max(speeds[index], 0.01)
                if score < bestScore {
                    bestScore = score
                    target = index
                }
            }
            load[target] += Double(chunk.length)
            assignment.append(target)
        }
        return assignment
    }

    private func downloadChunk(url: URL,
                               fallbackURL: URL?,
                               chunk: Chunk,
                               session: URLSession,
                               delegate: ChunkDelegate) async throws -> (Int, URL) {
        do {
            return try await attemptChunk(url: url, chunk: chunk, session: session, delegate: delegate)
        } catch {
            if Self.isCancellation(error) { throw DownloadError.cancelled }
            // 该通道彻底失败（镜像挂了/被限流），换主通道再试一次
            guard let fallbackURL else { throw error }
            return try await attemptChunk(url: fallbackURL, chunk: chunk, session: session, delegate: delegate)
        }
    }

    private func attemptChunk(url: URL,
                              chunk: Chunk,
                              session: URLSession,
                              delegate: ChunkDelegate) async throws -> (Int, URL) {
        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<3 {
            do {
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
                let partURL: URL = try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(with: req)
                    delegate.register(task: task, chunk: chunk, continuation: continuation)
                    task.resume()
                }
                return (chunk.index, partURL)
            } catch {
                if Self.isCancellation(error) { throw DownloadError.cancelled }
                lastError = error
                if attempt < 2 {
                    if Task.isCancelled { throw DownloadError.cancelled }
                    try? await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    /// 分块数取连接数的 4 倍：多出来的分块由 URLSession 内部排队，
    /// 哪条连接先空出来就接下一条，既避免"最慢的那块"拖住整体，也更容易吃满带宽。
    /// 注意分块下限不能太大，否则小产物根本拆不出几段（这正是当初"开了加速还是几百 KB"的原因）。
    private func makeChunks(total: Int64, connections: Int) -> [Chunk] {
        let minChunk: Int64 = 256 * 1024
        let maxChunks = Int64(max(1, min(connections, 64))) * 4
        let count = min(maxChunks, max(1, total / minChunk))
        let size = (total + count - 1) / count
        var chunks: [Chunk] = []
        var start: Int64 = 0
        while start < total {
            let end = min(start + size - 1, total - 1)
            chunks.append(Chunk(index: chunks.count, start: start, end: end))
            start = end + 1
        }
        return chunks
    }

    /// 探测文件大小：优先用 `Range: bytes=0-0`（返回 206 才能确认服务器支持分段下载），
    /// 失败再退回 HEAD。返回 nil 表示不能分段，调用方会退化为单连接下载。
    /// 逐条通道尝试，任何一条成功即可。
    private func probeSize(urls: [URL]) async throws -> Int64? {
        for url in urls {
            if let total = try await probeSize(url: url), total > 0 {
                return total
            }
        }
        return nil
    }

    private func probeSize(url: URL) async throws -> Int64? {
        var range = URLRequest(url: url)
        range.cachePolicy = .reloadIgnoringLocalCacheData
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, resp) = try? await URLSession.shared.data(for: range),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let last = contentRange.split(separator: "/").last,
               let total = Int64(last.trimmingCharacters(in: .whitespaces)), total > 0 {
                return total
            }
            // 返回 200 说明服务器忽略了 Range，不能分段
            if http.statusCode == 200 { return nil }
        }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalCacheData
        if let (_, resp) = try? await URLSession.shared.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let len = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(len), total > 0 {
            return total
        }
        return nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }
}