#if os(macOS)
import AppKit
import AVKit
import CloudTuneCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    public static let cloudTuneOpenPreferences = Notification.Name("com.gosu.cloudtune.openPreferences")
    public static let cloudTuneFocusSearch = Notification.Name("com.gosu.cloudtune.focusSearch")
}

public enum MacShortcutFocusGuard {
    @MainActor
    public static func shouldAllowSingleKeyPlaybackShortcut(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else {
            return true
        }
        if responder is NSText {
            return false
        }
        var currentView = responder as? NSView
        while let view = currentView {
            if NSStringFromClass(type(of: view)).contains("WKWebView") {
                return false
            }
            currentView = view.superview
        }
        return true
    }
}

private extension TrackSummary {
    var modifiedSortKey: String {
        modifiedAt ?? ""
    }
}

public struct MacWorkspaceView: View {
    @Bindable public var viewModel: CloudTuneViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTrackIDs: Set<TrackSummary.ID> = []
    @State private var sortOrder: [KeyPathComparator<TrackSummary>] = [
        .init(\.name, order: .forward)
    ]
    @State private var scrubPreviewSeconds: Double?
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: CloudTuneViewModel) {
        self.viewModel = viewModel
    }

    private var isDark: Bool {
        switch viewModel.appearancePreference {
        case .light: return false
        case .dark: return true
        case .system: return colorScheme == .dark
        }
    }

    private var sortedVisibleTracks: [TrackSummary] {
        viewModel.visibleTracks.sorted(using: sortOrder)
    }

    private var sidebarModules: [ModuleTab] {
        [.music, .video, .cloud, .transfers]
    }

    public var body: some View {
        let palette = CloudTunePalette(isDark: isDark)
        ZStack {
            palette.canvasBackground
                .ignoresSafeArea()

            if !viewModel.isAuthenticated {
                authStage(palette: palette)
            } else {
                authenticatedWorkbench(palette: palette)
            }

            if viewModel.isShowingSettingsSheet {
                ZStack {
                    Color.black.opacity(isDark ? 0.48 : 0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            _ = viewModel.canCloseSettingsSurface()
                        }
                    MacPreferencesView(
                        viewModel: viewModel,
                        onClose: {
                            Task { @MainActor in
                                if await viewModel.commitPendingSettingsDraftsIfNeeded() {
                                    viewModel.isShowingSettingsSheet = false
                                }
                            }
                        }
                    )
                    .frame(width: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.surfacePrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(palette.cardBorder, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.16), radius: 28, x: 0, y: 12)
                }
            }
        }
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .cloudTuneFocusSearch)) { _ in
            if viewModel.isAuthenticated {
                let needsModuleSwitch = viewModel.activeModule != .music
                viewModel.activeModule = .music
                isSearchFocused = true
                if needsModuleSwitch {
                    Task { @MainActor in
                        isSearchFocused = true
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingWebLoginSheet) {
            TianyiWebLoginSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.activeVideoURL != nil },
            set: {
                if !$0 {
                    viewModel.activeVideoURL = nil
                    viewModel.activeVideoTrack = nil
                }
            }
        )) {
            if let videoURL = viewModel.activeVideoURL {
                MacVideoPlayerSheet(
                    title: viewModel.activeVideoTrack?.name ?? "视频播放",
                    url: videoURL,
                    palette: palette,
                    onOpenExternal: {
                        if let track = viewModel.activeVideoTrack {
                            viewModel.activeVideoURL = nil
                            viewModel.activeVideoTrack = nil
                            Task { await triggerExternalVideoFlow(track) }
                        }
                    },
                    onClose: {
                        viewModel.activeVideoURL = nil
                        viewModel.activeVideoTrack = nil
                    }
                )
                .id(videoURL)
            }
        }
        .sheet(item: $viewModel.pendingExternalVideoChoice) { choice in
            MacExternalVideoChoiceSheet(
                choice: choice,
                palette: palette,
                onDownloadThenOpen: {
                    Task {
                        if let localURL = await viewModel.downloadVideoAndPrepareLocalFile(choice.video) {
                            NSWorkspace.shared.open(localURL)
                        }
                    }
                },
                onOpenStreamInInstalledPlayer: { appURL in
                    viewModel.pendingExternalVideoChoice = nil
                    if let streamURL = choice.streamURL, streamURL.host == "127.0.0.1" {
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.open([streamURL], withApplicationAt: appURL, configuration: config)
                    }
                },
                onCancel: {
                    viewModel.pendingExternalVideoChoice = nil
                }
            )
        }
    }

    @ViewBuilder
    private func authStage(palette: CloudTunePalette) -> some View {
        VStack(spacing: 18) {
            if let status = viewModel.settingsValidationError ?? viewModel.busyLabel ?? viewModel.statusMessage,
               !status.isEmpty {
                SubtleStatusBanner(
                    message: status,
                    isError: viewModel.credentialIssue != nil || status.contains("失败"),
                    busyLabel: viewModel.busyLabel,
                    palette: palette
                )
                .frame(maxWidth: 760)
            }

            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ArtworkView(
                            artworkData: nil,
                            seedText: "CloudTune",
                            size: 46,
                            cornerRadius: 12,
                            palette: palette
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CloudTune")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(palette.inkPrimary)
                            Text("天翼云盘无损音乐与媒体工作台")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.inkSecondary)
                        }
                    }

                    Text("使用天翼云盘 App 扫码，或通过内嵌官方网页一键完成登录。")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        PrimaryActionButton(
                            viewModel.qrPNGData != nil ? "刷新扫码二维码" : "生成扫码二维码",
                            systemImage: "qrcode",
                            palette: palette,
                            isDisabled: viewModel.isBootstrapping || viewModel.busyLabel != nil
                        ) {
                            Task { await viewModel.beginQrLogin() }
                        }
                        SecondaryActionButton("天翼官方网页登录", systemImage: "globe", palette: palette) {
                            viewModel.isShowingWebLoginSheet = true
                        }
                    }

                    HStack(spacing: 10) {
                        if let qrPNG = viewModel.qrPNGData {
                            SecondaryActionButton("保存二维码图片", systemImage: "square.and.arrow.down", palette: palette) {
                                saveQRImageToDisk(qrPNG)
                            }
                        }
                        if viewModel.credentialIssue != nil {
                            SecondaryActionButton("重试读取钥匙串", systemImage: "key.fill", palette: palette) {
                                Task { await viewModel.bootstrap(userInitiatedKeychainRetry: true) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)

                QrCodeArtworkView(
                    pngData: viewModel.qrPNGData,
                    hint: viewModel.qrHint,
                    host: viewModel.qrHost,
                    palette: palette
                )
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func authenticatedWorkbench(palette: CloudTunePalette) -> some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarPane(palette: palette)
                    .navigationSplitViewColumnWidth(min: 205, ideal: 224, max: 256)
            } detail: {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        detailHeaderBar(palette: palette)
                        Divider().overlay(palette.separator)
                        if let status = viewModel.settingsValidationError ?? viewModel.busyLabel ?? viewModel.statusMessage,
                           !status.isEmpty {
                            let isErr = viewModel.settingsValidationError != nil
                                || status.contains("失败")
                                || status.contains("不受系统解码器支持")
                                || status.contains("已停止自动重试")
                            SubtleStatusBanner(
                                message: status,
                                isError: isErr,
                                busyLabel: viewModel.busyLabel,
                                palette: palette,
                                onDismiss: { viewModel.statusMessage = nil }
                            )
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                        }
                        detailModuleContent(palette: palette)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if viewModel.isShowingNowPlayingSheet || viewModel.isShowingQueuePopover {
                        Divider().overlay(palette.separator)
                        nowPlayingInspectorPane(palette: palette)
                            .frame(width: 316)
                    }
                }
                .background(palette.canvasBackground)
            }

            Divider().overlay(palette.separator)

            macNowPlayingBar(palette: palette)
        }
    }

    @ViewBuilder
    private func sidebarPane(palette: CloudTunePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ArtworkView(
                    artworkData: nil,
                    seedText: "CloudTune",
                    size: 28,
                    cornerRadius: 7,
                    palette: palette
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("CloudTune")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                    Text(viewModel.accountName ?? "已连接")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Text("资料库与云盘")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            ForEach(sidebarModules) { tab in
                let isSelected = (viewModel.activeModule == tab)
                    || (viewModel.activeModule == .settings && tab == .music)
                Button {
                    viewModel.activeModule = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                            .frame(width: 18)
                            .foregroundStyle(isSelected ? palette.accent : palette.inkSecondary)
                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? palette.inkPrimary : palette.inkSecondary)
                        Spacer(minLength: 4)
                        if tab == .music && !viewModel.tracks.isEmpty {
                            Text("\(viewModel.tracks.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(palette.inkTertiary)
                        } else if tab == .transfers && !viewModel.transferSnapshot.items.isEmpty {
                            Text("\(viewModel.transferSnapshot.items.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? palette.rowActiveSurface : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            Divider().overlay(palette.separator)

            HStack(spacing: 6) {
                Button {
                    NotificationCenter.default.post(name: .cloudTuneOpenPreferences, object: nil)
                    if NSApp.windows.first(where: { $0.identifier?.rawValue == "cloudtune.preferences" }) == nil {
                        viewModel.isShowingSettingsSheet = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("偏好设置…")
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(palette.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.rowHoverSurface)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                MacPopUpMenuButton(
                    systemImage: "ellipsis.circle",
                    accessibilityTitle: "账户操作"
                ) {
                    [
                        .item(title: "扫描音乐库", systemImage: "arrow.clockwise") {
                            Task { await viewModel.scanMusicLibrary() }
                        },
                        .item(
                            title: "切换深浅外观",
                            systemImage: isDark ? "sun.max" : "moon"
                        ) {
                            Task { await viewModel.setAppearanceMode(isDark ? .light : .dark) }
                        },
                        .separator,
                        .item(title: "退出登录", systemImage: "rectangle.portrait.and.arrow.right") {
                            Task { await viewModel.logout() }
                        }
                    ]
                }
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(palette.sidebarBackground.opacity(0.86))
    }

    @ViewBuilder
    private func detailHeaderBar(palette: CloudTunePalette) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                let effectiveTitle = viewModel.activeModule == .settings ? ModuleTab.music.title : viewModel.activeModule.title
                Text(effectiveTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                let subtitle: String = switch viewModel.activeModule {
                case .music, .settings:
                    "\(viewModel.committedSettings.musicFolder?.name ?? "尚未设置音乐目录") · 共 \(viewModel.visibleTracks.count) 首 · 缓存 \(CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes))"
                case .video:
                    "\(viewModel.videoBrowser.payload?.currentFolderName ?? "我的云盘") · \(viewModel.videoBrowser.payload?.videoFiles.count ?? 0) 个视频"
                case .cloud:
                    "\(viewModel.cloudBrowser.payload?.currentFolderName ?? "我的云盘") · \(viewModel.cloudBrowser.payload?.folders.count ?? 0) 个文件夹 · \(viewModel.downloadableBrowserFiles.count) 个文件"
                case .transfers:
                    "实时速率 \(CloudTuneFormatters.formatBytes(viewModel.transferSnapshot.totalSpeedBytesPerSecond))/s · 导出目录 \(viewModel.committedSettings.exportFolderDisplayName ?? "未指定")"
                }
                Text(subtitle)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if viewModel.activeModule == .music || viewModel.activeModule == .settings {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                    TextField("过滤曲目或目录 (⌘F)", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 180)
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.inkTertiary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.inputSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.accentBorder, lineWidth: 1)
                )

                SecondaryActionButton("扫描曲库", systemImage: "arrow.clockwise", palette: palette) {
                    Task { await viewModel.scanMusicLibrary() }
                }
                SecondaryActionButton("切换曲库目录", systemImage: "folder", palette: palette) {
                    viewModel.activeModule = .cloud
                }
            } else if viewModel.activeModule == .transfers {
                SecondaryActionButton("选择导出目录", systemImage: "folder.badge.gearshape", palette: palette) {
                    if let url = pickDirectoryViaOpenPanel() {
                        Task { await viewModel.saveExportDirectoryBookmark(url) }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.surfacePrimary)
    }

    @ViewBuilder
    private func detailModuleContent(palette: CloudTunePalette) -> some View {
        switch viewModel.activeModule {
        case .music, .settings:
            musicTablePane(palette: palette)
        case .video:
            videoWorkspacePane(palette: palette)
        case .cloud:
            cloudBrowserPane(palette: palette)
        case .transfers:
            transfersWorkspacePane(palette: palette)
        }
    }

    @ViewBuilder
    private func musicTablePane(palette: CloudTunePalette) -> some View {
        let rows = sortedVisibleTracks
        if rows.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(palette.inkTertiary)
                Text(viewModel.searchQuery.isEmpty ? "曲库暂无音乐" : "未找到匹配的曲目")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("可在左侧进入「云盘」选择音乐目录并点击「设为音乐库」。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.inkTertiary)
                SecondaryActionButton("前往云盘目录", systemImage: "icloud", palette: palette) {
                    viewModel.activeModule = .cloud
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows, selection: $selectedTrackIDs, sortOrder: $sortOrder) {
                TableColumn("曲目", value: \.name) { track in
                    let isCurrent = track.id == viewModel.currentTrackId
                    HStack(spacing: 10) {
                        ArtworkView(
                            artworkData: isCurrent ? viewModel.nowPlayingMetadata?.artworkData : nil,
                            seedText: track.name,
                            size: 28,
                            cornerRadius: 6,
                            palette: palette
                        )
                        if isCurrent {
                            Image(systemName: viewModel.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.accent)
                        }
                        Text(track.name)
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? palette.accent : palette.inkPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        LosslessBadge(track: track, palette: palette)
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 2)
                }
                .width(min: 280, ideal: 420)

                TableColumn("所属目录", value: \.folderPath) { track in
                    Text(track.folderPath)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 160, ideal: 240)

                TableColumn("大小", value: \.sizeBytes) { track in
                    Text(CloudTuneFormatters.formatBytes(track.sizeBytes))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 76, ideal: 88, max: 110)

                TableColumn("更新时间", value: \.modifiedSortKey) { track in
                    Text(track.modifiedAt ?? "—")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                }
                .width(min: 132, ideal: 152, max: 175)

                TableColumn("操作") { track in
                    HStack(spacing: 4) {
                        Button {
                            Task { await viewModel.playTrack(track) }
                        } label: {
                            Image(systemName: track.id == viewModel.currentTrackId && viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .frame(width: 26, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        MacPopUpMenuButton(
                            systemImage: "ellipsis",
                            accessibilityTitle: "曲目更多操作"
                        ) {
                            [
                                .item(title: "立即播放", systemImage: "play.fill") {
                                    Task { await viewModel.playTrack(track) }
                                },
                                .item(title: "下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    viewModel.playNext(track)
                                },
                                .item(title: "加入待播队列", systemImage: "text.append") {
                                    viewModel.appendToQueue(track)
                                },
                                .separator,
                                .item(title: "导出下载到本地", systemImage: "arrow.down.circle") {
                                    Task { await enqueueDownloadEnsuringDirectory(track) }
                                }
                            ]
                        }
                    }
                }
                .width(68)
            }
            .contextMenu(forSelectionType: TrackSummary.ID.self) { selection in
                let targets = rows.filter { selection.contains($0.id) }
                if let first = targets.first {
                    Button("播放《\(first.name)》") {
                        Task { await viewModel.playTrack(first) }
                    }
                    Button("下一首播放") {
                        for item in targets.reversed() {
                            viewModel.playNext(item)
                        }
                    }
                    Button("加入待播队列") {
                        for item in targets {
                            viewModel.appendToQueue(item)
                        }
                    }
                    Divider()
                    Button(targets.count > 1 ? "导出下载选中曲目 (\(targets.count))" : "导出下载") {
                        Task {
                            for item in targets {
                                await enqueueDownloadEnsuringDirectory(item)
                            }
                        }
                    }
                }
            } primaryAction: { selection in
                if let firstID = selection.first,
                   let found = rows.first(where: { $0.id == firstID }) {
                    Task { await viewModel.playTrack(found) }
                }
            }
        }
    }

    @ViewBuilder
    private func videoWorkspacePane(palette: CloudTunePalette) -> some View {
        let pane = viewModel.videoBrowser
        let folders = pane.payload?.folders ?? []
        let videos = pane.payload?.videoFiles ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                browserHeaderStrip(
                    scope: .video,
                    pane: pane,
                    palette: palette,
                    showSetMusicLibrary: false,
                    showDownloadFolder: false
                )

                if !folders.isEmpty {
                    Text("子目录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.inkTertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                        ForEach(folders) { folder in
                            FolderRowButton(folder: folder, palette: palette) {
                                let next = pane.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                                Task { await viewModel.browseTo(scope: .video, folderId: folder.id, nextBreadcrumbs: next) }
                            }
                        }
                    }
                }

                Text("当前目录视频 (\(videos.count))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                    .padding(.top, 4)

                if videos.isEmpty {
                    Text("当前目录暂无视频文件，可进入上方子目录浏览。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(videos) { video in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(palette.accentSoft)
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "film")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(video.name)
                                            .font(.system(size: 13.5, weight: .semibold))
                                            .foregroundStyle(palette.inkPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if !video.fileExtensionUpper.isEmpty {
                                            Text(video.fileExtensionUpper)
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(palette.inkSecondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(palette.surfaceSecondary))
                                        }
                                    }
                                    Text("\(video.folderPath) · \(CloudTuneFormatters.formatBytes(video.sizeBytes))")
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(palette.inkTertiary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                SecondaryActionButton("应用内播放", systemImage: "play.rectangle.fill", palette: palette) {
                                    Task { await viewModel.openVideoInApp(video) }
                                }
                                SecondaryActionButton("外部播放器", systemImage: "arrow.up.right.square", palette: palette) {
                                    Task { await triggerExternalVideoFlow(video) }
                                }
                                SecondaryActionButton("导出", systemImage: "arrow.down.circle", palette: palette) {
                                    Task { await enqueueDownloadEnsuringDirectory(video) }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(palette.surfacePrimary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(palette.cardBorder, lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func cloudBrowserPane(palette: CloudTunePalette) -> some View {
        let pane = viewModel.cloudBrowser
        let folders = pane.payload?.folders ?? []
        let audios = pane.payload?.audioFiles ?? []
        let others = (pane.payload?.videoFiles ?? []) + (pane.payload?.otherFiles ?? [])

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                browserHeaderStrip(
                    scope: .cloud,
                    pane: pane,
                    palette: palette,
                    showSetMusicLibrary: true,
                    showDownloadFolder: true
                )

                if !folders.isEmpty {
                    Text("文件夹 (\(folders.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                        ForEach(folders) { folder in
                            FolderRowButton(folder: folder, palette: palette) {
                                let next = pane.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                                Task { await viewModel.browseTo(scope: .cloud, folderId: folder.id, nextBreadcrumbs: next) }
                            }
                        }
                    }
                }

                if !audios.isEmpty {
                    Text("音频文件 (\(audios.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 6) {
                        ForEach(audios) { track in
                            TrackRowButton(
                                track: track,
                                isActive: track.id == viewModel.currentTrackId,
                                actionLabel: track.id == viewModel.currentTrackId && viewModel.isPlaying ? "播放中" : "试听",
                                palette: palette,
                                action: {
                                    Task { await viewModel.playTrack(track) }
                                }
                            ) {
                                MacPopUpMenuButton(
                                    systemImage: "ellipsis.circle",
                                    accessibilityTitle: "云盘音频操作"
                                ) {
                                    [
                                        .item(title: "立即试听", systemImage: "play.fill") {
                                            Task { await viewModel.playTrack(track) }
                                        },
                                        .item(title: "下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                            viewModel.playNext(track)
                                        },
                                        .item(title: "加入待播队列", systemImage: "text.append") {
                                            viewModel.appendToQueue(track)
                                        },
                                        .separator,
                                        .item(title: "导出下载", systemImage: "arrow.down.circle") {
                                            Task { await enqueueDownloadEnsuringDirectory(track) }
                                        }
                                    ]
                                }
                            }
                        }
                    }
                }

                if !others.isEmpty {
                    Text("视频与附件 (\(others.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 6) {
                        ForEach(others) { item in
                            TrackRowButton(track: item, actionLabel: "导出下载", palette: palette) {
                                Task { await enqueueDownloadEnsuringDirectory(item) }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func transfersWorkspacePane(palette: CloudTunePalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.transferSnapshot.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(palette.inkTertiary)
                        Text("当前没有传输任务")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                        Text("从「曲库」右键导出，或在「云盘」点击整夹下载后在此查看实时分片进度。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    if !viewModel.downloadTransfers.isEmpty {
                        Text("导出下载 (\(viewModel.downloadTransfers.count))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                        VStack(spacing: 8) {
                            ForEach(viewModel.downloadTransfers) { item in
                                TransferRowCardView(
                                    item: item,
                                    palette: palette,
                                    onPause: { Task { await viewModel.pauseTransfer(item.id) } },
                                    onResume: { Task { await viewModel.resumeTransfer(item.id) } },
                                    onDelete: { Task { await viewModel.deleteTransfer(item.id) } }
                                )
                            }
                        }
                    }

                    if !viewModel.activeStreamAndCacheTransfers.isEmpty {
                        Text("流式写穿与预取缓存 (\(viewModel.activeStreamAndCacheTransfers.count))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                            .padding(.top, 6)
                        VStack(spacing: 8) {
                            ForEach(viewModel.activeStreamAndCacheTransfers) { item in
                                TransferRowCardView(
                                    item: item,
                                    palette: palette,
                                    onPause: {},
                                    onResume: {},
                                    onDelete: {}
                                )
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func browserHeaderStrip(
        scope: BrowserScope,
        pane: BrowserPaneState,
        palette: CloudTunePalette,
        showSetMusicLibrary: Bool,
        showDownloadFolder: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if pane.breadcrumbs.count > 1 {
                SecondaryActionButton("上一级", systemImage: "chevron.left", palette: palette) {
                    Task { await viewModel.navigateBackInBrowser(scope: scope) }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(pane.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                        let isLast = idx == pane.breadcrumbs.count - 1
                        Button {
                            let prefix = Array(pane.breadcrumbs.prefix(idx + 1))
                            Task { await viewModel.browseTo(scope: scope, folderId: crumb.id, nextBreadcrumbs: prefix) }
                        } label: {
                            Text(crumb.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isLast ? palette.accent : palette.inkSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(isLast ? palette.accentSoft : palette.surfaceSecondary)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLast)
                    }
                }
            }

            Spacer(minLength: 8)

            SecondaryActionButton("根目录", palette: palette) {
                Task { await viewModel.browseTo(scope: scope, folderId: nil, nextBreadcrumbs: [.root]) }
            }
            if showDownloadFolder {
                SecondaryActionButton("整夹下载", systemImage: "arrow.down.doc", palette: palette, isDisabled: pane.payload == nil) {
                    Task {
                        if viewModel.committedSettings.exportFolderDisplayName == nil {
                            if let dir = pickDirectoryViaOpenPanel() {
                                await viewModel.saveExportDirectoryBookmark(dir)
                                await viewModel.enqueueFolderDownload(from: pane, explicitDirectoryURL: dir)
                            }
                        } else {
                            await viewModel.enqueueFolderDownload(from: pane)
                        }
                    }
                }
            }
            if showSetMusicLibrary {
                PrimaryActionButton("设为音乐库", systemImage: "checkmark.circle", palette: palette, isDisabled: pane.payload == nil) {
                    Task { await viewModel.setFolderAsMusicLibrary(from: pane) }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func nowPlayingInspectorPane(palette: CloudTunePalette) -> some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "尚未播放曲目"
        let artist = viewModel.nowPlayingMetadata?.artist
        let album = viewModel.nowPlayingMetadata?.album ?? track?.folderPath

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("正在播放与待播队列")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                Spacer()
                Button {
                    viewModel.isShowingNowPlayingSheet = false
                    viewModel.isShowingQueuePopover = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.inkSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                ArtworkView(
                    artworkData: viewModel.nowPlayingMetadata?.artworkData,
                    seedText: title,
                    size: 184,
                    cornerRadius: 16,
                    palette: palette
                )
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        if let track {
                            LosslessBadge(track: track, palette: palette)
                        }
                    }
                    if let subtitle = [artist, album].compactMap({ $0?.isEmpty == false ? $0 : nil }).joined(separator: " · ").nilIfBlank {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(palette.separator)

            HStack {
                Text("接下来播放 (\(viewModel.upcomingTracks.count))")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.inkSecondary)
                Spacer()
                if !viewModel.upNextQueue.isEmpty {
                    Button {
                        viewModel.clearUpNextQueue()
                    } label: {
                        Text("清空插播")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(viewModel.upcomingTracks) { item in
                        let isManual = viewModel.upNextQueue.contains { $0.id == item.id }
                        HStack(spacing: 8) {
                            Button {
                                Task { await viewModel.playFromUpcomingQueue(item) }
                            } label: {
                                HStack(spacing: 8) {
                                    ArtworkView(
                                        artworkData: nil,
                                        seedText: item.name,
                                        size: 30,
                                        cornerRadius: 6,
                                        palette: palette
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(palette.inkPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(isManual ? "手动插播 · \(item.folderPath)" : item.folderPath)
                                            .font(.system(size: 11))
                                            .foregroundStyle(isManual ? palette.accent : palette.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isManual {
                                Button {
                                    viewModel.removeFromQueue(trackId: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(palette.inkTertiary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.surfaceSecondary.opacity(0.75))
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(palette.surfacePrimary)
    }

    @ViewBuilder
    private func macNowPlayingBar(palette: CloudTunePalette) -> some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "尚未选择曲目"
        let subtitle = [
            viewModel.nowPlayingMetadata?.artist,
            viewModel.nowPlayingMetadata?.album ?? track?.folderPath
        ]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: " · ")

        HStack(spacing: 18) {
            // Left: Artwork + Track metadata
            Button {
                viewModel.isShowingQueuePopover.toggle()
                if !viewModel.isShowingQueuePopover {
                    viewModel.isShowingNowPlayingSheet = false
                }
            } label: {
                HStack(spacing: 11) {
                    ArtworkView(
                        artworkData: viewModel.nowPlayingMetadata?.artworkData,
                        seedText: title,
                        size: 44,
                        cornerRadius: 9,
                        palette: palette
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let track {
                                LosslessBadge(track: track, palette: palette)
                            }
                        }
                        Text(subtitle.isEmpty ? "点击曲目或按播放键开始收听" : subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 310, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Center: Transport controls + Scrub slider
            VStack(spacing: 4) {
                HStack(spacing: 14) {
                    barIconButton(
                        systemImage: "shuffle",
                        isActive: viewModel.shuffle,
                        palette: palette
                    ) {
                        viewModel.toggleShuffle()
                    }
                    barIconButton(
                        systemImage: "backward.fill",
                        isDisabled: !viewModel.canSkipPrevious,
                        palette: palette
                    ) {
                        Task { await viewModel.playAdjacent(direction: -1) }
                    }
                    Button {
                        Task { await viewModel.togglePlayback() }
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(palette.primaryForeground)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(palette.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    barIconButton(
                        systemImage: "forward.fill",
                        isDisabled: !viewModel.canSkipNext,
                        palette: palette
                    ) {
                        Task { await viewModel.playAdjacent(direction: 1) }
                    }
                    barIconButton(
                        systemImage: viewModel.loopMode == .one ? "repeat.1" : "repeat",
                        isActive: viewModel.loopMode != .off,
                        palette: palette
                    ) {
                        viewModel.cycleLoopMode()
                    }
                }

                HStack(spacing: 8) {
                    Text(CloudTuneFormatters.formatClock(scrubPreviewSeconds ?? viewModel.currentTime))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .frame(width: 40, alignment: .trailing)

                    InteractiveScrubSlider(
                        value: viewModel.currentTime,
                        total: viewModel.duration,
                        palette: palette,
                        onPreviewChange: { preview in
                            scrubPreviewSeconds = preview
                        },
                        onSeek: { targetSeconds in
                            Task { await viewModel.seekPlayback(to: targetSeconds) }
                        }
                    )

                    Text(CloudTuneFormatters.formatClock(viewModel.duration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .frame(width: 40, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Volume + AirPlay + Queue toggle
            HStack(spacing: 10) {
                Image(systemName: viewModel.volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkSecondary)
                Slider(
                    value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.setVolume($0) }
                    ),
                    in: 0.0...1.0
                )
                .tint(palette.accent)
                .frame(width: 84)

                AirPlayRoutePicker()
                    .frame(width: 26, height: 26)

                barIconButton(
                    systemImage: "list.bullet",
                    isActive: viewModel.isShowingNowPlayingSheet || viewModel.isShowingQueuePopover,
                    palette: palette
                ) {
                    let nextVisible = !(viewModel.isShowingNowPlayingSheet || viewModel.isShowingQueuePopover)
                    viewModel.isShowingQueuePopover = nextVisible
                    if !nextVisible {
                        viewModel.isShowingNowPlayingSheet = false
                    }
                }
            }
            .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .background(palette.surfacePrimary.opacity(0.88))
    }

    @ViewBuilder
    private func barIconButton(
        systemImage: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        palette: CloudTunePalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? palette.accent : palette.inkSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? palette.accentSoft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
    }

    private func triggerExternalVideoFlow(_ video: TrackSummary) async {
        if let cachedURL = await viewModel.requestExternalVideoPlayback(video) {
            NSWorkspace.shared.open(cachedURL)
        }
    }

    private func enqueueDownloadEnsuringDirectory(_ track: TrackSummary) async {
        if viewModel.committedSettings.exportFolderDisplayName == nil {
            if let dir = pickDirectoryViaOpenPanel() {
                await viewModel.saveExportDirectoryBookmark(dir)
                await viewModel.enqueueTrackDownload(track, explicitDirectoryURL: dir)
            }
        } else {
            await viewModel.enqueueTrackDownload(track)
        }
    }

    private func pickDirectoryViaOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func saveQRImageToDisk(_ pngData: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "CloudTune-Tianyi-QRCode.png"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try pngData.write(to: url, options: .atomic)
                viewModel.statusMessage = "二维码已保存至 \(url.lastPathComponent)"
            } catch {
                viewModel.statusMessage = "保存二维码失败：\(error.localizedDescription)"
            }
        }
    }
}

public struct MacPreferencesView: View {
    @Bindable public var viewModel: CloudTuneViewModel
    public let onClose: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: CloudTuneViewModel, onClose: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var isDark: Bool {
        switch viewModel.appearancePreference {
        case .light: return false
        case .dark: return true
        case .system: return colorScheme == .dark
        }
    }

    public var body: some View {
        let palette = CloudTunePalette(isDark: isDark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("CloudTune 偏好设置")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                Spacer()
                if viewModel.hasUnsavedSettingsDrafts {
                    SecondaryActionButton("还原修改", palette: palette) {
                        viewModel.syncDraftsFromCommitted()
                    }
                }
                if let onClose {
                    SecondaryActionButton("完成", palette: palette, action: onClose)
                }
            }

            if let err = viewModel.settingsValidationError, !err.isEmpty {
                SubtleStatusBanner(message: err, isError: true, palette: palette)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("外观与播放策略")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)

                HStack(spacing: 8) {
                    Text("界面主题")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    ForEach(AppearanceMode.allCases) { mode in
                        ToggleChipButton(
                            mode.title,
                            isActive: viewModel.appearancePreference == mode,
                            palette: palette
                        ) {
                            Task { await viewModel.setAppearanceMode(mode) }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("默认播放")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    ForEach(PlaybackMode.allCases, id: \.rawValue) { mode in
                        ToggleChipButton(
                            mode.displayTitle,
                            isActive: viewModel.committedSettings.playbackMode == mode,
                            palette: palette
                        ) {
                            Task { await viewModel.updatePlaybackMode(mode) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceSecondary))

            VStack(alignment: .leading, spacing: 12) {
                Text("缓存上限与并发线程")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)

                HStack(spacing: 8) {
                    Text("当前占用")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    Text("\(CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes)) / \(viewModel.committedSettings.cacheLimitMb) MB")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkSecondary)
                }

                HStack(spacing: 8) {
                    Text("缓存上限 (MB)")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    TextField("2048", text: $viewModel.cacheLimitDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 110)
                        .onChange(of: viewModel.cacheLimitDraft) { _, _ in viewModel.noteDraftEdited() }
                        .onSubmit { Task { await viewModel.commitCacheLimitDraft() } }
                    SecondaryActionButton("应用上限", palette: palette) {
                        Task { await viewModel.commitCacheLimitDraft() }
                    }
                }

                HStack(spacing: 8) {
                    Text("下载 / 预取线程")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    TextField("8", text: $viewModel.downloadThreadsDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 64)
                        .onChange(of: viewModel.downloadThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                    TextField("4", text: $viewModel.cacheThreadsDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 64)
                        .onChange(of: viewModel.cacheThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                    SecondaryActionButton("应用线程", palette: palette) {
                        Task { await viewModel.commitTransferThreadsDraft() }
                    }
                }

                HStack(spacing: 8) {
                    Text("本地导出目录")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 96, alignment: .leading)
                    Text(viewModel.committedSettings.exportFolderDisplayName ?? "未授权目录")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    SecondaryActionButton("选择目录…", systemImage: "folder.badge.gearshape", palette: palette) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let dir = panel.url {
                            Task { await viewModel.saveExportDirectoryBookmark(dir) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceSecondary))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前账号：\(viewModel.accountName ?? "未登录")")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.inkPrimary)
                    Text("音乐库：\(viewModel.committedSettings.musicFolder?.name ?? "未设置") · 导出目录：\(viewModel.committedSettings.exportFolderDisplayName ?? "未设置")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.inkTertiary)
                }
                Spacer()
                if viewModel.isAuthenticated {
                    SecondaryActionButton("退出登录", systemImage: "rectangle.portrait.and.arrow.right", palette: palette) {
                        Task {
                            await viewModel.logout()
                            onClose?()
                        }
                    }
                }
            }
        }
        .padding(22)
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
    }
}

struct MacAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player?.replaceCurrentItem(with: nil)
        nsView.player = nil
    }
}

struct MacVideoPlayerSheet: View {
    let title: String
    let url: URL
    let palette: CloudTunePalette
    let onOpenExternal: () -> Void
    let onClose: () -> Void
    @State private var videoPlayer: AVPlayer

    init(
        title: String,
        url: URL,
        palette: CloudTunePalette,
        onOpenExternal: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.url = url
        self.palette = palette
        self.onOpenExternal = onOpenExternal
        self.onClose = onClose
        _videoPlayer = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .lineLimit(1)
                Spacer()
                SecondaryActionButton("外部播放器打开", systemImage: "arrow.up.right.square", palette: palette, action: onOpenExternal)
                SecondaryActionButton("关闭", systemImage: "xmark", palette: palette) {
                    videoPlayer.pause()
                    onClose()
                }
            }
            .padding(12)
            .background(palette.surfacePrimary)

            Divider().overlay(palette.separator)

            MacAVPlayerRepresentable(player: videoPlayer)
                .frame(minWidth: 880, minHeight: 520)
                .onAppear { videoPlayer.play() }
                .onChange(of: url) { _, nextURL in
                    videoPlayer.pause()
                    videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: nextURL))
                    videoPlayer.play()
                }
                .onDisappear {
                    videoPlayer.pause()
                    videoPlayer.replaceCurrentItem(with: nil)
                }
        }
    }
}

struct MacExternalVideoChoiceSheet: View {
    let choice: PendingExternalVideoChoice
    let palette: CloudTunePalette
    let onDownloadThenOpen: () -> Void
    let onOpenStreamInInstalledPlayer: (URL) -> Void
    let onCancel: () -> Void

    private var installedVideoPlayers: [(name: String, url: URL)] {
        let bundleIds = [
            "com.colliderli.iina",
            "org.videolan.vlc",
            "io.mpv",
            "com.movist.MovistPro",
            "com.apple.QuickTimePlayerX"
        ]
        var found: [(String, URL)] = []
        var seen = Set<String>()
        for id in bundleIds {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               seen.insert(appURL.path).inserted {
                let name = appURL.deletingPathExtension().lastPathComponent
                found.append((name, appURL))
            }
        }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择本地视频打开方式")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.inkPrimary)
            Text("《\(choice.video.name)》尚未缓存到本地。为避免远程链接被交给浏览器，您可以先缓存后打开，或直接指定本机已安装的视频播放器读取本地代理流。")
                .font(.system(size: 13))
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryActionButton("先缓存到本地再打开（推荐）", systemImage: "arrow.down.circle.fill", palette: palette, action: onDownloadThenOpen)

            if choice.streamURL?.host == "127.0.0.1" && !installedVideoPlayers.isEmpty {
                Divider().overlay(palette.separator)
                Text("直接用已安装播放器串流：")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.inkTertiary)
                HStack(spacing: 8) {
                    ForEach(installedVideoPlayers, id: \.url) { player in
                        SecondaryActionButton(player.name, systemImage: "play.tv", palette: palette) {
                            onOpenStreamInInstalledPlayer(player.url)
                        }
                    }
                    SecondaryActionButton("选择其他应用…", systemImage: "folder", palette: palette) {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let appURL = panel.url {
                            onOpenStreamInInstalledPlayer(appURL)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                SecondaryActionButton("取消", palette: palette, action: onCancel)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(palette.surfacePrimary)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
