import Cocoa

/// Contents of the status-bar popover: the display-sleep action and a compact
/// Codex token chart.
final class UsagePopoverViewController: NSViewController {
    var onSleepDisplay: (() -> Void)?
    var onHistory: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?
    private let dataController = UsageDataController()

    private let headerLabel = NSTextField(labelWithString: "Codex Token 用量")
    private let subtitleLabel = NSTextField(labelWithString: "近 24 小时 · 本地只读")
    private let summaryLabel = NSTextField(labelWithString: "正在读取本地 Codex 数据…")
    private let chartTitleLabel = NSTextField(labelWithString: "每小时 Token 用量（柱）与速度趋势（曲线）")
    private let combinedChart = UsageChartView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在读取本地 Codex 数据…")
    private let sleepButton = NSButton(title: "立即熄屏（主机保持运行）", target: nil, action: nil)
    private let historyButton = NSButton(title: "历史数据", target: nil, action: nil)
    private let aboutButton = NSButton(title: "关于", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)

    private lazy var hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:00"
        formatter.timeZone = Calendar.current.timeZone
        return formatter
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 306))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 340, height: 306)
        configureSubviews()
        layoutSubviews()

        dataController.onUpdate = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    /// Called by the status item when the popover opens.
    func beginRefreshing() {
        dataController.start()
    }

    /// Called when the popover closes; suspends all background work.
    func endRefreshing() {
        dataController.stop()
    }

    // MARK: - Configuration

    private func configureSubviews() {
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        chartTitleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        chartTitleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor

        combinedChart.barColor = .systemTeal
        combinedChart.lineColor = .systemOrange
        combinedChart.setAccessibilityLabel("每小时 Token 用量与速度合并图")

        sleepButton.target = self
        sleepButton.action = #selector(sleepDisplayTapped)
        sleepButton.bezelStyle = .rounded
        sleepButton.controlSize = .large
        sleepButton.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
        sleepButton.imagePosition = .imageLeading

        historyButton.target = self
        historyButton.action = #selector(historyTapped)
        historyButton.bezelStyle = .rounded

        aboutButton.target = self
        aboutButton.action = #selector(aboutTapped)
        aboutButton.bezelStyle = .rounded

        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        quitButton.bezelStyle = .rounded
        quitButton.keyEquivalent = "q"

        for subview in [
            headerLabel, subtitleLabel, summaryLabel, chartTitleLabel,
            combinedChart, statusLabel,
            sleepButton, historyButton, aboutButton, quitButton
        ] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func layoutSubviews() {
        let margin: CGFloat = 14
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            subtitleLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

            summaryLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

            chartTitleLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            chartTitleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            chartTitleLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

            combinedChart.topAnchor.constraint(equalTo: chartTitleLabel.bottomAnchor, constant: 2),
            combinedChart.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            combinedChart.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            combinedChart.heightAnchor.constraint(equalToConstant: 118),

            statusLabel.topAnchor.constraint(equalTo: combinedChart.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

            sleepButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            sleepButton.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            sleepButton.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            sleepButton.heightAnchor.constraint(equalToConstant: 28),

            historyButton.topAnchor.constraint(equalTo: sleepButton.bottomAnchor, constant: 6),
            historyButton.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            historyButton.heightAnchor.constraint(equalToConstant: 22),

            aboutButton.topAnchor.constraint(equalTo: historyButton.topAnchor),
            aboutButton.leadingAnchor.constraint(equalTo: historyButton.trailingAnchor, constant: 6),
            aboutButton.heightAnchor.constraint(equalToConstant: 22),

            quitButton.topAnchor.constraint(equalTo: historyButton.topAnchor),
            quitButton.leadingAnchor.constraint(equalTo: aboutButton.trailingAnchor, constant: 6),
            quitButton.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            quitButton.heightAnchor.constraint(equalToConstant: 22),
            historyButton.widthAnchor.constraint(equalTo: aboutButton.widthAnchor),
            aboutButton.widthAnchor.constraint(equalTo: quitButton.widthAnchor),

            view.bottomAnchor.constraint(greaterThanOrEqualTo: aboutButton.bottomAnchor, constant: 12)
        ])
    }

    // MARK: - Updates

    private func apply(_ snapshot: UsageSnapshot) {
        summaryLabel.stringValue = summaryText(for: snapshot)
        combinedChart.buckets = snapshot.buckets
        statusLabel.stringValue = statusText(for: snapshot)
    }

    private func summaryText(for snapshot: UsageSnapshot) -> String {
        switch snapshot.state {
        case .ok:
            let total = TokenFormat.grouped(snapshot.totalUsage.totalTokens)
            let speed = TokenFormat.speed(snapshot.latestHourlySpeed)
            let hour = snapshot.latestSpeedHour.map { hourFormatter.string(from: $0) } ?? "—"
            return "总计 \(total) tokens · 最新 \(hour) 速度 \(speed) tokens/分钟"
        case .noData:
            return "总计 0 tokens · 最新速度 0 tokens/分钟"
        case .missingRoot:
            return "总计 — · 最新速度 —"
        case .error(let message):
            return message
        }
    }

    private func statusText(for snapshot: UsageSnapshot) -> String {
        switch snapshot.state {
        case .missingRoot:
            return "未找到 ~/.codex 目录，暂无本地 Codex 用量数据。"
        case .noData:
            return "近 24 小时没有可用的 Codex Token 记录。"
        case .error(let message):
            return "读取 Codex 数据出错：\(message)"
        case .ok:
            var text = "已读取 \(snapshot.diagnostics.filesScanned) 个本地会话文件"
            if snapshot.diagnostics.malformedLines > 0 {
                text += "，已忽略 \(snapshot.diagnostics.malformedLines) 行无法解析的记录"
            }
            if snapshot.diagnostics.unreadableFiles > 0 {
                text += "，\(snapshot.diagnostics.unreadableFiles) 个文件暂时不可读"
            }
            return text
        }
    }

    // MARK: - Actions

    @objc private func sleepDisplayTapped() {
        onSleepDisplay?()
    }

    @objc private func aboutTapped() {
        onAbout?()
    }

    @objc private func historyTapped() {
        onHistory?()
    }

    @objc private func quitTapped() {
        onQuit?()
    }
}
