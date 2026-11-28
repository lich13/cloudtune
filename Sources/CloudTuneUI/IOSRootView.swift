#if os(iOS)
import AVFoundation
import AVKit
import CloudTuneCore
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct IOSRootView: View {
    @Bindable private var viewModel: CloudTuneViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingFolderPicker = false
    @State private var isShowingShareSheet = false
    @State private var pendingExportTrack: TrackSummary?
    @State private var pendingExportPane: BrowserPaneState?
    @State private var pendingResumeTransferId: String?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var hapticCounter: Int = 0
    @State private var pendingIPadSearchFocus: Bool = false
    @State private var isRevertingInvalidSettingsTabSwitch: Bool = false
    @FocusState private var isIPadSearchFocused: Bool

    public init(viewModel: CloudTuneViewModel) {
        self.viewModel = viewModel
        IOSTabBarAppearance.apply()
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
        }
        .tint(palette.accent)
        .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
        .sensoryFeedback(.selection, trigger: hapticCounter)
        .sheet(isPresented: $viewModel.isShowingWebLoginSheet) {
            TianyiWebLoginSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingNowPlaying) {
            IOSFullPlayerView(
                viewModel: viewModel,
                palette: palette,
                onHaptic: { hapticCounter += 1 }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingFolderPicker, onDismiss: {
            pendingExportTrack = nil
            pendingExportPane = nil
            pendingResumeTransferId = nil
        }) {
            IOSFolderPicker { pickedURL in
                let trackToExport = pendingExportTrack
                let paneToExport = pendingExportPane
                let resumeId = pendingResumeTransferId
                pendingExportTrack = nil
                pendingExportPane = nil
                pendingResumeTransferId = nil
                Task {
                    guard await viewModel.saveExportDirectoryBookmark(pickedURL) else { return }
                    if let trackToExport {
                        await viewModel.enqueueTrackDownload(trackToExport, explicitDirectoryURL: pickedURL)
                    } else if let paneToExport {
                        await viewModel.enqueueFolderDownload(from: paneToExport, explicitDirectoryURL: pickedURL)
                    } else if let resumeId {
                        await viewModel.resumeTransfer(resumeId, explicitDirectoryURL: pickedURL)
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
                pendingIPadSearchFocus = false
                isIPadSearchFocused = false
            }
        }
        .onChange(of: viewModel.activeModule) { oldModule, nextModule in
            if nextModule != .music {
                pendingIPadSearchFocus = false
                isIPadSearchFocused = false
            }
            if isRevertingInvalidSettingsTabSwitch {
                isRevertingInvalidSettingsTabSwitch = false
                return
            }
            if horizontalSizeClass == .regular {
                if nextModule == .settings {
                    viewModel.isShowingSettingsSheet = true
                }
            } else if oldModule == .settings, nextModule != .settings, viewModel.isAuthenticated, viewModel.hasUnsavedSettingsDrafts {
                Task { @MainActor in
                    if !(await viewModel.commitPendingSettingsDraftsIfNeeded()) {
                        isRevertingInvalidSettingsTabSwitch = true
                        viewModel.activeModule = .settings
                    }
                }
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
                        isError: viewModel.busyLabel == nil && (viewModel.credentialIssue != nil || viewModel.statusKind == .error),
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
                                    let vm = viewModel
                                    Self.saveQRToPhotoLibrary(pngData) { message, kind in
                                        vm.setStatus(message, kind: kind)
                                    }
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
                IOSSettingsFormView(viewModel: viewModel, palette: palette)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarBackground(palette.surfacePrimary, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                Task { @MainActor in
                                    if await viewModel.commitPendingSettingsDraftsIfNeeded() {
                                        viewModel.activeModule = .music
                                    }
                                }
                            }
                        }
                        if viewModel.hasUnsavedSettingsDrafts {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("还原修改") {
                                    viewModel.syncDraftsFromCommitted()
                                }
                            }
                        }
                    }
            }
        } else {
            let tabBarHeight: CGFloat = verticalSizeClass == .compact ? 32 : 49
            let miniPlayerReservedHeight: CGFloat = 68
            ZStack(alignment: .bottom) {
                TabView(selection: $viewModel.activeModule) {
                    ForEach(iphoneTabs) { tab in
                        NavigationStack {
                            moduleBody(for: tab, palette: palette)
                                .contentMargins(.bottom, miniPlayerReservedHeight, for: .scrollContent)
                                .navigationTitle(tab.title)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarBackground(.visible, for: .navigationBar)
                                .toolbarBackground(palette.surfacePrimary, for: .navigationBar)
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
                        }
                        .tabItem {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .tag(tab)
                    }
                }

                VStack(spacing: 0) {
                    Divider().overlay(palette.separator)
                    IOSMiniPlayerBarView(
                        viewModel: viewModel,
                        palette: palette,
                        onHaptic: { hapticCounter += 1 }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(palette.canvasBackground)
                .padding(.bottom, tabBarHeight)
            }
        }
    }

    // MARK: - iPadOS Native Sidebar SplitView + Hardware Keyboard Shortcuts

    @ViewBuilder
    private func ipadSplitLayout(palette: CloudTunePalette) -> some View {
        let effectiveDetailTab: ModuleTab = viewModel.activeModule == .settings ? .music : viewModel.activeModule
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List {
                Section {
                    ForEach(iphoneTabs) { tab in
                        let isSelected = effectiveDetailTab == tab && !viewModel.isShowingSettingsSheet
                        Button {
                            viewModel.isShowingSettingsSheet = false
                            viewModel.activeModule = tab
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.systemImage)
                                    .foregroundStyle(isSelected ? palette.accent : palette.inkSecondary)
                                    .frame(width: 20)
                                Text(tab.title)
                                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? palette.inkPrimary : palette.inkSecondary)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? palette.rowActiveSurface : Color.clear)
                        )
                    }
                }

                Section {
                    let settingsSelected = viewModel.isShowingSettingsSheet || viewModel.activeModule == .settings
                    Button {
                        viewModel.isShowingSettingsSheet = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: ModuleTab.settings.systemImage)
                                .foregroundStyle(settingsSelected ? palette.accent : palette.inkSecondary)
                                .frame(width: 20)
                            Text(ModuleTab.settings.title)
                                .font(.system(size: 14.5, weight: settingsSelected ? .semibold : .regular))
                                .foregroundStyle(settingsSelected ? palette.inkPrimary : palette.inkSecondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 8))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(settingsSelected ? palette.rowActiveSurface : Color.clear)
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("CloudTune")
        } detail: {
            HStack(spacing: 0) {
                moduleBody(for: effectiveDetailTab, palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(palette.separator)
                IPadNowPlayingInspectorView(
                    viewModel: viewModel,
                    palette: palette,
                    onHaptic: { hapticCounter += 1 }
                )
                .frame(width: 320)
            }
            .background(palette.canvasBackground)
            .background {
                ipadKeyboardShortcuts
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(palette.surfacePrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(effectiveDetailTab.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isShowingSettingsSheet },
                set: { next in
                    if next {
                        viewModel.isShowingSettingsSheet = true
                    } else if viewModel.canCloseSettingsSurface() {
                        if viewModel.activeModule == .settings {
                            viewModel.activeModule = .music
                        }
                    }
                }
            )
        ) {
            NavigationStack {
                IOSSettingsFormView(viewModel: viewModel, palette: palette)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarBackground(palette.surfacePrimary, for: .navigationBar)
                    .toolbar {
                        if viewModel.hasUnsavedSettingsDrafts {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("还原修改") {
                                    viewModel.syncDraftsFromCommitted()
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                Task { @MainActor in
                                    if await viewModel.commitPendingSettingsDraftsIfNeeded() {
                                        viewModel.isShowingSettingsSheet = false
                                        if viewModel.activeModule == .settings {
                                            viewModel.activeModule = .music
                                        }
                                    }
                                }
                            }
                        }
                    }
            }
            .preferredColorScheme(viewModel.appearancePreference.preferredColorScheme)
            .interactiveDismissDisabled(viewModel.hasUnsavedSettingsDrafts)
        }
    }

    @ViewBuilder
    private var ipadKeyboardShortcuts: some View {
        Group {
            Button("") {
                Task { await viewModel.togglePlayback() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(isIPadSearchFocused || viewModel.activeModule == .settings)

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
                if viewModel.activeModule == .music {
                    isIPadSearchFocused = true
                } else {
                    pendingIPadSearchFocus = true
                    viewModel.activeModule = .music
                }
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
            Button("") { viewModel.isShowingSettingsSheet = true }
                .keyboardShortcut("5", modifiers: [.command])
            Button("") { viewModel.isShowingSettingsSheet = true }
                .keyboardShortcut(",", modifiers: [.command])
        }
        .opacity(0)
        .allowsHitTesting(false)
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
            IOSSettingsFormView(viewModel: viewModel, palette: palette)
        }
    }

    @ViewBuilder
    private func iosStatusRow(palette: CloudTunePalette) -> some View {
        if let status = viewModel.settingsValidationError ?? viewModel.busyLabel ?? viewModel.statusMessage,
           !status.isEmpty {
            let isErr = viewModel.settingsValidationError != nil
                || (viewModel.busyLabel == nil && viewModel.statusKind == .error)
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
        if horizontalSizeClass == .regular {
            VStack(spacing: 0) {
                ipadMusicSearchBar(palette: palette)
                Divider().overlay(palette.separator)
                iosMusicTrackList(palette: palette)
            }
            .background(palette.canvasBackground)
        } else {
            iosMusicTrackList(palette: palette)
                .searchable(
                    text: $viewModel.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索曲目或目录"
                )
        }
    }

    @ViewBuilder
    private func ipadMusicSearchBar(palette: CloudTunePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.inkTertiary)

            TextField("搜索曲目或目录", text: $viewModel.searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
                .foregroundStyle(palette.inkPrimary)
                .focused($isIPadSearchFocused)
                .submitLabel(.search)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.inkTertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 6))
                .accessibilityLabel("清除搜索词")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.inputSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surfacePrimary)
        .onAppear {
            guard pendingIPadSearchFocus else { return }
            pendingIPadSearchFocus = false
            Task { @MainActor in
                if viewModel.isAuthenticated, viewModel.activeModule == .music {
                    isIPadSearchFocused = true
                }
            }
        }
    }

    @ViewBuilder
    private func iosMusicTrackList(palette: CloudTunePalette) -> some View {
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
        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8, pressScale: 0.992))
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
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8))
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            }

            Section {
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
                                .layoutPriority(1)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    Text(CloudTuneFormatters.formatBytes(video.sizeBytes))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(palette.inkTertiary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    HStack(spacing: 8) {
                                        SecondaryActionButton("应用内播放", systemImage: "play.fill", palette: palette) {
                                            Task { await viewModel.openVideoInApp(video) }
                                        }
                                        SecondaryActionButton("其他应用", systemImage: "square.and.arrow.up", palette: palette) {
                                            Task {
                                                if let cachedURL = await viewModel.requestExternalVideoPlayback(video, prepareLoopbackStream: false) {
                                                    viewModel.shareFileURL = cachedURL
                                                    isShowingShareSheet = true
                                                }
                                            }
                                        }
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(CloudTuneFormatters.formatBytes(video.sizeBytes))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(palette.inkTertiary)
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        SecondaryActionButton("应用内播放", systemImage: "play.fill", palette: palette) {
                                            Task { await viewModel.openVideoInApp(video) }
                                        }
                                        SecondaryActionButton("其他应用", systemImage: "square.and.arrow.up", palette: palette) {
                                            Task {
                                                if let cachedURL = await viewModel.requestExternalVideoPlayback(video, prepareLoopbackStream: false) {
                                                    viewModel.shareFileURL = cachedURL
                                                    isShowingShareSheet = true
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(palette.surfacePrimary)
                    }
                }
            } header: {
                Text("当前目录视频 (\(videos.count))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
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
                Section {
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
                                    .truncationMode(.middle)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.inkTertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8))
                        .listRowBackground(palette.surfacePrimary)
                    }
                } header: {
                    Text("文件夹 (\(folders.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                }
            }

            if !audios.isEmpty {
                Section {
                    ForEach(audios) { track in
                        iosTrackListRow(track: track, palette: palette)
                    }
                } header: {
                    Text("目录音频 (\(audios.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                }
            }

            if !others.isEmpty {
                Section {
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
                                        .truncationMode(.middle)
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
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8))
                        .listRowBackground(palette.surfacePrimary)
                    }
                } header: {
                    Text("视频与附件 (\(others.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
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
                Section {
                    ForEach(viewModel.transferSnapshot.items) { item in
                        TransferRowCardView(
                            item: item,
                            palette: palette,
                            onPause: { Task { await viewModel.pauseTransfer(item.id) } },
                            onResume: { Task { await viewModel.resumeTransfer(item.id) } },
                            onPickDirectoryAndResume: {
                                pendingResumeTransferId = item.id
                                isShowingFolderPicker = true
                            },
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
                } header: {
                    Text("队列明细 (\(viewModel.transferSnapshot.items.count))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 12))
                        .disabled(isLast)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
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
                        SecondaryActionButton("下载目录", systemImage: "arrow.down.doc", palette: palette, isDisabled: pane.payload == nil) {
                            triggerFolderDownload(from: pane)
                        }
                        PrimaryActionButton("设为音乐库", systemImage: "checkmark.circle", palette: palette, isDisabled: pane.payload == nil) {
                            Task { await viewModel.setFolderAsMusicLibrary(from: pane) }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if pane.breadcrumbs.count > 1 {
                            SecondaryActionButton("上一级", systemImage: "chevron.left", palette: palette) {
                                Task { await viewModel.navigateBackInBrowser(scope: scope) }
                            }
                        }
                        SecondaryActionButton("根目录", palette: palette) {
                            Task { await viewModel.browseTo(scope: scope, folderId: nil, nextBreadcrumbs: [.root]) }
                        }
                        Spacer(minLength: 0)
                    }
                    if showMusicActions {
                        HStack(spacing: 8) {
                            SecondaryActionButton("下载目录", systemImage: "arrow.down.doc", palette: palette, isDisabled: pane.payload == nil) {
                                triggerFolderDownload(from: pane)
                            }
                            PrimaryActionButton("设为音乐库", systemImage: "checkmark.circle", palette: palette, isDisabled: pane.payload == nil) {
                                Task { await viewModel.setFolderAsMusicLibrary(from: pane) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
    }

    private func triggerFolderDownload(from pane: BrowserPaneState) {
        if viewModel.committedSettings.exportFolderDisplayName == nil {
            pendingExportPane = pane
            isShowingFolderPicker = true
        } else {
            Task { await viewModel.enqueueFolderDownload(from: pane) }
        }
    }

    private func enqueueTrackWithPickerIfNeeded(_ track: TrackSummary) {
        if viewModel.committedSettings.exportFolderDisplayName == nil {
            pendingExportTrack = track
            isShowingFolderPicker = true
        } else {
            Task { await viewModel.enqueueTrackDownload(track) }
        }
    }

    nonisolated private static func saveQRToPhotoLibrary(
        _ pngData: Data,
        onStatus: @escaping @MainActor @Sendable (String, StatusKind) -> Void
    ) {
        guard !pngData.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    onStatus("未获相册写入权限，请在系统设置中开启相册访问。", .error)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: pngData, options: nil)
            }) { ok, err in
                let errDesc = err?.localizedDescription ?? ""
                Task { @MainActor in
                    if ok {
                        onStatus("二维码已保存到系统相册，请打开天翼云盘 App 扫一扫选择相册图片。", .info)
                    } else {
                        onStatus("保存相册失败：\(errDesc)", .error)
                    }
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
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

@MainActor
package enum IOSTabBarAppearance {
    package static func makeAppearance() -> UITabBarAppearance {
        let surfaceColor = UIColor { traits in
            let palette = CloudTunePalette(isDark: traits.userInterfaceStyle == .dark)
            return UIColor(palette.surfacePrimary).resolvedColor(with: traits)
        }
        let separatorColor = UIColor { traits in
            let palette = CloudTunePalette(isDark: traits.userInterfaceStyle == .dark)
            return UIColor(palette.separator).resolvedColor(with: traits)
        }
        let normalColor = UIColor { traits in
            let palette = CloudTunePalette(isDark: traits.userInterfaceStyle == .dark)
            return UIColor(palette.inkSecondary).resolvedColor(with: traits)
        }
        let selectedColor = UIColor { traits in
            let palette = CloudTunePalette(isDark: traits.userInterfaceStyle == .dark)
            return UIColor(palette.accent).resolvedColor(with: traits)
        }

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = surfaceColor
        appearance.shadowColor = separatorColor

        for itemAppearance in [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ] {
            itemAppearance.normal.iconColor = normalColor
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
            itemAppearance.selected.iconColor = selectedColor
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
            itemAppearance.focused.iconColor = selectedColor
            itemAppearance.focused.titleTextAttributes = [.foregroundColor: selectedColor]
        }
        return appearance
    }

    package static func apply() {
        let appearance = makeAppearance()
        let proxy = UITabBar.appearance()
        proxy.standardAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.isTranslucent = false
    }
}

/// Standalone leaf view reading `PlaybackTimeline` ONLY when no artist string is present.
private struct IOSMiniPlayerSubtitleView: View {
    let artist: String?
    let timeline: PlaybackTimeline
    let palette: CloudTunePalette

    var body: some View {
        let text = artist ?? "\(CloudTuneFormatters.formatClock(timeline.currentTime)) / \(CloudTuneFormatters.formatClock(timeline.duration))"
        Text(text)
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(palette.inkTertiary)
            .lineLimit(1)
    }
}

package struct IOSMiniPlayerBarView: View {
    @Bindable package var viewModel: CloudTuneViewModel
    package let palette: CloudTunePalette
    package let onHaptic: () -> Void

    package var body: some View {
        let track = viewModel.currentTrack
        let title = viewModel.nowPlayingMetadata?.title ?? track?.name ?? "点击选择或随机播放"

        HStack(spacing: 10) {
            Button {
                onHaptic()
                viewModel.isShowingNowPlaying = true
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
                                .truncationMode(.middle)
                            if let track {
                                LosslessBadge(track: track, palette: palette)
                            }
                        }
                        IOSMiniPlayerSubtitleView(
                            artist: viewModel.nowPlayingMetadata?.artist?.trimmedNilIfEmpty,
                            timeline: viewModel.timeline,
                            palette: palette
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 10, pressScale: 0.992))

            Button {
                onHaptic()
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.primaryForeground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 18))

            Button {
                onHaptic()
                Task { await viewModel.playAdjacent(direction: 1) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 18))
            .disabled(!viewModel.canSkipNext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(palette.isDark ? 0.28 : 0.06), radius: 8, x: 0, y: 3)
        .gesture(
            DragGesture(minimumDistance: 28)
                .onEnded { gesture in
                    let dx = gesture.translation.width
                    guard abs(dx) > abs(gesture.translation.height), abs(dx) >= 36 else { return }
                    onHaptic()
                    Task {
                        await viewModel.playAdjacent(direction: dx < 0 ? 1 : -1)
                    }
                }
        )
    }
}

package struct IOSSettingsFormView: View {
    private enum NumericField: Hashable {
        case cacheLimit
        case downloadThreads
        case cacheThreads
    }

    @Bindable package var viewModel: CloudTuneViewModel
    package let palette: CloudTunePalette
    @FocusState private var focusedField: NumericField?

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let status = viewModel.settingsValidationError ?? viewModel.busyLabel ?? viewModel.statusMessage,
                   !status.isEmpty {
                    SubtleStatusBanner(
                        message: status,
                        isError: viewModel.settingsValidationError != nil
                            || (viewModel.busyLabel == nil && viewModel.statusKind == .error),
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
                            .focused($focusedField, equals: .cacheLimit)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.cacheLimitDraft) { _, _ in viewModel.noteDraftEdited() }
                        SecondaryActionButton("应用上限", palette: palette) {
                            focusedField = nil
                            Task { await viewModel.commitCacheLimitDraft() }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("下载线程", text: $viewModel.downloadThreadsDraft)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .downloadThreads)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.downloadThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                        TextField("缓存线程", text: $viewModel.cacheThreadsDraft)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .cacheThreads)
                            .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.inputSurface))
                            .onChange(of: viewModel.cacheThreadsDraft) { _, _ in viewModel.noteDraftEdited() }
                        SecondaryActionButton("应用线程", palette: palette) {
                            focusedField = nil
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
                        focusedField = nil
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    let completedField = focusedField
                    focusedField = nil
                    Task { @MainActor in
                        switch completedField {
                        case .cacheLimit:
                            _ = await viewModel.commitCacheLimitDraft()
                        case .downloadThreads, .cacheThreads:
                            _ = await viewModel.commitTransferThreadsDraft()
                        case nil:
                            _ = await viewModel.commitPendingSettingsDraftsIfNeeded()
                        }
                    }
                }
            }
        }
    }
}

package struct IPadNowPlayingInspectorView: View {
    @Bindable package var viewModel: CloudTuneViewModel
    package let palette: CloudTunePalette
    package let onHaptic: () -> Void

    package var body: some View {
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
                onHaptic()
                viewModel.isShowingNowPlaying = true
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
            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 16, pressScale: 0.992))
            .accessibilityLabel("展开全屏正在播放视图")

            NowPlayingScrubberView(
                timeline: viewModel.timeline,
                palette: palette,
                layout: .iosStacked(fontSize: 11.5)
            ) { sec in
                await viewModel.seekPlayback(to: sec)
            }

            HStack(spacing: 16) {
                Button {
                    onHaptic()
                    viewModel.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(viewModel.shuffle ? palette.accent : palette.inkTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 18))

                Button {
                    onHaptic()
                    Task { await viewModel.playAdjacent(direction: -1) }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 19))
                .disabled(!viewModel.canSkipPrevious)

                Button {
                    onHaptic()
                    Task { await viewModel.togglePlayback() }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.primaryForeground)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(palette.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 23))

                Button {
                    onHaptic()
                    Task { await viewModel.playAdjacent(direction: 1) }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 19))
                .disabled(!viewModel.canSkipNext)

                Button {
                    onHaptic()
                    viewModel.cycleLoopMode()
                } label: {
                    Image(systemName: viewModel.loopMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(viewModel.loopMode != .off ? palette.accent : palette.inkTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 18))
            }

            Divider().overlay(palette.separator)

            HStack {
                Text("待播队列 (\(viewModel.upcomingTracks.count))")
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
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 6))
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(viewModel.upcomingTracks) { item in
                        let isManual = viewModel.isManualUpNext(trackId: item.id)
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
                        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8, pressScale: 0.992))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(palette.surfacePrimary)
    }
}

