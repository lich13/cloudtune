import Darwin
import Foundation

public struct StreamSourceRegistration: Sendable {
    public let token: String
    public let accountHash: String
    public let trackId: String
    public var remoteURL: URL
    public let cacheDestinationURL: URL
    public let expectedSize: UInt64
    public let fileName: String
    public let cacheLimitBytes: UInt64

    public init(
        token: String = UUID().uuidString.lowercased(),
        accountHash: String,
        trackId: String,
        remoteURL: URL,
        cacheDestinationURL: URL,
        expectedSize: UInt64,
        fileName: String,
        cacheLimitBytes: UInt64
    ) {
        self.token = token
        self.accountHash = accountHash
        self.trackId = trackId
        self.remoteURL = remoteURL
        self.cacheDestinationURL = cacheDestinationURL
        self.expectedSize = expectedSize
        self.fileName = fileName
        self.cacheLimitBytes = cacheLimitBytes
    }
}

public protocol UpstreamStreamFetcher: Sendable {
    func openStream(url: URL, rangeHeader: String?) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    )
}

private final class PullByteStreamReader: @unchecked Sendable {
    private let session: URLSession
    private var iterator: URLSession.AsyncBytes.AsyncIterator
    private var finished = false
    private let chunkSize: Int

    init(session: URLSession, bytes: URLSession.AsyncBytes, chunkSize: Int = 32_768) {
        self.session = session
        self.iterator = bytes.makeAsyncIterator()
        self.chunkSize = max(1024, chunkSize)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func nextChunk() async throws -> Data? {
        guard !finished else { return nil }
        return try await withTaskCancellationHandler {
            do {
                var buffer = Data()
                buffer.reserveCapacity(chunkSize)
                while buffer.count < chunkSize {
                    try Task.checkCancellation()
                    guard let byte = try await iterator.next() else {
                        finished = true
                        session.finishTasksAndInvalidate()
                        return buffer.isEmpty ? nil : buffer
                    }
                    buffer.append(byte)
                }
                return buffer
            } catch {
                finished = true
                session.invalidateAndCancel()
                throw error
            }
        } onCancel: { [session] in
            session.invalidateAndCancel()
        }
    }
}

public struct URLSessionUpstreamStreamFetcher: UpstreamStreamFetcher {
    public init() {}

    public func openStream(url: URL, rangeHeader: String?) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        req.setValue(Cloud189Constants.userAgent, forHTTPHeaderField: "User-Agent")
        if let rangeHeader {
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            session.invalidateAndCancel()
            throw CloudTuneError.protocolError("非 HTTP 媒体流响应")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k).lowercased()] = String(describing: v)
        }
        let reader = PullByteStreamReader(session: session, bytes: bytes, chunkSize: 32_768)
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await reader.nextChunk()
        })
        return (http.statusCode, headers, stream)
    }
}

private final class ActiveStreamConnection: @unchecked Sendable {
    let id = UUID()
    let accountHash: String
    let token: String
    private let lock = NSLock()
    private var fd: Int32
    private var revoked = false
    private var streamTask: Task<Void, Never>?

    init(fd: Int32, accountHash: String, token: String) {
        self.fd = fd
        self.accountHash = accountHash
        self.token = token
    }

    var isRevoked: Bool {
        lock.withLock { revoked }
    }

    func attachTask(_ task: Task<Void, Never>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            self.streamTask = task
            return revoked
        }
        if cancelImmediately {
            task.cancel()
        }
    }

    func revokeAndShutdownSocket() {
        let (activeFD, task) = lock.withLock { () -> (Int32, Task<Void, Never>?) in
            revoked = true
            return (fd, streamTask)
        }
        if activeFD >= 0 {
            _ = Darwin.shutdown(activeFD, SHUT_RDWR)
        }
        task?.cancel()
    }

    func closeOnce() {
        let fdToClose = lock.withLock { () -> Int32 in
            let current = fd
            fd = -1
            return current
        }
        if fdToClose >= 0 {
            _ = Darwin.shutdown(fdToClose, SHUT_RDWR)
            _ = Darwin.close(fdToClose)
        }
    }
}

