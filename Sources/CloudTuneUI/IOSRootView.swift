#if os(iOS)
import AVKit
import CloudTuneCore
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct IOSRootView: View {
    @Bindable public var viewModel: CloudTuneViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingFullPlayer = false
    @State private var isShowingFolderPicker = false
    @State private var isShowingShareSheet = false
    @State private var pendingExportTrack: TrackSummary?
    @State private var pendingExportCurrentFolder = false
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

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
        Group {
            if !viewModel.isAuthenticated {
                iosLoginStage(palette: palette)
            } else if horizontalSizeClass == .regular {
                ipadSplitLayout(palette: palette)
            } else {
                iphoneTabLayout(palette: palette)
            }
        }
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
        .sheet(isPresented: $viewModel.isShowingWebLoginSheet) {
            TianyiWebLoginSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingFullPlayer) {
            iosFullPlayerSheet(palette: palette)
        }
        .sheet(isPresented: $isShowingFolderPicker, onDismiss: {
            pendingExportTrack = nil
            pendingExportCurrentFolder = false
        }) {
            IOSFolderPicker { pickedURL in
                let trackToExport = pendingExportTrack
                let shouldExportFolder = pendingExportCurrentFolder
                pendingExportTrack = nil
                pendingExportCurrentFolder = false
                Task {
                    await viewModel.saveExportDirectoryBookmark(pickedURL)
                    if let trackToExport {
                        await viewModel.enqueueTrackDownload(trackToExport, explicitDirectoryURL: pickedURL)
                    } else if shouldExportFolder {
                        await viewModel.enqueueCurrentFolderDownload(explicitDirectoryURL: pickedURL)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.activeVideoURL != nil },
            set: { if !$0 { viewModel.activeVideoURL = nil; viewModel.activeVideoTrack = nil } }
        )) {
            if let videoURL = viewModel.activeVideoURL {
                IOSAVPlayerContainer(url: videoURL)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let url = viewModel.shareFileURL {
                IOSActivityShareSheet(items: [url])
            }
        }
    }

    @ViewBuilder
    private func iosLoginStage(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CLOUDTUNE")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(palette.inkTertiary)
                            Text("天翼云盘音乐播放器")
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(palette.inkPrimary)
                            Text("支持本机天翼网页一键回调登录，或保存二维码至相册扫码")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.inkTertiary)
                        }
                    }

                    if let status = viewModel.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.inkPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.noticeBackground))
                    }

                    GlassCard(palette: palette, padding: 18) {
                        VStack(spacing: 16) {
                            QrCodeArtworkView(
                                pngData: viewModel.qrPNGData,
                                hint: viewModel.qrHint,
                                host: viewModel.qrHost,
                                palette: palette
                            )
                            VStack(spacing: 10) {
                                PrimaryActionButton(
                                    "天翼官方网页一键登录",
                                    systemImage: "safari.fill",
                                    palette: palette,
                                    minWidth: 220
                                ) {
                                    viewModel.isShowingWebLoginSheet = true
                                }
                                SecondaryActionButton(
                                    viewModel.qrPNGData != nil ? "重新生成二维码" : "生成扫码二维码",
                                    systemImage: "qrcode",
                                    palette: palette
                                ) {
                                    Task { await viewModel.beginQrLogin() }
                                }
                                if let pngData = viewModel.qrPNGData {
                                    SecondaryActionButton("保存二维码到系统相册", systemImage: "photo.badge.arrow.down", palette: palette) {
                                        saveQRToPhotoLibrary(pngData)
                                    }
                                }
                                if viewModel.credentialIssue != nil {
                                    SecondaryActionButton("重试读取钥匙串", systemImage: "key.fill", palette: palette) {
                                        Task { await viewModel.bootstrap(userInitiatedKeychainRetry: true) }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func iphoneTabLayout(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            VStack(spacing: 0) {
                NavigationStack {
                    Group {
                        switch viewModel.activeModule {
                        case .music, .cloud: iosMusicTab(palette: palette)
                        case .video: iosVideoTab(palette: palette)
                        case .transfers: iosDownloadTab(palette: palette)
                        case .settings: iosSettingsTab(palette: palette)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 8) {
                    iosMiniPlayerBar(palette: palette)
                        .padding(.horizontal, 12)
                    iosBottomTabBar(palette: palette)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func iosBottomTabBar(palette: CloudTunePalette) -> some View {
        HStack(spacing: 6) {
            ForEach(ModuleTab.allCases) { tab in
                let isSelected = viewModel.activeModule == tab
                let icon = tab.systemImage
                Button {
                    viewModel.activeModule = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? palette.primaryForeground : palette.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(palette.primaryGradient) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.cardStrong.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.accentBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func ipadSplitLayout(palette: CloudTunePalette) -> some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            ZStack {
                CloudTuneBackground(palette: palette)
                VStack(alignment: .leading, spacing: 10) {
                    Text("CloudTune")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)
                        .padding(.horizontal, 12)
                    ForEach(ModuleTab.allCases) { tab in
                        let icon = tab.systemImage
                        Button {
                            viewModel.activeModule = tab
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon)
                                Text(tab.title)
                                    .font(.system(size: 14, weight: .bold))
                                Spacer()
                            }
                            .foregroundStyle(viewModel.activeModule == tab ? palette.primaryForeground : palette.inkPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(viewModel.activeModule == tab ? AnyShapeStyle(palette.primaryGradient) : AnyShapeStyle(palette.rowSurface))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(14)
            }
        } detail: {
            ZStack {
                CloudTuneBackground(palette: palette)
                VStack(spacing: 0) {
                    Group {
                        switch viewModel.activeModule {
                        case .music, .cloud: iosMusicTab(palette: palette)
                        case .video: iosVideoTab(palette: palette)
                        case .transfers: iosDownloadTab(palette: palette)
                        case .settings: iosSettingsTab(palette: palette)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    iosMiniPlayerBar(palette: palette)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .tint(palette.isDark ? palette.warmGold : palette.primaryStart)
    }

    @ViewBuilder
    private func iosMiniPlayerBar(palette: CloudTunePalette) -> some View {
        HStack(spacing: 12) {
            Button {
                isShowingFullPlayer = true
            } label: {
                HStack(spacing: 12) {
                    if let artData = viewModel.nowPlayingMetadata?.artworkData, let uiImg = UIImage(data: artData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(palette.warmGold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "点击选择或随机播放")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                        Text("\(CloudTuneFormatters.formatClock(viewModel.currentTime)) / \(CloudTuneFormatters.formatClock(viewModel.duration))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.primaryForeground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.primaryGradient))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.playAdjacent(direction: 1) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.cardStrong))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.accentBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func iosFullPlayerSheet(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            VStack(spacing: 22) {
                HStack {
                    Text("正在播放")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)
                    Spacer()
                    SecondaryActionButton("收起", systemImage: "chevron.down", palette: palette) {
                        isShowingFullPlayer = false
                    }
                }

                if let artData = viewModel.nowPlayingMetadata?.artworkData, let uiImg = UIImage(data: artData) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(palette.cardStrong)
                        .frame(width: 240, height: 240)
                        .overlay(
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 92))
                                .foregroundStyle(palette.warmGold)
                        )
                }

                VStack(spacing: 6) {
                    Text(viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "未选择曲目")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(palette.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text(viewModel.nowPlayingMetadata?.artist ?? viewModel.currentTrack?.folderPath ?? "CloudTune")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.inkTertiary)
                }

                VStack(spacing: 6) {
                    WarmProgressSlider(value: viewModel.currentTime, total: viewModel.duration, palette: palette) { sec in
                        Task { await viewModel.seekPlayback(to: sec) }
                    }
                    HStack {
                        Text(CloudTuneFormatters.formatClock(viewModel.currentTime))
                        Spacer()
                        Text(CloudTuneFormatters.formatClock(viewModel.duration))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                }

                HStack(spacing: 16) {
                    SecondaryActionButton("上一首", systemImage: "backward.fill", palette: palette) {
                        Task { await viewModel.playAdjacent(direction: -1) }
                    }
                    PrimaryActionButton(
                        viewModel.isPlaying ? "暂停" : "播放",
                        systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                        palette: palette,
                        minWidth: 110
                    ) {
                        Task { await viewModel.togglePlayback() }
                    }
                    SecondaryActionButton("下一首", systemImage: "forward.fill", palette: palette) {
                        Task { await viewModel.playAdjacent(direction: 1) }
                    }
                }

                iosPlaybackOrderChips(palette: palette)
                Spacer()
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private func iosPlaybackOrderChips(palette: CloudTunePalette) -> some View {
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

    @ViewBuilder
    private func iosStatusBanner(palette: CloudTunePalette) -> some View {
        if let status = viewModel.settingsValidationError ?? viewModel.statusMessage, !status.isEmpty {
            Text(status)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.inkPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.noticeBackground))
        }
    }

    @ViewBuilder
    private func iosFolderBrowserCard(
        title: String,
        showMusicActions: Bool = false,
        showDownloadFolderAction: Bool = false,
        palette: CloudTunePalette
    ) -> some View {
        GlassCard(palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        folderHeaderButtons(
                            showMusicActions: showMusicActions,
                            showDownloadFolderAction: showDownloadFolderAction,
                            palette: palette
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            folderHeaderButtons(
                                showMusicActions: showMusicActions,
                                showDownloadFolderAction: showDownloadFolderAction,
                                palette: palette
                            )
                        }
                    }
                }

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

                ForEach(viewModel.browser?.folders ?? []) { folder in
                    FolderRowButton(folder: folder, palette: palette) {
                        let next = viewModel.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                        Task { await viewModel.browseTo(folderId: folder.id, nextBreadcrumbs: next) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func folderHeaderButtons(
        showMusicActions: Bool,
        showDownloadFolderAction: Bool,
        palette: CloudTunePalette
    ) -> some View {
        SecondaryActionButton("根目录", palette: palette) {
            Task { await viewModel.browseTo(folderId: nil, nextBreadcrumbs: [.root]) }
        }
        if showMusicActions {
            SecondaryActionButton("扫描曲库", systemImage: "arrow.clockwise", palette: palette) {
                Task { await viewModel.scanMusicLibrary() }
            }
            PrimaryActionButton("设为音乐库", palette: palette) {
                Task { await viewModel.setCurrentFolderAsMusicLibrary() }
            }
        }
        if showDownloadFolderAction {
            SecondaryActionButton("下载文件夹", palette: palette, isDisabled: viewModel.browser == nil) {
                if viewModel.committedSettings.exportFolderDisplayName == nil {
                    pendingExportCurrentFolder = true
                    isShowingFolderPicker = true
                } else {
                    Task { await viewModel.enqueueCurrentFolderDownload() }
                }
            }
        }
    }

    @ViewBuilder
    private func iosMusicTab(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    iosStatusBanner(palette: palette)

                    iosFolderBrowserCard(
                        title: "云盘目录 · \(viewModel.committedSettings.musicFolder?.name ?? "未设曲库")",
                        showMusicActions: true,
                        palette: palette
                    )

                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 9) {
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Text("音乐列表 (\(viewModel.visibleTracks.count))")
                                        .font(.system(size: 15, weight: .heavy).monospacedDigit())
                                        .foregroundStyle(palette.inkPrimary)
                                    Spacer()
                                    iosPlaybackOrderChips(palette: palette)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("音乐列表 (\(viewModel.visibleTracks.count))")
                                        .font(.system(size: 15, weight: .heavy).monospacedDigit())
                                        .foregroundStyle(palette.inkPrimary)
                                    iosPlaybackOrderChips(palette: palette)
                                }
                            }
                            TextField("搜索曲目或目录", text: $viewModel.searchQuery)
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
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
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func iosVideoTab(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    iosStatusBanner(palette: palette)
                    iosFolderBrowserCard(title: "视频目录", palette: palette)

                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("云盘视频")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(palette.inkPrimary)
                            let videos = viewModel.browser?.videoFiles ?? []
                            if videos.isEmpty {
                                Text("当前目录没有视频文件。")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.inkTertiary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(videos) { video in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(video.name)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(palette.inkPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        HStack {
                                            Text(CloudTuneFormatters.formatBytes(video.sizeBytes))
                                                .font(.system(size: 12).monospacedDigit())
                                                .foregroundStyle(palette.inkTertiary)
                                            Spacer()
                                            SecondaryActionButton("应用内播放", systemImage: "play.fill", palette: palette) {
                                                Task { await viewModel.openVideoInApp(video) }
                                            }
                                            SecondaryActionButton("其他应用打开", systemImage: "square.and.arrow.up", palette: palette) {
                                                Task {
                                                    if let url = await viewModel.prepareVideoForExternalApp(video) {
                                                        viewModel.shareFileURL = url
                                                        isShowingShareSheet = true
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.rowSurface))
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func iosDownloadTab(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            ScrollView {
                VStack(spacing: 12) {
                    iosStatusBanner(palette: palette)

                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("传输任务 (\(CloudTuneFormatters.formatBytes(viewModel.transferSnapshot.totalSpeedBytesPerSecond))/s)")
                                    .font(.system(size: 14.5, weight: .heavy).monospacedDigit())
                                    .foregroundStyle(palette.inkPrimary)
                                Spacer()
                                SecondaryActionButton("选导出目录", systemImage: "folder", palette: palette) {
                                    isShowingFolderPicker = true
                                }
                            }
                            if viewModel.downloadTransfers.isEmpty {
                                Text("当前没有活动传输。")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.inkTertiary)
                                    .padding(.vertical, 6)
                            } else {
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

                    iosFolderBrowserCard(
                        title: "下载目录 · \(viewModel.committedSettings.exportFolderDisplayName ?? "未选目录")",
                        showDownloadFolderAction: true,
                        palette: palette
                    )

                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前目录文件")
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(palette.inkPrimary)
                            ForEach(viewModel.downloadableBrowserFiles) { item in
                                TrackRowButton(track: item, actionLabel: "导出", palette: palette) {
                                    if viewModel.committedSettings.exportFolderDisplayName == nil {
                                        pendingExportTrack = item
                                        isShowingFolderPicker = true
                                    } else {
                                        Task { await viewModel.enqueueTrackDownload(item) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func iosSettingsTab(palette: CloudTunePalette) -> some View {
        ZStack {
            CloudTuneBackground(palette: palette)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    iosStatusBanner(palette: palette)

                    GlassCard(palette: palette) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("账户与缓存设置")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(palette.inkPrimary)
                            MetricTile(label: "当前账号", value: viewModel.accountName ?? "未登录", isMonospacedDigits: false, palette: palette)
                            MetricTile(label: "缓存占用 / 上限", value: "\(CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes)) / \(viewModel.committedSettings.cacheLimitMb) MB", palette: palette)

                            HStack {
                                TextField("缓存上限 MB", text: $viewModel.cacheLimitDraft)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                    .onChange(of: viewModel.cacheLimitDraft) { _, _ in viewModel.noteDraftEdited() }
                                SecondaryActionButton("保存上限", palette: palette) {
                                    Task { await viewModel.commitCacheLimitDraft() }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("下载线程", text: $viewModel.downloadThreadsDraft)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                    .onChange(of: viewModel.downloadThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                                TextField("缓存线程", text: $viewModel.cacheThreadsDraft)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                                    .onChange(of: viewModel.cacheThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                                SecondaryActionButton("保存线程", palette: palette) {
                                    Task { await viewModel.commitTransferThreadsDraft() }
                                }
                            }

                            HStack(spacing: 8) {
                                ToggleChipButton("优先缓存", isActive: viewModel.committedSettings.playbackMode == .downloadFirst, palette: palette) {
                                    Task { await viewModel.updatePlaybackMode(.downloadFirst) }
                                }
                                ToggleChipButton("边播边缓存", isActive: viewModel.committedSettings.playbackMode == .streamCache, palette: palette) {
                                    Task { await viewModel.updatePlaybackMode(.streamCache) }
                                }
                            }

                            HStack(spacing: 8) {
                                ForEach(AppAppearancePreference.allCases, id: \.rawValue) { pref in
                                    ToggleChipButton(pref.title, isActive: viewModel.appearancePreference == pref, palette: palette) {
                                        viewModel.appearancePreference = pref
                                    }
                                }
                            }

                            SecondaryActionButton("退出登录", systemImage: "rectangle.portrait.and.arrow.right", palette: palette) {
                                Task { await viewModel.logout() }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func saveQRToPhotoLibrary(_ pngData: Data) {
        guard let image = UIImage(data: pngData) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    viewModel.statusMessage = "未获相册写入权限，请在系统设置中开启相册访问。"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, err in
                Task { @MainActor in
                    viewModel.statusMessage = ok ? "二维码已保存到系统相册，请打开天翼云盘 App 扫一扫选择相册图片。" : "保存相册失败：\(err?.localizedDescription ?? "")"
                }
            }
        }
    }
}

struct IOSAVPlayerContainer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: url)
        vc.player = player
        player.play()
        return vc
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

struct IOSFolderPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first { onPicked(first) }
        }
    }
}

struct IOSActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
