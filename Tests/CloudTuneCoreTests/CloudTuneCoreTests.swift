import CloudTuneCore
import Foundation
import Testing

private struct MockUpstreamFetcher: UpstreamStreamFetcher {
    let handler: @Sendable (URL, String?) async throws -> (Int, [String: String], AsyncThrowingStream<Data, Error>)

    func openStream(url: URL, rangeHeader: String?) async throws -> (
        statusCode: Int,
        headers: [String: String],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        try await handler(url, rangeHeader)
    }
}

private final class MockKeychainBackend: KeychainBackend, @unchecked Sendable {
    var nextReadResult: KeychainLoadResult = .notFound
    var savedCredential: PersistedRefreshCredential?
    var readCallCount = 0

    func readCredential() -> KeychainLoadResult {
        readCallCount += 1
        return nextReadResult
    }

    func saveCredential(_ credential: PersistedRefreshCredential) throws {
        savedCredential = credential
        nextReadResult = .found(credential)
    }

    func deleteCredential() {
        savedCredential = nil
        nextReadResult = .notFound
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Suite("CloudTuneCore Protocol, Range Proxy, Concurrency & Keychain Tests")
struct CloudTuneCoreTests {
    @Test("Shared protocol-vectors.json parity (HMAC-SHA1, alt-safe HTML extraction, QR & session split, account SHA-256)")
    func verifySharedProtocolVectors() throws {
        let vectorsURL = repoRootURL().appendingPathComponent("contracts/protocol-vectors.json")
        let data = try Data(contentsOf: vectorsURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 1) HMAC-SHA1
        let hmacBlock = try #require(root["hmacSignature"] as? [String: Any])
        let (reqURI, sig) = try Cloud189Protocol.computeSignature(
            sessionKey: try #require(hmacBlock["sessionKey"] as? String),
            sessionSecret: try #require(hmacBlock["sessionSecret"] as? String),
            method: try #require(hmacBlock["method"] as? String),
            urlString: try #require(hmacBlock["url"] as? String),
            dateHeader: try #require(hmacBlock["date"] as? String)
        )
        #expect(reqURI == (hmacBlock["expectedRequestUri"] as? String))
        #expect(sig == (hmacBlock["expectedSignature"] as? String))

        // 2) Login HTML extraction avoiding alt="二维码登录成功"
        let htmlBlock = try #require(root["loginHtmlExtraction"] as? [String: Any])
        let extracted = try Cloud189Protocol.extractLoginParameters(from: try #require(htmlBlock["html"] as? String))
        #expect(extracted.lt == (htmlBlock["expectedLt"] as? String))
        #expect(extracted.paramId == (htmlBlock["expectedParamId"] as? String))
        #expect(extracted.reqId == (htmlBlock["expectedReqId"] as? String))

        // 3) QR poll payloads (redirectUrl / redirectURL / toUrl / states)
        let qrPayloads = try #require(root["qrPollPayloads"] as? [[String: Any]])
        for entry in qrPayloads {
            let parsed = try Cloud189Protocol.parseQrPollPayload(try #require(entry["json"] as? String), statusCode: 200)
            #expect(parsed.state.rawValue == (entry["expectedState"] as? String))
            #expect(parsed.redirectURL == (entry["expectedRedirectUrl"] as? String))
        }

        // 4) Strict session split (JSON with refreshToken vs XML without refreshToken)
        let sessionPayloads = try #require(root["sessionPayloads"] as? [[String: Any]])
        for entry in sessionPayloads {
            let parsed = try Cloud189Protocol.parseSessionResponse(try #require(entry["body"] as? String), statusCode: 200)
            #expect(parsed.activeSession.loginName == (entry["expectedAccountName"] as? String))
            #expect(parsed.activeSession.sessionKey == (entry["expectedSessionKey"] as? String))
            #expect(parsed.activeSession.sessionSecret == (entry["expectedSessionSecret"] as? String))
            #expect(parsed.persistedCredential?.refreshToken == (entry["expectedPersistedRefreshToken"] as? String))
        }

        // 5) Web login callback classifier
        let callbacks = try #require(root["webLoginCallbacks"] as? [[String: Any]])
        for entry in callbacks {
            let urlStr = try #require(entry["url"] as? String)
            let url = try #require(URL(string: urlStr))
            let expected = try #require(entry["shouldIntercept"] as? Bool)
            #expect(Cloud189Protocol.isInterceptableWebLoginCallback(url) == expected)
        }

        // 6) Account SHA-256 bucket isolation
        let accounts = try #require(root["accountIsolation"] as? [[String: Any]])
        for entry in accounts {
            let raw = try #require(entry["rawAccountId"] as? String)
            let expectedHash = try #require(entry["expectedBucketHash"] as? String)
            #expect(Cloud189Protocol.accountBucketHash(for: raw) == expectedHash)
        }
    }

    @Test("Loopback StreamProxyServer: bytes=0-1 probe never writes cache; full stream writes; non-zero 206 resume succeeds & 200 rejected")
    func verifyStreamProxyRangeAndResumeSafety() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheStore = try CacheStore(cacheDirectory: tempDir)
        let fullPayload = Data((0..<8192).map { UInt8($0 & 0xFF) })

        // Case A + B + C: probe bytes=0-1, then interrupted stream that resumes cleanly with 206
        actor DropCounter {
            var didDropOnce = false
            func consumeDrop() -> Bool {
                if !didDropOnce {
                    didDropOnce = true
                    return true
                }
                return false
            }
        }
        let dropCounter = DropCounter()
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        let server = try StreamProxyServer(
            semaphore: semaphore,
            fetcher: MockUpstreamFetcher { _, rangeHeader in
                if rangeHeader == "bytes=0-1" {
                    let sub = fullPayload.subdata(in: 0..<2)
                    let stream = AsyncThrowingStream<Data, Error> { c in c.yield(sub); c.finish() }
                    return (206, ["content-length": "2", "content-range": "bytes 0-1/\(fullPayload.count)"], stream)
                }
                if let rangeHeader, let parsed = RangeHeaderValidator.parseRequestRange(rangeHeader), parsed.start > 0 {
                    let start = Int(parsed.start)
                    let sub = fullPayload.subdata(in: start..<fullPayload.count)
                    let stream = AsyncThrowingStream<Data, Error> { c in c.yield(sub); c.finish() }
                    return (
                        206,
                        [
                            "content-length": "\(sub.count)",
                            "content-range": "bytes \(start)-\(fullPayload.count - 1)/\(fullPayload.count)"
                        ],
                        stream
                    )
                }
                let shouldDrop = await dropCounter.consumeDrop()
                let stream = AsyncThrowingStream<Data, Error> { c in
                    if shouldDrop {
                        c.yield(fullPayload.subdata(in: 0..<3000))
                        c.finish(throwing: URLError(.networkConnectionLost))
                    } else {
                        c.yield(fullPayload)
                        c.finish()
                    }
                }
                return (200, ["content-length": "\(fullPayload.count)"], stream)
            }
        )
        defer { Task { await server.shutdown() } }

        let destURL = await cacheStore.cacheFileURL(trackId: "track-1", originalFileName: "aria.flac")
        let streamURL = await server.registerSource(
            StreamSourceRegistration(
                accountHash: "acctA",
                trackId: "track-1",
                remoteURL: URL(string: "https://media.example.invalid/aria.flac")!,
                cacheDestinationURL: destURL,
                expectedSize: UInt64(fullPayload.count),
                fileName: "aria.flac",
                cacheLimitBytes: 256 * 1024 * 1024
            ),
            cacheStore: cacheStore
        )

        // 1) AVPlayer-style bytes=0-1 probe MUST NOT cache 2 bytes
        var probeReq = URLRequest(url: streamURL)
        probeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (probeData, probeResp) = try await URLSession.shared.data(for: probeReq)
        #expect((probeResp as? HTTPURLResponse)?.statusCode == 206)
        #expect(probeData.count == 2)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await cacheStore.existingCachedFile(trackId: "track-1") == nil)

        // 2) Full stream drops at 3000 bytes, resumes with 206 from 3000, delivers exact 8192 bytes & caches!
        let (fullData, fullResp) = try await URLSession.shared.data(from: streamURL)
        #expect((fullResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(fullData == fullPayload)
        try await Task.sleep(for: .milliseconds(80))
        let cachedURL = try #require(await cacheStore.existingCachedFile(trackId: "track-1"))
        #expect(try Data(contentsOf: cachedURL) == fullPayload)

        // 3) Upstream ignoring Range and returning 200 OK on non-zero resume MUST be rejected!
        #expect(throws: CloudTuneError.self) {
            try RangeHeaderValidator.validateResumeResponse(
                expectedStartOffset: 4096,
                statusCode: 200,
                contentRangeHeader: nil
            )
        }
        #expect(throws: CloudTuneError.self) {
            try RangeHeaderValidator.validateResumeResponse(
                expectedStartOffset: 4096,
                statusCode: 206,
                contentRangeHeader: "bytes 0-8191/8192"
            )
        }
    }

    @Test("GlobalTransferSemaphore enforces <= 8 peak concurrent permits under 24 parallel tasks")
    func verifyGlobalConcurrencyCap() async throws {
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await semaphore.withPermit {
                        try await Task.sleep(for: .milliseconds(15))
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await semaphore.peakObservedPermits
        let remaining = await semaphore.activePermits
        #expect(peak <= 8)
        #expect(peak >= 2)
        #expect(remaining == 0)
    }

    @Test("Playback policy: 16 MiB timeout bypass and immediate stop on unsupported local codec")
    func verifyPlaybackDecisionAndFailurePolicy() {
        let largeSize: UInt64 = 48 * 1024 * 1024
        #expect(PlaybackDecisionPolicy.shouldDownloadBeforePlayback(mode: .streamCache, sizeBytes: largeSize, forceStreamProxy: false) == true)
        #expect(PlaybackDecisionPolicy.shouldDownloadBeforePlayback(mode: .streamCache, sizeBytes: largeSize, forceStreamProxy: true) == false)

        let timeoutFallback = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName: "symphony.flac",
            wasLoopbackStream: false,
            wasDownloadPhaseTimeout: true,
            isDecodeOrFormatUnsupported: false,
            priorAttemptCount: 0
        )
        #expect(timeoutFallback == .fallbackToStreamProxyOnce)

        let streamDecodeFallback = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName: "symphony.flac",
            wasLoopbackStream: true,
            wasDownloadPhaseTimeout: false,
            isDecodeOrFormatUnsupported: true,
            priorAttemptCount: 0
        )
        #expect(streamDecodeFallback == .fallbackToFullDownloadOnce)

        let localUnsupported = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName: "archive_session.ape",
            wasLoopbackStream: false,
            wasDownloadPhaseTimeout: false,
            isDecodeOrFormatUnsupported: true,
            priorAttemptCount: 0
        )
        if case let .stopImmediatelyUnsupportedCodec(msg) = localUnsupported {
            #expect(msg.contains(".ape"))
        } else {
            Issue.record("Expected immediate stop for unsupported local .ape file")
        }
    }