package struct IOSFullPlayerView: View {
    @Bindable package var viewModel: CloudTuneViewModel
    package let palette: CloudTunePalette
    package let onHaptic: () -> Void

    package var body: some View {
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
                        viewModel.isShowingNowPlaying = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.inkSecondary)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 20))

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

                NowPlayingScrubberView(
                    timeline: viewModel.timeline,
                    palette: palette,
                    layout: .iosStacked(fontSize: 12)
                ) { sec in
                    await viewModel.seekPlayback(to: sec)
                }

                HStack(spacing: 22) {
                    Button {
                        onHaptic()
                        viewModel.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.shuffle ? palette.accent : palette.inkTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 22))

                    Button {
                        onHaptic()
                        Task { await viewModel.playAdjacent(direction: -1) }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 24))
                    .disabled(!viewModel.canSkipPrevious)

                    Button {
                        onHaptic()
                        Task { await viewModel.togglePlayback() }
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(palette.primaryForeground)
                            .frame(width: 62, height: 62)
                            .background(Circle().fill(palette.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 31))

                    Button {
                        onHaptic()
                        Task { await viewModel.playAdjacent(direction: 1) }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 24))
                    .disabled(!viewModel.canSkipNext)

                    Button {
                        onHaptic()
                        viewModel.cycleLoopMode()
                    } label: {
                        Image(systemName: viewModel.loopMode == .one ? "repeat.1" : "repeat")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.loopMode != .off ? palette.accent : palette.inkTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 22))
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
                            Button {
                                viewModel.clearUpNextQueue()
                            } label: {
                                Text("清空插播")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 6))
                        }
                    }

                    ForEach(viewModel.upcomingTracks.prefix(8)) { item in
                        let isManual = viewModel.isManualUpNext(trackId: item.id)
                        HStack(spacing: 10) {
                            Button {
                                Task { await viewModel.playFromUpcomingQueue(item) }
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
                                            .truncationMode(.middle)
                                        Text(isManual ? "插播 · \(item.folderPath)" : item.folderPath)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(isManual ? palette.accent : palette.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 8, pressScale: 0.992))

                            if isManual {
                                Button {
                                    viewModel.removeFromQueue(trackId: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(palette.inkTertiary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: nil, cornerRadius: 16))
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
}
#endif
