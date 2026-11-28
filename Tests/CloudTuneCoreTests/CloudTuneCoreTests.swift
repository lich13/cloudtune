import CloudTuneCore
import Darwin
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

    @Test("Export target safety: rejects directory targets and preserves existing file when copy fails")
    func verifyExportTargetSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-exp-safe-\(UUID().uuidString)")
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-exp-out-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportDir)
        }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let store = try AccountScopedStore(rootDirectory: root)
        let staged = root.appendingPathComponent("staged.flac")
        let newContent = Data("new-audio-payload".utf8)
        try newContent.write(to: staged)

        // 1) Directory collision MUST throw and NEVER delete the directory or its child files
        let dirCollision = exportDir.appendingPathComponent("Collision.flac", isDirectory: true)
        try FileManager.default.createDirectory(at: dirCollision, withIntermediateDirectories: true)
        let childInsideDir = dirCollision.appendingPathComponent("keep.txt")
        try Data("precious".utf8).write(to: childInsideDir)

        await #expect(throws: CloudTuneError.self) {
            _ = try await store.exportStagedFile(
                stagedFileURL: staged,
                relativeSubpath: "Collision.flac",
                explicitDirectoryURL: exportDir,
                for: "alice@example.invalid"
            )
        }
        #expect(FileManager.default.fileExists(atPath: childInsideDir.path))

        // 2) Copy failure (missing staged file) MUST preserve existing destination file intact
        let existingTarget = exportDir.appendingPathComponent("Existing.flac")
        let oldContent = Data("original-intact-file".utf8)
        try oldContent.write(to: existingTarget)
        let missingStaged = root.appendingPathComponent("nonexistent-source.flac")

        await #expect(throws: CloudTuneError.self) {
            _ = try await store.exportStagedFile(
                stagedFileURL: missingStaged,
                relativeSubpath: "Existing.flac",
                explicitDirectoryURL: exportDir,
                for: "alice@example.invalid"
            )
        }
        #expect(try Data(contentsOf: existingTarget) == oldContent)

        // 3) Valid staged replacement atomically updates target and leaves no temporary sibling files
        let replacedURL = try await store.exportStagedFile(
            stagedFileURL: staged,
            relativeSubpath: "Existing.flac",
            explicitDirectoryURL: exportDir,
            for: "alice@example.invalid"
        )
        #expect(try Data(contentsOf: replacedURL) == newContent)
        let children = try FileManager.default.contentsOfDirectory(atPath: exportDir.path)
        #expect(!children.contains { $0.contains(".tmp") })

        // 4) Path traversal segments (".." / ".") are neutralized and NEVER escape exportDir
        #expect(Cloud189Protocol.sanitizeFileName("..") == "_")
        #expect(Cloud189Protocol.sanitizeFileName(".") == "_")
        let parentCanary = exportDir.deletingLastPathComponent().appendingPathComponent("cloudtune-outside-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: parentCanary) }
        let safeExported = try await store.exportStagedFile(
            stagedFileURL: staged,
            relativeSubpath: "../../\(parentCanary.lastPathComponent)",
            explicitDirectoryURL: exportDir,
            for: "alice@example.invalid"
        )
        #expect(safeExported.standardizedFileURL.path.hasPrefix(exportDir.standardizedFileURL.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: parentCanary.path))
    }

    @Test("Cross-origin redirect blocks auth header, cookie, and POST token leaks; API status & fileListAO validated")
    func verifyCrossOriginRedirectProtectionAndApiValidation() async throws {
        // 1) Origin classification checks
        #expect(Cloud189Protocol.isTrustedTianyiOrigin(URL(string: "https://api.cloud.189.cn/listFiles.action")!) == true)
        #expect(Cloud189Protocol.isTrustedTianyiOrigin(URL(string: "https://open.e.189.cn/api/oauth2/refreshToken.do")!) == true)
        #expect(Cloud189Protocol.isTrustedTianyiOrigin(URL(string: "http://api.cloud.189.cn/listFiles.action")!) == false)
        #expect(Cloud189Protocol.isTrustedTianyiOrigin(URL(string: "https://cloud.189.cn.evil.invalid/steal")!) == false)
        #expect(Cloud189Protocol.isTrustedTianyiOrigin(URL(string: "https://api.cloud.189.cn:8443/listFiles.action")!) == false)

        // 2) Real loopback redirect server: 307 cross-origin redirect MUST NOT contact untrusted target
        let targetHitCount = LockedBox(0)
        let targetServer = try OneShotLoopbackServer { _ in
            targetHitCount.withValue { $0 += 1 }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        }
        defer { targetServer.close() }

        let originServer = try OneShotLoopbackServer { [targetPort = targetServer.port] _ in
            let resp = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(targetPort)/collect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return Data(resp.utf8)
        }
        defer { originServer.close() }

        let transport = URLSessionCloudHTTPTransport()
        if let cookie = HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "SESSIONID",
            .value: "secret_cookie"
        ]) {
            await transport.importCookies([cookie])
        }
        var postReq = URLRequest(url: URL(string: "http://127.0.0.1:\(originServer.port)/api/oauth2/refreshToken.do")!)
        postReq.httpMethod = "POST"
        postReq.setValue("sk_secret", forHTTPHeaderField: "SessionKey")
        postReq.setValue("sig_secret", forHTTPHeaderField: "Signature")
        postReq.httpBody = Data("refreshToken=rt_super_secret".utf8)

        await #expect(throws: CloudTuneError.self) {
            _ = try await transport.send(postReq)
        }
        #expect(targetHitCount.withValue { $0 } == 0)

        // 3) Non-2xx JSON and missing fileListAO MUST throw in Cloud189Client
        struct MockTransport: CloudHTTPTransport {
            let statusCode: Int
            let bodyText: String
            func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
                if request.url?.path.contains("getSessionForPC.action") == true {
                    let s = #"{"res_code":0,"loginName":"alice@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(s.utf8), finalURL: request.url!)
                }
                return CloudHTTPResponse(statusCode: statusCode, body: Data(bodyText.utf8), finalURL: request.url!)
            }
            func importCookies(_ cookies: [HTTPCookie]) async {}
            func clearCookies() async {}
        }

        let gateway502Client = Cloud189Client(transport: MockTransport(statusCode: 502, bodyText: "{}"))
        _ = try await gateway502Client.exchangeRedirectForSession(redirectURL: "https://m.cloud.189.cn/cb?paras=1")
        await #expect(throws: CloudTuneError.self) {
            _ = try await gateway502Client.listRemoteFolder(folderId: nil)
        }

        let missingAOClient = Cloud189Client(transport: MockTransport(statusCode: 200, bodyText: #"{"res_code":0}"#))
        _ = try await missingAOClient.exchangeRedirectForSession(redirectURL: "https://m.cloud.189.cn/cb?paras=1")
        await #expect(throws: CloudTuneError.self) {
            _ = try await missingAOClient.scanMusicLibrary(folderId: "f1", folderName: "Music")
        }
    }

    @Test("Completed download status isolation across accounts, zero PII in transfers.json, and coalesced prefetch+playback")
    func verifyCompletedDownloadIsolationZeroPiiAndCoalescing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-iso-\(UUID().uuidString)")
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-iso-exp-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportDir)
        }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let store = try AccountScopedStore(rootDirectory: root)
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let probeCalls = LockedBox(0)

        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        let engine = TransferEngine(
            semaphore: semaphore,
            fetcher: MockUpstreamFetcher { _, rangeHeader in
                if rangeHeader == "bytes=0-0" {
                    probeCalls.withValue { $0 += 1 }
                    let s = AsyncThrowingStream<Data, Error> {
                        $0.yield(payload.subdata(in: 0..<1))
                        $0.finish()
                    }
                    return (206, ["content-range": "bytes 0-0/\(payload.count)", "content-length": "1"], s)
                }
                let s = AsyncThrowingStream<Data, Error> { cont in
                    Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        cont.yield(payload)
                        cont.finish()
                    }
                }
                return (200, ["content-length": "\(payload.count)"], s)
            },
            urlResolver: { _ in URL(string: "https://media.example.invalid/song.flac")! }
        )

        // 1) Enqueue download for Alice, check transfers.json contains ZERO PII before completion
        let aliceId = "alice_private_13800138000@example.invalid"
        let track = TrackSummary(id: "t-coalesce", name: "SharedTrack.flac", folderPath: "Music", sizeBytes: UInt64(payload.count))
        let taskId = try await engine.enqueueExportDownload(
            accountId: aliceId,
            track: track,
            relativeExportSubpath: "SharedTrack.flac",
            parallelThreads: 2,
            explicitDirectoryURL: exportDir,
            accountStore: store
        )
        let alicePaths = try await store.paths(for: aliceId)
        if let rawTransfers = try? String(contentsOf: alicePaths.transfersURL, encoding: .utf8) {
            #expect(!rawTransfers.contains("alice_private"))
            #expect(!rawTransfers.contains("13800138000"))
        }

        for _ in 0..<40 {
            if await engine.snapshot().items.first(where: { $0.id == taskId })?.state == "completed" {
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await engine.snapshot().items.first(where: { $0.id == taskId })?.state == "completed")

        // Purging Alice on logout MUST remove completed downloads too so Bob never sees them
        await engine.cancelAll(forAccountId: aliceId)
        #expect(await engine.snapshot().items.isEmpty)

        // 2) Concurrent prefetch + playback downloadTrackToCache coalesces onto a single upstream download
        probeCalls.withValue { $0 = 0 }
        let cacheStore = try CacheStore(cacheDirectory: alicePaths.cacheDir)
        async let prefetchURL = engine.downloadTrackToCache(
            track: track,
            cacheStore: cacheStore,
            parallelThreads: 4,
            cacheLimitBytes: 256 * 1024 * 1024,
            kind: "prefetch",
            accountHash: alicePaths.bucketHash
        )
        try await Task.sleep(for: .milliseconds(15))
        async let playbackURL = engine.downloadTrackToCache(
            track: track,
            cacheStore: cacheStore,
            parallelThreads: 8,
            cacheLimitBytes: 256 * 1024 * 1024,
            kind: "playback",
            accountHash: alicePaths.bucketHash
        )
        let (u1, u2) = try await (prefetchURL, playbackURL)
        #expect(u1 == u2)
        #expect(try Data(contentsOf: u1) == payload)
        #expect(probeCalls.withValue { $0 } == 1)

        // 3) Cancelling prefetch right before starting playback MUST NOT delete new worker's .parts shards
        let raceTrack = TrackSummary(id: "t-cancel-race", name: "CancelRace.flac", folderPath: "Music", sizeBytes: UInt64(payload.count))
        let cancelledPrefetch = Task {
            try await engine.downloadTrackToCache(
                track: raceTrack,
                cacheStore: cacheStore,
                parallelThreads: 2,
                cacheLimitBytes: 256 * 1024 * 1024,
                kind: "prefetch",
                accountHash: alicePaths.bucketHash
            )
        }
        try await Task.sleep(for: .milliseconds(15))
        cancelledPrefetch.cancel()
        let immediatePlaybackURL = try await engine.downloadTrackToCache(
            track: raceTrack,
            cacheStore: cacheStore,
            parallelThreads: 4,
            cacheLimitBytes: 256 * 1024 * 1024,
            kind: "playback",
            accountHash: alicePaths.bucketHash
        )
        _ = await cancelledPrefetch.result
        #expect(try Data(contentsOf: immediatePlaybackURL) == payload)
    }

    @Test("Active stream connection tears down immediately on logout without committing cache, and pull fetcher streams cleanly")
    func verifyActiveStreamLogoutTeardownAndPullFetcher() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-teardown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheStore = try CacheStore(cacheDirectory: tempDir)
        let fullPayload = Data((0..<65_536).map { UInt8($0 & 0xFF) })

        // 1) Pull-based URLSessionUpstreamStreamFetcher reads multi-chunk HTTP response accurately
        let upstreamHTTP = try OneShotLoopbackServer { _ in
            var header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(fullPayload.count)\r\nConnection: close\r\n\r\n".utf8)
            header.append(fullPayload)
            return header
        }
        defer { upstreamHTTP.close() }
        let pullFetcher = URLSessionUpstreamStreamFetcher()
        let opened = try await pullFetcher.openStream(
            url: URL(string: "http://127.0.0.1:\(upstreamHTTP.port)/track.flac")!,
            rangeHeader: nil
        )
        #expect(opened.statusCode == 200)
        var assembled = Data()
        for try await chunk in opened.chunks {
            assembled.append(chunk)
        }
        #expect(assembled == fullPayload)

        // 2) Active mid-flight stream tears down immediately on revokeAllSources without writing cache
        let firstChunkSent = LockedBox(false)
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        let proxy = try StreamProxyServer(
            semaphore: semaphore,
            fetcher: MockUpstreamFetcher { _, _ in
                let stream = AsyncThrowingStream<Data, Error> { cont in
                    let task = Task {
                        cont.yield(fullPayload.subdata(in: 0..<16_384))
                        firstChunkSent.withValue { $0 = true }
                        try? await Task.sleep(for: .seconds(10))
                        cont.yield(fullPayload.subdata(in: 16_384..<fullPayload.count))
                        cont.finish()
                    }
                    cont.onTermination = { _ in task.cancel() }
                }
                return (200, ["content-length": "\(fullPayload.count)"], stream)
            }
        )
        defer { Task { await proxy.shutdown() } }

        let destURL = await cacheStore.cacheFileURL(trackId: "live-1", originalFileName: "live.flac")
        let streamURL = await proxy.registerSource(
            StreamSourceRegistration(
                accountHash: "acctLive",
                trackId: "live-1",
                remoteURL: URL(string: "https://media.example.invalid/live.flac")!,
                cacheDestinationURL: destURL,
                expectedSize: UInt64(fullPayload.count),
                fileName: "live.flac",
                cacheLimitBytes: 256 * 1024 * 1024
            ),
            cacheStore: cacheStore
        )

        let clientTask = Task<Int, Never> {
            guard let (bytes, _) = try? await URLSession.shared.bytes(from: streamURL) else {
                return 0
            }
            var count = 0
            do {
                for try await _ in bytes {
                    count += 1
                }
            } catch {
                return count
            }
            return count
        }

        for _ in 0..<50 {
            if firstChunkSent.withValue({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let revokeStart = ContinuousClock.now
        await proxy.revokeAllSources(forAccountHash: "acctLive")
        let receivedBytes = await clientTask.value
        let elapsed = revokeStart.duration(to: .now)
        #expect(elapsed < .seconds(2))
        #expect(receivedBytes < fullPayload.count)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cacheStore.existingCachedFile(trackId: "live-1") == nil)
        #expect(!FileManager.default.fileExists(atPath: destURL.path))
    }

    @Test("Legacy Tauri macOS migration supports flat com.gosu.cloudtune root, threads, and never overwrites existing account data")
    func verifyLegacyTauriFlatRootMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let legacySettings = """
        {
          "refreshToken": "rt_legacy_gosu",
          "accountName": "legacy_user@example.invalid",
          "musicFolderId": "f-legacy-99",
          "musicFolderName": "经典无损收藏",
          "cacheLimitMb": 4096,
          "downloadThreads": 12,
          "cacheThreads": 6,
          "playbackMode": "stream_cache"
        }
        """
        let legacyLibrary = """
        [{"id":"t-leg-1","name":"LegacySong.flac","folderPath":"经典无损收藏","sizeBytes":12345}]
        """
        try Data(legacySettings.utf8).write(to: root.appendingPathComponent("settings.json"))
        try Data(legacyLibrary.utf8).write(to: root.appendingPathComponent("library.json"))

        let store = try AccountScopedStore(rootDirectory: root)
        let migratedCred = try #require(await store.migrateLegacyTauriDataIfPresent())
        #expect(migratedCred.refreshToken == "rt_legacy_gosu")
        #expect(migratedCred.accountName == "legacy_user@example.invalid")

        let migratedSettings = try await store.loadSettings(for: "legacy_user@example.invalid")
        #expect(migratedSettings.musicFolder == FolderSelection(id: "f-legacy-99", name: "经典无损收藏"))
        #expect(migratedSettings.cacheLimitMb == 4096)
        #expect(migratedSettings.downloadThreads == 12)
        #expect(migratedSettings.cacheThreads == 6)
        #expect(migratedSettings.playbackMode == .streamCache)

        let migratedTracks = try await store.loadLibrary(for: "legacy_user@example.invalid")
        #expect(migratedTracks.count == 1)
        #expect(migratedTracks.first?.name == "LegacySong.flac")

        // Existing account data MUST NOT be overwritten by migration
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-mig2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root2) }
        let store2 = try AccountScopedStore(rootDirectory: root2)
        let preExistingSettings = AccountSettings(cacheLimitMb: 8192, downloadThreads: 4, cacheThreads: 2, playbackMode: .downloadFirst)
        try await store2.saveSettings(preExistingSettings, for: "legacy_user@example.invalid")
        try await store2.saveLibrary([TrackSummary(id: "new-1", name: "NewTrack.flac", folderPath: "New", sizeBytes: 99)], for: "legacy_user@example.invalid")
        try Data(legacySettings.utf8).write(to: root2.appendingPathComponent("settings.json"))
        try Data(legacyLibrary.utf8).write(to: root2.appendingPathComponent("library.json"))

        _ = await store2.migrateLegacyTauriDataIfPresent()
        #expect(try await store2.loadSettings(for: "legacy_user@example.invalid").cacheLimitMb == 8192)
        #expect(try await store2.loadLibrary(for: "legacy_user@example.invalid").first?.id == "new-1")

        // Logged-out flat root settings.json MUST NOT shadow portable candidate that holds live refreshToken
        let root3 = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-mig3-\(UUID().uuidString)")
        let portable3 = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-port3-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root3)
            try? FileManager.default.removeItem(at: portable3)
        }
        try FileManager.default.createDirectory(at: root3, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: portable3, withIntermediateDirectories: true)
        try Data(#"{"refreshToken":null,"cacheLimitMb":1024}"#.utf8).write(to: root3.appendingPathComponent("settings.json"))
        try Data(legacySettings.utf8).write(to: portable3.appendingPathComponent("settings.json"))
        let store3 = try AccountScopedStore(rootDirectory: root3)
        let picked = try #require(await store3.migrateLegacyTauriDataIfPresent(candidateRoots: [root3, portable3]))
        #expect(picked.refreshToken == "rt_legacy_gosu")
    }

    @Test("Slice 0: AccountSettings appearance backward compatibility, PlaybackQueueResolver, write-through callback, and on-demand TransferEngine notifications")
    func verifyQueueResolverAppearanceCompatWriteThroughCallbackAndTransferActivity() async throws {
        // 1) Legacy settings JSON without appearanceMode/dynamicColorEnabled decodes cleanly; ModuleTab maps legacy "download" -> .transfers
        let legacyJSON = Data(#"{"cacheLimitMb":2048,"downloadThreads":6,"cacheThreads":3,"playbackMode":"stream_cache"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(AccountSettings.self, from: legacyJSON)
        #expect(decodedLegacy.appearanceMode == .system)
        #expect(decodedLegacy.dynamicColorEnabled == false)
        #expect(decodedLegacy.cacheLimitMb == 2048)

        let updatedSettings = AccountSettings(
            cacheLimitMb: 4096,
            downloadThreads: 8,
            cacheThreads: 4,
            playbackMode: .streamCache,
            appearanceMode: .dark,
            dynamicColorEnabled: true
        )
        let encodedUpdated = try JSONEncoder().encode(updatedSettings)
        let roundTripped = try JSONDecoder().decode(AccountSettings.self, from: encodedUpdated)
        #expect(roundTripped.appearanceMode == .dark)
        #expect(roundTripped.dynamicColorEnabled == true)

        let legacyTab = try JSONDecoder().decode(ModuleTab.self, from: Data(#""download""#.utf8))
        #expect(legacyTab == .transfers)

        // 2) PlaybackQueueResolver: Play Next FIFO priority, LoopMode.off boundaries, LoopMode.all wrap, and ad-hoc cloud track
        let t1 = TrackSummary(id: "t1", name: "01.flac", folderPath: "A", sizeBytes: 100)
        let t2 = TrackSummary(id: "t2", name: "02.wav", folderPath: "A", sizeBytes: 100)
        let t3 = TrackSummary(id: "t3", name: "03.mp3", folderPath: "A", sizeBytes: 100)
        let cloudOnly = TrackSummary(id: "cloud-x", name: "Preview.flac", folderPath: "Cloud", sizeBytes: 100)
        #expect(t1.isLosslessAudio == true)
        #expect(t2.isLosslessAudio == true)
        #expect(t3.isLosslessAudio == false)

        let lib = [t1, t2, t3]
        var upNext = PlaybackQueueResolver.insertPlayNext(upNext: [], track: t3)
        upNext = PlaybackQueueResolver.insertPlayNext(upNext: upNext, track: t2)
        #expect(upNext.map(\.id) == ["t2", "t3"])

        let step1 = PlaybackQueueResolver.resolveNext(
            currentTrack: t1,
            libraryTracks: lib,
            upNextQueue: upNext,
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .off
        )
        #expect(step1.track?.id == "t2")
        #expect(step1.remainingUpNext.map(\.id) == ["t3"])

        // At end of list: LoopMode.off disables skip next; LoopMode.all wraps to t1
        #expect(PlaybackQueueResolver.canSkipNext(
            currentTrack: t3,
            libraryTracks: lib,
            upNextQueue: [],
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .off
        ) == false)
        #expect(PlaybackQueueResolver.canSkipPrevious(
            currentTrack: t1,
            libraryTracks: lib,
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .off
        ) == false)
        #expect(PlaybackQueueResolver.resolveNext(
            currentTrack: t3,
            libraryTracks: lib,
            upNextQueue: [],
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .all
        ).track?.id == "t1")

        // Ad-hoc cloud track not in libraryTracks still steps cleanly into libraryTracks
        #expect(PlaybackQueueResolver.resolveNext(
            currentTrack: cloudOnly,
            libraryTracks: lib,
            upNextQueue: [],
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .off
        ).track?.id == "t1")

        // upcomingPreview anchors library continuation on upNextQueue.last ?? currentTrack (matching resolveNext)
        let previewOff = PlaybackQueueResolver.upcomingPreview(
            currentTrack: t1,
            libraryTracks: lib,
            upNextQueue: [t3],
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .off
        )
        #expect(previewOff.map(\.id) == ["t3"])

        let previewAll = PlaybackQueueResolver.upcomingPreview(
            currentTrack: t1,
            libraryTracks: lib,
            upNextQueue: [t3],
            shuffle: false,
            shuffleOrderIds: [],
            loopMode: .all
        )
        #expect(previewAll.map(\.id) == ["t3", "t2"])

        // Concurrent AccountScopedStore.mutateSettings serializes read-modify-write without losing fields
        let concurrentRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-mut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: concurrentRoot) }
        let concurrentStore = try AccountScopedStore(rootDirectory: concurrentRoot)
        let acctId = "concurrent@example.invalid"
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await concurrentStore.mutateSettings(for: acctId) { $0.appearanceMode = .dark }
            }
            group.addTask {
                _ = try await concurrentStore.mutateSettings(for: acctId) { $0.playbackMode = .streamCache }
            }
            group.addTask {
                _ = try await concurrentStore.mutateSettings(for: acctId) { $0.cacheLimitMb = 4096 }
            }
            group.addTask {
                _ = try await concurrentStore.mutateSettings(for: acctId) {
                    $0.downloadThreads = 14
                    $0.cacheThreads = 7
                }
            }
            group.addTask {
                _ = try await concurrentStore.mutateSettings(for: acctId) {
                    $0.musicFolder = FolderSelection(id: "m-1", name: "Lossless")
                }
            }
            try await group.waitForAll()
        }
        let merged = try await concurrentStore.loadSettings(for: acctId)
        #expect(merged.appearanceMode == .dark)
        #expect(merged.playbackMode == .streamCache)
        #expect(merged.cacheLimitMb == 4096)
        #expect(merged.downloadThreads == 14)
        #expect(merged.cacheThreads == 7)
        #expect(merged.musicFolder == FolderSelection(id: "m-1", name: "Lossless"))

        // 3) StreamProxyServer onWriteThroughCompleted fires ONLY on full write-through, never on bytes=0-1 probe
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheStore = try CacheStore(cacheDirectory: tempDir.appendingPathComponent("cache"))
        let payload = Data((0..<8192).map { UInt8($0 & 0xFF) })
        let completedEvents = LockedBox<[(String, String, URL)]>([])
        let semaphore = GlobalTransferSemaphore(maxPermits: 8)
        let proxy = try StreamProxyServer(
            semaphore: semaphore,
            fetcher: MockUpstreamFetcher { _, range in
                if range == "bytes=0-1" {
                    return (
                        206,
                        ["content-range": "bytes 0-1/\(payload.count)", "content-length": "2"],
                        AsyncThrowingStream { c in c.yield(payload.prefix(2)); c.finish() }
                    )
                }
                return (
                    200,
                    ["content-length": "\(payload.count)"],
                    AsyncThrowingStream { c in c.yield(payload); c.finish() }
                )
            },
            onWriteThroughCompleted: { acctHash, tid, url in
                completedEvents.withValue { $0.append((acctHash, tid, url)) }
            }
        )
        let destURL = await cacheStore.cacheFileURL(trackId: "wt-1", originalFileName: "Song.flac")
        let streamURL = await proxy.registerSource(
            StreamSourceRegistration(
                accountHash: "hashA",
                trackId: "wt-1",
                remoteURL: URL(string: "https://media.example.invalid/wt-1.flac")!,
                cacheDestinationURL: destURL,
                expectedSize: UInt64(payload.count),
                fileName: "Song.flac",
                cacheLimitBytes: 64 * 1024 * 1024
            ),
            cacheStore: cacheStore
        )

        var probeReq = URLRequest(url: streamURL)
        probeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (_, _) = try await URLSession.shared.data(for: probeReq)
        try await Task.sleep(for: .milliseconds(30))
        #expect(completedEvents.withValue { $0.isEmpty })

        let (fullBytes, _) = try await URLSession.shared.data(from: streamURL)
        #expect(fullBytes == payload)
        for _ in 0..<20 {
            if completedEvents.withValue({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let recordedEvents = completedEvents.withValue { $0 }
        #expect(recordedEvents.count == 1)
        #expect(recordedEvents.first?.0 == "hashA")
        #expect(recordedEvents.first?.1 == "wt-1")
        await proxy.shutdown()

        // 4) TransferEngine onActivityChange transitions active -> idle cleanly
        let activityTransitions = LockedBox<[Bool]>([])
        let engine = TransferEngine(
            semaphore: semaphore,
            onActivityChange: { _, active in
                activityTransitions.withValue { $0.append(active) }
            },
            urlResolver: { _ in URL(string: "https://media.example.invalid/x")! }
        )
        await engine.updateExternalTransferStatus(
            id: "stream:t1",
            accountHash: "hashA",
            status: TransferStatus(id: "stream:t1", label: "01.flac", kind: "stream", state: "running", bytesPerSecond: 1024)
        )
        #expect(await engine.hasActiveTransfers() == true)
        await engine.updateExternalTransferStatus(id: "stream:t1", accountHash: "hashA", status: nil)
        #expect(await engine.hasActiveTransfers() == false)
        #expect(activityTransitions.withValue { $0 } == [true, false])
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&value) }
    }
}

private final class OneShotLoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let queue: DispatchQueue

    init(responder: @escaping @Sendable (String) -> Data) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CloudTuneError.storageError("socket failed") }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
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
        guard bindRes == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw CloudTuneError.storageError("bind failed")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        self.queue = DispatchQueue(label: "test.loopback.\(self.port)")
        queue.async {
            while true {
                var cAddr = sockaddr_in()
                var cLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let cfd = withUnsafeMutablePointer(to: &cAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &cLen)
                    }
                }
                if cfd < 0 { break }
                var noSigPipe: Int32 = 1
                _ = Darwin.setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var reqBuf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.recv(cfd, &reqBuf, reqBuf.count, 0)
                let reqText = n > 0 ? String(decoding: reqBuf.prefix(n), as: UTF8.self) : ""
                let reply = responder(reqText)
                reply.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        _ = Darwin.send(cfd, base, raw.count, 0)
                    }
                }
                _ = Darwin.shutdown(cfd, SHUT_RDWR)
                Darwin.close(cfd)
            }
        }
    }

    func close() {
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }
}