    @Test("Account A/B storage isolation and logout stream revocation")
    func verifyAccountIsolationAndLogoutRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-acct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AccountScopedStore(rootDirectory: root)
        let trackA = TrackSummary(id: "a1", name: "AliceSong.flac", folderPath: "MusicA", sizeBytes: 1024)
        let trackB = TrackSummary(id: "b1", name: "BobSong.flac", folderPath: "MusicB", sizeBytes: 2048)

        try await store.saveLibrary([trackA], for: "alice@example.invalid")
        try await store.saveLibrary([trackB], for: "bob@example.invalid")

        let loadedA = try await store.loadLibrary(for: "alice@example.invalid")
        let loadedB = try await store.loadLibrary(for: "bob@example.invalid")
        #expect(loadedA == [trackA])
        #expect(loadedB == [trackB])

        let sem = GlobalTransferSemaphore(maxPermits: 8)
        let server = try StreamProxyServer(
            semaphore: sem,
            fetcher: MockUpstreamFetcher { _, _ in
                let s = AsyncThrowingStream<Data, Error> { c in c.yield(Data("ok".utf8)); c.finish() }
                return (200, ["content-length": "2"], s)
            }
        )
        defer { Task { await server.shutdown() } }

        let pathsA = try await store.paths(for: "alice@example.invalid")
        let cacheA = try CacheStore(cacheDirectory: pathsA.cacheDir)
        let urlA = await server.registerSource(
            StreamSourceRegistration(
                accountHash: pathsA.bucketHash,
                trackId: "a1",
                remoteURL: URL(string: "https://media.example.invalid/a1.flac")!,
                cacheDestinationURL: pathsA.cacheDir.appendingPathComponent("a1.flac"),
                expectedSize: 2,
                fileName: "a1.flac",
                cacheLimitBytes: 256 * 1024 * 1024
            ),
            cacheStore: cacheA
        )

