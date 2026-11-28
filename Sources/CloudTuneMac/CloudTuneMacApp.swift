import AppKit
import CloudTuneCore
import CloudTuneUI
import SwiftUI

@main
struct CloudTuneMacMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = CloudTuneAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class CloudTuneAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let viewModel = CloudTuneViewModel()
    private var mainWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var menuBarController: MenuBarController?
    private var prefsNotificationToken: NSObjectProtocol?
    private var isQuittingExplicitly = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildApplicationMenu()
        showOrCreateMainWindow()
        prefsNotificationToken = NotificationCenter.default.addObserver(
            forName: .cloudTuneOpenPreferences,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showOrCreatePreferencesWindow()
            }
        }
        menuBarController = MenuBarController(
            viewModel: viewModel,
            onShowMainWindow: { [weak self] in self?.showOrCreateMainWindow() },
            onShowPreferences: { [weak self] in self?.showOrCreatePreferencesWindow() },
            onQuitApp: { [weak self] in self?.quitExplicitly() }
        )
        Task {
            await viewModel.bootstrap()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showOrCreateMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let trackTitle = viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "未在播放"
        let header = NSMenuItem(title: trackTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let artist = viewModel.nowPlayingMetadata?.artist, !artist.isEmpty {
            let sub = NSMenuItem(title: artist, action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
        }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: viewModel.isPlaying ? "暂停" : "播放",
            action: #selector(handleDockTogglePlay),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = viewModel.isAuthenticated
        menu.addItem(toggleItem)

        let prevItem = NSMenuItem(title: "上一首", action: #selector(handleDockPrev), keyEquivalent: "")
        prevItem.target = self
        prevItem.isEnabled = viewModel.isAuthenticated && viewModel.canSkipPrevious
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "下一首", action: #selector(handleDockNext), keyEquivalent: "")
        nextItem.target = self
        nextItem.isEnabled = viewModel.isAuthenticated && viewModel.canSkipNext
        menu.addItem(nextItem)

        let shuffleItem = NSMenuItem(title: "随机播放", action: #selector(handleDockToggleShuffle), keyEquivalent: "")
        shuffleItem.target = self
        shuffleItem.state = viewModel.shuffle ? .on : .off
        shuffleItem.isEnabled = viewModel.isAuthenticated
        menu.addItem(shuffleItem)

        menu.addItem(.separator())

        let showWin = NSMenuItem(title: "显示主窗口", action: #selector(handleMenuShowWindow), keyEquivalent: "")
        showWin.target = self
        menu.addItem(showWin)
        return menu
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isQuittingExplicitly else { return true }
        if sender === mainWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func showOrCreateMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: MacWorkspaceView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("cloudtune.main")
        window.title = "CloudTune"
        window.toolbarStyle = .unified
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1460, height: 930))
        window.minSize = NSSize(width: 1080, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.mainWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOrCreatePreferencesWindow() {
        viewModel.isShowingSettingsSheet = false
        if let existing = preferencesWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let prefsView = MacPreferencesView(
            viewModel: viewModel,
            onClose: { [weak self] in self?.preferencesWindow?.close() }
        )
        let hosting = NSHostingController(rootView: prefsView)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("cloudtune.preferences")
        window.title = "偏好设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 470))
        window.isReleasedWhenClosed = false
        window.center()
        self.preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitExplicitly() {
        isQuittingExplicitly = true
        NSApplication.shared.terminate(nil)
    }

    private func buildApplicationMenu() {
        let mainMenu = NSMenu()

        // 1. Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 CloudTune", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(handleMenuShowPreferences), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())

        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(handleMenuShowWindow), keyEquivalent: "0")
        showItem.target = self
        appMenu.addItem(showItem)

        let closeItem = NSMenuItem(title: "关闭 / 隐藏窗口", action: #selector(handleMenuSmartCloseWindow), keyEquivalent: "w")
        closeItem.target = self
        appMenu.addItem(closeItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 CloudTune", action: #selector(handleMenuQuit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // 2. Edit Menu (with Cmd+F search focus)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "搜索曲库…", action: #selector(handleMenuFocusSearch), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        editMenuItem.submenu = editMenu

        // 3. Playback Control Menu
        let controlMenuItem = NSMenuItem()
        mainMenu.addItem(controlMenuItem)
        let controlMenu = NSMenu(title: "控制")
        let playPause = NSMenuItem(title: "播放 / 暂停", action: #selector(handleDockTogglePlay), keyEquivalent: " ")
        playPause.keyEquivalentModifierMask = []
        playPause.target = self
        controlMenu.addItem(playPause)

        let prev = NSMenuItem(title: "上一首", action: #selector(handleDockPrev), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prev.keyEquivalentModifierMask = [.command]
        prev.target = self
        controlMenu.addItem(prev)

        let next = NSMenuItem(title: "下一首", action: #selector(handleDockNext), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        next.keyEquivalentModifierMask = [.command]
        next.target = self
        controlMenu.addItem(next)
        controlMenu.addItem(.separator())

        let volUp = NSMenuItem(title: "增大音量", action: #selector(handleVolumeUp), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        volUp.keyEquivalentModifierMask = [.command]
        volUp.target = self
        controlMenu.addItem(volUp)

        let volDown = NSMenuItem(title: "减小音量", action: #selector(handleVolumeDown), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        volDown.keyEquivalentModifierMask = [.command]
        volDown.target = self
        controlMenu.addItem(volDown)
        controlMenuItem.submenu = controlMenu

        // 4. View & Window Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "视图")
        for (idx, tab) in [ModuleTab.music, .video, .cloud, .transfers].enumerated() {
            let item = NSMenuItem(title: tab.title, action: #selector(handleSwitchModule(_:)), keyEquivalent: "\(idx + 1)")
            item.tag = idx
            item.target = self
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let queueItem = NSMenuItem(title: "显示 / 隐藏待播队列", action: #selector(handleToggleQueueInspector), keyEquivalent: "u")
        queueItem.target = self
        viewMenu.addItem(queueItem)
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleMenuShowWindow() {
        showOrCreateMainWindow()
    }

    @objc private func handleMenuShowPreferences() {
        showOrCreatePreferencesWindow()
    }

    /// Smart `Cmd+W`: dismiss active Sheet or Preferences window first; only hide main window to preserve playback.
    @objc private func handleMenuSmartCloseWindow() {
        if viewModel.isShowingWebLoginSheet {
            viewModel.isShowingWebLoginSheet = false
            return
        }
        if viewModel.activeVideoURL != nil {
            viewModel.activeVideoURL = nil
            viewModel.activeVideoTrack = nil
            return
        }
        if viewModel.pendingExternalVideoChoice != nil {
            viewModel.pendingExternalVideoChoice = nil
            return
        }
        if viewModel.isShowingSettingsSheet {
            viewModel.isShowingSettingsSheet = false
            return
        }
        if let keyWin = NSApp.keyWindow {
            if keyWin.isSheet, let parent = keyWin.sheetParent {
                parent.endSheet(keyWin)
                return
            }
            if keyWin === preferencesWindow {
                keyWin.close()
                return
            }
            if keyWin !== mainWindow {
                keyWin.performClose(nil)
                return
            }
        }
        mainWindow?.orderOut(nil)
    }

    @objc private func handleMenuFocusSearch() {
        showOrCreateMainWindow()
        NotificationCenter.default.post(name: .cloudTuneFocusSearch, object: nil)
    }

    @objc private func handleSwitchModule(_ sender: NSMenuItem) {
        let tabs: [ModuleTab] = [.music, .video, .cloud, .transfers]
        guard tabs.indices.contains(sender.tag) else { return }
        showOrCreateMainWindow()
        viewModel.activeModule = tabs[sender.tag]
    }

    @objc private func handleToggleQueueInspector() {
        viewModel.isShowingQueuePopover.toggle()
        if !viewModel.isShowingQueuePopover {
            viewModel.isShowingNowPlayingSheet = false
        }
    }

    @objc private func handleDockTogglePlay() {
        Task { await viewModel.togglePlayback() }
    }

    @objc private func handleDockPrev() {
        Task { await viewModel.playAdjacent(direction: -1) }
    }

    @objc private func handleDockNext() {
        Task { await viewModel.playAdjacent(direction: 1) }
    }

    @objc private func handleDockToggleShuffle() {
        viewModel.toggleShuffle()
    }

    @objc private func handleVolumeUp() {
        viewModel.setVolume(viewModel.volume + 0.08)
    }

    @objc private func handleVolumeDown() {
        viewModel.setVolume(viewModel.volume - 0.08)
    }

    @objc private func handleMenuQuit() {
        quitExplicitly()
    }
}

/// Custom `NSStatusItem` + `NSView` + `NSMenu.popUp` menu bar controller (never uses SwiftUI `Menu`).
@MainActor
final class MenuBarController: NSObject {
    private let viewModel: CloudTuneViewModel
    private let statusItem: NSStatusItem
    private let triggerView: StatusBarTriggerView
    private let onShowMainWindow: () -> Void
    private let onShowPreferences: () -> Void
    private let onQuitApp: () -> Void

    init(
        viewModel: CloudTuneViewModel,
        onShowMainWindow: @escaping () -> Void,
        onShowPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onShowMainWindow = onShowMainWindow
        self.onShowPreferences = onShowPreferences
        self.onQuitApp = onQuitApp
        self.statusItem = NSStatusBar.system.statusItem(withLength: 30)
        self.triggerView = StatusBarTriggerView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        super.init()

        if let button = statusItem.button {
            triggerView.frame = button.bounds
            triggerView.autoresizingMask = [.width, .height]
            triggerView.onTrigger = { [weak self] anchorView in
                self?.presentMenu(from: anchorView)
            }
            button.addSubview(triggerView)
        }
        observePlaybackIcon()
    }

    private func observePlaybackIcon() {
        withObservationTracking {
            _ = viewModel.isPlaying
            _ = viewModel.currentTrackId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.triggerView.isPlaying = self.viewModel.isPlaying
                self.observePlaybackIcon()
            }
        }
    }

    private func presentMenu(from view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let trackTitle = viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "未选择曲目"
        let header = NSMenuItem(title: "CloudTune · \(trackTitle)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let artist = viewModel.nowPlayingMetadata?.artist, !artist.isEmpty {
            let sub = NSMenuItem(title: artist, action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
        }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: viewModel.isPlaying ? "暂停播放" : "开始 / 继续播放",
            action: #selector(menuTogglePlayPause),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = viewModel.isAuthenticated
        menu.addItem(toggleItem)

        let prevItem = NSMenuItem(title: "上一首", action: #selector(menuPreviousTrack), keyEquivalent: "")
        prevItem.target = self
        prevItem.isEnabled = viewModel.isAuthenticated && viewModel.canSkipPrevious
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "下一首", action: #selector(menuNextTrack), keyEquivalent: "")
        nextItem.target = self
        nextItem.isEnabled = viewModel.isAuthenticated && viewModel.canSkipNext
        menu.addItem(nextItem)

        let shuffleItem = NSMenuItem(title: "随机播放", action: #selector(menuToggleShuffle), keyEquivalent: "")
        shuffleItem.target = self
        shuffleItem.state = viewModel.shuffle ? .on : .off
        shuffleItem.isEnabled = viewModel.isAuthenticated
        menu.addItem(shuffleItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(menuShowPrefs), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let showItem = NSMenuItem(title: "打开主窗口", action: #selector(menuShowWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let quitItem = NSMenuItem(title: "退出 CloudTune", action: #selector(menuQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func menuTogglePlayPause() {
        Task { await viewModel.togglePlayback() }
    }

    @objc private func menuPreviousTrack() {
        Task { await viewModel.playAdjacent(direction: -1) }
    }

    @objc private func menuNextTrack() {
        Task { await viewModel.playAdjacent(direction: 1) }
    }

    @objc private func menuToggleShuffle() {
        viewModel.toggleShuffle()
    }

    @objc private func menuShowPrefs() {
        onShowPreferences()
    }

    @objc private func menuShowWindow() {
        onShowMainWindow()
    }

    @objc private func menuQuit() {
        onQuitApp()
    }
}

final class StatusBarTriggerView: NSView {
    var onTrigger: ((NSView) -> Void)?
    var isPlaying: Bool = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        onTrigger?(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onTrigger?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let symbolName = isPlaying ? "waveform.circle.fill" : "music.note"
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CloudTune")?.withSymbolConfiguration(cfg) else {
            return
        }
        img.isTemplate = true
        let size = img.size
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2.0,
            y: (bounds.height - size.height) / 2.0
        )
        img.draw(in: NSRect(origin: origin, size: size))
    }
}
