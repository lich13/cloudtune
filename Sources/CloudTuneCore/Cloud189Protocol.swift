import CryptoKit
import Foundation

public enum CloudTuneError: LocalizedError, Equatable, Sendable {
    case unauthenticated
    case invalidRequest(String)
    case protocolError(String)
    case httpStatus(Int, String)
    case sessionExpired
    case storageError(String)
    case exportPermissionRevoked(String)
    case unsupportedLocalMediaFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "请先登录天翼云盘"
        case let .invalidRequest(msg),
             let .protocolError(msg),
             let .storageError(msg),
             let .exportPermissionRevoked(msg),
             let .unsupportedLocalMediaFormat(msg):
            return msg
        case let .httpStatus(code, msg):
            return "请求失败 (HTTP \(code)): \(msg)"
        case .sessionExpired:
            return "天翼云盘会话已失效，请重新登录"
        }
    }
}

public enum Cloud189Constants {
    public static let rootFolderId = "-11"
    public static let rootFolderName = "我的云盘"
    public static let defaultAccountDisplayName = "天翼云盘用户"
    public static let webURL = "https://cloud.189.cn"
    public static let authURL = "https://open.e.189.cn"
    public static let apiURL = "https://api.cloud.189.cn"
    public static let appId = "8025431004"
    public static let clientType = "10020"
    public static let returnURL = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html"
    public static let pcClient = "TELEPC"
    public static let version = "6.2"
    public static let channelId = "web_cloud.189.cn"
    public static let userAgent = "CloudTune/1.0.0"
    public static let referer = "https://cloud.189.cn/"
}

public enum Cloud189Protocol {
    public struct LoginPageParameters: Equatable, Sendable {
        public let lt: String
        public let paramId: String
        public let reqId: String
    }

    public struct ParsedSessionPayload: Equatable, Sendable {
        public let activeSession: ActiveCloudSession
        public let persistedCredential: PersistedRefreshCredential?
    }

    public static func webLoginEntryURL(timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> URL {
        var comps = URLComponents(string: "\(Cloud189Constants.webURL)/api/portal/unifyLoginForPC.action")!
        comps.queryItems = [
            URLQueryItem(name: "appId", value: Cloud189Constants.appId),
            URLQueryItem(name: "clientType", value: Cloud189Constants.clientType),
            URLQueryItem(name: "returnURL", value: Cloud189Constants.returnURL),
            URLQueryItem(name: "timeStamp", value: String(timestampMillis))
        ]
        return comps.url!
    }

    /// Distinguishes intermediate Tianyi login pages from the post-login callback redirect URL.
    public static func isInterceptableWebLoginCallback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        let path = url.path
        let query = url.query ?? ""

        if host == "m.cloud.189.cn" && path.contains("/loginErrorPc/") && !query.isEmpty {
            return true
        }
        if host == "cloud.189.cn" {
            if path.contains("unifyLoginForPC.action") {
                return false
            }
            if path.contains("udb_login.jsp") || path.contains("callbackUnify.action") {
                return !query.isEmpty
            }
            if query.contains("paras=") || query.contains("ticket=") {
                return true
            }
        }
        return false
    }

    public static func formatHTTPDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    public static func formatQrPollDate(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-ddHH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    public static func computeSignature(
        sessionKey: String,
        sessionSecret: String,
        method: String,
        urlString: String,
        dateHeader: String
    ) throws -> (requestURI: String, signature: String) {
        guard let url = URL(string: urlString), !url.path.isEmpty else {
            throw CloudTuneError.invalidRequest("无效的请求地址")
        }
        let requestURI = url.path
        let payload = "SessionKey=\(sessionKey)&Operate=\(method)&RequestURI=\(requestURI)&Date=\(dateHeader)"
        let key = SymmetricKey(data: Data(sessionSecret.utf8))
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: Data(payload.utf8), using: key)
        let signature = digest.map { String(format: "%02X", $0) }.joined()
        return (requestURI, signature)
    }

