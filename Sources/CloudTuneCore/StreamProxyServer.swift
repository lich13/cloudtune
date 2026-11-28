import Darwin
import Foundation

package struct StreamSourceRegistration: Sendable {
    package let token: String
    package let accountHash: String
    package let trackId: String
    package var remoteURL: URL
    package let cacheDestinationURL: URL
    package let expectedSize: UInt64
    package let fileName: String
    package let cacheLimitBytes: UInt64

    package init(
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

package protocol UpstreamStreamFetcher: Sendable {
    func openStream(url: URL, rangeHeader: String?) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    )
}

private final class UpstreamTaskContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var task: URLSessionDataTask?
    private let highWaterMarkBytes: Int
    private let lowWaterMarkBytes: Int

    private var hasStarted = false
    private var isSuspended = false
    private var isFinished = false
    private var isCancelled = false
    private var completionError: Error?

    private var chunks: [Data] = []
    private var headIndex: Int = 0
    private var queuedBytes: Int = 0

    private var responseContinuation: CheckedContinuation<(Int, [String: String]), Error>?
    private var chunkContinuation: CheckedContinuation<Data?, Error>?

    init(task: URLSessionDataTask, highWaterMarkBytes: Int, lowWaterMarkBytes: Int) {
        self.task = task
        self.highWaterMarkBytes = max(16 * 1024, highWaterMarkBytes)
        self.lowWaterMarkBytes = max(4 * 1024, min(lowWaterMarkBytes, self.highWaterMarkBytes / 2))
    }

    var currentSuspendedState: Bool {
        lock.withLock { isSuspended }
    }

    func startOrFailIfCancelled(continuation: CheckedContinuation<(Int, [String: String]), Error>) {
        let shouldStart = lock.withLock { () -> Bool in
            if isCancelled {
                return false
            }
            responseContinuation = continuation
            hasStarted = true
            return true
        }
        if shouldStart {
            task?.resume()
        } else {
            continuation.resume(throwing: CancellationError())
        }
    }

    func handleResponse(_ response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            let pending = lock.withLock { () -> CheckedContinuation<(Int, [String: String]), Error>? in
                isFinished = true
                let err = CloudTuneError.protocolError("非 HTTP 媒体流响应")
                completionError = err
                let cont = responseContinuation
                responseContinuation = nil
                return cont
            }
            completionHandler(.cancel)
            pending?.resume(throwing: CloudTuneError.protocolError("非 HTTP 媒体流响应"))
            return
        }

        var headers: [String: String] = [:]
        headers.reserveCapacity(http.allHeaderFields.count)
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k).lowercased()] = String(describing: v)
        }

        let (allow, pending) = lock.withLock { () -> (Bool, CheckedContinuation<(Int, [String: String]), Error>?) in
            let cont = responseContinuation
            responseContinuation = nil
            if isCancelled {
                return (false, cont)
            }
            return (true, cont)
        }
        if allow {
            completionHandler(.allow)
            pending?.resume(returning: (http.statusCode, headers))
        } else {
            completionHandler(.cancel)
            pending?.resume(throwing: CancellationError())
        }
    }

    func handleData(_ data: Data) {
        guard !data.isEmpty else { return }
        var waiterToResume: CheckedContinuation<Data?, Error>?
        var taskToSuspend: URLSessionDataTask?

        lock.withLock {
            guard !isCancelled, !isFinished else { return }
            if let waiter = chunkContinuation {
                chunkContinuation = nil
                waiterToResume = waiter
                return
            }
            chunks.append(data)
            queuedBytes += data.count
            if !isSuspended && queuedBytes >= highWaterMarkBytes {
                isSuspended = true
                taskToSuspend = task
            }
        }

        if let waiterToResume {
            waiterToResume.resume(returning: data)
        } else if let taskToSuspend {
            taskToSuspend.suspend()
        }
    }

    func handleCompletion(error: Error?) {
        var respCont: CheckedContinuation<(Int, [String: String]), Error>?
        var chunkCont: CheckedContinuation<Data?, Error>?
        var shouldFailWithoutHeaders = false

        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            isSuspended = false
            completionError = error
            if let rc = responseContinuation {
                responseContinuation = nil
                respCont = rc
                shouldFailWithoutHeaders = true
            } else if let cc = chunkContinuation {
                chunkContinuation = nil
                chunkCont = cc
            }
        }

        if let respCont {
            if isCancelled {
                respCont.resume(throwing: CancellationError())
            } else if shouldFailWithoutHeaders {
                respCont.resume(throwing: error ?? CloudTuneError.protocolError("媒体流无响应头"))
            }
        } else if let chunkCont {
            if let error {
                chunkCont.resume(throwing: error)
            } else {
                chunkCont.resume(returning: nil)
            }
        }
    }

    func nextChunk(onCancel: @Sendable @escaping () -> Void) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                var immediateResult: Result<Data?, Error>?
                var taskToResume: URLSessionDataTask?

                lock.withLock {
                    if isCancelled {
                        immediateResult = .failure(CancellationError())
                        return
                    }
                    if headIndex < chunks.count {
                        let chunk = chunks[headIndex]
                        chunks[headIndex] = Data()
                        headIndex += 1
                        queuedBytes = max(0, queuedBytes - chunk.count)
                        if headIndex == chunks.count {
                            chunks.removeAll(keepingCapacity: true)
                            headIndex = 0
                        } else if headIndex >= 32 {
                            chunks.removeFirst(headIndex)
                            headIndex = 0
                        }
                        if isSuspended && !isFinished && queuedBytes <= lowWaterMarkBytes {
                            isSuspended = false
                            taskToResume = task
                        }
                        immediateResult = .success(chunk)
                        return
                    }
                    if isFinished {
                        if let err = completionError {
                            immediateResult = .failure(err)
                        } else {
                            immediateResult = .success(nil)
                        }
                        return
                    }
                    if isSuspended {
                        isSuspended = false
                        taskToResume = task
                    }
                    chunkContinuation = cont
                }

                if let taskToResume {
                    taskToResume.resume()
                }
                if let immediateResult {
                    cont.resume(with: immediateResult)
                }
            }
        } onCancel: {
            onCancel()
        }
    }

    func cancel() {
        var taskToCancel: URLSessionDataTask?
        var shouldResumeBeforeCancel = false
        var respCont: CheckedContinuation<(Int, [String: String]), Error>?
        var chunkCont: CheckedContinuation<Data?, Error>?

        lock.withLock {
            guard !isCancelled else { return }
            isCancelled = true
            chunks.removeAll(keepingCapacity: false)
            headIndex = 0
            queuedBytes = 0
            if !isFinished {
                isFinished = true
                taskToCancel = task
                if hasStarted && isSuspended {
                    isSuspended = false
                    shouldResumeBeforeCancel = true
                } else {
                    isSuspended = false
                }
            }
            respCont = responseContinuation
            responseContinuation = nil
            chunkCont = chunkContinuation
            chunkContinuation = nil
        }

        if shouldResumeBeforeCancel {
            taskToCancel?.resume()
        }
        taskToCancel?.cancel()
        respCont?.resume(throwing: CancellationError())
        chunkCont?.resume(throwing: CancellationError())
    }
}

