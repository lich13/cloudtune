#if os(iOS)
import AVFoundation
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
    @State private var isShowingFolderPicker = false
    @State private var isShowingShareSheet = false
    @State private var pendingExportTrack: TrackSummary?
    @State private var pendingExportPane: BrowserPaneState?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var hapticCounter: Int = 0
    @State private var scrubPreviewSeconds: Double?
    @State private var isSearchPresented: Bool = false

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

    private var iphoneTabs: [ModuleTab] {
        [.music, .video, .cloud, .transfers]
    }

    public var body: some View {
        let palette = CloudTunePalette(isDark: isDark)
        ZStack {
            palette.canvasBackground
                .ignoresSafeArea()

            if !viewModel.isAuthenticated {
                iosLoginStage(palette: palette)
            } else if horizontalSizeClass == .regular {
                ipadSplitLayout(palette: palette)
            } else {
                iphoneAdaptiveLayout(palette: palette)
            }

            if viewModel.isAuthenticated && viewModel.isShowingNowPlayingSheet && !viewModel.hasActivePlayerObservers {
                iosFullPlayerView(palette: palette)
                    .transition(.move(edge: .bottom))
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
        .sensoryFeedback(.selection, trigger: hapticCounter)
        .sheet(isPresented: $viewModel.isShowingWebLoginSheet) {
            TianyiWebLoginSheet(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isShowingNowPlayingSheet && viewModel.hasActivePlayerObservers },
                set: { viewModel.isShowingNowPlayingSheet = $0 }
            )
        ) {
            iosFullPlayerView(palette: palette)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingFolderPicker, onDismiss: {
            pendingExportTrack = nil
            pendingExportPane = nil
        }) {
            IOSFolderPicker { pickedURL in
                let trackToExport = pendingExportTrack
                let paneToExport = pendingExportPane
                pendingExportTrack = nil
                pendingExportPane = nil
                Task {
                    await viewModel.saveExportDirectoryBookmark(pickedURL)
                    if let trackToExport {
                        await viewModel.enqueueTrackDownload(trackToExport, explicitDirectoryURL: pickedURL)
                    } else if let paneToExport {
                        await viewModel.enqueueFolderDownload(from: paneToExport, explicitDirectoryURL: pickedURL)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.activeVideoURL != nil },
            set: {
                if !$0 {
                    viewModel.activeVideoURL = nil
                    viewModel.activeVideoTrack = nil
                }
            }
        )) {
            if let videoURL = viewModel.activeVideoURL {
                IOSAVPlayerContainer(url: videoURL)
                    .id(videoURL)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: viewModel.isAuthenticated) { _, authenticated in
            if !authenticated {
                isShowingShareSheet = false
                isShowingFolderPicker = false
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let url = viewModel.shareFileURL {
                IOSActivityShareSheet(items: [url])
            }
        }
        .confirmationDialog(
            "视频尚未缓存到本地",
            isPresented: Binding(
                get: { viewModel.pendingExternalVideoChoice != nil },
                set: { if !$0 { viewModel.pendingExternalVideoChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let choice = viewModel.pendingExternalVideoChoice {
                Button("先缓存到本地再用其他应用打开") {
                    Task {
                        if let localURL = await viewModel.downloadVideoAndPrepareLocalFile(choice.video) {
                            viewModel.shareFileURL = localURL
                            isShowingShareSheet = true
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {
                viewModel.pendingExternalVideoChoice = nil
            }
        } message: {
            Text("先缓存至本地文件后再通过系统分享面板打开，可避免远程链接被跳转至浏览器。")
        }
    }

    // MARK: - Unauthenticated Login Stage

    @ViewBuilder
    private func iosLoginStage(palette: CloudTunePalette) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ArtworkView(
                        artworkData: nil,
                        seedText: "CloudTune",
                        size: 60,
                        cornerRadius: 16,
                        palette: palette
                    )
                    Text("CloudTune")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                    Text("天翼云盘无损音乐与现场视频播放器")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                if let status = viewModel.busyLabel ?? viewModel.statusMessage, !status.isEmpty {
                    SubtleStatusBanner(
                        message: status,
                        isError: viewModel.credentialIssue != nil || status.contains("失败"),
                        busyLabel: viewModel.busyLabel,
                        palette: palette
                    )
                }

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
                            minWidth: 240
                        ) {
                            viewModel.isShowingWebLoginSheet = true
                        }

                        HStack(spacing: 10) {
                            SecondaryActionButton(
                                viewModel.qrPNGData != nil ? "刷新二维码" : "生成扫码二维码",
                                systemImage: "qrcode",
                                palette: palette
                            ) {
                                Task { await viewModel.beginQrLogin() }
                            }
                            if let pngData = viewModel.qrPNGData {
                                SecondaryActionButton(
                                    "保存到相册",
                                    systemImage: "photo.badge.arrow.down",
                                    palette: palette
                                ) {
                                    saveQRToPhotoLibrary(pngData)
                                }
                            }
                        }

                        if viewModel.credentialIssue != nil {
                            SecondaryActionButton(
                                "重试读取钥匙串",
                                systemImage: "key.fill",
                                palette: palette
                            ) {
                                Task { await viewModel.bootstrap(userInitiatedKeychainRetry: true) }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 460)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(palette.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(palette.cardBorder, lineWidth: 1)
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - iPhone Native TabView + Floating Mini Player

    @ViewBuilder
    private func iphoneAdaptiveLayout(palette: CloudTunePalette) -> some View {
        if viewModel.activeModule == .settings {
            NavigationStack {
                iosSettingsContent(palette: palette)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") {
                                viewModel.activeModule = .music
                            }
                        }
                    }
            }
        } else {
            TabView(selection: $viewModel.activeModule) {
                ForEach(iphoneTabs) { tab in
                    NavigationStack {
                        moduleBody(for: tab, palette: palette)
                            .navigationTitle(tab.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button {
                                        viewModel.activeModule = .settings
                                    } label: {
                                        Image(systemName: "gearshape")
                                    }
                                    .accessibilityLabel("设置")
                                }
                            }
                            .safeAreaInset(edge: .bottom) {
                                iosMiniPlayerBar(palette: palette)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 6)
                            }
                    }
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
                }
            }
        }
    }

    // MARK: - iPadOS Native Sidebar SplitView + Hardware Keyboard Shortcuts

    @ViewBuilder
    private func ipadSplitLayout(palette: CloudTunePalette) -> some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List {
                Section("CloudTune") {
                    ForEach(ModuleTab.allCases) { tab in
                        Button {
                            viewModel.activeModule = tab
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.systemImage)
                                    .foregroundStyle(viewModel.activeModule == tab ? palette.accent : palette.inkSecondary)
                                    .frame(width: 20)
                                Text(tab.title)
                                    .font(.system(size: 14.5, weight: viewModel.activeModule == tab ? .semibold : .regular))
                                    .foregroundStyle(viewModel.activeModule == tab ? palette.inkPrimary : palette.inkSecondary)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(viewModel.activeModule == tab ? palette.rowActiveSurface : Color.clear)
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("CloudTune")
        } detail: {
            HStack(spacing: 0) {
                NavigationStack {
                    moduleBody(for: viewModel.activeModule, palette: palette)
                        .navigationTitle(viewModel.activeModule.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.activeModule != .settings {
                    Divider().overlay(palette.separator)
                    ipadInspectorColumn(palette: palette)
                        .frame(width: 320)
                }
            }
            .background(palette.canvasBackground)
            .background {
                ipadKeyboardShortcuts
            }
        }
    }

    @ViewBuilder
    private var ipadKeyboardShortcuts: some View {
        Group {
            Button("") {
                Task { await viewModel.togglePlayback() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(isSearchPresented || viewModel.activeModule == .settings)

            Button("") {
                Task { await viewModel.playAdjacent(direction: -1) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(!viewModel.canSkipPrevious)

            Button("") {
                Task { await viewModel.playAdjacent(direction: 1) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(!viewModel.canSkipNext)

            Button("") {
                viewModel.activeModule = .music
                isSearchPresented = true
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("") { viewModel.activeModule = .music }
                .keyboardShortcut("1", modifiers: [.command])
            Button("") { viewModel.activeModule = .video }
                .keyboardShortcut("2", modifiers: [.command])
            Button("") { viewModel.activeModule = .cloud }
                .keyboardShortcut("3", modifiers: [.command])
            Button("") { viewModel.activeModule = .transfers }
                .keyboardShortcut("4", modifiers: [.command])
            Button("") { viewModel.activeModule = .settings }
                .keyboardShortcut("5", modifiers: [.command])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ipadInspectorColumn(palette: CloudTunePalette) -> some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "未选择曲目"
        let subtitle = [
            viewModel.nowPlayingMetadata?.artist,
            viewModel.nowPlayingMetadata?.album ?? track?.folderPath
        ]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: " · ")

        VStack(spacing: 14) {
            HStack {
                Text("正在播放")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                Spacer()
                AirPlayRoutePicker(tint: UIColor(palette.inkSecondary))
                    .frame(width: 28, height: 28)
            }

            Button {
                hapticCounter += 1
                viewModel.isShowingNowPlayingSheet = true
            } label: {
                VStack(spacing: 14) {
                    ArtworkView(
                        artworkData: viewModel.nowPlayingMetadata?.artworkData,
                        seedText: title,
                        size: 168,
                        cornerRadius: 18,
                        palette: palette
                    )
                    .scaleEffect(viewModel.isPlaying ? 1.0 : 0.94)
                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: viewModel.isPlaying)

                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(palette.inkPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let track {
                                LosslessBadge(track: track, palette: palette)
                            }
                        }
                        Text(subtitle.isEmpty ? "选择左侧曲目开始播放" : subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开全屏正在播放视图")

            VStack(spacing: 4) {
                InteractiveScrubSlider(
                    value: viewModel.currentTime,
                    total: viewModel.duration,
                    palette: palette,
                    onPreviewChange: { preview in
                        scrubPreviewSeconds = preview
                    },
                    onSeek: { sec in
                        Task { await viewModel.seekPlayback(to: sec) }
                    }
                )
                HStack {
                    Text(CloudTuneFormatters.formatClock(scrubPreviewSeconds ?? viewModel.currentTime))
                    Spacer()
                    Text(CloudTuneFormatters.formatClock(viewModel.duration))
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(palette.inkTertiary)
            }

            HStack(spacing: 16) {
                Button {
                    hapticCounter += 1
                    viewModel.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(viewModel.shuffle ? palette.accent : palette.inkTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    hapticCounter += 1
                    Task { await viewModel.playAdjacent(direction: -1) }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSkipPrevious)

                Button {
                    hapticCounter += 1
                    Task { await viewModel.togglePlayback() }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.primaryForeground)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(palette.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    hapticCounter += 1
                    Task { await viewModel.playAdjacent(direction: 1) }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSkipNext)

                Button {
                    hapticCounter += 1
                    viewModel.cycleLoopMode()
                } label: {
                    Image(systemName: viewModel.loopMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(viewModel.loopMode != .off ? palette.accent : palette.inkTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(palette.separator)

            HStack {
                Text("待播队列 (\(viewModel.upcomingTracks.count))")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.inkSecondary)
                Spacer()
                if !viewModel.upNextQueue.isEmpty {
                    Button("清空插播") {
                        viewModel.clearUpNextQueue()
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(viewModel.upcomingTracks) { item in
                        let isManual = viewModel.upNextQueue.contains { $0.id == item.id }
                        Button {
                            Task { await viewModel.playTrack(item) }
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
                                    Text(isManual ? "插播 · \(item.folderPath)" : item.folderPath)
                                        .font(.system(size: 11))
                                        .foregroundStyle(isManual ? palette.accent : palette.inkTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(palette.surfaceSecondary)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(palette.surfacePrimary)
    }

    // MARK: - Frosted Mini Player & Interactive Full-Screen Now Playing

    @ViewBuilder
    private func iosMiniPlayerBar(palette: CloudTunePalette) -> some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "点击选择或随机播放"
        let sub = viewModel.nowPlayingMetadata?.artist
            ?? "\(CloudTuneFormatters.formatClock(viewModel.currentTime)) / \(CloudTuneFormatters.formatClock(viewModel.duration))"

        HStack(spacing: 10) {
            Button {
                hapticCounter += 1
                viewModel.isShowingNowPlayingSheet = true
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(
                        artworkData: viewModel.nowPlayingMetadata?.artworkData,
                        seedText: title,
                        size: 38,
                        cornerRadius: 8,
                        palette: palette
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                                .lineLimit(1)
                            if let track {
                                LosslessBadge(track: track, palette: palette)
                            }
                        }
                        Text(sub)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                hapticCounter += 1
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.primaryForeground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                hapticCounter += 1
                Task { await viewModel.playAdjacent(direction: 1) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSkipNext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(palette.isDark ? 0.30 : 0.08), radius: 10, x: 0, y: 4)
        .gesture(
            DragGesture(minimumDistance: 28)
                .onEnded { gesture in
                    let dx = gesture.translation.width
                    guard abs(dx) > abs(gesture.translation.height), abs(dx) >= 36 else { return }
                    hapticCounter += 1
                    Task {
                        await viewModel.playAdjacent(direction: dx < 0 ? 1 : -1)
                    }
                }
        )
    }

    @ViewBuilder
    private func iosFullPlayerView(palette: CloudTunePalette) -> some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "未选择曲目"
        let artistLine = [
            viewModel.nowPlayingMetadata?.artist,
            viewModel.nowPlayingMetadata?.album ?? track?.folderPath
        ]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: " · ")

        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Button {
                        viewModel.isShowingNowPlayingSheet = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.inkSecondary)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text("正在播放")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary)
                    Spacer()

                    AirPlayRoutePicker(tint: UIColor(palette.inkPrimary))
                        .frame(width: 36, height: 36)
                }

                ArtworkView(
                    artworkData: viewModel.nowPlayingMetadata?.artworkData,
                    seedText: title,
                    size: 236,
                    cornerRadius: 24,
                    palette: palette
                )
                .scaleEffect(viewModel.isPlaying ? 1.0 : 0.91)
                .animation(.spring(response: 0.36, dampingFraction: 0.78), value: viewModel.isPlaying)

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(palette.inkPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if let track {
                            LosslessBadge(track: track, palette: palette)
                        }
                    }
                    Text(artistLine.isEmpty ? "CloudTune" : artistLine)
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                }

                VStack(spacing: 4) {
                    InteractiveScrubSlider(
                        value: viewModel.currentTime,
                        total: viewModel.duration,
                        palette: palette,
                        onPreviewChange: { preview in
                            scrubPreviewSeconds = preview
                        },
                        onSeek: { sec in
                            Task { await viewModel.seekPlayback(to: sec) }
                        }
                    )
                    HStack {
                        Text(CloudTuneFormatters.formatClock(scrubPreviewSeconds ?? viewModel.currentTime))
                        Spacer()
                        Text(CloudTuneFormatters.formatClock(viewModel.duration))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                }

                HStack(spacing: 22) {
                    Button {
                        hapticCounter += 1
                        viewModel.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.shuffle ? palette.accent : palette.inkTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        hapticCounter += 1
                        Task { await viewModel.playAdjacent(direction: -1) }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSkipPrevious)

                    Button {
                        hapticCounter += 1
                        Task { await viewModel.togglePlayback() }
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(palette.primaryForeground)
                            .frame(width: 62, height: 62)
                            .background(Circle().fill(palette.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        hapticCounter += 1
                        Task { await viewModel.playAdjacent(direction: 1) }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSkipNext)

                    Button {
                        hapticCounter += 1
                        viewModel.cycleLoopMode()
                    } label: {
                        Image(systemName: viewModel.loopMode == .one ? "repeat.1" : "repeat")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.loopMode != .off ? palette.accent : palette.inkTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                    Slider(
                        value: Binding(
                            get: { viewModel.volume },
                            set: { viewModel.setVolume($0) }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(palette.accent)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("待播队列 (\(viewModel.upcomingTracks.count))")
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(palette.inkPrimary)
                        Spacer()
                        if !viewModel.upNextQueue.isEmpty {
                            Button("清空插播") {
                                viewModel.clearUpNextQueue()
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                        }
                    }

                    ForEach(viewModel.upcomingTracks.prefix(8)) { item in
                        let isManual = viewModel.upNextQueue.contains { $0.id == item.id }
                        HStack(spacing: 10) {
                            Button {
                                Task { await viewModel.playTrack(item) }
                            } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(
                                        artworkData: nil,
                                        seedText: item.name,
                                        size: 34,
                                        cornerRadius: 7,
                                        palette: palette
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(palette.inkPrimary)
                                            .lineLimit(1)
                                        Text(isManual ? "插播 · \(item.folderPath)" : item.folderPath)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(isManual ? palette.accent : palette.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isManual {
                                Button {
                                    viewModel.removeFromQueue(trackId: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(palette.inkTertiary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(palette.surfaceSecondary)
                        )
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(palette.surfacePrimary.ignoresSafeArea())
    }

    // MARK: - Module Screens (Music / Video / Cloud / Transfers / Settings)

    @ViewBuilder
    private func moduleBody(for tab: ModuleTab, palette: CloudTunePalette) -> some View {
        switch tab {
        case .music:
            iosMusicContent(palette: palette)
        case .video:
            iosVideoContent(palette: palette)
        case .cloud:
            iosCloudContent(palette: palette)
        case .transfers:
            iosTransfersContent(palette: palette)
        case .settings:
            iosSettingsContent(palette: palette)
        }
    }

    @ViewBuilder
    private func iosStatusRow(palette: CloudTunePalette) -> some View {
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
            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func iosMusicContent(palette: CloudTunePalette) -> some View {
        List {
            iosStatusRow(palette: palette)

            Section {
                HStack(spacing: 8) {
                    ToggleChipButton(
                        "随机播放",
                        systemImage: "shuffle",
                        isActive: viewModel.shuffle,
                        palette: palette
                    ) {
                        hapticCounter += 1
                        viewModel.toggleShuffle()
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
                        hapticCounter += 1
                        viewModel.cycleLoopMode()
                    }
                    Spacer()
                    SecondaryActionButton("扫描", systemImage: "arrow.clockwise", palette: palette) {
                        Task { await viewModel.scanMusicLibrary() }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                if viewModel.visibleTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂无匹配曲目")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                        Text("前往「云盘」标签页进入音乐目录并点击「设为音乐库」即可自动扫描。")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.inkSecondary)
                    }
                    .padding(.vertical, 12)
                    .listRowBackground(palette.surfacePrimary)
                } else {
                    ForEach(viewModel.visibleTracks) { track in
                        iosTrackListRow(track: track, palette: palette)
                    }
                }
            } header: {
                Text("\(viewModel.committedSettings.musicFolder?.name ?? "未设目录") · \(viewModel.visibleTracks.count) 首")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvasBackground)
        .searchable(text: $viewModel.searchQuery, isPresented: $isSearchPresented, prompt: "搜索曲目或目录")
        .refreshable {
            await viewModel.scanMusicLibrary(showBusy: false)
        }
    }

    @ViewBuilder
    private func iosTrackListRow(track: TrackSummary, palette: CloudTunePalette) -> some View {
        let isCurrent = track.id == viewModel.currentTrackId
        Button {
            hapticCounter += 1
            Task { await viewModel.playTrack(track) }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(
                    artworkData: isCurrent ? viewModel.nowPlayingMetadata?.artworkData : nil,
                    seedText: track.name,
                    size: 40,
                    cornerRadius: 8,
                    palette: palette
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(track.name)
                            .font(.system(size: 14, weight: isCurrent ? .bold : .semibold))
                            .foregroundStyle(isCurrent ? palette.accent : palette.inkPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        LosslessBadge(track: track, palette: palette)
                    }
                    Text("\(track.folderPath) · \(CloudTuneFormatters.formatBytes(track.sizeBytes))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if viewModel.loadingTrackId == track.id {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: viewModel.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? palette.rowActiveSurface : palette.surfacePrimary)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                hapticCounter += 1
                viewModel.playNext(track)
            } label: {
                Label("下一首", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(palette.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                enqueueTrackWithPickerIfNeeded(track)
            } label: {
                Label("导出", systemImage: "arrow.down.circle")
            }
        }
        .contextMenu {
            Button {
                Task { await viewModel.playTrack(track) }
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }
            Button {
                viewModel.playNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                viewModel.appendToQueue(track)
            } label: {
                Label("加入待播队列", systemImage: "text.append")
            }
            Divider()
            Button {
                enqueueTrackWithPickerIfNeeded(track)
            } label: {
                Label("导出到本地文件夹", systemImage: "arrow.down.circle")
            }
        }
    }

    @ViewBuilder
    private func iosVideoContent(palette: CloudTunePalette) -> some View {
        let pane = viewModel.videoBrowser
        let folders = pane.payload?.folders ?? []
        let videos = pane.payload?.videoFiles ?? []

        List {
            iosStatusRow(palette: palette)

            Section {
                iosBreadcrumbStrip(scope: .video, pane: pane, showMusicActions: false, palette: palette)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !folders.isEmpty {
                Section("文件夹") {
                    ForEach(folders) { folder in
                        Button {
                            let next = pane.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                            Task { await viewModel.browseTo(scope: .video, folderId: folder.id, nextBreadcrumbs: next) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(palette.accent)
                                Text(folder.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(palette.inkPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.inkTertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            }

            Section("当前目录视频 (\(videos.count))") {
                if videos.isEmpty {
                    Text("当前目录没有视频文件。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.inkTertiary)
                        .listRowBackground(palette.surfacePrimary)
                } else {
                    ForEach(videos) { video in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(video.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                Text(CloudTuneFormatters.formatBytes(video.sizeBytes))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(palette.inkTertiary)
                                Spacer()
                                SecondaryActionButton("应用内播放", systemImage: "play.fill", palette: palette) {
                                    Task { await viewModel.openVideoInApp(video) }
                                }
                                SecondaryActionButton("其他应用", systemImage: "square.and.arrow.up", palette: palette) {
                                    Task {
                                        if let cachedURL = await viewModel.requestExternalVideoPlayback(video) {
                                            viewModel.shareFileURL = cachedURL
                                            isShowingShareSheet = true
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvasBackground)
        .refreshable {
            let currentId = pane.breadcrumbs.last?.id
            await viewModel.browseTo(scope: .video, folderId: currentId, nextBreadcrumbs: pane.breadcrumbs, showBusy: false)
        }
    }

    @ViewBuilder
    private func iosCloudContent(palette: CloudTunePalette) -> some View {
        let pane = viewModel.cloudBrowser
        let folders = pane.payload?.folders ?? []
        let audios = pane.payload?.audioFiles ?? []
        let others = (pane.payload?.videoFiles ?? []) + (pane.payload?.otherFiles ?? [])

        List {
            iosStatusRow(palette: palette)

            Section {
                iosBreadcrumbStrip(scope: .cloud, pane: pane, showMusicActions: true, palette: palette)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !folders.isEmpty {
                Section("文件夹 (\(folders.count))") {
                    ForEach(folders) { folder in
                        Button {
                            let next = pane.breadcrumbs + [BreadcrumbItem(id: folder.id, name: folder.name)]
                            Task { await viewModel.browseTo(scope: .cloud, folderId: folder.id, nextBreadcrumbs: next) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(palette.accent)
                                Text(folder.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(palette.inkPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.inkTertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            }

            if !audios.isEmpty {
                Section("目录音频 (\(audios.count))") {
                    ForEach(audios) { track in
                        iosTrackListRow(track: track, palette: palette)
                    }
                }
            }

            if !others.isEmpty {
                Section("视频与附件 (\(others.count))") {
                    ForEach(others) { item in
                        Button {
                            enqueueTrackWithPickerIfNeeded(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc")
                                    .foregroundStyle(palette.inkSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(palette.inkPrimary)
                                        .lineLimit(1)
                                    Text(CloudTuneFormatters.formatBytes(item.sizeBytes))
                                        .font(.system(size: 11.5).monospacedDigit())
                                        .foregroundStyle(palette.inkTertiary)
                                }
                                Spacer()
                                Text("导出")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvasBackground)
        .refreshable {
            let currentId = pane.breadcrumbs.last?.id
            await viewModel.browseTo(scope: .cloud, folderId: currentId, nextBreadcrumbs: pane.breadcrumbs, showBusy: false)
        }
    }

    @ViewBuilder
    private func iosTransfersContent(palette: CloudTunePalette) -> some View {
        List {
            iosStatusRow(palette: palette)

            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("总速率 \(CloudTuneFormatters.formatBytes(viewModel.transferSnapshot.totalSpeedBytesPerSecond))/s")
                            .font(.system(size: 14.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(palette.inkPrimary)
                        Text("导出文件夹：\(viewModel.committedSettings.exportFolderDisplayName ?? "尚未授权")")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer()
                    SecondaryActionButton("选导出目录", systemImage: "folder", palette: palette) {
                        isShowingFolderPicker = true
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(palette.surfacePrimary)
            }

            if viewModel.transferSnapshot.items.isEmpty {
                Section {
                    Text("当前没有传输任务。可在「曲库」左滑曲目或在「云盘」点击整夹下载。")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(.vertical, 8)
                        .listRowBackground(palette.surfacePrimary)
                }
            } else {
                Section("队列明细 (\(viewModel.transferSnapshot.items.count))") {
                    ForEach(viewModel.transferSnapshot.items) { item in
                        TransferRowCardView(
                            item: item,
                            palette: palette,
                            onPause: { Task { await viewModel.pauseTransfer(item.id) } },
                            onResume: { Task { await viewModel.resumeTransfer(item.id) } },
                            onDelete: { Task { await viewModel.deleteTransfer(item.id) } }
                        )
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            if item.canDelete {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteTransfer(item.id) }
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvasBackground)
    }

    @ViewBuilder
    private func iosSettingsContent(palette: CloudTunePalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let status = viewModel.settingsValidationError ?? viewModel.busyLabel ?? viewModel.statusMessage,
                   !status.isEmpty {
                    SubtleStatusBanner(
                        message: status,
                        isError: viewModel.settingsValidationError != nil || status.contains("失败"),
                        busyLabel: viewModel.busyLabel,
                        palette: palette
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("界面外观与播放策略")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)

                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases) { pref in
                            ToggleChipButton(pref.title, isActive: viewModel.appearancePreference == pref, palette: palette) {
                                Task { await viewModel.setAppearanceMode(pref) }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        ToggleChipButton(
                            "优先缓存",
                            isActive: viewModel.committedSettings.playbackMode == .downloadFirst,
                            palette: palette
                        ) {
                            Task { await viewModel.updatePlaybackMode(.downloadFirst) }
                        }
                        ToggleChipButton(
                            "边播边缓存",
                            isActive: viewModel.committedSettings.playbackMode == .streamCache,
                            palette: palette
                        ) {
                            Task { await viewModel.updatePlaybackMode(.streamCache) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))

                VStack(alignment: .leading, spacing: 12) {
                    Text("缓存配额与分片线程")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                    Text("已用缓存：\(CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes)) / \(viewModel.committedSettings.cacheLimitMb) MB")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(palette.inkSecondary)

                    HStack(spacing: 8) {
                        TextField("缓存上限 MB", text: $viewModel.cacheLimitDraft)
                            .keyboardType(.numberPad)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.cacheLimitDraft) { _, _ in viewModel.noteDraftEdited() }
                        SecondaryActionButton("应用上限", palette: palette) {
                            Task { await viewModel.commitCacheLimitDraft() }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("下载线程", text: $viewModel.downloadThreadsDraft)
                            .keyboardType(.numberPad)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.downloadThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                        TextField("缓存线程", text: $viewModel.cacheThreadsDraft)
                            .keyboardType(.numberPad)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.cacheThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                        SecondaryActionButton("应用线程", palette: palette) {
                            Task { await viewModel.commitTransferThreadsDraft() }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))

                VStack(alignment: .leading, spacing: 10) {
                    Text("账号会话")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                    Text("当前账号：\(viewModel.accountName ?? "未登录")")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.inkSecondary)
                    Text("音乐库目录：\(viewModel.committedSettings.musicFolder?.name ?? "未设置") · 导出目录：\(viewModel.committedSettings.exportFolderDisplayName ?? "未设置")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkTertiary)

                    SecondaryActionButton("退出登录", systemImage: "rectangle.portrait.and.arrow.right", palette: palette) {
                        Task { await viewModel.logout() }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surfacePrimary))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
            }
            .padding(16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(palette.canvasBackground)
    }

    @ViewBuilder
    private func iosBreadcrumbStrip(
        scope: BrowserScope,
        pane: BrowserPaneState,
        showMusicActions: Bool,
        palette: CloudTunePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 8) {
                if pane.breadcrumbs.count > 1 {
                    SecondaryActionButton("上一级", systemImage: "chevron.left", palette: palette) {
                        Task { await viewModel.navigateBackInBrowser(scope: scope) }
                    }
                }
                SecondaryActionButton("根目录", palette: palette) {
                    Task { await viewModel.browseTo(scope: scope, folderId: nil, nextBreadcrumbs: [.root]) }
                }
                if showMusicActions {
                    SecondaryActionButton("下载目录", palette: palette, isDisabled: pane.payload == nil) {
                        if viewModel.committedSettings.exportFolderDisplayName == nil {
                            pendingExportPane = pane
                            isShowingFolderPicker = true
                        } else {
                            Task { await viewModel.enqueueFolderDownload(from: pane) }
                        }
                    }
                    PrimaryActionButton("设为音乐库", palette: palette, isDisabled: pane.payload == nil) {
                        Task { await viewModel.setFolderAsMusicLibrary(from: pane) }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
    }

    private func enqueueTrackWithPickerIfNeeded(_ track: TrackSummary) {
        if viewModel.committedSettings.exportFolderDisplayName == nil {
            pendingExportTrack = track
            isShowingFolderPicker = true
        } else {
            Task { await viewModel.enqueueTrackDownload(track) }
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
                    viewModel.statusMessage = ok
                        ? "二维码已保存到系统相册，请打开天翼云盘 App 扫一扫选择相册图片。"
                        : "保存相册失败：\(err?.localizedDescription ?? "")"
                }
            }
        }
    }
}

struct IOSAVPlayerContainer: UIViewControllerRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session fallback uses existing active category
        }
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        let player = AVPlayer(url: url)
        context.coordinator.loadedURL = url
        vc.player = player
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        if let player = uiViewController.player {
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        } else {
            let player = AVPlayer(url: url)
            uiViewController.player = player
            player.play()
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
        uiViewController.player = nil
    }
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
