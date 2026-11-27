import Foundation

public struct AccountPaths: Equatable, Sendable {
    public let accountId: String
    public let bucketHash: String
    public let accountDir: URL
    public let cacheDir: URL
    public let stagingDir: URL
    public let artworkDir: URL
    public let settingsURL: URL
    public let libraryURL: URL
    public let cacheIndexURL: URL
    public let transfersURL: URL
    public let exportBookmarkURL: URL

    public init(baseRoot: URL, accountId: String) {
        let hash = Cloud189Protocol.accountBucketHash(for: accountId)
        let dir = baseRoot.appendingPathComponent("accounts/\(hash)", isDirectory: true)
        self.accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.bucketHash = hash
        self.accountDir = dir
        self.cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        self.stagingDir = dir.appendingPathComponent("staging", isDirectory: true)
        self.artworkDir = dir.appendingPathComponent("artwork", isDirectory: true)
        self.settingsURL = dir.appendingPathComponent("settings.json")
        self.libraryURL = dir.appendingPathComponent("library.json")
        self.cacheIndexURL = self.cacheDir.appendingPathComponent("index.json")
        self.transfersURL = dir.appendingPathComponent("transfers.json")
        self.exportBookmarkURL = dir.appendingPathComponent("export-bookmark.bin")
    }
}

