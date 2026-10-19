import Cocoa

/// A compact, self-contained combined chart drawn with AppKit/Core Graphics.
///
/// It renders 24 wall-clock hourly buckets once: token totals as teal bars and
/// the corresponding tokens/minute values as an orange trend curve. The two measures
/// share one time axis and use matched left/right value axes.
final class UsageChartView: NSView {
    var buckets: [UsageBucket] = [] {
        didSet { needsDisplay = true }
    }

    var barColor: NSColor = .systemTeal { didSet { needsDisplay = true } }
    var lineColor: NSColor = .systemOrange { didSet { needsDisplay = true } }

    var emptyText: String = "暂无数据" {
        didSet { needsDisplay = true }
    }

    private let leftInset: CGFloat = 46
    private let rightInset: CGFloat = 46
    private let topInset: CGFloat = 20
    private let bottomInset: CGFloat = 16

    private let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private let unitFont = NSFont.systemFont(ofSize: 9, weight: .regular)

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let tokenValues = buckets.map { Double($0.usage.totalTokens) }
        let speedValues = buckets.map(\.tokensPerMinute)
        let maxTokens = tokenValues.max() ?? 0
        guard !tokenValues.isEmpty, maxTokens > 0 else {
            drawEmptyState()
            return
        }

        let plotRect = NSRect(
            x: leftInset,
            y: bottomInset,
            width: max(1, bounds.width - leftInset - rightInset),
            height: max(1, bounds.height - topInset - bottomInset)
        )