private final class UpstreamStreamLifetimeBox: @unchecked Sendable {
    private let taskID: Int
    private let context: UpstreamTaskContext
    private unowned let multiplexer: UpstreamSessionMultiplexer

    init(taskID: Int, context: UpstreamTaskContext, multiplexer: UpstreamSessionMultiplexer) {
        self.taskID = taskID
        self.context = context
        self.multiplexer = multiplexer
    }

    deinit {
        multiplexer.cancelTask(id: taskID, fallbackContext: context)
    }

    func nextChunk() async throws -> Data? {
        let id = taskID
        let ctx = context
        let mux = multiplexer
        return try await context.nextChunk {
            mux.cancelTask(id: id, fallbackContext: ctx)
        }
    }
}
private final class UpstreamSessionMultiplexer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = UpstreamSessionMultiplexer()

    private let lock = NSLock()
    private var contextsByTaskID: [Int: UpstreamTaskContext] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.gosu.cloudtune.upstream.multiplexer"
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.maxConcurrentOperationCount = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    var activeTaskCount: Int {
        lock.withLock { contextsByTaskID.count }
    }

    func openStream(
        url: URL,
        rangeHeader: String?,
        highWaterMarkBytes: Int,
        lowWaterMarkBytes: Int
    ) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        req.setValue(Cloud189Constants.userAgent, forHTTPHeaderField: "User-Agent")
        if let rangeHeader {
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        let dataTask = session.dataTask(with: req)
        let taskID = dataTask.taskIdentifier
        let context = UpstreamTaskContext(
            task: dataTask,
            highWaterMarkBytes: highWaterMarkBytes,
            lowWaterMarkBytes: lowWaterMarkBytes
        )
        lock.withLock {
            contextsByTaskID[taskID] = context
        }

        let (statusCode, headers): (Int, [String: String])
        do {
            (statusCode, headers) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    context.startOrFailIfCancelled(continuation: cont)
                }
            } onCancel: {
                self.cancelTask(id: taskID, fallbackContext: context)
            }
        } catch {
            cancelTask(id: taskID, fallbackContext: context)
            throw error
        }

        let lifetimeBox = UpstreamStreamLifetimeBox(taskID: taskID, context: context, multiplexer: self)
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await lifetimeBox.nextChunk()
        })
        return (statusCode, headers, stream)
    }

    func cancelTask(id: Int, fallbackContext: UpstreamTaskContext? = nil) {
        let removed = lock.withLock {
            contextsByTaskID.removeValue(forKey: id)
        }
        (removed ?? fallbackContext)?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let ctx = lock.withLock { contextsByTaskID[dataTask.taskIdentifier] }
        guard let ctx else {
            completionHandler(.cancel)
            return
        }
        ctx.handleResponse(response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ctx = lock.withLock { contextsByTaskID[dataTask.taskIdentifier] }
        ctx?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ctx = lock.withLock { contextsByTaskID.removeValue(forKey: task.taskIdentifier) }
        ctx?.handleCompletion(error: error)
    }
}