        await server.revokeAllSources(forAccountHash: pathsA.bucketHash)
        let (_, revokedResp) = try await URLSession.shared.data(from: urlA)
        #expect((revokedResp as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Keychain CredentialStateMachine handles DarkWake deferral without false logout or retry loops")
    func verifyKeychainStateMachine() throws {
        let backend = MockKeychainBackend()
        var machine = CredentialStateMachine()

        // DarkWake deferred error must NOT mark missing and must suppress non-GUI / cooldown retries
        backend.nextReadResult = .deferredBySystem(KeychainLoadResult.cssmErrCSPInDarkWake)
        let t0 = Date()
        let first = machine.load(isInteractiveGUI: false, now: t0, backend: backend)
        #expect(first.credential == nil)
        #expect(first.issue == .deferredBySystem(status: KeychainLoadResult.cssmErrCSPInDarkWake))
        #expect(machine.isKnownMissing == false)
        #expect(backend.readCallCount == 1)

        // Cooldown suppresses repeated interactive call 1s later
        let suppressed = machine.load(isInteractiveGUI: true, now: t0.addingTimeInterval(1.0), backend: backend)
        #expect(suppressed.issue == .deferredBySystem(status: KeychainLoadResult.cssmErrCSPInDarkWake))
        #expect(backend.readCallCount == 1)

        //After cooldown expires and system unlocks, credential loads cleanly
        let cred = try #require(PersistedRefreshCredential(refreshToken: "rt_valid", accountName: "alice@example.invalid"))
        backend.nextReadResult = .found(cred)
        let recovered = machine.load(isInteractiveGUI: true, now: t0.addingTimeInterval(4.0), backend: backend)
        #expect(recovered.credential == cred)
        #expect(recovered.issue == nil)
        #expect(backend.readCallCount == 2)
    }