public actor AccountScopedStore {
    public let rootDirectory: URL
    private let fm = FileManager.default

    public init(rootDirectory: URL? = nil) throws {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootDirectory = appSupport.appendingPathComponent("com.gosu.cloudtune", isDirectory: true)
        }
        try fm.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    private init(uncheckedDirectory: URL) {
        self.rootDirectory = uncheckedDirectory
        do {
            try fm.createDirectory(at: uncheckedDirectory, withIntermediateDirectories: true)
        } catch {
            // Directory creation error will surface on subsequent read/write calls
        }
    }

    public static func resolveOrFallback(_ explicit: AccountScopedStore?) -> (store: AccountScopedStore, warning: String?) {
        if let explicit {
            return (explicit, nil)
        }
        do {
            return (try AccountScopedStore(), nil)
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("com.gosu.cloudtune.fallback", isDirectory: true)
            return (
                AccountScopedStore(uncheckedDirectory: fallbackURL),
                "应用支持目录不可用，已回退临时存储：\(error.localizedDescription)"
            )
        }
    }

    public func paths(for accountId: String) throws -> AccountPaths {
        let resolved = AccountPaths(baseRoot: rootDirectory, accountId: accountId)
        for dir in [resolved.accountDir, resolved.cacheDir, resolved.stagingDir, resolved.artworkDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return resolved
    }

    public func loadSettings(for accountId: String) throws -> AccountSettings {
        let p = try paths(for: accountId)
        guard let data = try? Data(contentsOf: p.settingsURL) else {
            return AccountSettings()
        }
        return (try? JSONDecoder().decode(AccountSettings.self, from: data)) ?? AccountSettings()
    }

    public func saveSettings(_ settings: AccountSettings, for accountId: String) throws {
        let p = try paths(for: accountId)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: p.settingsURL, options: .atomic)
    }

    public func loadLibrary(for accountId: String) throws -> [TrackSummary] {
        let p = try paths(for: accountId)
        guard let data = try? Data(contentsOf: p.libraryURL) else {
            return []
        }
        return (try? JSONDecoder().decode([TrackSummary].self, from: data)) ?? []
    }

    public func saveLibrary(_ tracks: [TrackSummary], for accountId: String) throws {
        let p = try paths(for: accountId)
        let data = try JSONEncoder().encode(tracks)
        try data.write(to: p.libraryURL, options: .atomic)
    }

    public func saveExportDirectoryBookmark(_ folderURL: URL, for accountId: String) throws -> String {
        let p = try paths(for: accountId)
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { folderURL.stopAccessingSecurityScopedResource() }
        }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        // On iOS, standard bookmarks created while accessing a security-scoped resource
        // implicitly embed security scope, whereas `.minimalBookmark` strips security scope.
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmarkData = try folderURL.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try bookmarkData.write(to: p.exportBookmarkURL, options: .atomic)
        var settings = try loadSettings(for: accountId)
        settings.exportFolderDisplayName = folderURL.lastPathComponent
        try saveSettings(settings, for: accountId)
        return folderURL.lastPathComponent
    }

    /// Exports a verified staged file into the user-selected folder using security-scoped bookmark + NSFileCoordinator.
    public func exportStagedFile(
        stagedFileURL: URL,
        relativeSubpath: String,
        explicitDirectoryURL: URL? = nil,
        for accountId: String
    ) throws -> URL {
        let folderURL: URL
        if let explicitDirectoryURL {
            folderURL = explicitDirectoryURL
        } else {
            let p = try paths(for: accountId)
            guard let bookmarkData = try? Data(contentsOf: p.exportBookmarkURL) else {
                throw CloudTuneError.exportPermissionRevoked("尚未选择导出目录或目录授权已失效，请重新选择导出文件夹。")
            }
            var isStale = false
            #if os(macOS)
            let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let resolveOptions: URL.BookmarkResolutionOptions = []
            #endif
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: resolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                throw CloudTuneError.exportPermissionRevoked("导出文件夹权限已撤销，请重新授权下载目录。")
            }
            if isStale {
                let refreshedAccess = resolved.startAccessingSecurityScopedResource()
                defer {
                    if refreshedAccess { resolved.stopAccessingSecurityScopedResource() }
                }
                #if os(macOS)
                let refreshCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
                #else
                let refreshCreationOptions: URL.BookmarkCreationOptions = []
                #endif
                if let refreshedData = try? resolved.bookmarkData(
                    options: refreshCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    try? refreshedData.write(to: p.exportBookmarkURL, options: .atomic)
                }
            }
            folderURL = resolved
        }

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { folderURL.stopAccessingSecurityScopedResource() }
        }

        let components = relativeSubpath
            .split(separator: "/")
            .map { Cloud189Protocol.sanitizeFileName(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else {
            throw CloudTuneError.invalidRequest("导出文件名为空")
        }

        let baseStandardPath = folderURL.standardizedFileURL.path
        let basePrefix = baseStandardPath.hasSuffix("/") ? baseStandardPath : (baseStandardPath + "/")
        var targetURL = folderURL
        for part in components.dropLast() {
            targetURL.appendPathComponent(part, isDirectory: true)
            if let vals = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                if vals.isSymbolicLink == true {
                    throw CloudTuneError.storageError("拒绝穿过符号链接目录导出：\(part)")
                }
                if vals.isDirectory == false {
                    throw CloudTuneError.storageError("导出路径已存在同名文件：\(part)")
                }
            }
        }
        let parentDir = targetURL
        targetURL.appendPathComponent(components.last!, isDirectory: false)
        guard targetURL.standardizedFileURL.path.hasPrefix(basePrefix) else {
            throw CloudTuneError.invalidRequest("导出路径越界")
        }

        var coordinatorError: NSError?
        var writeError: Error?
        let targetLeafName = components.last!
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: targetURL, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                if let linkVals = try? coordinatedURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   linkVals.isSymbolicLink == true {
                    throw CloudTuneError.storageError("导出目标路径不允许覆盖符号链接：\(targetLeafName)")
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: coordinatedURL.path, isDirectory: &isDir), isDir.boolValue {
                    throw CloudTuneError.storageError("导出目标路径已存在同名文件夹：\(targetLeafName)")
                }
                let tempName = ".\(coordinatedURL.lastPathComponent).cloudtune-\(UUID().uuidString.lowercased()).tmp"
                let tempURL = coordinatedURL.deletingLastPathComponent().appendingPathComponent(tempName, isDirectory: false)
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: stagedFileURL, to: tempURL)

                var replaceIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: coordinatedURL.path, isDirectory: &replaceIsDir) {
                    if replaceIsDir.boolValue {
                        throw CloudTuneError.storageError("导出目标路径已存在同名文件夹：\(targetLeafName)")
                    }
                    _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: coordinatedURL)
                }
            } catch {
                writeError = error
            }
        }
        if let coordinatorError {
            throw CloudTuneError.exportPermissionRevoked("写入导出目录被拒绝: \(coordinatorError.localizedDescription)")
        }
        if let writeError {
            if let ctError = writeError as? CloudTuneError {
                throw ctError
            }
            throw CloudTuneError.exportPermissionRevoked("导出文件失败: \(writeError.localizedDescription)")
        }
        return targetURL
    }

    /// Non-destructive migration from legacy Tauri directories (`com.gosu.cloudtune` flat root,
    /// `/Applications/CloudTune.app/Contents/MacOS/data`, and `com.cloudtune.desktop`) if present.
    public func migrateLegacyTauriDataIfPresent(
        legacyRoot: URL? = nil,
        candidateRoots: [URL]? = nil
    ) -> PersistedRefreshCredential? {
        let marker = rootDirectory.appendingPathComponent(".migrated-v2")
        guard !fm.fileExists(atPath: marker.path) else { return nil }

        let rawCandidates: [URL]
        if let candidateRoots {
            rawCandidates = candidateRoots
        } else if let legacyRoot {
            rawCandidates = [legacyRoot]
        } else {
            var defaults: [URL] = [
                rootDirectory,
                URL(fileURLWithPath: "/Applications/CloudTune.app/Contents/MacOS/data", isDirectory: true)
            ]
            if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                defaults.append(appSupport.appendingPathComponent("com.cloudtune.desktop", isDirectory: true))
            }
            rawCandidates = defaults
        }

        var seenPaths = Set<String>()
        var matchedCandidate: URL?
        var parsedSettings: [String: Any]?
        var bestScore = -1
        for dir in rawCandidates {
            let stdPath = dir.standardizedFileURL.path
            guard seenPaths.insert(stdPath).inserted else { continue }
            let settingsURL = dir.appendingPathComponent("settings.json")
            guard let settingsData = try? Data(contentsOf: settingsURL),
                  let json = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
                continue
            }
            let hasToken = (Cloud189Protocol.stringValue(json["refreshToken"]) != nil)
            let hasAccount = (Cloud189Protocol.stringValue(json["accountName"]) != nil)
            let hasFolder = (Cloud189Protocol.stringValue(json["musicFolderId"]) != nil)
            let hasLibrary = fm.fileExists(atPath: dir.appendingPathComponent("library.json").path)
            let score = (hasToken ? 8 : 0) + (hasAccount ? 4 : 0) + (hasFolder ? 2 : 0) + (hasLibrary ? 1 : 0)
            if score > bestScore {
                bestScore = score
                matchedCandidate = dir
                parsedSettings = json
                if hasToken { break }
            }
        }

        guard let candidate = matchedCandidate, let json = parsedSettings else {
            return nil
        }

        let accountName = Cloud189Protocol.stringValue(json["accountName"])
        let refreshToken = Cloud189Protocol.stringValue(json["refreshToken"]) ?? ""
        let targetAccount: String
        if let accountName, accountName != Cloud189Constants.defaultAccountDisplayName {
            targetAccount = accountName
        } else if !refreshToken.isEmpty {
            targetAccount = Cloud189Protocol.deriveFallbackAccountKey(
                refreshToken: refreshToken,
                accessToken: nil,
                sessionKey: "legacy_account"
            )
        } else {
            targetAccount = "legacy_account"
        }

        if let p = try? paths(for: targetAccount) {
            if !fm.fileExists(atPath: p.settingsURL.path) {
                var migrated = AccountSettings()
                if let fid = Cloud189Protocol.stringValue(json["musicFolderId"]),
                   let fname = Cloud189Protocol.stringValue(json["musicFolderName"]) {
                    migrated.musicFolder = FolderSelection(id: fid, name: fname)
                }
                if let limit = Cloud189Protocol.intValue(json["cacheLimitMb"]), limit >= Int(AccountSettings.minCacheLimitMB) {
                    migrated.cacheLimitMb = UInt64(limit)
                }
                if let dlThreads = Cloud189Protocol.intValue(json["downloadThreads"]) {
                    migrated.downloadThreads = min(max(1, dlThreads), AccountSettings.maxDownloadThreads)
                }
                if let cThreads = Cloud189Protocol.intValue(json["cacheThreads"]) {
                    migrated.cacheThreads = min(max(1, cThreads), AccountSettings.maxCacheThreads)
                }
                if let modeRaw = Cloud189Protocol.stringValue(json["playbackMode"]),
                   let mode = PlaybackMode(rawValue: modeRaw) {
                    migrated.playbackMode = mode
                }
                if let appRaw = Cloud189Protocol.stringValue(json["appearanceMode"]),
                   let appMode = AppearanceMode(rawValue: appRaw.lowercased()) {
                    migrated.appearanceMode = appMode
                }
                try? saveSettings(migrated, for: targetAccount)
            }
            let legacyLib = candidate.appendingPathComponent("library.json")
            if fm.fileExists(atPath: legacyLib.path), !fm.fileExists(atPath: p.libraryURL.path) {
                try? fm.copyItem(at: legacyLib, to: p.libraryURL)
            }
        }

        try? Data("ok".utf8).write(to: marker, options: .atomic)
        return PersistedRefreshCredential(
            refreshToken: refreshToken,
            accountName: accountName,
            accountKey: targetAccount
        )
    }
}
