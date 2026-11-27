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
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw CloudTuneError.invalidRequest("导出文件名为空")
        }

        var targetURL = folderURL
        for part in components.dropLast() {
            targetURL.appendPathComponent(part, isDirectory: true)
        }
        let parentDir = targetURL
        targetURL.appendPathComponent(components.last!, isDirectory: false)

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: targetURL, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                try FileManager.default.copyItem(at: stagedFileURL, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError {
            throw CloudTuneError.exportPermissionRevoked("写入导出目录被拒绝: \(coordinatorError.localizedDescription)")
        }
        if let writeError {
            throw CloudTuneError.exportPermissionRevoked("导出文件失败: \(writeError.localizedDescription)")
        }
        return targetURL
    }

    /// Non-destructive migration from legacy Tauri `com.cloudtune.desktop` directory if present.
    public func migrateLegacyTauriDataIfPresent(legacyRoot: URL? = nil) -> PersistedRefreshCredential? {
        let candidate: URL
        if let legacyRoot {
            candidate = legacyRoot
        } else if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            candidate = appSupport.appendingPathComponent("com.cloudtune.desktop", isDirectory: true)
        } else {
            return nil
        }

        let marker = rootDirectory.appendingPathComponent(".migrated-v1")
        guard !fm.fileExists(atPath: marker.path) else { return nil }
        let legacySettingsURL = candidate.appendingPathComponent("settings.json")
        guard let settingsData = try? Data(contentsOf: legacySettingsURL),
              let json = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            return nil
        }

        let accountName = Cloud189Protocol.stringValue(json["accountName"])
        let refreshToken = Cloud189Protocol.stringValue(json["refreshToken"]) ?? ""
        let targetAccount = accountName ?? "legacy_account"

        if let p = try? paths(for: targetAccount) {
            if !fm.fileExists(atPath: p.settingsURL.path) {
                var migrated = AccountSettings()
                if let fid = Cloud189Protocol.stringValue(json["musicFolderId"]),
                   let fname = Cloud189Protocol.stringValue(json["musicFolderName"]) {
                    migrated.musicFolder = FolderSelection(id: fid, name: fname)
                }
                if let limit = Cloud189Protocol.intValue(json["cacheLimitMb"]), limit >= 256 {
                    migrated.cacheLimitMb = UInt64(limit)
                }
                if let modeRaw = Cloud189Protocol.stringValue(json["playbackMode"]),
                   let mode = PlaybackMode(rawValue: modeRaw) {
                    migrated.playbackMode = mode
                }
                try? saveSettings(migrated, for: targetAccount)
            }
            let legacyLib = candidate.appendingPathComponent("library.json")
            if fm.fileExists(atPath: legacyLib.path), !fm.fileExists(atPath: p.libraryURL.path) {
                try? fm.copyItem(at: legacyLib, to: p.libraryURL)
            }
        }

        try? Data("ok".utf8).write(to: marker, options: .atomic)
        return PersistedRefreshCredential(refreshToken: refreshToken, accountName: accountName)
    }
}