    @Test("GlobalTransferSemaphore never leaks permits when queued waiters cancel or release is called extra times")
    func verifySemaphoreWaiterCancellationNoPermitLeak() async throws {
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        for _ in 0..<8 {
            try await semaphore.acquire()
        }
        #expect(await semaphore.activePermits == 8)

        var waiterTasks: [Task<Void, Error>] = []
        for _ in 0..<16 {
            waiterTasks.append(Task {
                try await semaphore.acquire()
                await semaphore.release()
            })
        }
        try await Task.sleep(for: .milliseconds(30))
        for task in waiterTasks {
            task.cancel()
        }
        for task in waiterTasks {
            _ = await task.result
        }

        for _ in 0..<10 {
            await semaphore.release()
        }
        #expect(await semaphore.activePermits == 0)

        // All 8 permits must still be acquirable without deadlock
        for _ in 0..<8 {
            try await semaphore.acquire()
        }
        #expect(await semaphore.activePermits == 8)
        for _ in 0..<8 {
            await semaphore.release()
        }
        #expect(await semaphore.activePermits == 0)
    }

    @Test("TransferEngine restores cross-restart partial downloads, refreshes 403 URLs without double-releasing permits, and tracks stream speed")
    func verifyTransferEngineCrossRestartResumeAnd403Refresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-transfer-\(UUID().uuidString)")
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportDir)
        }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let store = try AccountScopedStore(rootDirectory: root)
        let accountId = "alice@example.invalid"
        let paths = try await store.paths(for: accountId)
        let payloadSize = 600_000
        let payload = Data((0..<payloadSize).map { UInt8(($0 * 7) & 0xFF) })

        // Pre-stage a 2-part paused manifest where part 00 is 100% done and part 01 is 50% done
        let taskId = "download:resume-test-01"
        let safeKey = Cloud189Protocol.sanitizeFileName(taskId)
        let partsDir = paths.stagingDir.appendingPathComponent("\(safeKey).parts", isDirectory: true)
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        try payload.subdata(in: 0..<300_000).write(to: partsDir.appendingPathComponent("00.part"))
        try payload.subdata(in: 300_000..<450_000).write(to: partsDir.appendingPathComponent("01.part"))

        let savedManifest = StagedDownloadManifest(
            taskId: taskId,
            accountId: accountId,
            trackId: "track-resumable",
            fileName: "ResumableConcert.flac",
            relativeExportSubpath: "ResumableConcert.flac",
            totalSize: UInt64(payloadSize),
            partCount: 2,
            state: "running"
        )
        try JSONEncoder().encode([savedManifest]).write(to: paths.transfersURL)

        actor RefreshTracker {
            var resolverCalls = 0
            var returned403Once = false
            var observedRanges: [String] = []
            func nextURL() -> URL {
                resolverCalls += 1
                if resolverCalls == 1 {
                    return URL(string: "https://media.example.invalid/expired/track.flac")!
                }
                return URL(string: "https://media.example.invalid/fresh/track.flac")!
            }
            func recordRange(_ range: String?) {
                if let range { observedRanges.append(range) }
            }
            func shouldReturn403(for url: URL, range: String?) -> Bool {
                if range != "bytes=0-0", url.absoluteString.contains("expired"), !returned403Once {
                    returned403Once = true
                    return true
                }
                return false
            }
        }
        let tracker = RefreshTracker()
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        let engine = TransferEngine(
            semaphore: semaphore,
            fetcher: MockUpstreamFetcher { url, rangeHeader in
                await tracker.recordRange(rangeHeader)
                if await tracker.shouldReturn403(for: url, range: rangeHeader) {
                    let empty = AsyncThrowingStream<Data, Error> { $0.finish() }
                    return (403, [:], empty)
                }
                if rangeHeader == "bytes=0-0" {
                    let s = AsyncThrowingStream<Data, Error> { $0.yield(payload.subdata(in: 0..<1)); $0.finish() }
                    return (206, ["content-range": "bytes 0-0/\(payloadSize)", "content-length": "1"], s)
                }
                let parsed = try #require(RangeHeaderValidator.parseRequestRange(rangeHeader))
                let start = Int(parsed.start)
                let end = Int(parsed.end ?? UInt64(payloadSize - 1))
                let slice = payload.subdata(in: start..<(end + 1))
                let s = AsyncThrowingStream<Data, Error> { $0.yield(slice); $0.finish() }
                return (
                    206,
                    ["content-range": "bytes \(start)-\(end)/\(payloadSize)", "content-length": "\(slice.count)"],
                    s
                )
            },
            urlResolver: { _ in
                await tracker.nextURL()
            }
        )

        await engine.restorePersistedDownloads(for: accountId, accountStore: store)
        let restoredSnap = await engine.snapshot()
        let restoredItem = try #require(restoredSnap.items.first { $0.id == taskId })
        #expect(restoredItem.state == "paused")
        #expect(restoredItem.canResume == true)
        #expect(restoredItem.transferredBytes == 450_000)

        await engine.resumeTransfer(id: taskId, explicitDirectoryURL: exportDir, accountStore: store)
        for _ in 0..<40 {
            let snap = await engine.snapshot()
            if snap.items.first(where: { $0.id == taskId })?.state == "completed" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let finalSnap = await engine.snapshot()
        let finalItem = try #require(finalSnap.items.first { $0.id == taskId })
        #expect(finalItem.state == "completed")
        #expect(await semaphore.activePermits == 0)
        #expect(await semaphore.peakObservedPermits <= 8)

        let exportedData = try Data(contentsOf: exportDir.appendingPathComponent("ResumableConcert.flac"))
        #expect(exportedData == payload)
        #expect(await tracker.returned403Once == true)
        #expect(await tracker.resolverCalls == 2)
        let ranges = await tracker.observedRanges
        #expect(ranges.contains("bytes=450000-599999"))
        #expect(!ranges.contains("bytes=0-299999"))
    }
}