    /// Uses word boundaries (`\blt\b`) so attributes like `alt="二维码登录成功"` never match `lt`.
    public static func extractLoginParameters(from html: String) throws -> LoginPageParameters {
        let lt = try matchFirst(in: html, pattern: #"\blt\s*=\s*["']([^"']+)["']"#, label: "lt")
        let paramId = try matchFirst(in: html, pattern: #"\bparamId\s*=\s*["']([^"']+)["']"#, label: "paramId")
        let reqId = try matchFirst(in: html, pattern: #"\breqId\s*=\s*["']([^"']+)["']"#, label: "reqId")
        return LoginPageParameters(lt: lt, paramId: paramId, reqId: reqId)
    }

    private static func matchFirst(in text: String, pattern: String, label: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            throw CloudTuneError.protocolError("登录页面中缺少 \(label)")
        }
        return String(text[range])
    }

    public static func parseQrPollPayload(_ body: String, statusCode: Int) throws -> QrPollResponse {
        let cleaned = normalizeBody(body)
        guard !cleaned.isEmpty else {
            throw CloudTuneError.protocolError("二维码轮询返回空响应，HTTP \(statusCode)")
        }
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = intValue(json["status"]) else {
            throw CloudTuneError.protocolError("二维码轮询返回的不是可解析 JSON，HTTP \(statusCode)")
        }

        switch status {
        case 0:
            let redirect = stringValue(json["redirectUrl"])
                ?? stringValue(json["redirectURL"])
                ?? stringValue(json["toUrl"])
            guard let redirect, !redirect.isEmpty else {
                throw CloudTuneError.protocolError("二维码登录成功，但没有返回跳转链接")
            }
            return QrPollResponse(state: .authenticated, message: "扫码登录成功", redirectURL: redirect)
        case -106:
            return QrPollResponse(state: .waitingScan, message: "二维码已生成，等待手机扫码")
        case -11002:
            return QrPollResponse(state: .waitingConfirm, message: "手机已扫码，等待你在 App 里确认登录")
        case -11001:
            return QrPollResponse(state: .expired, message: "二维码已过期，请重新生成")
        default:
            let msg = stringValue(json["msg"]) ?? "未知错误"
            throw CloudTuneError.protocolError("二维码登录失败 (status=\(status)): \(msg)")
        }
    }

    public static func parseSessionResponse(
        _ body: String,
        statusCode: Int,
        fallbackAccessToken: String = "",
        fallbackRefreshToken: String = "",
        fallbackAccountName: String? = nil,
        fallbackAccountKey: String? = nil
    ) throws -> ParsedSessionPayload {
        let cleaned = normalizeBody(body)
        guard !cleaned.isEmpty else {
            throw CloudTuneError.protocolError("会话接口返回空响应，HTTP \(statusCode)")
        }

        let accessToken: String
        let refreshToken: String
        let loginName: String?
        let userId: String?
        let sessionKey: String
        let sessionSecret: String
        let emptySessionKeyError: String

        if cleaned.hasPrefix("<") {
            accessToken = fallbackAccessToken
            refreshToken = fallbackRefreshToken
            loginName = extractXMLTag("loginName", in: cleaned)
                ?? extractXMLTag("userAccount", in: cleaned)
                ?? fallbackAccountName
            userId = extractXMLTag("userId", in: cleaned)
            sessionKey = extractXMLTag("sessionKey", in: cleaned) ?? ""
            sessionSecret = extractXMLTag("sessionSecret", in: cleaned) ?? ""
            emptySessionKeyError = "189CloudPC XML 会话初始化失败，sessionKey 为空"
        } else {
            if let err = extractAPIErrorMessage(cleaned) {
                throw CloudTuneError.protocolError(err)
            }
            guard let data = cleaned.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudTuneError.protocolError("会话接口返回非预期响应，HTTP \(statusCode)")
            }
            accessToken = stringValue(json["accessToken"]) ?? fallbackAccessToken
            refreshToken = stringValue(json["refreshToken"]) ?? fallbackRefreshToken
            loginName = stringValue(json["loginName"])
                ?? stringValue(json["userAccount"])
                ?? fallbackAccountName
            userId = stringValue(json["userId"])
            sessionKey = stringValue(json["sessionKey"]) ?? ""
            sessionSecret = stringValue(json["sessionSecret"]) ?? ""
            emptySessionKeyError = "189CloudPC 会话初始化失败，sessionKey 为空"
        }

        guard let active = ActiveCloudSession(
            accessToken: accessToken,
            sessionKey: sessionKey,
            sessionSecret: sessionSecret,
            loginName: loginName
        ) else {
            throw CloudTuneError.protocolError(emptySessionKeyError)
        }
        let explicitLogin = active.loginName?.nilIfNotDefaultDisplayName
        let storageKey = explicitLogin
            ?? fallbackAccountKey?.nilIfNotDefaultDisplayName
            ?? deriveFallbackAccountKey(
                userId: userId,
                refreshToken: refreshToken,
                accessToken: active.accessToken,
                sessionKey: active.sessionKey
            )
        let persisted = PersistedRefreshCredential(
            refreshToken: refreshToken,
            accountName: active.loginName,
            accountKey: storageKey
        )
        return ParsedSessionPayload(activeSession: active, persistedCredential: persisted)
    }

    public static func isTrustedTianyiOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let port = url.port, port != 443 {
            return false
        }
        return host == "cloud.189.cn"
            || host.hasSuffix(".cloud.189.cn")
            || host == "e.189.cn"
            || host.hasSuffix(".e.189.cn")
    }