private final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: ActiveStreamConnection] = [:]

    func insert(_ conn: ActiveStreamConnection) {
        lock.withLock {
            entries[conn.id] = conn
        }
    }

    func remove(id: UUID) {
        _ = lock.withLock {
            entries.removeValue(forKey: id)
        }
    }

    func removeAll(matchingToken token: String) -> [ActiveStreamConnection] {
        lock.withLock {
            var matched: [ActiveStreamConnection] = []
            for (id, conn) in entries where conn.token == token {
                entries.removeValue(forKey: id)
                matched.append(conn)
            }
            return matched
        }
    }

    func removeAll(matchingAccountHash accountHash: String) -> [ActiveStreamConnection] {
        lock.withLock {
            var matched: [ActiveStreamConnection] = []
            for (id, conn) in entries where conn.accountHash == accountHash {
                entries.removeValue(forKey: id)
                matched.append(conn)
            }
            return matched
        }
    }

    func drainAll() -> [ActiveStreamConnection] {
        lock.withLock {
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
    }
}

/// Localhost (`127.0.0.1:0`) HTTP/1.1 Range streaming proxy with strict write-through & `206` resume validation.
public actor StreamProxyServer {
    public nonisolated let port: UInt16
    private nonisolated let acceptQueue: DispatchQueue
    private nonisolated let clientIOQueue: DispatchQueue
    private nonisolated let acceptSource: DispatchSourceRead
    private nonisolated let semaphore: GlobalTransferSemaphore
    private nonisolated let fetcher: UpstreamStreamFetcher
    private nonisolated let urlRefresher: (@Sendable (String) async throws -> URL)?
    private nonisolated let onAccountStreamStatusUpdate: (@Sendable (String, String, TransferStatus?) async -> Void)?
    private nonisolated let onWriteThroughCompleted: (@Sendable (String, String, URL) async -> Void)?
    private nonisolated let connectionRegistry = ConnectionRegistry()
    private var sourcesByToken: [String: StreamSourceRegistration] = [:]
    private var cacheStoresByAccount: [String: CacheStore] = [:]

    public init(
        semaphore: GlobalTransferSemaphore,
        fetcher: UpstreamStreamFetcher = URLSessionUpstreamStreamFetcher(),
        onAccountStreamStatusUpdate: (@Sendable (String, String, TransferStatus?) async -> Void)? = nil,
        onWriteThroughCompleted: (@Sendable (String, String, URL) async -> Void)? = nil,
        urlRefresher: (@Sendable (String) async throws -> URL)? = nil
    ) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CloudTuneError.storageError("无法创建本地流代理套接字")
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let listenFlags = Darwin.fcntl(fd, F_GETFL, 0)
        if listenFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, listenFlags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw CloudTuneError.storageError("无法绑定 127.0.0.1 流代理端口")
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)
        self.semaphore = semaphore
        self.fetcher = fetcher
        self.onAccountStreamStatusUpdate = onAccountStreamStatusUpdate
        self.onWriteThroughCompleted = onWriteThroughCompleted
        self.urlRefresher = urlRefresher

        let acceptQ = DispatchQueue(label: "com.gosu.cloudtune.proxy.accept.\(self.port)", qos: .userInitiated)
        let ioQ = DispatchQueue(label: "com.gosu.cloudtune.proxy.io.\(self.port)", qos: .userInitiated, attributes: .concurrent)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQ)
        self.acceptQueue = acceptQ
        self.clientIOQueue = ioQ
        self.acceptSource = source

        source.setCancelHandler {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
        source.setEventHandler { [weak self] in
            while true {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &addrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let cFlags = Darwin.fcntl(clientFD, F_GETFL, 0)
                if cFlags >= 0 {
                    _ = Darwin.fcntl(clientFD, F_SETFL, cFlags & ~O_NONBLOCK)
                }
                var noSigPipe: Int32 = 1
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 15, tv_usec: 0)
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                guard let strongSelf = self else {
                    Darwin.close(clientFD)
                    continue
                }
                ioQ.async {
                    guard let req = Self.readHTTPRequest(from: clientFD) else {
                        Darwin.close(clientFD)
                        return
                    }
                    Task {
                        await strongSelf.handleParsedClientConnection(clientFD, req: req)
                    }
                }
            }
        }
        source.resume()
    }

    deinit {
        acceptSource.cancel()
    }

    public func registerSource(_ registration: StreamSourceRegistration, cacheStore: CacheStore) -> URL {
        sourcesByToken[registration.token] = registration
        cacheStoresByAccount[registration.accountHash] = cacheStore
        let encodedName = Cloud189Protocol.sanitizeFileName(registration.fileName)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "track.bin"
        return URL(string: "http://127.0.0.1:\(port)/stream/\(registration.token)/\(encodedName)")!
    }

    public func revokeSource(token: String) {
        sourcesByToken.removeValue(forKey: token)
        for conn in connectionRegistry.removeAll(matchingToken: token) {
            conn.revokeAndShutdownSocket()
        }
    }

    public func revokeAllSources(forAccountHash accountHash: String) {
        sourcesByToken = sourcesByToken.filter { $0.value.accountHash != accountHash }
        cacheStoresByAccount.removeValue(forKey: accountHash)
        for conn in connectionRegistry.removeAll(matchingAccountHash: accountHash) {
            conn.revokeAndShutdownSocket()
        }
    }

    public func shutdown() {
        sourcesByToken.removeAll()
        cacheStoresByAccount.removeAll()
        for conn in connectionRegistry.drainAll() {
            conn.revokeAndShutdownSocket()
        }
        acceptSource.cancel()
    }

    public nonisolated func shutdownImmediate() {
        for conn in connectionRegistry.drainAll() {
            conn.revokeAndShutdownSocket()
        }
        acceptSource.cancel()
        Task { await self.clearSourcesOnTermination() }
    }

    private func clearSourcesOnTermination() {
        sourcesByToken.removeAll()
        cacheStoresByAccount.removeAll()
    }

    private func acquireConnection(
        token: String,
        clientFD: Int32
    ) -> (StreamSourceRegistration, CacheStore, ActiveStreamConnection)? {
        guard let reg = sourcesByToken[token],
              let store = cacheStoresByAccount[reg.accountHash] else {
            return nil
        }
        let conn = ActiveStreamConnection(fd: clientFD, accountHash: reg.accountHash, token: token)
        connectionRegistry.insert(conn)
        return (reg, store, conn)
    }

    private nonisolated func unregisterConnection(id: UUID) {
        connectionRegistry.remove(id: id)
    }

    private func isSourceStillRegistered(token: String, accountHash: String) -> Bool {
        guard let reg = sourcesByToken[token] else { return false }
        return reg.accountHash == accountHash && cacheStoresByAccount[accountHash] != nil
    }

    private func updateSourceURL(token: String, newURL: URL) {
        if var reg = sourcesByToken[token] {
            reg.remoteURL = newURL
            sourcesByToken[token] = reg
        }
    }

    private nonisolated func writeSocketAsync(_ fd: Int32, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            clientIOQueue.async {
                continuation.resume(returning: Self.writeAll(fd, data))
            }
        }
    }

    private nonisolated func publishStreamStatus(
        id: String,
        accountHash: String,
        status: TransferStatus?
    ) async {
        if let onAccountStreamStatusUpdate {
            await onAccountStreamStatusUpdate(id, accountHash, status)
        }
    }

    private nonisolated func handleParsedClientConnection(
        _ clientFD: Int32,
        req: (method: String, path: String, headers: [String: String])
    ) async {
        let parts = req.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "stream" else {
            _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            Darwin.close(clientFD)
            return
        }
        let token = String(parts[1])
        guard let (foundSource, cacheStore, conn) = await acquireConnection(token: token, clientFD: clientFD) else {
            _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            Darwin.close(clientFD)
            return
        }

        let worker = Task { [weak self] in
            guard let self else {
                conn.closeOnce()
                return
            }
            await self.serveAcquiredConnection(
                clientFD: clientFD,
                conn: conn,
                initialSource: foundSource,
                cacheStore: cacheStore,
                req: req
            )
        }
        conn.attachTask(worker)
        await worker.value
    }

    private nonisolated func serveAcquiredConnection(
        clientFD: Int32,
        conn: ActiveStreamConnection,
        initialSource: StreamSourceRegistration,
        cacheStore: CacheStore,
        req: (method: String, path: String, headers: [String: String])
    ) async {
        defer {
            conn.closeOnce()
            self.unregisterConnection(id: conn.id)
        }
        guard !conn.isRevoked, !Task.isCancelled else { return }
        var source = initialSource

        let isHead = req.method.uppercased() == "HEAD"
        let clientRangeRaw = req.headers["range"]
        let requestedRange = RangeHeaderValidator.parseRequestRange(clientRangeRaw)
        let upstreamInitialRange = isHead ? "bytes=0-0" : clientRangeRaw

        do {
            try await semaphore.acquire()
        } catch {
            return
        }
        defer { Task { await semaphore.release() } }

        guard !conn.isRevoked, !Task.isCancelled else { return }

        do {
            var opened = try await openWithRefreshIfNeeded(source: &source, rangeHeader: upstreamInitialRange)
            guard !conn.isRevoked, !Task.isCancelled else { return }
            guard opened.statusCode == 200 || opened.statusCode == 206 else {
                _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }

            let mime = Cloud189Protocol.guessMimeType(for: source.fileName)
            let fullLength = RangeHeaderValidator.extractFullAssetLength(
                statusCode: opened.statusCode,
                requestHadRange: upstreamInitialRange != nil,
                contentRangeHeader: opened.headers["content-range"],
                contentLengthHeader: opened.headers["content-length"]
            ) ?? (source.expectedSize > 0 ? source.expectedSize : nil)

            if isHead {
                var headResp = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
                if let fullLength {
                    headResp += "Content-Length: \(fullLength)\r\n"
                }
                headResp += "\r\n"
                _ = await writeSocketAsync(clientFD, Data(headResp.utf8))
                return
            }

            let statusLine = opened.statusCode == 206 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
            var respHeader = "\(statusLine)\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if let cl = opened.headers["content-length"] {
                respHeader += "Content-Length: \(cl)\r\n"
            } else if opened.statusCode == 200, let fullLength {
                respHeader += "Content-Length: \(fullLength)\r\n"
            }
            if let cr = opened.headers["content-range"] {
                respHeader += "Content-Range: \(cr)\r\n"
            }
            respHeader += "\r\n"
            guard !conn.isRevoked, !Task.isCancelled, await writeSocketAsync(clientFD, Data(respHeader.utf8)) else { return }

            let eligibleForCache: Bool
            if !conn.isRevoked, RangeHeaderValidator.canWriteThroughToCache(rangeHeader: clientRangeRaw) {
                eligibleForCache = await cacheStore.beginWriteThroughIfIdle(trackId: source.trackId)
            } else {
                eligibleForCache = false
            }
            let partURL = source.cacheDestinationURL.appendingPathExtension("part")
            var fileHandle: FileHandle?

            if eligibleForCache {
                try? FileManager.default.removeItem(at: partURL)
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
                fileHandle = try? FileHandle(forWritingTo: partURL)
            }

            let reqStart = requestedRange?.start ?? 0
            let reqEnd = requestedRange?.end
            let isTinyProbe = (reqStart == 0 && (reqEnd ?? UInt64.max) <= 1)
            let streamTaskId = "stream:\(source.trackId)"
            let hasStatusCallback = onAccountStreamStatusUpdate != nil
            var didPublishStreamStatus = false
            defer {
                if didPublishStreamStatus && hasStatusCallback {
                    let accountHash = source.accountHash
                    Task { await self.publishStreamStatus(id: streamTaskId, accountHash: accountHash, status: nil) }
                }
            }
            var delivered: UInt64 = 0
            var streamCompletedCleanly = false
            var resumeAttempt = 0
            var windowBytes: UInt64 = 0
            var windowStart = ContinuousClock.now

            streamLoop: while true {
                do {
                    for try await chunk in opened.chunks {
                        if conn.isRevoked || Task.isCancelled {
                            streamCompletedCleanly = false
                            break streamLoop
                        }
                        guard !chunk.isEmpty else { continue }
                        if !(await writeSocketAsync(clientFD, chunk)) || conn.isRevoked || Task.isCancelled {
                            streamCompletedCleanly = false
                            break streamLoop
                        }
                        if let fh = fileHandle {
                            do {
                                try fh.write(contentsOf: chunk)
                            } catch {
                                try? fh.close()
                                fileHandle = nil
                            }
                        }
                        delivered += UInt64(chunk.count)
                        windowBytes += UInt64(chunk.count)
                        if !isTinyProbe && hasStatusCallback && !conn.isRevoked {
                            let elapsed = windowStart.duration(to: .now)
                            if !didPublishStreamStatus || elapsed >= .milliseconds(300) {
                                let secs = max(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                                let speed = didPublishStreamStatus ? UInt64(Double(windowBytes) / secs) : UInt64(chunk.count)
                                didPublishStreamStatus = true
                                windowBytes = 0
                                windowStart = .now
                                await publishStreamStatus(
                                    id: streamTaskId,
                                    accountHash: source.accountHash,
                                    status: TransferStatus(
                                        id: streamTaskId,
                                        label: source.fileName,
                                        kind: "stream",
                                        state: "running",
                                        bytesPerSecond: speed,
                                        transferredBytes: min(reqStart + delivered, fullLength ?? (reqStart + delivered)),
                                        totalBytes: fullLength
                                    )
                                )
                            }
                        }
                        resumeAttempt = 0
                    }
                    streamCompletedCleanly = !conn.isRevoked && !Task.isCancelled
                    break streamLoop
                } catch {
                    if conn.isRevoked || Task.isCancelled {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    resumeAttempt += 1
                    if resumeAttempt > 4 {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    let resumeStart = reqStart + delivered
                    if let reqEnd, resumeStart > reqEnd {
                        streamCompletedCleanly = !conn.isRevoked && !Task.isCancelled
                        break streamLoop
                    }
                    let resumeRange = ParsedByteRange(start: resumeStart, end: reqEnd).headerValue
                    guard let nextOpened = try? await openWithRefreshIfNeeded(source: &source, rangeHeader: resumeRange) else {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    do {
                        try RangeHeaderValidator.validateResumeResponse(
                            expectedStartOffset: resumeStart,
                            statusCode: nextOpened.statusCode,
                            contentRangeHeader: nextOpened.headers["content-range"]
                        )
                        opened = nextOpened
                    } catch {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                }
            }

            try? fileHandle?.close()
            if eligibleForCache {
                let targetTotal = fullLength ?? 0
                let matchesExpected = (source.expectedSize == 0) || (delivered == source.expectedSize)
                let sourceRegistered = await isSourceStillRegistered(token: source.token, accountHash: source.accountHash)
                let stillRegistered = !conn.isRevoked && !Task.isCancelled && sourceRegistered
                if stillRegistered && streamCompletedCleanly && fileHandle != nil && targetTotal > 0 && delivered == targetTotal && matchesExpected {
                    let promoted: Bool
                    if FileManager.default.fileExists(atPath: source.cacheDestinationURL.path) {
                        promoted = (try? FileManager.default.replaceItemAt(source.cacheDestinationURL, withItemAt: partURL)) != nil
                    } else {
                        promoted = (try? FileManager.default.moveItem(at: partURL, to: source.cacheDestinationURL)) != nil
                    }
                    if promoted {
                        do {
                            _ = try await cacheStore.recordCompletedFile(
                                trackId: source.trackId,
                                fileURL: source.cacheDestinationURL,
                                sizeBytes: delivered,
                                limitBytes: source.cacheLimitBytes
                            )
                            if let onWriteThroughCompleted,
                               !conn.isRevoked,
                               !Task.isCancelled,
                               await isSourceStillRegistered(token: source.token, accountHash: source.accountHash) {
                                await onWriteThroughCompleted(source.accountHash, source.trackId, source.cacheDestinationURL)
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: source.cacheDestinationURL)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: partURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: partURL)
                }
                await cacheStore.finishWriteThrough(trackId: source.trackId)
            }
        } catch {
            if !conn.isRevoked {
                _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            }
        }
    }

    private nonisolated func openWithRefreshIfNeeded(
        source: inout StreamSourceRegistration,
        rangeHeader: String?
    ) async throws -> (statusCode: Int, headers: [String: String], chunks: AsyncThrowingStream<Data, Error>) {
        let initial = try await fetcher.openStream(url: source.remoteURL, rangeHeader: rangeHeader)
        if [403, 404, 410].contains(initial.statusCode), let refresher = urlRefresher {
            let newURL = try await refresher(source.trackId)
            source.remoteURL = newURL
            await updateSourceURL(token: source.token, newURL: newURL)
            return try await fetcher.openStream(url: newURL, rangeHeader: rangeHeader)
        }
        return initial
    }

    private nonisolated static func readHTTPRequest(from fd: Int32) -> (method: String, path: String, headers: [String: String])? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while data.count < 16_384 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.range(of: terminator) != nil { break }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let reqParts = first.split(separator: " ")
        guard reqParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let rawPath = String(reqParts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return (String(reqParts[0]), rawPath, headers)
    }

    @discardableResult
    private nonisolated static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return true }
            var offset = 0
            while offset < rawBuf.count {
                let sent = Darwin.send(fd, base.advanced(by: offset), rawBuf.count - offset, 0)
                if sent <= 0 {
                    if sent < 0 && errno == EINTR { continue }
                    return false
                }
                offset += sent
            }
            return true
        }
    }
}
