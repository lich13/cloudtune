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
    private var menuBarController: MenuBarController?
    private var isQuittingExplicitly = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildApplicationMenu()
        showOrCreateMainWindow()
        menuBarController = MenuBarController(
            viewModel: viewModel,
            onShowMainWindow: { [weak self] in self?.showOrCreateMainWindow() },
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isQuittingExplicitly else { return true }
        sender.orderOut(nil)
        return false
    }

    func showOrCreateMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: MacWorkspaceView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CloudTune"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1460, height: 930))
        window.minSize = NSSize(width: 1100, height: 760)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.mainWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitExplicitly() {
        isQuittingExplicitly = true
        NSApplication.shared.terminate(nil)
    }

    private func buildApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(handleMenuShowWindow), keyEquivalent: "0")
        showItem.target = self
        appMenu.addItem(showItem)
        appMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "隐藏窗口（后台继续播放）", action: #selector(handleMenuHideWindow), keyEquivalent: "w")
        closeItem.target = self
        appMenu.addItem(closeItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 CloudTune", action: #selector(handleMenuQuit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleMenuShowWindow() {
        showOrCreateMainWindow()
    }

    @objc private func handleMenuHideWindow() {
        mainWindow?.orderOut(nil)
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
    private let onQuitApp: () -> Void

    init(
        viewModel: CloudTuneViewModel,
        onShowMainWindow: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onShowMainWindow = onShowMainWindow
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
        let trackTitle = viewModel.nowPlayingMetadata?.title ?? viewModel.currentTrack?.name ?? "未选择曲目"
        let header = NSMenuItem(title: "CloudTune · \(trackTitle)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: viewModel.isPlaying ? "暂停播放" : "开始 / 继续播放",
            action: #selector(menuTogglePlayPause),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let prevItem = NSMenuItem(title: "上一首", action: #selector(menuPreviousTrack), keyEquivalent: "")
        prevItem.target = self
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "下一首", action: #selector(menuNextTrack), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        menu.addItem(.separator())

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
