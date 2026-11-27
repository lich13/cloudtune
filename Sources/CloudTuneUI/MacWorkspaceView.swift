#if os(macOS)
import AppKit
import AVKit
import CloudTuneCore
import SwiftUI
import UniformTypeIdentifiers

public struct MacWorkspaceView: View {
    @Bindable public var viewModel: CloudTuneViewModel
    @Environment(\.colorScheme) private var colorScheme

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

    public var body: some View {
        let palette = CloudTunePalette(isDark: isDark)
        ZStack {
            CloudTuneBackground(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    heroHeader(palette: palette)

                    if let status = viewModel.settingsValidationError ?? viewModel.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.inkPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(palette.noticeBackground))
                    }

                    if let busy = viewModel.busyLabel, !busy.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(busy)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(palette.busyForeground)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(palette.busyBackground))
                    }

                    if !viewModel.isAuthenticated {
                        authStage(palette: palette)
                    } else {
                        moduleTabRow(palette: palette)
                        HStack(alignment: .top, spacing: 14) {
                            sidebarColumn(palette: palette)
                                .frame(width: 326)
                            mainColumn(palette: palette)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 1420)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
        .sheet(isPresented: $viewModel.isShowingWebLoginSheet) {
            TianyiWebLoginSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.activeVideoURL != nil },
            set: { if !$0 { viewModel.activeVideoURL = nil; viewModel.activeVideoTrack = nil } }
        )) {
            if let videoURL = viewModel.activeVideoURL {
                MacVideoPlayerSheet(
                    title: viewModel.activeVideoTrack?.name ?? "视频播放",
                    url: videoURL,
                    palette: palette,
                    onOpenExternal: { NSWorkspace.shared.open(videoURL) },
                    onClose: { viewModel.activeVideoURL = nil; viewModel.activeVideoTrack = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func heroHeader(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLOUDTUNE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2.0)
                            .foregroundStyle(palette.inkTertiary)
                        Text("天翼云盘音乐播放器")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                        Text(
                            viewModel.isAuthenticated
                                ? "\(viewModel.committedSettings.musicFolder?.name ?? "未设置目录") · \(viewModel.tracks.count) 首"
                                : "扫码或天翼网页登录后立即播放"
                        )
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                    }
                    .frame(minWidth: 230, alignment: .leading)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        statusPill(palette: palette)
                        MetricTile(label: "当前账号", value: viewModel.accountName ?? "等待登录", isMonospacedDigits: false, palette: palette)
                        MetricTile(label: "缓存占用", value: CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes), palette: palette)
                        MetricTile(label: "缓存上限", value: "\(viewModel.committedSettings.cacheLimitMb) MB", palette: palette)
                        MetricTile(label: "下载/缓存线程", value: "\(viewModel.committedSettings.downloadThreads) / \(viewModel.committedSettings.cacheThreads)", palette: palette)
                        MetricTile(label: "实时速度", value: "\(CloudTuneFormatters.formatBytes(viewModel.transferSnapshot.totalSpeedBytesPerSecond))/s", palette: palette)
                    }
                }

                if viewModel.isAuthenticated {
                    Divider().overlay(palette.cardBorder)
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("上限(MB)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.inkTertiary)
                            TextField("2048", text: $viewModel.cacheLimitDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(palette.inkPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: 82)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.accentBorder, lineWidth: 1))
                                .onChange(of: viewModel.cacheLimitDraft) { _, _ in viewModel.noteDraftEdited() }
                                .onSubmit { Task { await viewModel.commitCacheLimitDraft() } }
                            SecondaryActionButton("保存上限", palette: palette) {
                                Task { await viewModel.commitCacheLimitDraft() }
                            }
                        }

                        HStack(spacing: 6) {
                            Text("下载/缓存线程")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.inkTertiary)
                            TextField("8", text: $viewModel.downloadThreadsDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(palette.inkPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: 52)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.accentBorder, lineWidth: 1))
                                .onChange(of: viewModel.downloadThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                            TextField("4", text: $viewModel.cacheThreadsDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(palette.inkPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: 52)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.accentBorder, lineWidth: 1))
                                .onChange(of: viewModel.cacheThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                            SecondaryActionButton("保存线程", palette: palette) {
                                Task { await viewModel.commitTransferThreadsDraft() }
                            }
                        }

                        Spacer(minLength: 6)

                        HStack(spacing: 6) {
                            ToggleChipButton(
                                "优先缓存",
                                systemImage: "internaldrive",
                                isActive: viewModel.committedSettings.playbackMode == .downloadFirst,
                                palette: palette
                            ) {
                                Task { await viewModel.updatePlaybackMode(.downloadFirst) }
                            }
                            ToggleChipButton(
                                "边播边缓存",
                                systemImage: "waveform.path.ecg",
                                isActive: viewModel.committedSettings.playbackMode == .streamCache,
                                palette: palette
                            ) {
                                Task { await viewModel.updatePlaybackMode(.streamCache) }
                            }
                            ToggleChipButton(
                                isDark ? "松林暗夜" : "暖羊皮纸",
                                systemImage: isDark ? "moon.stars.fill" : "sun.max.fill",
                                isActive: false,
                                palette: palette
                            ) {
                                viewModel.appearancePreference = isDark ? .light : .dark
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(palette: CloudTunePalette) -> some View {
        Text(viewModel.isAuthenticated ? "已连接天翼云盘" : "未登录")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(viewModel.isAuthenticated ? Color.white : palette.inkSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    viewModel.isAuthenticated
                        ? AnyShapeStyle(palette.onlineGradient)
                        : AnyShapeStyle(palette.inkPrimary.opacity(0.08))
                )
            )
    }

    @ViewBuilder
    private func authStage(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette, padding: 22) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("扫码或网页登录")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)
                    Text("用天翼云盘 App 扫码，或直接打开官方登录页。")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)

                    HStack(spacing: 10) {
                        PrimaryActionButton(
                            viewModel.qrPNGData != nil ? "重新生成二维码" : "生成扫码二维码",
                            systemImage: "qrcode",
                            palette: palette,
                            isDisabled: viewModel.isBootstrapping || viewModel.busyLabel != nil
                        ) {
                            Task { await viewModel.beginQrLogin() }
                        }
                        SecondaryActionButton("天翼官方网页登录", systemImage: "globe", palette: palette) {
                            viewModel.isShowingWebLoginSheet = true
                        }
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
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                QrCodeArtworkView(
                    pngData: viewModel.qrPNGData,
                    hint: viewModel.qrHint,
                    host: viewModel.qrHost,
                    palette: palette
                )
            }
        }
    }

    @ViewBuilder
    private func moduleTabRow(palette: CloudTunePalette) -> some View {
        HStack(spacing: 8) {
            ForEach([ModuleTab.music, .video, .download]) { tab in
                let icon: String = switch tab {
                case .music: "music.note.list"
                case .video: "film"
                case .download: "arrow.down.circle"
                case .settings: "gearshape"
                }
                ToggleChipButton(
                    tab.title,
                    systemImage: icon,
                    isActive: viewModel.activeModule == tab,
                    palette: palette
                ) {
                    viewModel.activeModule = tab
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarColumn(palette: CloudTunePalette) -> some View {
        VStack(spacing: 13) {
            GlassCard(palette: palette) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("账户")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                        Spacer()
                        SecondaryActionButton("退出登录", systemImage: "rectangle.portrait.and.arrow.right", palette: palette) {
                            Task { await viewModel.logout() }
                        }
                    }

                    labeledValue("账号", viewModel.accountName ?? "未登录", palette: palette)
                    if viewModel.activeModule == .music {
                        labeledValue("当前音乐目录", viewModel.committedSettings.musicFolder?.name ?? "尚未设置", palette: palette)
                        labeledValue("库内曲目", "\(viewModel.tracks.count) 首", palette: palette)
                        SecondaryActionButton("扫描音乐库", systemImage: "arrow.clockwise", palette: palette) {
                            Task { await viewModel.scanMusicLibrary() }
                        }
                    }
                    if viewModel.activeModule == .download {
                        labeledValue("导出目录", viewModel.committedSettings.exportFolderDisplayName ?? "下载时选择", palette: palette)
                        SecondaryActionButton("选择导出文件夹", systemImage: "folder.badge.gearshape", palette: palette) {
                            if let url = pickDirectoryViaOpenPanel() {
                                Task { await viewModel.saveExportDirectoryBookmark(url) }
                            }
                        }
                        if let currentTrack = viewModel.currentTrack {
                            SecondaryActionButton("下载当前曲目", systemImage: "arrow.down.doc", palette: palette) {
                                Task {
                                    if viewModel.committedSettings.exportFolderDisplayName == nil {
                                        if let dir = pickDirectoryViaOpenPanel() {
                                            await viewModel.saveExportDirectoryBookmark(dir)
                                            await viewModel.enqueueTrackDownload(currentTrack, explicitDirectoryURL: dir)
                                        }
                                    } else {
                                        await viewModel.enqueueTrackDownload(currentTrack)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            GlassCard(palette: palette) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(viewModel.activeModule == .music ? "音乐目录" : (viewModel.activeModule == .video ? "视频目录" : "下载目录"))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                        Spacer()
                        SecondaryActionButton("根目录", palette: palette) {
                            Task { await viewModel.browseTo(folderId: nil, nextBreadcrumbs: [.root]) }
                        }
                        SecondaryActionButton("下载文件夹", palette: palette, isDisabled: viewModel.browser == nil) {
                            Task {
                                if viewModel.committedSettings.exportFolderDisplayName == nil {
                                    if let dir = pickDirectoryViaOpenPanel() {
                                        await viewModel.saveExportDirectoryBookmark(dir)
                                        await viewModel.enqueueCurrentFolderDownload(explicitDirectoryURL: dir)
                                    }
                                } else {
                                    await viewModel.enqueueCurrentFolderDownload()
                                }
                            }
                        }
                    }

                    // Breadcrumbs
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                                Button {
                                    let prefix = Array(viewModel.breadcrumbs.prefix(idx + 1))
                                    Task { await viewModel.browseTo(folderId: crumb.id, nextBreadcrumbs: prefix) }
                                } label: {
                                    Text(crumb.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(palette.inkPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(palette.noticeBackground))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(idx == viewModel.breadcrumbs.count - 1)
                            }
                        }
                    }

                    if viewModel.activeModule == .music {
                        PrimaryActionButton("设为音乐库", systemImage: "checkmark.circle", palette: palette) {
                            Task { await viewModel.setCurrentFolderAsMusicLibrary() }
                        }
                    }

                    VStack(spacing: 6) {
                        ForEach(viewModel.browser?.folders ?? []) { folder in
                            FolderRowButton(folder: folder, palette: palette) {
                                let next = viewModel.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                                Task { await viewModel.browseTo(folderId: folder.id, nextBreadcrumbs: next) }
                            }
                        }
                    }

                    if viewModel.activeModule == .music, let audios = viewModel.browser?.audioFiles, !audios.isEmpty {
                        Text("当前目录音频")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(palette.inkPrimary)
                            .padding(.top, 4)
                        VStack(spacing: 6) {
                            ForEach(audios) { track in
                                TrackRowButton(
                                    track: track,
                                    isActive: track.id == viewModel.currentTrackId,
                                    actionLabel: "试听",
                                    palette: palette
                                ) {
                                    Task { await viewModel.playTrack(track) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mainColumn(palette: CloudTunePalette) -> some View {
        switch viewModel.activeModule {
        case .music, .settings:
            VStack(spacing: 13) {
                playerCard(palette: palette)
                musicLibraryCard(palette: palette)
            }
        case .video:
            videoLibraryCard(palette: palette)
        case .download:
            VStack(spacing: 13) {
                transferQueueCard(palette: palette)
                downloadFilesCard(palette: palette)
            }
        }
    }

    @ViewBuilder
    private func playerCard(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在播放")
                            .font(.system(size: 13.5, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                        Text(viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "还没有选择歌曲")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(viewModel.currentTrack?.folderPath ?? "点击播放键会随机起播。")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        SecondaryActionButton("上一首", systemImage: "backward.fill", palette: palette) {
                            Task { await viewModel.playAdjacent(direction: -1) }
                        }
                        PrimaryActionButton(
                            viewModel.isPlaying ? "暂停" : (viewModel.currentTrack != nil ? "播放" : "随机播放"),
                            systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                            palette: palette,
                            minWidth: 108
                        ) {
                            Task { await viewModel.togglePlayback() }
                        }
                        SecondaryActionButton("下一首", systemImage: "forward.fill", palette: palette) {
                            Task { await viewModel.playAdjacent(direction: 1) }
                        }
                    }
                }

                VStack(spacing: 4) {
                    WarmProgressSlider(
                        value: viewModel.currentTime,
                        total: viewModel.duration,
                        palette: palette
                    ) { next in
                        Task { await viewModel.seekPlayback(to: next) }
                    }
                    HStack {
                        Text(CloudTuneFormatters.formatClock(viewModel.currentTime))
                        Spacer()
                        Text(CloudTuneFormatters.formatClock(viewModel.duration))
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                }

                HStack(spacing: 8) {
                    ToggleChipButton(
                        "随机播放",
                        systemImage: "shuffle",
                        isActive: viewModel.shuffle,
                        palette: palette
                    ) {
                        viewModel.shuffle.toggle()
                    }
                    let loopTitle: String = switch viewModel.loopMode {
                    case .off: "不循环"
                    case .all: "列表循环"
                    case .one: "单曲循环"
                    }
                    ToggleChipButton(
                        loopTitle,
                        systemImage: viewModel.loopMode == .one ? "repeat.1" : "repeat",
                        isActive: viewModel.loopMode != .off,
                        palette: palette
                    ) {
                        viewModel.loopMode = switch viewModel.loopMode {
                        case .off: .all
                        case .all: .one
                        case .one: .off
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func musicLibraryCard(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 12) {
                    Text("音乐列表")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(palette.inkTertiary)
                        TextField("搜索文件名或目录", text: $viewModel.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .foregroundStyle(palette.inkPrimary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.inputSurface))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(palette.accentBorder, lineWidth: 1))
                }

                VStack(spacing: 7) {
                    ForEach(viewModel.visibleTracks) { track in
                        TrackRowButton(
                            track: track,
                            isActive: track.id == viewModel.currentTrackId,
                            actionLabel: viewModel.loadingTrackId == track.id ? "缓存中..." : "播放",
                            palette: palette
                        ) {
                            Task { await viewModel.playTrack(track) }
                        }
                    }
                    if viewModel.visibleTracks.isEmpty {
                        Text("暂无匹配曲目，请先在左侧选择音乐目录并扫描。")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.inkTertiary)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func videoLibraryCard(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 11) {
                Text("视频")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(palette.inkPrimary)
                let videos = viewModel.browser?.videoFiles ?? []
                if videos.isEmpty {
                    Text("当前目录没有视频文件。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(videos) { video in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(video.name)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(palette.inkPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(video.folderPath) · \(CloudTuneFormatters.formatBytes(video.sizeBytes))")
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(palette.inkTertiary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                SecondaryActionButton("应用内播放", systemImage: "play.rectangle.fill", palette: palette) {
                                    Task { await viewModel.openVideoInApp(video) }
                                }
                                SecondaryActionButton("系统播放", systemImage: "arrow.up.right.square", palette: palette) {
                                    Task {
                                        if let url = await viewModel.prepareVideoForExternalApp(video) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(palette.rowSurface))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transferQueueCard(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Text("传输任务")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(palette.inkPrimary)
                if viewModel.downloadTransfers.isEmpty {
                    Text("当前没有活动传输。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.vertical, 8)
                } else {
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
            }
        }
    }

    @ViewBuilder
    private func downloadFilesCard(palette: CloudTunePalette) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Text("下载")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(palette.inkPrimary)
                let files = viewModel.downloadableBrowserFiles
                if files.isEmpty {
                    Text("当前目录没有可下载文件。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 7) {
                        ForEach(files) { file in
                            TrackRowButton(track: file, actionLabel: "下载", palette: palette) {
                                Task {
                                    if viewModel.committedSettings.exportFolderDisplayName == nil {
                                        if let dir = pickDirectoryViaOpenPanel() {
                                            await viewModel.saveExportDirectoryBookmark(dir)
                                            await viewModel.enqueueTrackDownload(file, explicitDirectoryURL: dir)
                                        }
                                    } else {
                                        await viewModel.enqueueTrackDownload(file)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labeledValue(_ label: String, _ value: String, palette: CloudTunePalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.inkTertiary)
            Text(value)
                .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                .foregroundStyle(palette.inkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
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
            try? pngData.write(to: url, options: .atomic)
            viewModel.statusMessage = "二维码已保存至 \(url.lastPathComponent)"
        }
    }
}

struct MacVideoPlayerSheet: View {
    let title: String
    let url: URL
    let palette: CloudTunePalette
    let onOpenExternal: () -> Void
    let onClose: () -> Void
    @State private var videoPlayer: AVPlayer

    init(title: String, url: URL, palette: CloudTunePalette, onOpenExternal: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.url = url
        self.palette = palette
        self.onOpenExternal = onOpenExternal
        self.onClose = onClose
        _videoPlayer = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                    .lineLimit(1)
                Spacer()
                SecondaryActionButton("用系统播放器打开", systemImage: "arrow.up.right.square", palette: palette, action: onOpenExternal)
                SecondaryActionButton("关闭", systemImage: "xmark", palette: palette) {
                    videoPlayer.pause()
                    onClose()
                }
            }
            .padding(12)
            .background(palette.cardStrong)

            VideoPlayer(player: videoPlayer)
                .frame(minWidth: 840, minHeight: 500)
                .onAppear { videoPlayer.play() }
                .onDisappear { videoPlayer.pause() }
        }
    }
}
#endif
