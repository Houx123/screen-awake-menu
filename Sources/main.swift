import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: "熄屏不休眠"
            )
            button.toolTip = "熄屏不休眠"
        }

        let menu = NSMenu()

        let sleepDisplayItem = NSMenuItem(
            title: "立即熄屏（主机保持运行）",
            action: #selector(sleepDisplay),
            keyEquivalent: ""
        )
        sleepDisplayItem.target = self
        sleepDisplayItem.image = NSImage(
            systemSymbolName: "moon.fill",
            accessibilityDescription: nil
        )
        menu.addItem(sleepDisplayItem)

        menu.addItem(.separator())

        let explanationItem = NSMenuItem(
            title: "系统已设为不自动休眠，可等待远程连接",
            action: nil,
            keyEquivalent: ""
        )
        explanationItem.isEnabled = false
        menu.addItem(explanationItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于熄屏不休眠",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func sleepDisplay() {
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

    @objc private func showAbout() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "熄屏不休眠",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(
                string: "关闭显示器，主机保持低功耗运行，随时等待远程连接。"
            )
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