        let tokenScaleMax = UsageChartView.niceMax(maxTokens)
        // Hourly speed is defined as tokens / 60, so the right axis stays
        // mathematically aligned with the token axis at every grid line.
        let speedScaleMax = tokenScaleMax / 60
        drawGrid(
            plotRect: plotRect,
            tokenScaleMax: tokenScaleMax,
            speedScaleMax: speedScaleMax
        )
        drawBars(plotRect: plotRect, values: tokenValues, scaleMax: tokenScaleMax)
        drawSpeedCurve(plotRect: plotRect, values: speedValues, scaleMax: speedScaleMax)
        drawTimeLabels(plotRect: plotRect)
        drawUnitLabel(plotRect: plotRect)
    }

    // MARK: - Drawing

    private func drawGrid(
        plotRect: NSRect,
        tokenScaleMax: Double,
        speedScaleMax: Double
    ) {
        let fractions: [CGFloat] = [0, 0.5, 1]
        NSColor.separatorColor.setStroke()
        for fraction in fractions {
            let y = (plotRect.minY + plotRect.height * fraction).rounded() + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plotRect.minX, y: y))
            path.line(to: NSPoint(x: plotRect.maxX, y: y))
            path.lineWidth = fraction == 0 ? 1 : 0.5
            path.stroke()

            let tokenValue = tokenScaleMax * Double(fraction)
            drawString(
                TokenFormat.compact(tokenValue),
                attributes: [.font: axisFont, .foregroundColor: NSColor.secondaryLabelColor],
                rightAlignedAt: NSPoint(x: plotRect.minX - 4, y: y)
            )
            let speedValue = speedScaleMax * Double(fraction)
            drawString(
                TokenFormat.compact(speedValue),
                attributes: [.font: axisFont, .foregroundColor: lineColor],
                leftAlignedAt: NSPoint(x: plotRect.maxX + 4, y: y)
            )
        }
    }

    private func drawBars(plotRect: NSRect, values: [Double], scaleMax: Double) {
        let count = values.count
        let slot = plotRect.width / CGFloat(count)
        let barWidth = max(1, slot * 0.66)

        for (index, value) in values.enumerated() {
            let fraction = CGFloat(value / scaleMax)
            let barHeight = max(value > 0 ? 1 : 0, fraction * plotRect.height)
            guard barHeight > 0 else { continue }
            let x = plotRect.minX + CGFloat(index) * slot + (slot - barWidth) / 2
            let rect = NSRect(x: x, y: plotRect.minY, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let isCurrent = index == count - 1
            (isCurrent ? barColor : barColor.withAlphaComponent(0.58)).setFill()
            path.fill()
        }
    }

    private func drawSpeedCurve(plotRect: NSRect, values: [Double], scaleMax: Double) {
        guard !values.isEmpty, scaleMax > 0 else { return }
        let slot = plotRect.width / CGFloat(values.count)
        let points = values.enumerated().map { index, value in
            let x = plotRect.minX + (CGFloat(index) + 0.5) * slot
            let fraction = min(max(CGFloat(value / scaleMax), 0), 1)
            return NSPoint(x: x, y: plotRect.minY + fraction * plotRect.height)
        }
        let path = NSBezierPath()
        path.move(to: points[0])

        // Catmull-Rom-style control points create a readable smooth trend.
        // Clamp both controls to each segment's vertical range so smoothing
        // never invents a peak or a negative speed between hourly samples.
        for index in 0..<(points.count - 1) {
            let previous = index > 0 ? points[index - 1] : points[index]
            let start = points[index]
            let end = points[index + 1]
            let following = index + 2 < points.count ? points[index + 2] : end
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            let firstControl = NSPoint(
                x: start.x + (end.x - start.x) / 3,
                y: min(max(start.y + (end.y - previous.y) / 6, minY), maxY)
            )
            let secondControl = NSPoint(
                x: end.x - (end.x - start.x) / 3,
                y: min(max(end.y - (following.y - start.y) / 6, minY), maxY)
            )
            path.curve(to: end, controlPoint1: firstControl, controlPoint2: secondControl)
        }

        lineColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()

        for (index, value) in values.enumerated() where value > 0 {
            let point = points[index]
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 1.75, y: point.y - 1.75, width: 3.5, height: 3.5))
            lineColor.setFill()
            dot.fill()
        }
    }

    private func drawTimeLabels(plotRect: NSRect) {
        let count = buckets.count
        guard count > 0 else { return }
        let candidateIndices = Set([0, count / 4, count / 2, (count * 3) / 4, count - 1])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:00"
        formatter.timeZone = Calendar.current.timeZone

        let slot = plotRect.width / CGFloat(count)
        for index in candidateIndices.sorted() where index >= 0 && index < count {
            let label = formatter.string(from: buckets[index].start)
            let centerX = plotRect.minX + (CGFloat(index) + 0.5) * slot
            drawString(
                label,
                attributes: [.font: axisFont, .foregroundColor: NSColor.tertiaryLabelColor],
                centeredAt: NSPoint(x: centerX, y: plotRect.minY - 9)
            )
        }
    }

    private func drawUnitLabel(plotRect: NSRect) {
        drawString(
            "tokens",
            attributes: [.font: unitFont, .foregroundColor: barColor],
            leftAlignedAt: NSPoint(x: plotRect.minX, y: plotRect.maxY + 8)
        )
        drawString(
            "tokens/min",
            attributes: [.font: unitFont, .foregroundColor: lineColor],
            rightAlignedAt: NSPoint(x: plotRect.maxX, y: plotRect.maxY + 7)
        )
    }

    private func drawEmptyState() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        drawString(emptyText, attributes: attributes, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Text helpers

    private func drawString(
        _ string: String,
        attributes: [NSAttributedString.Key: Any],
        rightAlignedAt point: NSPoint
    ) {
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: point.x - size.width, y: point.y - size.height / 2))
    }

    private func drawString(
        _ string: String,
        attributes: [NSAttributedString.Key: Any],
        leftAlignedAt point: NSPoint
    ) {
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: point.x, y: point.y - size.height / 2))
    }

    private func drawString(
        _ string: String,
        attributes: [NSAttributedString.Key: Any],
        centeredAt point: NSPoint
    ) {
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    /// Rounds a maximum up to a 1/2/5 × 10ⁿ value so axis labels stay clean.
    static func niceMax(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let normalized = value / base
        let nice: Double
        if normalized <= 1 {
            nice = 1
        } else if normalized <= 2 {
            nice = 2
        } else if normalized <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * base
    }
}