    public static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let schemeA = a.scheme?.lowercased(),
              let schemeB = b.scheme?.lowercased(),
              schemeA == schemeB,
              let hostA = a.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              let hostB = b.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !hostA.isEmpty,
              hostA == hostB else {
            return false
        }
        let defaultPort: (String) -> Int? = { scheme in
            switch scheme {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
        let portA = a.port ?? defaultPort(schemeA)
        let portB = b.port ?? defaultPort(schemeB)
        return portA == portB
    }

    public static func deriveFallbackAccountKey(
        refreshToken: String? = nil,
        accessToken: String? = nil,
        sessionKey: String
    ) -> String {
        deriveFallbackAccountKey(
            userId: nil,
            refreshToken: refreshToken,
            accessToken: accessToken,
            sessionKey: sessionKey
        )
    }

    public static func deriveFallbackAccountKey(
        userId: String?,
        refreshToken: String? = nil,
        accessToken: String? = nil,
        sessionKey: String
    ) -> String {
        let seed = [userId, refreshToken, accessToken, Optional(sessionKey)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != Cloud189Constants.defaultAccountDisplayName } ?? sessionKey
        let digest = SHA256.hash(data: Data("cloudtune-anon-account:\(seed)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct:\(hex)"
    }

    public static func resolveAccountIdentity(
        activeSession: ActiveCloudSession,
        persistedCredential: PersistedRefreshCredential? = nil,
        priorAccountKey: String? = nil
    ) -> (storageKey: String, displayName: String) {
        if let explicitLogin = activeSession.loginName?.nilIfNotDefaultDisplayName
            ?? persistedCredential?.accountName?.nilIfNotDefaultDisplayName {
            return (explicitLogin, explicitLogin)
        }
        if let prior = priorAccountKey?.nilIfNotDefaultDisplayName {
            return (prior, Cloud189Constants.defaultAccountDisplayName)
        }
        if let savedKey = persistedCredential?.accountKey?.nilIfNotDefaultDisplayName {
            return (savedKey, Cloud189Constants.defaultAccountDisplayName)
        }
        let derived = deriveFallbackAccountKey(
            refreshToken: persistedCredential?.refreshToken,
            accessToken: activeSession.accessToken,
            sessionKey: activeSession.sessionKey
        )
        return (derived, Cloud189Constants.defaultAccountDisplayName)
    }

    public static func extractAPIErrorMessage(_ body: String) -> String? {
        guard let data = normalizeBody(body).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let resCode = json["res_code"] {
            if let num = intValue(resCode), num != 0 {
                return stringValue(json["res_message"]) ?? stringValue(json["msg"]) ?? stringValue(json["message"]) ?? "189Cloud error \(num)"
            }
            if let str = stringValue(resCode), str != "0" {
                return stringValue(json["res_message"]) ?? stringValue(json["msg"]) ?? stringValue(json["message"]) ?? "189Cloud error \(str)"
            }
        }
        if let errorCode = stringValue(json["errorCode"]) {
            return stringValue(json["errorMsg"]) ?? stringValue(json["msg"]) ?? stringValue(json["message"]) ?? errorCode
        }
        if let code = stringValue(json["code"]), code != "SUCCESS" {
            return stringValue(json["msg"]) ?? stringValue(json["message"]) ?? code
        }
        if let err = stringValue(json["error"]) {
            return stringValue(json["message"]) ?? stringValue(json["msg"]) ?? err
        }
        return nil
    }

    public static func accountBucketHash(for accountId: String) -> String {
        let normalized = accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sanitizeFileName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let mapped = String(raw.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mapped.isEmpty {
            return "track.bin"
        }
        if mapped.allSatisfy({ $0 == "." }) {
            return "_"
        }
        return mapped
    }

    private struct MediaExtensionDescriptor: Sendable {
        enum Kind: Equatable, Sendable {
            case audio(isLossless: Bool)
            case video
        }

        let kind: Kind
        let mimeType: String?
    }

    private static let mediaDescriptorsByExtension: [String: MediaExtensionDescriptor] = [
        // Audio formats
        "mp3": .init(kind: .audio(isLossless: false), mimeType: "audio/mpeg"),
        "flac": .init(kind: .audio(isLossless: true), mimeType: "audio/flac"),
        "wav": .init(kind: .audio(isLossless: true), mimeType: "audio/wav"),
        "m4a": .init(kind: .audio(isLossless: false), mimeType: "audio/mp4"),
        "alac": .init(kind: .audio(isLossless: true), mimeType: "audio/mp4"),
        "aac": .init(kind: .audio(isLossless: false), mimeType: "audio/aac"),
        "ogg": .init(kind: .audio(isLossless: false), mimeType: "audio/ogg"),
        "opus": .init(kind: .audio(isLossless: false), mimeType: "audio/opus"),
        "ape": .init(kind: .audio(isLossless: true), mimeType: nil),
        "wma": .init(kind: .audio(isLossless: false), mimeType: nil),
        "aiff": .init(kind: .audio(isLossless: true), mimeType: "audio/aiff"),
        "aif": .init(kind: .audio(isLossless: true), mimeType: "audio/aiff"),
        "dsf": .init(kind: .audio(isLossless: true), mimeType: "audio/dsf"),
        "dff": .init(kind: .audio(isLossless: true), mimeType: "audio/dff"),
        // Video formats
        "mp4": .init(kind: .video, mimeType: "video/mp4"),
        "m4v": .init(kind: .video, mimeType: "video/mp4"),
        "mov": .init(kind: .video, mimeType: "video/quicktime"),
        "mkv": .init(kind: .video, mimeType: "video/x-matroska"),
        "webm": .init(kind: .video, mimeType: "video/webm"),
        "avi": .init(kind: .video, mimeType: nil),
        "wmv": .init(kind: .video, mimeType: nil),
        "flv": .init(kind: .video, mimeType: nil),
        "mpeg": .init(kind: .video, mimeType: nil),
        "mpg": .init(kind: .video, mimeType: nil)
    ]

    private static func mediaDescriptor(for fileName: String) -> MediaExtensionDescriptor? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = trimmed.lastIndex(of: "."),
              dotIndex < trimmed.index(before: trimmed.endIndex) else {
            return nil
        }
        let ext = trimmed[trimmed.index(after: dotIndex)...]
        guard !ext.contains("/"), !ext.contains("\\") else {
            return nil
        }
        return mediaDescriptorsByExtension[ext.lowercased()]
    }

    public static func isAudioFile(_ name: String) -> Bool {
        if case .audio = mediaDescriptor(for: name)?.kind {
            return true
        }
        return false
    }

    public static func isLosslessAudioFile(_ name: String) -> Bool {
        mediaDescriptor(for: name)?.kind == .audio(isLossless: true)
    }

    public static func isVideoFile(_ name: String) -> Bool {
        mediaDescriptor(for: name)?.kind == .video
    }

    public static func guessMimeType(for fileName: String) -> String {
        mediaDescriptor(for: fileName)?.mimeType ?? "application/octet-stream"
    }

    private static func normalizeBody(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{feff}", with: "")
    }

    private static func extractXMLTag(_ tag: String, in xml: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))>\\s*(?:<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>|([^<]*))\\s*</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)) else {
            return nil
        }
        for idx in [1, 2] where match.numberOfRanges > idx {
            if let r = Range(match.range(at: idx), in: xml) {
                let value = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = any as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
