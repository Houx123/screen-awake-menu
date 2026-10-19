import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let popoverController = UsagePopoverViewController()
    private var historyWindowController: HistoryWindowController?
    private var lastPopoverClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePopover()
        createStatusItem()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: "熄屏不休眠"
            )
            button.toolTip = "熄屏不休眠 · Codex Token 用量"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    private func configurePopover() {
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        popoverController.onSleepDisplay = { [weak self] in
            self?.sleepDisplay()
        }
        popoverController.onHistory = { [weak self] in
            self?.showHistory()
        }
        popoverController.onAbout = { [weak self] in
            self?.showAbout()
        }
        popoverController.onQuit = {
            NSApp.terminate(nil)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // A transient popover dismisses itself on the same click that lands on
        // the status item; never immediately reopen on that closing click.
        if Date().timeIntervalSince(lastPopoverClose) < 0.25 {
            return
        }
        guard let button = statusItem.button else { return }
        popoverController.loadViewIfNeeded()
        popoverController.beginRefreshing()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        popoverController.endRefreshing()
    }

    private func sleepDisplay() {
        popover.performClose(nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法关闭显示器"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func showHistory() {
        popover.performClose(nil)
        let controller: HistoryWindowController
        if let existing = historyWindowController {
            controller = existing
        } else {
            controller = HistoryWindowController()
            historyWindowController = controller
        }
        controller.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "熄屏不休眠",
            .applicationVersion: "1.2.0",
            .credits: NSAttributedString(
                string: "关闭显示器，主机保持低功耗运行，随时等待远程连接。\n\nCodex Token 图表只读取本机 ~/.codex 的用量元数据，不读取对话内容，也不会联网。"
            )
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}
