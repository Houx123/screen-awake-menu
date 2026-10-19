import Foundation

/// Owns the background refresh cadence for the popup.
///
/// Scanning and parsing happen on a dedicated serial utility queue; only the
/// finished snapshot hops back to the main thread. The controller starts when
/// the popup opens and stops when it closes, so hidden windows do no work.
/// It is confined to the main thread for lifecycle calls, and the scanner is
/// only ever touched from its own serial queue.
final class UsageDataController: NSObject, @unchecked Sendable {
    typealias UpdateHandler = (UsageSnapshot) -> Void

    private let scanner: CodexUsageScanner
    private let queue = DispatchQueue(
        label: "com.houxyin.screenawakemenu.codex-usage",
        qos: .utility
    )
    private let refreshInterval: TimeInterval
    private let windowHours: Int

    private var timer: Timer?
    private var generation = 0
    private var running = false

    var onUpdate: UpdateHandler?

    init(
        scanner: CodexUsageScanner = CodexUsageScanner(),
        refreshInterval: TimeInterval = 30,
        windowHours: Int = HourlyUsageAggregator.defaultWindowHours
    ) {
        self.scanner = scanner
        self.refreshInterval = refreshInterval
        self.windowHours = windowHours
        super.init()
    }

    /// Refreshes immediately and then periodically until `stop()`.
    func start() {
        guard !running else { return }
        running = true
        refresh()
        let timer = Timer(
            timeInterval: refreshInterval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        // Invalidate any in-flight UI update.
        generation += 1
    }

    func refresh() {
        generation += 1
        let requestGeneration = generation
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            // Re-read the calendar each pass so a time-zone change is honored.
            self.scanner.calendar = Calendar.current
            let calendar = self.scanner.calendar
            let windowStart = HourlyUsageAggregator.windowStart(
                for: now,
                hours: self.windowHours,
                calendar: calendar
            )
            let windowEnd = HourlyUsageAggregator.windowEnd(for: now, calendar: calendar)
            let result = self.scanner.scan(
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            let snapshot = HourlyUsageAggregator.snapshot(
                events: result.events,
                now: now,
                hours: self.windowHours,
                calendar: calendar,
                diagnostics: result.diagnostics
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, requestGeneration == self.generation else { return }
                self.onUpdate?(snapshot)
            }
        }
    }

    @objc private func timerFired() {
        refresh()
    }
}
