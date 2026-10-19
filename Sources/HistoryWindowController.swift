import Cocoa

private struct HistoryDay {
    let start: Date
    var usage: CodexTokenUsage = .zero
    var eventCount = 0

    var averageTokensPerMinute: Double {
        Double(usage.totalTokens) / (24 * 60)
    }
}

/// A normal App window for history that performs no work while closed.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let historyViewController = HistoryViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex 历史数据"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.contentViewController = historyViewController
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        historyViewController.beginRefreshing()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        historyViewController.endRefreshing()
    }
}

private final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let dataController = UsageDataController(refreshInterval: 300, windowHours: 30 * 24)
    private var days: [HistoryDay] = []

    private let titleLabel = NSTextField(labelWithString: "最近 30 天 Codex 用量")
    private let subtitleLabel = NSTextField(labelWithString: "本地只读 · 窗口关闭后停止扫描")
    private let summaryLabel = NSTextField(labelWithString: "正在读取历史数据…")
    private let chartTitleLabel = NSTextField(labelWithString: "每日 Token（柱）与平均速度趋势（曲线）")
    private let chart = HistoryChartView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scrollView = NSScrollView()

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd")
        return formatter
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        layoutViews()
        dataController.onUpdate = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    func beginRefreshing() {
        dataController.start()
    }

    func endRefreshing() {
        dataController.stop()
    }

    private func configureViews() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        chartTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor

        let columns: [(String, String, CGFloat)] = [
            ("date", "日期", 118),
            ("input", "输入", 104),
            ("cached", "缓存输入", 104),
            ("output", "输出", 104),
            ("reasoning", "推理输出", 104),
            ("total", "总 Token", 112),
            ("events", "记录", 64)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "date" ? 100 : 64
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for subview in [titleLabel, subtitleLabel, summaryLabel, chartTitleLabel, chart, statusLabel, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            subtitleLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),

            chartTitleLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 14),
            chartTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            chartTitleLabel.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),

            chart.topAnchor.constraint(equalTo: chartTitleLabel.bottomAnchor, constant: 4),
            chart.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),
            chart.heightAnchor.constraint(equalToConstant: 170),

            statusLabel.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
    }

    private func apply(_ snapshot: UsageSnapshot) {
        days = aggregateByDay(snapshot.buckets)
        chart.days = days
        table.reloadData()

        let total = days.reduce(CodexTokenUsage.zero) { $0 + $1.usage }
        let average = days.isEmpty ? 0 : total.totalTokens / Int64(days.count)
        let cacheRate: Double = total.inputTokens > 0
            ? Double(total.cachedInputTokens) / Double(total.inputTokens) * 100
            : 0
        let cacheRateText = String(format: "%.1f%%", cacheRate)
        summaryLabel.stringValue = "累计 \(TokenFormat.grouped(total.totalTokens)) · 日均 \(TokenFormat.grouped(average)) · 缓存命中 \(cacheRateText)"

        switch snapshot.state {
        case .missingRoot:
            statusLabel.stringValue = "未找到 ~/.codex，暂无历史数据。"
        case .noData:
            statusLabel.stringValue = "最近 30 天没有可用的 Codex Token 记录。"
        case .error(let message):
            statusLabel.stringValue = "读取历史数据失败：\(message)"
        case .ok:
            statusLabel.stringValue = "已读取 \(snapshot.diagnostics.filesScanned) 个本地会话文件；明细按日期从新到旧排列。"
        }
    }

    private func aggregateByDay(_ buckets: [UsageBucket]) -> [HistoryDay] {
        var calendar = Calendar.current
        calendar.timeZone = .current
        var byDay: [Date: HistoryDay] = [:]
        for bucket in buckets {
            let start = calendar.startOfDay(for: bucket.start)
            var day = byDay[start] ?? HistoryDay(start: start)
            day.usage += bucket.usage
            day.eventCount += bucket.eventCount
            byDay[start] = day
        }
        return byDay.values.sorted { $0.start < $1.start }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { days.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < days.count, let tableColumn else { return nil }
        let day = days[days.count - 1 - row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        switch identifier.rawValue {
        case "date": cell.textField?.stringValue = dayFormatter.string(from: day.start)
        case "input": cell.textField?.stringValue = TokenFormat.grouped(day.usage.inputTokens)
        case "cached": cell.textField?.stringValue = TokenFormat.grouped(day.usage.cachedInputTokens)
        case "output": cell.textField?.stringValue = TokenFormat.grouped(day.usage.outputTokens)
        case "reasoning": cell.textField?.stringValue = TokenFormat.grouped(day.usage.reasoningOutputTokens)
        case "total": cell.textField?.stringValue = TokenFormat.grouped(day.usage.totalTokens)
        case "events": cell.textField?.stringValue = "\(day.eventCount)"
        default: cell.textField?.stringValue = "—"
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

private final class HistoryChartView: NSView {
    var days: [HistoryDay] = [] { didSet { needsDisplay = true } }

    private let leftInset: CGFloat = 52
    private let rightInset: CGFloat = 52
    private let topInset: CGFloat = 20
    private let bottomInset: CGFloat = 20
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let values = days.map { Double($0.usage.totalTokens) }
        guard let maxValue = values.max(), maxValue > 0 else {
            drawText("暂无历史数据", at: NSPoint(x: bounds.midX, y: bounds.midY), centered: true)
            return
        }
        let plot = NSRect(
            x: leftInset,
            y: bottomInset,
            width: max(1, bounds.width - leftInset - rightInset),
            height: max(1, bounds.height - topInset - bottomInset)
        )
        let tokenMax = UsageChartView.niceMax(maxValue)
        let speedMax = tokenMax / (24 * 60)
        drawGrid(in: plot, tokenMax: tokenMax, speedMax: speedMax)
        drawBars(in: plot, values: values, max: tokenMax)
        drawCurve(in: plot, values: days.map(\.averageTokensPerMinute), max: speedMax)
        drawDates(in: plot)
        drawText("tokens", at: NSPoint(x: plot.minX, y: plot.maxY + 8), color: .systemTeal)
        drawText("tokens/min", at: NSPoint(x: plot.maxX, y: plot.maxY + 8), color: .systemOrange, right: true)
    }

    private func drawGrid(in plot: NSRect, tokenMax: Double, speedMax: Double) {
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = (plot.minY + plot.height * fraction).rounded() + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.setStroke()
            path.lineWidth = fraction == 0 ? 1 : 0.5
            path.stroke()
            drawText(TokenFormat.compact(tokenMax * Double(fraction)), at: NSPoint(x: plot.minX - 5, y: y), right: true)
            drawText(TokenFormat.compact(speedMax * Double(fraction)), at: NSPoint(x: plot.maxX + 5, y: y), color: .systemOrange)
        }
    }

    private func drawBars(in plot: NSRect, values: [Double], max scaleMax: Double) {
        let slot = plot.width / CGFloat(values.count)
        let width = max(2, slot * 0.64)
        for (index, value) in values.enumerated() where value > 0 {
            let height = max(1, CGFloat(value / scaleMax) * plot.height)
            let rect = NSRect(
                x: plot.minX + CGFloat(index) * slot + (slot - width) / 2,
                y: plot.minY,
                width: width,
                height: height
            )
            NSColor.systemTeal.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawCurve(in plot: NSRect, values: [Double], max scaleMax: Double) {
        guard values.count > 1, scaleMax > 0 else { return }
        let slot = plot.width / CGFloat(values.count)
        let points = values.enumerated().map { index, value in
            NSPoint(
                x: plot.minX + (CGFloat(index) + 0.5) * slot,
                y: plot.minY + min(max(CGFloat(value / scaleMax), 0), 1) * plot.height
            )
        }
        let path = NSBezierPath()
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let previous = index > 0 ? points[index - 1] : points[index]
            let start = points[index]
            let end = points[index + 1]
            let following = index + 2 < points.count ? points[index + 2] : end
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            let c1 = NSPoint(x: start.x + (end.x - start.x) / 3, y: min(Swift.max(start.y + (end.y - previous.y) / 6, minY), maxY))
            let c2 = NSPoint(x: end.x - (end.x - start.x) / 3, y: min(Swift.max(end.y - (following.y - start.y) / 6, minY), maxY))
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        }
        NSColor.systemOrange.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawDates(in plot: NSRect) {
        guard !days.isEmpty else { return }
        let indices = Set([0, days.count / 4, days.count / 2, days.count * 3 / 4, days.count - 1])
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let slot = plot.width / CGFloat(days.count)
        for index in indices.sorted() where index < days.count {
            let x = plot.minX + (CGFloat(index) + 0.5) * slot
            drawText(formatter.string(from: days[index].start), at: NSPoint(x: x, y: plot.minY - 10), centered: true)
        }
    }

    private func drawText(
        _ text: String,
        at point: NSPoint,
        color: NSColor = .secondaryLabelColor,
        centered: Bool = false,
        right: Bool = false
    ) {
        let value = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = value.size()
        let x = centered ? point.x - size.width / 2 : (right ? point.x - size.width : point.x)
        value.draw(at: NSPoint(x: x, y: point.y - size.height / 2))
    }
}
