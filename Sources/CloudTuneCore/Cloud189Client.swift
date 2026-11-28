import Foundation

public struct CloudHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let finalURL: URL

    public init(statusCode: Int, headers: [String: String] = [:], body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var text: String {
        String(decoding: body, as: UTF8.self)
    }
}

public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CloudHTTPResponse
    func importCookies(_ cookies: [HTTPCookie]) async
    func clearCookies() async
}

private final class PerRequestRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let initialRequest: URLRequest
    private var _blockedError: CloudTuneError?

    init(initialRequest: URLRequest) {
        self.initialRequest = initialRequest
    }

    var blockedError: CloudTuneError? {
        lock.withLock { _blockedError }
    }

    private func recordBlocked(_ error: CloudTuneError) {
        lock.withLock {
            if _blockedError == nil {
                _blockedError = error
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origURL = task.originalRequest?.url ?? initialRequest.url,
              let targetURL = request.url else {
            recordBlocked(.protocolError("重定向地址无效"))
            completionHandler(nil)
            return
        }
        let prevURL = response.url ?? origURL
        let sameOrigin = Cloud189Protocol.isSameOrigin(origURL, targetURL)
            && Cloud189Protocol.isSameOrigin(prevURL, targetURL)
        if sameOrigin {
            completionHandler(request)
            return
        }

        guard Cloud189Protocol.isTrustedTianyiOrigin(targetURL) else {
            recordBlocked(.protocolError("拒绝向非受信域名重定向鉴权请求"))
            completionHandler(nil)
            return
        }

        let isBodyPreservingRedirect = (response.statusCode == 307 || response.statusCode == 308)
        let hadBody = (initialRequest.httpBody != nil)
            || (task.originalRequest?.httpBody != nil)
            || (request.httpBody != nil)
        if isBodyPreservingRedirect && hadBody {
            recordBlocked(.protocolError("拒绝跨源重定向转发鉴权表单请求"))
            completionHandler(nil)
            return
        }

        var sanitized = request
        for sensitiveHeader in ["SessionKey", "Signature", "Authorization", "Cookie", "Reqid", "lt"] {
            sanitized.setValue(nil, forHTTPHeaderField: sensitiveHeader)
        }
        if [301, 302, 303].contains(response.statusCode) {
            sanitized.httpMethod = "GET"
            sanitized.httpBody = nil
            sanitized.setValue(nil, forHTTPHeaderField: "Content-Type")
            sanitized.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        completionHandler(sanitized)
    }
}

public final class URLSessionCloudHTTPTransport: CloudHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession
    private var cookieStorage: HTTPCookieStorage

    private static func makeSessionAndCookieStorage() -> (session: URLSession, cookieStorage: HTTPCookieStorage) {
        let config = URLSessionConfiguration.ephemeral
        let storage = config.httpCookieStorage ?? HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = storage
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = ["User-Agent": Cloud189Constants.userAgent]
        return (URLSession(configuration: config), storage)
    }

    public init() {
        let created = Self.makeSessionAndCookieStorage()
        self.session = created.session
        self.cookieStorage = created.cookieStorage
    }

    public func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        let activeSession = lock.withLock { session }
        let redirectGuard = PerRequestRedirectGuard(initialRequest: request)
        let (data, response) = try await activeSession.data(for: request, delegate: redirectGuard)
        if let blocked = redirectGuard.blockedError {
            throw blocked
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudTuneError.protocolError("非 HTTP 响应")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k)] = String(describing: v)
        }
        return CloudHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            finalURL: http.url ?? request.url!
        )
    }

    public func importCookies(_ cookies: [HTTPCookie]) async {
        lock.withLock {
            for cookie in cookies {
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let isTianyi = domain == "cloud.189.cn"
                    || domain.hasSuffix(".cloud.189.cn")
                    || domain == "e.189.cn"
                    || domain.hasSuffix(".e.189.cn")
                let isLoopback = domain == "127.0.0.1" || domain == "localhost"
                guard isTianyi || isLoopback else { continue }
                cookieStorage.setCookie(cookie)
                if domain == "cloud.189.cn" || domain.hasSuffix(".cloud.189.cn") {
                    var props = cookie.properties ?? [:]
                    props[.domain] = ".cloud.189.cn"
                    props[.path] = "/"
                    if let shared = HTTPCookie(properties: props) {
                        cookieStorage.setCookie(shared)
                    }
                }
            }
        }
    }

    public func clearCookies() async {
        let oldSession = lock.withLock { () -> URLSession in
            let previous = session
            let created = Self.makeSessionAndCookieStorage()
            cookieStorage = created.cookieStorage
            session = created.session
            return previous
        }
        oldSession.invalidateAndCancel()
    }
}