package struct URLSessionUpstreamStreamFetcher: UpstreamStreamFetcher {
    package let highWaterMarkBytes: Int
    package let lowWaterMarkBytes: Int

    package init(
        highWaterMarkBytes: Int = 512 * 1024,
        lowWaterMarkBytes: Int = 128 * 1024
    ) {
        self.highWaterMarkBytes = highWaterMarkBytes
        self.lowWaterMarkBytes = lowWaterMarkBytes
    }

    package static var activePooledTaskCount: Int {
        UpstreamSessionMultiplexer.shared.activeTaskCount
    }

    package func openStream(url: URL, rangeHeader: String?) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        try await UpstreamSessionMultiplexer.shared.openStream(
            url: url,
            rangeHeader: rangeHeader,
            highWaterMarkBytes: highWaterMarkBytes,
            lowWaterMarkBytes: lowWaterMarkBytes
        )
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

    func activeTokens() -> Set<String> {
        lock.withLock {
            Set(entries.values.map(\.token))
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
package actor StreamProxyServer {
    private static let maxRegisteredSources = 128
    private static let localCacheSliceBytes = 64 * 1024
    private static let writeThroughBufferBytes = 256 * 1024

    package nonisolated let port: UInt16
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
    private var tokenInsertionOrder: [String] = []
    private var cacheStoresByAccount: [String: CacheStore] = [:]

    package init(
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
                var noDelay: Int32 = 1
                _ = Darwin.setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
                var headerRecvTimeout = timeval(tv_sec: 15, tv_usec: 0)
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &headerRecvTimeout, socklen_t(MemoryLayout<timeval>.size))

                guard let strongSelf = self else {
                    Darwin.close(clientFD)
                    continue
                }
                ioQ.async {
                    guard let req = Self.readHTTPRequest(from: clientFD) else {
                        Darwin.close(clientFD)
                        return
                    }
                    var clearRecvTimeout = timeval(tv_sec: 0, tv_usec: 0)
                    _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &clearRecvTimeout, socklen_t(MemoryLayout<timeval>.size))
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

    package var registeredSourceCount: Int {
        sourcesByToken.count
    }

    package func registerSource(_ registration: StreamSourceRegistration, cacheStore: CacheStore) -> URL {
        if sourcesByToken[registration.token] != nil {
            tokenInsertionOrder.removeAll { $0 == registration.token }
        }
        sourcesByToken[registration.token] = registration
        tokenInsertionOrder.append(registration.token)
        cacheStoresByAccount[registration.accountHash] = cacheStore
        evictInactiveSourcesIfNeeded(preservingToken: registration.token)

        let encodedName = Cloud189Protocol.sanitizeFileName(registration.fileName)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "track.bin"
        return URL(string: "http://127.0.0.1:\(port)/stream/\(registration.token)/\(encodedName)")!
    }

    private func evictInactiveSourcesIfNeeded(preservingToken: String) {
        guard sourcesByToken.count > Self.maxRegisteredSources else { return }
        let activeTokens = connectionRegistry.activeTokens()
        var idx = 0
        while sourcesByToken.count > Self.maxRegisteredSources && idx < tokenInsertionOrder.count {
            let candidate = tokenInsertionOrder[idx]
            if candidate == preservingToken || activeTokens.contains(candidate) {
                idx += 1
                continue
            }
            tokenInsertionOrder.remove(at: idx)
            sourcesByToken.removeValue(forKey: candidate)
        }
    }

    package func revokeSource(token: String) {
        sourcesByToken.removeValue(forKey: token)
        tokenInsertionOrder.removeAll { $0 == token }
        for conn in connectionRegistry.removeAll(matchingToken: token) {
            conn.revokeAndShutdownSocket()
        }
    }

    package func revokeAllSources(forAccountHash accountHash: String) {
        sourcesByToken = sourcesByToken.filter { $0.value.accountHash != accountHash }
        tokenInsertionOrder.removeAll { sourcesByToken[$0] == nil }
        cacheStoresByAccount.removeValue(forKey: accountHash)
        for conn in connectionRegistry.removeAll(matchingAccountHash: accountHash) {
            conn.revokeAndShutdownSocket()
        }
    }

    package func shutdown() {
        sourcesByToken.removeAll()
        tokenInsertionOrder.removeAll()
        cacheStoresByAccount.removeAll()
        for conn in connectionRegistry.drainAll() {
            conn.revokeAndShutdownSocket()
        }
        acceptSource.cancel()
    }

    package nonisolated func shutdownImmediate() {
        for conn in connectionRegistry.drainAll() {
            conn.revokeAndShutdownSocket()
        }
        acceptSource.cancel()
        Task { await self.clearSourcesOnTermination() }
    }

    private func clearSourcesOnTermination() {
        sourcesByToken.removeAll()
        tokenInsertionOrder.removeAll()
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

    private nonisolated func serveFromLocalCacheIfAvailable(
        clientFD: Int32,
        conn: ActiveStreamConnection,
        source: StreamSourceRegistration,
        cacheStore: CacheStore,
        isHead: Bool,
        clientRangeRaw: String?
    ) async -> Bool {
        guard let cachedURL = await cacheStore.existingCachedFile(trackId: source.trackId),
              let fh = try? FileHandle(forReadingFrom: cachedURL) else {
            return false
        }
        defer { try? fh.close() }
        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else {
            return false
        }

        let mime = Cloud189Protocol.guessMimeType(for: source.fileName)
        let trimmedRange = clientRangeRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

        let sliceStart: UInt64
        let sliceLength: UInt64
        let headerText: String

        if let trimmedRange, !trimmedRange.isEmpty {
            guard let parsed = RangeHeaderValidator.parseRequestRange(trimmedRange),
                  let resolved = parsed.resolve(totalLength: fileSize) else {
                let notSatisfiable = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(fileSize)\r\nAccept-Ranges: bytes\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = await writeSocketAsync(clientFD, Data(notSatisfiable.utf8))
                return true
            }
            sliceStart = resolved.start
            sliceLength = resolved.end - resolved.start + 1
            headerText = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(resolved.start)-\(resolved.end)/\(fileSize)\r\nContent-Length: \(sliceLength)\r\nConnection: close\r\n\r\n"
        } else {
            sliceStart = 0
            sliceLength = fileSize
            headerText = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(fileSize)\r\nConnection: close\r\n\r\n"
        }

        guard !conn.isRevoked, !Task.isCancelled, await writeSocketAsync(clientFD, Data(headerText.utf8)) else {
            return true
        }
        if isHead {
            return true
        }
        do {
            try fh.seek(toOffset: sliceStart)
            var remaining = sliceLength
            while remaining > 0 {
                if conn.isRevoked || Task.isCancelled { break }
                let toRead = Int(min(UInt64(Self.localCacheSliceBytes), remaining))
                guard let data = try fh.read(upToCount: toRead), !data.isEmpty else {
                    break
                }
                if !(await writeSocketAsync(clientFD, data)) {
                    break
                }
                remaining -= UInt64(data.count)
            }
        } catch {
            // Connection closes cleanly in defer
        }
        return true
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
        let rawRangeHeader = req.headers["range"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientRangeRaw = (rawRangeHeader?.isEmpty == false) ? rawRangeHeader : nil

        // Serve already-cached tracks directly from local disk BEFORE acquiring a remote permit!
        if await serveFromLocalCacheIfAvailable(
            clientFD: clientFD,
            conn: conn,
            source: source,
            cacheStore: cacheStore,
            isHead: isHead,
            clientRangeRaw: clientRangeRaw
        ) {
            return
        }

        guard !conn.isRevoked, !Task.isCancelled else { return }

        let requestedRange: ParsedByteRange?
        if let clientRangeRaw {
            guard let parsed = RangeHeaderValidator.parseRequestRange(clientRangeRaw) else {
                _ = await writeSocketAsync(
                    clientFD,
                    Data("HTTP/1.1 416 Range Not Satisfiable\r\nAccept-Ranges: bytes\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                )
                return
            }
            requestedRange = parsed
        } else {
            requestedRange = nil
        }

        let upstreamInitialRange: String?
        if let requestedRange {
            upstreamInitialRange = requestedRange.headerValue
        } else if isHead {
            upstreamInitialRange = "bytes=0-0"
        } else {
            upstreamInitialRange = nil
        }

        do {
            try await semaphore.acquire()
        } catch {
            return
        }
        defer { Task { await semaphore.release() } }

        guard !conn.isRevoked, !Task.isCancelled else { return }

        do {
            let maxRetries = 4
            var resumeAttempt = 0
            var opened: (statusCode: Int, headers: [String: String], chunks: AsyncThrowingStream<Data, Error>)
            while true {
                do {
                    let candidate = try await openWithRefreshIfNeeded(source: &source, rangeHeader: upstreamInitialRange)
                    if candidate.statusCode >= 500 && resumeAttempt < maxRetries && !conn.isRevoked && !Task.isCancelled {
                        resumeAttempt += 1
                        continue
                    }
                    opened = candidate
                    break
                } catch {
                    if conn.isRevoked || Task.isCancelled { return }
                    resumeAttempt += 1
                    if resumeAttempt > maxRetries {
                        throw error
                    }
                }
            }
            guard !conn.isRevoked, !Task.isCancelled else { return }

            if opened.statusCode == 416 {
                var header416 = "HTTP/1.1 416 Range Not Satisfiable\r\nAccept-Ranges: bytes\r\nContent-Length: 0\r\n"
                if let cr = opened.headers["content-range"] {
                    header416 += "Content-Range: \(cr)\r\n"
                }
                header416 += "Connection: close\r\n\r\n"
                _ = await writeSocketAsync(clientFD, Data(header416.utf8))
                return
            }

            let resolvedStart: UInt64
            let resolvedEnd: UInt64?
            let expectedResponseBytes: UInt64?

            if let suffixLen = requestedRange?.suffixLength {
                let cr = try RangeHeaderValidator.validateSuffixResponse(
                    suffixLength: suffixLen,
                    statusCode: opened.statusCode,
                    contentRangeHeader: opened.headers["content-range"]
                )
                resolvedStart = cr.start
                resolvedEnd = cr.end
                expectedResponseBytes = cr.end - cr.start + 1
            } else if let requestedRange, requestedRange.start > 0 {
                try RangeHeaderValidator.validateResumeResponse(
                    expectedStartOffset: requestedRange.start,
                    statusCode: opened.statusCode,
                    contentRangeHeader: opened.headers["content-range"]
                )
                resolvedStart = requestedRange.start
                if let cr = RangeHeaderValidator.parseContentRange(opened.headers["content-range"]) {
                    resolvedEnd = cr.end
                    expectedResponseBytes = cr.end - cr.start + 1
                } else {
                    resolvedEnd = requestedRange.end
                    expectedResponseBytes = opened.headers["content-length"]
                        .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            } else {
                guard opened.statusCode == 200 || opened.statusCode == 206 else {
                    _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    return
                }
                resolvedStart = 0
                if opened.statusCode == 206 {
                    if let cr = RangeHeaderValidator.parseContentRange(opened.headers["content-range"]) {
                        guard cr.start == 0 else {
                            _ = await writeSocketAsync(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                            return
                        }
                        resolvedEnd = cr.end
                        expectedResponseBytes = isHead && requestedRange == nil ? nil : (cr.end - cr.start + 1)
                    } else {
                        resolvedEnd = requestedRange?.end
                        expectedResponseBytes = opened.headers["content-length"]
                            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                } else {
                    let cl = opened.headers["content-length"]
                        .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    expectedResponseBytes = cl
                    resolvedEnd = cl.flatMap { $0 > 0 ? ($0 - 1) : nil }
                }
            }

            let mime = Cloud189Protocol.guessMimeType(for: source.fileName)
            let fullLength = RangeHeaderValidator.extractFullAssetLength(
                statusCode: opened.statusCode,
                requestHadRange: upstreamInitialRange != nil,
                contentRangeHeader: opened.headers["content-range"],
                contentLengthHeader: opened.headers["content-length"]
            ) ?? (source.expectedSize > 0 ? source.expectedSize : nil)

            if isHead {
                if requestedRange == nil {
                    var headResp = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
                    if let fullLength {
                        headResp += "Content-Length: \(fullLength)\r\n"
                    }
                    headResp += "\r\n"
                    _ = await writeSocketAsync(clientFD, Data(headResp.utf8))
                    return
                }
                let headStatus = opened.statusCode == 206 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
                var headResp = "\(headStatus)\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
                if let expectedResponseBytes {
                    headResp += "Content-Length: \(expectedResponseBytes)\r\n"
                } else if let cl = opened.headers["content-length"] {
                    headResp += "Content-Length: \(cl)\r\n"
                }
                if let cr = opened.headers["content-range"] {
                    headResp += "Content-Range: \(cr)\r\n"
                }
                headResp += "\r\n"
                _ = await writeSocketAsync(clientFD, Data(headResp.utf8))
                return
            }

            let statusLine = opened.statusCode == 206 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
            var respHeader = "\(statusLine)\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if let expectedResponseBytes {
                respHeader += "Content-Length: \(expectedResponseBytes)\r\n"
            } else if let cl = opened.headers["content-length"] {
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
            var writeBuffer = Data()

            if eligibleForCache {
                try? FileManager.default.removeItem(at: partURL)
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
                fileHandle = try? FileHandle(forWritingTo: partURL)
                if fileHandle != nil {
                    writeBuffer.reserveCapacity(Self.writeThroughBufferBytes)
                }
            }

            let isTinyProbe = (resolvedStart == 0 && (resolvedEnd ?? UInt64.max) <= 1)
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
            resumeAttempt = 0
            var windowBytes: UInt64 = 0
            var windowStart = ContinuousClock.now

            streamLoop: while true {
                var bytesThisAttempt: UInt64 = 0
                do {
                    for try await chunk in opened.chunks {
                        if conn.isRevoked || Task.isCancelled {
                            streamCompletedCleanly = false
                            break streamLoop
                        }
                        guard !chunk.isEmpty else { continue }
                        let slice: Data
                        if let expectedResponseBytes {
                            if delivered >= expectedResponseBytes { break }
                            let remaining = Int(min(UInt64(Int.max), expectedResponseBytes - delivered))
                            slice = chunk.count > remaining ? chunk.prefix(remaining) : chunk
                        } else {
                            slice = chunk
                        }
                        if !(await writeSocketAsync(clientFD, slice)) || conn.isRevoked || Task.isCancelled {
                            streamCompletedCleanly = false
                            break streamLoop
                        }
                        if fileHandle != nil {
                            writeBuffer.append(slice)
                            if writeBuffer.count >= Self.writeThroughBufferBytes, let fh = fileHandle {
                                do {
                                    try fh.write(contentsOf: writeBuffer)
                                    writeBuffer.removeAll(keepingCapacity: true)
                                } catch {
                                    writeBuffer.removeAll(keepingCapacity: false)
                                    try? fh.close()
                                    fileHandle = nil
                                }
                            }
                        }
                        let chunkLen = UInt64(slice.count)
                        delivered += chunkLen
                        bytesThisAttempt += chunkLen
                        windowBytes += chunkLen
                        if !isTinyProbe && hasStatusCallback && !conn.isRevoked {
                            let elapsed = windowStart.duration(to: .now)
                            if !didPublishStreamStatus || elapsed >= .milliseconds(300) {
                                let secs = max(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                                let speed = UInt64(Double(windowBytes) / secs)
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
                                        transferredBytes: min(resolvedStart + delivered, fullLength ?? (resolvedStart + delivered)),
                                        totalBytes: fullLength
                                    )
                                )
                            }
                        }
                        resumeAttempt = 0
                        if let expectedResponseBytes, delivered >= expectedResponseBytes {
                            break
                        }
                    }

                    if conn.isRevoked || Task.isCancelled {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    if let expectedResponseBytes, delivered < expectedResponseBytes {
                        if bytesThisAttempt > 0 {
                            resumeAttempt = 0
                        }
                        throw CloudTuneError.protocolError("上游媒体流提前结束 (已传输 \(delivered)/\(expectedResponseBytes))")
                    }
                    streamCompletedCleanly = true
                    break streamLoop
                } catch {
                    if conn.isRevoked || Task.isCancelled {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    resumeAttempt += 1
                    if resumeAttempt > maxRetries {
                        streamCompletedCleanly = false
                        break streamLoop
                    }
                    let resumeStart = resolvedStart + delivered
                    let targetEnd = resolvedEnd ?? requestedRange?.end
                    if let targetEnd, resumeStart > targetEnd {
                        streamCompletedCleanly = !conn.isRevoked && !Task.isCancelled
                        break streamLoop
                    }
                    let resumeRange = ParsedByteRange(start: resumeStart, end: targetEnd).headerValue
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

            if eligibleForCache {
                let targetTotal = fullLength ?? 0
                let matchesExpected = (source.expectedSize == 0) || (delivered == source.expectedSize)
                let sourceRegistered = await isSourceStillRegistered(token: source.token, accountHash: source.accountHash)
                let stillRegistered = !conn.isRevoked && !Task.isCancelled && sourceRegistered
                var flushedAndSynced = false
                if stillRegistered && streamCompletedCleanly && targetTotal > 0 && delivered == targetTotal && matchesExpected,
                   let fh = fileHandle {
                    do {
                        if !writeBuffer.isEmpty {
                            try fh.write(contentsOf: writeBuffer)
                            writeBuffer.removeAll(keepingCapacity: false)
                        }
                        try fh.synchronize()
                        try fh.close()
                        fileHandle = nil
                        flushedAndSynced = true
                    } catch {
                        try? fh.close()
                        fileHandle = nil
                    }
                }
                try? fileHandle?.close()
                fileHandle = nil

                if flushedAndSynced {
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
            } else {
                try? fileHandle?.close()
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
