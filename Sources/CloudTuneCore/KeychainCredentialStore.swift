import Foundation
import Security

public enum KeychainLoadResult: Equatable, Sendable {
    case found(PersistedRefreshCredential)
    case notFound
    case deferredBySystem(Int32)
    case deniedOrFailed(Int32)

    public static let cssmErrCSPInDarkWake: Int32 = -2_147_415_834
    public static let errSecInteractionNotAllowedCode: Int32 = -25_308
    public static let errSecInteractionRequiredCode: Int32 = -25_315
    public static let errSecItemNotFoundCode: Int32 = -25_300
    public static let errSecAuthFailedCode: Int32 = -25_293

    public static func classify(status: Int32, data: Data?) -> KeychainLoadResult {
        if status == errSecSuccess {
            guard let data,
                  let cred = try? JSONDecoder().decode(PersistedRefreshCredential.self, from: data) else {
                return .notFound
            }
            return .found(cred)
        }
        if status == errSecItemNotFoundCode {
            return .notFound
        }
        switch status {
        case cssmErrCSPInDarkWake, errSecInteractionNotAllowedCode, errSecInteractionRequiredCode:
            return .deferredBySystem(status)
        default:
            return .deniedOrFailed(status)
        }
    }
}

public enum CredentialIssue: Equatable, Sendable {
    case deferredBySystem(status: Int32)
    case deniedOrFailed(status: Int32)

    public var userMessage: String {
        switch self {
        case let .deferredBySystem(code):
            return "系统正在唤醒或锁屏，钥匙串凭据读取已暂缓 (status=\(code))，未清除您的登录记录。"
        case let .deniedOrFailed(code):
            return "钥匙串凭据访问未获授权或签名变更 (status=\(code))，可点击重试授权或重新登录覆盖。"
        }
    }
}

public protocol KeychainBackend: Sendable {
    func readCredential() -> KeychainLoadResult
    func saveCredential(_ credential: PersistedRefreshCredential) throws
    func deleteCredential()
}

/// Pure state machine governing Keychain access classification, DarkWake deferral protection,
/// retry cooldowns, and ensuring transient ACL/DarkWake errors never trigger false logouts.
public struct CredentialStateMachine: Sendable {
    public static let retryCooldownSec: TimeInterval = 3.0

    public private(set) var cachedCredential: PersistedRefreshCredential?
    public private(set) var activeIssue: CredentialIssue?
    public private(set) var isKnownMissing: Bool = false
    private var lastAttemptAt: Date?

    public init() {}

    public mutating func load(
        isInteractiveGUI: Bool,
        userInitiatedRetry: Bool = false,
        now: Date = Date(),
        backend: KeychainBackend
    ) -> (credential: PersistedRefreshCredential?, issue: CredentialIssue?) {
        if userInitiatedRetry {
            activeIssue = nil
            isKnownMissing = false
            lastAttemptAt = nil
        } else {
            if let cachedCredential {
                return (cachedCredential, nil)
            }
            if case .deniedOrFailed = activeIssue {
                return (nil, activeIssue)
            }
            if case .deferredBySystem = activeIssue {
                guard isInteractiveGUI else {
                    return (nil, activeIssue)
                }
                if let last = lastAttemptAt, now.timeIntervalSince(last) < Self.retryCooldownSec {
                    return (nil, activeIssue)
                }
            }
            if isKnownMissing {
                return (nil, nil)
            }
        }

        lastAttemptAt = now
        switch backend.readCredential() {
        case let .found(cred):
            cachedCredential = cred
            activeIssue = nil
            isKnownMissing = false
            return (cred, nil)
        case .notFound:
            cachedCredential = nil
            activeIssue = nil
            isKnownMissing = true
            return (nil, nil)
        case let .deferredBySystem(code):
            cachedCredential = nil
            activeIssue = .deferredBySystem(status: code)
            isKnownMissing = false
            return (nil, activeIssue)
        case let .deniedOrFailed(code):
            cachedCredential = nil
            activeIssue = .deniedOrFailed(status: code)
            isKnownMissing = false
            return (nil, activeIssue)
        }
    }

    public mutating func save(_ credential: PersistedRefreshCredential, backend: KeychainBackend) throws {
        try backend.saveCredential(credential)
        cachedCredential = credential
        activeIssue = nil
        isKnownMissing = false
    }

    public mutating func clear(backend: KeychainBackend) {
        backend.deleteCredential()
        cachedCredential = nil
        activeIssue = nil
        isKnownMissing = true
    }
}

public struct SystemKeychainBackend: KeychainBackend {
    public let service: String
    public let account: String

    public init(service: String = "com.gosu.cloudtune.session", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func readCredential() -> KeychainLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainLoadResult.classify(status: status, data: item as? Data)
    }

    public func saveCredential(_ credential: PersistedRefreshCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        // On ad-hoc cdhash ACL conflict or missing item, delete + add cleanly replaces the entry.
        _ = SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        for (k, v) in attributes {
            addQuery[k] = v
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudTuneError.storageError("无法保存登录凭据到钥匙串 (OSStatus \(addStatus))")
        }
    }

    public func deleteCredential() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