public actor Cloud189Client {
    private struct PendingQrLogin: Sendable {
        let lt: String
        let paramId: String
        let reqId: String
        let uuid: String
        let encryUuid: String
    }

    private let transport: CloudHTTPTransport
    public private(set) var activeSession: ActiveCloudSession?
    public private(set) var persistedCredential: PersistedRefreshCredential?
    private var pendingQr: PendingQrLogin?
    private var sessionEpoch: UInt64 = 0

    public init(transport: CloudHTTPTransport = URLSessionCloudHTTPTransport()) {
        self.transport = transport
    }

    public var currentSessionEpoch: UInt64 {
        sessionEpoch
    }

    public var isAuthenticated: Bool {
        activeSession != nil
    }

    public var accountName: String? {
        activeSession?.loginName ?? persistedCredential?.accountName
    }

    public func clearSession(ifEpoch expectedEpoch: UInt64? = nil) async {
        if let expectedEpoch {
            guard sessionEpoch == expectedEpoch else { return }
        }
        sessionEpoch &+= 1
        activeSession = nil
        persistedCredential = nil
        pendingQr = nil
        await transport.clearCookies()
    }

    public func invalidateInFlightAuth() {
        sessionEpoch &+= 1
        pendingQr = nil
    }

    public func sessionSnapshot(forEpoch expectedEpoch: UInt64?) -> (active: ActiveCloudSession?, persisted: PersistedRefreshCredential?)? {
        if let expectedEpoch, sessionEpoch != expectedEpoch {
            return nil
        }
        return (activeSession, persistedCredential)
    }

    public func importWebCookies(_ cookies: [HTTPCookie]) async {
        await transport.importCookies(cookies)
    }

    /// Cold-start session restoration: only sets `activeSession` AFTER network exchange succeeds.
    public func restoreFromRefreshCredential(_ credential: PersistedRefreshCredential) async throws -> Cloud189Protocol.ParsedSessionPayload {
        try await restoreSessionWithEpoch(credential).payload
    }

    public func restoreSessionWithEpoch(
        _ credential: PersistedRefreshCredential
    ) async throws -> (payload: Cloud189Protocol.ParsedSessionPayload, epoch: UInt64) {
        let startEpoch = sessionEpoch
        var req = URLRequest(url: URL(string: "\(Cloud189Constants.authURL)/api/oauth2/refreshToken.do")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        req.httpBody = formEncoded([
            ("clientId", Cloud189Constants.appId),
            ("refreshToken", credential.refreshToken),
            ("grantType", "refresh_token"),
            ("format", "json")
        ])

        let resp = try await transport.send(req)
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        if let err = Cloud189Protocol.extractAPIErrorMessage(resp.text) {
            throw CloudTuneError.protocolError(err)
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw CloudTuneError.httpStatus(resp.statusCode, "刷新登录态请求失败")
        }
        guard let data = resp.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = Cloud189Protocol.stringValue(json["accessToken"]),
              !accessToken.isEmpty else {
            throw CloudTuneError.protocolError("刷新登录态失败，未拿到 accessToken")
        }
        let nextRefresh = Cloud189Protocol.stringValue(json["refreshToken"]) ?? credential.refreshToken
        let parsed = try await exchangeAccessTokenForSession(
            accessToken: accessToken,
            fallbackRefreshToken: nextRefresh,
            fallbackAccountName: credential.accountName,
            fallbackAccountKey: credential.accountKey
        )
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        sessionEpoch &+= 1
        let committedEpoch = sessionEpoch
        self.activeSession = parsed.activeSession
        self.persistedCredential = parsed.persistedCredential
        return (parsed, committedEpoch)
    }

    public func startQrLogin() async throws -> QrLoginStart {
        let startEpoch = sessionEpoch
        let entryURL = Cloud189Protocol.webLoginEntryURL()
        var initReq = URLRequest(url: entryURL)
        initReq.httpMethod = "GET"
        initReq.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        let initResp = try await transport.send(initReq)
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        guard (200..<300).contains(initResp.statusCode) else {
            throw CloudTuneError.httpStatus(initResp.statusCode, "获取扫码登录页失败")
        }
        let loginParams = try Cloud189Protocol.extractLoginParameters(from: initResp.text)

        var uuidReq = URLRequest(url: URL(string: "\(Cloud189Constants.authURL)/api/logbox/oauth2/getUUID.do")!)
        uuidReq.httpMethod = "POST"
        uuidReq.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        uuidReq.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        uuidReq.setValue(Cloud189Constants.authURL, forHTTPHeaderField: "Referer")
        uuidReq.httpBody = formEncoded([("appId", Cloud189Constants.appId)])

        let uuidResp = try await transport.send(uuidReq)
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        if let err = Cloud189Protocol.extractAPIErrorMessage(uuidResp.text) {
            throw CloudTuneError.protocolError(err)
        }
        guard (200..<300).contains(uuidResp.statusCode) else {
            throw CloudTuneError.httpStatus(uuidResp.statusCode, "二维码初始化请求失败")
        }
        guard let data = uuidResp.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = Cloud189Protocol.stringValue(json["uuid"]),
              let encryUuid = Cloud189Protocol.stringValue(json["encryuuid"]) else {
            throw CloudTuneError.protocolError("二维码初始化失败")
        }

        self.pendingQr = PendingQrLogin(
            lt: loginParams.lt,
            paramId: loginParams.paramId,
            reqId: loginParams.reqId,
            uuid: uuid,
            encryUuid: encryUuid
        )
        return QrLoginStart(qrContent: uuid, message: "请使用天翼云盘 App 扫码，并在手机端确认登录")
    }

    public func pollQrLogin() async throws -> QrPollResponse {
        guard let pending = pendingQr else {
            throw CloudTuneError.invalidRequest("请先生成二维码，再轮询登录状态")
        }
        let startEpoch = sessionEpoch
        let now = Date()
        var req = URLRequest(url: URL(string: "\(Cloud189Constants.authURL)/api/logbox/oauth2/qrcodeLoginState.do")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.authURL, forHTTPHeaderField: "Referer")
        req.setValue(pending.reqId, forHTTPHeaderField: "Reqid")
        req.setValue(pending.lt, forHTTPHeaderField: "lt")
        req.httpBody = formEncoded([
            ("appId", Cloud189Constants.appId),
            ("clientType", Cloud189Constants.clientType),
            ("returnUrl", Cloud189Constants.returnURL),
            ("paramId", pending.paramId),
            ("uuid", pending.uuid),
            ("encryuuid", pending.encryUuid),
            ("date", Cloud189Protocol.formatQrPollDate(now)),
            ("timeStamp", String(Int64(now.timeIntervalSince1970 * 1000)))
        ])

        let resp = try await transport.send(req)
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw CloudTuneError.httpStatus(resp.statusCode, "二维码轮询请求失败")
        }
        var parsed = try Cloud189Protocol.parseQrPollPayload(resp.text, statusCode: resp.statusCode)
        switch parsed.state {
        case .authenticated:
            guard let redirect = parsed.redirectURL else {
                throw CloudTuneError.protocolError("缺少扫码跳转链接")
            }
            let (sessionResult, committedEpoch) = try await exchangeRedirectForSessionWithEpoch(redirectURL: redirect)
            self.pendingQr = nil
            parsed.accountName = sessionResult.activeSession.loginName
            parsed.sessionEpoch = committedEpoch
            return parsed
        case .expired:
            guard sessionEpoch == startEpoch else {
                throw CancellationError()
            }
            self.pendingQr = nil
            return parsed
        case .waitingScan, .waitingConfirm:
            return parsed
        }
    }

    @discardableResult
    public func exchangeRedirectForSession(redirectURL: String) async throws -> Cloud189Protocol.ParsedSessionPayload {
        try await exchangeRedirectForSessionWithEpoch(redirectURL: redirectURL).payload
    }

    @discardableResult
    public func exchangeRedirectForSessionWithEpoch(
        redirectURL: String
    ) async throws -> (payload: Cloud189Protocol.ParsedSessionPayload, epoch: UInt64) {
        let startEpoch = sessionEpoch
        var comps = URLComponents(string: "\(Cloud189Constants.apiURL)/getSessionForPC.action")!
        comps.queryItems = clientSuffixItems() + [URLQueryItem(name: "redirectURL", value: redirectURL)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")

        let resp = try await transport.send(req)
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        guard (200..<300).contains(resp.statusCode) else {
            if let err = Cloud189Protocol.extractAPIErrorMessage(resp.text) {
                throw CloudTuneError.protocolError(err)
            }
            throw CloudTuneError.httpStatus(resp.statusCode, "会话兑换失败")
        }
        let parsed = try Cloud189Protocol.parseSessionResponse(
            resp.text,
            statusCode: resp.statusCode
        )
        guard sessionEpoch == startEpoch else {
            throw CancellationError()
        }
        sessionEpoch &+= 1
        let committedEpoch = sessionEpoch
        self.activeSession = parsed.activeSession
        self.persistedCredential = parsed.persistedCredential
        self.pendingQr = nil
        return (parsed, committedEpoch)
    }

    public func listRemoteFolder(
        folderId: String?,
        folderName: String? = nil,
        folderPath: String? = nil
    ) async throws -> FolderBrowsePayload {
        let isRoot = (folderId == nil || folderId == Cloud189Constants.rootFolderId)
        let targetId = folderId ?? Cloud189Constants.rootFolderId
        let resolvedFolderName: String
        let resolvedFolderPath: String
        if isRoot {
            resolvedFolderName = Cloud189Constants.rootFolderName
            resolvedFolderPath = Cloud189Constants.rootFolderName
        } else {
            let trimmedName = folderName?.trimmedNilIfEmpty
            let trimmedPath = folderPath?.trimmedNilIfEmpty
            let leafFromPath = trimmedPath?.split(separator: "/").last.map(String.init)?.trimmedNilIfEmpty
            resolvedFolderName = trimmedName ?? leafFromPath ?? targetId
            resolvedFolderPath = trimmedPath ?? resolvedFolderName
        }

        var folders: [RemoteFolder] = []
        var audioFiles: [TrackSummary] = []
        var videoFiles: [TrackSummary] = []
        var otherFiles: [TrackSummary] = []

        var pageNum = 1
        while pageNum <= 200 {
            let json = try await signedGetJSON(
                path: "/listFiles.action",
                query: [
                    ("folderId", targetId),
                    ("fileType", "0"),
                    ("mediaAttr", "0"),
                    ("iconOption", "5"),
                    ("pageNum", String(pageNum)),
                    ("pageSize", "1000"),
                    ("recursive", "0"),
                    ("orderBy", "filename"),
                    ("descending", "false")
                ]
            )
            guard let block = json["fileListAO"] as? [String: Any] else {
                throw CloudTuneError.protocolError("云盘目录响应缺少 fileListAO 字段")
            }
            guard block["count"] != nil || block["folderList"] != nil || block["fileList"] != nil else {
                throw CloudTuneError.protocolError("云盘目录 fileListAO 结构无效")
            }
            let count = Cloud189Protocol.intValue(block["count"]) ?? 0
            if count == 0 && (block["folderList"] as? [[String: Any]] ?? []).isEmpty && (block["fileList"] as? [[String: Any]] ?? []).isEmpty {
                break
            }

            let rawFolders = (block["folderList"] as? [[String: Any]]) ?? []
            let rawFiles = (block["fileList"] as? [[String: Any]]) ?? []
            if rawFolders.isEmpty && rawFiles.isEmpty { break }

            for item in rawFolders {
                if let id = Cloud189Protocol.stringValue(item["id"]),
                   let name = Cloud189Protocol.stringValue(item["name"]) {
                    folders.append(RemoteFolder(
                        id: id,
                        name: name,
                        parentId: Cloud189Protocol.stringValue(item["parentId"])
                    ))
                }
            }
            for item in rawFiles {
                if let id = Cloud189Protocol.stringValue(item["id"]),
                   let name = Cloud189Protocol.stringValue(item["name"]) {
                    let size = UInt64(max(0, Cloud189Protocol.intValue(item["size"]) ?? 0))
                    let summary = TrackSummary(
                        id: id,
                        name: name,
                        folderPath: resolvedFolderPath,
                        sizeBytes: size,
                        modifiedAt: Cloud189Protocol.stringValue(item["lastOpTime"])
                    )
                    if Cloud189Protocol.isAudioFile(name) {
                        audioFiles.append(summary)
                    } else if Cloud189Protocol.isVideoFile(name) {
                        videoFiles.append(summary)
                    } else {
                        otherFiles.append(summary)
                    }
                }
            }
            if rawFolders.count + rawFiles.count < 1000 { break }
            pageNum += 1
        }

        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        audioFiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        videoFiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        otherFiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return FolderBrowsePayload(
            currentFolderId: targetId,
            currentFolderName: resolvedFolderName,
            parentFolderId: nil,
            isRoot: isRoot,
            folders: folders,
            audioFiles: audioFiles,
            videoFiles: videoFiles,
            otherFiles: otherFiles
        )
    }

    public func scanMusicLibrary(folderId: String, folderName: String) async throws -> [TrackSummary] {
        try await scanRecursive(folderId: folderId, folderName: folderName, audioOnly: true)
    }

    public func scanAllFiles(folderId: String, folderName: String) async throws -> [TrackSummary] {
        try await scanRecursive(folderId: folderId, folderName: folderName, audioOnly: false)
    }

    public func resolveDownloadURL(fileId: String) async throws -> URL {
        let json = try await signedGetJSON(
            path: "/getFileDownloadUrl.action",
            query: [("fileId", fileId), ("dt", "3"), ("flag", "1")]
        )
        guard let raw = Cloud189Protocol.stringValue(json["fileDownloadUrl"]), !raw.isEmpty else {
            throw CloudTuneError.protocolError("没有获取到文件下载地址")
        }
        var normalized = raw.replacingOccurrences(of: "&amp;", with: "&")
        if normalized.hasPrefix("http://") {
            normalized = "https://" + normalized.dropFirst("http://".count)
        }
        guard let url = URL(string: normalized) else {
            throw CloudTuneError.protocolError("文件下载地址格式无效")
        }
        return url
    }

    private func scanRecursive(folderId: String, folderName: String, audioOnly: Bool) async throws -> [TrackSummary] {
        var queue: [(String, String)] = [(folderId, folderName)]
        var index = 0
        var collected: [TrackSummary] = []

        while index < queue.count {
            let (currId, currPath) = queue[index]
            index += 1
            let leafName = currPath.split(separator: "/").last.map(String.init) ?? currPath
            let listing = try await listRemoteFolder(folderId: currId, folderName: leafName, folderPath: currPath)
            for sub in listing.folders {
                queue.append((sub.id, "\(currPath)/\(sub.name)"))
            }
            let items = audioOnly ? listing.audioFiles : (listing.audioFiles + listing.videoFiles + listing.otherFiles)
            for var track in items {
                track.folderPath = currPath
                collected.append(track)
            }
        }
        collected.sort {
            ("\($0.folderPath)/\($0.name)".lowercased()) < ("\($1.folderPath)/\($1.name)".lowercased())
        }
        return collected
    }

    private func exchangeAccessTokenForSession(
        accessToken: String,
        fallbackRefreshToken: String,
        fallbackAccountName: String?,
        fallbackAccountKey: String? = nil
    ) async throws -> Cloud189Protocol.ParsedSessionPayload {
        var comps = URLComponents(string: "\(Cloud189Constants.apiURL)/getSessionForPC.action")!
        comps.queryItems = clientSuffixItems() + [
            URLQueryItem(name: "appId", value: Cloud189Constants.appId),
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")

        let resp = try await transport.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            if let err = Cloud189Protocol.extractAPIErrorMessage(resp.text) {
                throw CloudTuneError.protocolError(err)
            }
            throw CloudTuneError.httpStatus(resp.statusCode, "会话刷新失败")
        }
        return try Cloud189Protocol.parseSessionResponse(
            resp.text,
            statusCode: resp.statusCode,
            fallbackAccessToken: accessToken,
            fallbackRefreshToken: fallbackRefreshToken,
            fallbackAccountName: fallbackAccountName,
            fallbackAccountKey: fallbackAccountKey
        )
    }

    private func signedGetJSON(path: String, query: [(String, String)]) async throws -> [String: Any] {
        for attempt in 0..<2 {
            guard let session = activeSession else {
                throw CloudTuneError.unauthenticated
            }
            let startEpoch = sessionEpoch
            var comps = URLComponents(string: "\(Cloud189Constants.apiURL)\(path)")!
            comps.queryItems = clientSuffixItems() + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            let url = comps.url!
            let dateHeader = Cloud189Protocol.formatHTTPDate()
            let (_, signature) = try Cloud189Protocol.computeSignature(
                sessionKey: session.sessionKey,
                sessionSecret: session.sessionSecret,
                method: "GET",
                urlString: url.absoluteString,
                dateHeader: dateHeader
            )

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
            req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
            req.setValue(dateHeader, forHTTPHeaderField: "Date")
            req.setValue(session.sessionKey, forHTTPHeaderField: "SessionKey")
            req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
            req.setValue(signature, forHTTPHeaderField: "Signature")

            let resp = try await transport.send(req)
            guard sessionEpoch == startEpoch else {
                throw CancellationError()
            }
            let body = resp.text
            if body.contains("userSessionBO is null") || body.contains("InvalidSessionKey") {
                if attempt == 0, !session.accessToken.isEmpty {
                    let refreshed = try await exchangeAccessTokenForSession(
                        accessToken: session.accessToken,
                        fallbackRefreshToken: persistedCredential?.refreshToken ?? "",
                        fallbackAccountName: session.loginName,
                        fallbackAccountKey: persistedCredential?.accountKey
                    )
                    guard sessionEpoch == startEpoch else {
                        throw CancellationError()
                    }
                    self.activeSession = refreshed.activeSession
                    self.persistedCredential = refreshed.persistedCredential
                    continue
                }
                throw CloudTuneError.sessionExpired
            }
            if let err = Cloud189Protocol.extractAPIErrorMessage(body) {
                throw CloudTuneError.protocolError(err)
            }
            guard (200..<300).contains(resp.statusCode) else {
                throw CloudTuneError.httpStatus(resp.statusCode, "读取天翼云盘接口失败")
            }
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudTuneError.protocolError("读取天翼云盘接口失败 (HTTP \(resp.statusCode))")
            }
            return json
        }
        throw CloudTuneError.sessionExpired
    }

    private func clientSuffixItems() -> [URLQueryItem] {
        let r1 = Int.random(in: 0..<100_000)
        let r2 = Int64.random(in: 0..<10_000_000_000)
        return [
            URLQueryItem(name: "clientType", value: Cloud189Constants.pcClient),
            URLQueryItem(name: "version", value: Cloud189Constants.version),
            URLQueryItem(name: "channelId", value: Cloud189Constants.channelId),
            URLQueryItem(name: "rand", value: "\(r1)_\(r2)")
        ]
    }

    private func formEncoded(_ pairs: [(String, String)]) -> Data {
        var comps = URLComponents()
        comps.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}
