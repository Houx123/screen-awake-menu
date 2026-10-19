import Foundation

/// Buckets token deltas into wall-clock hours in the user's current calendar
/// and time zone, producing the visible window (default: the most recent 24
/// hours, including hours with zero usage).
enum HourlyUsageAggregator {
    static let defaultWindowHours = 24

    static func hourStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    /// Start of the earliest visible bucket: the start of the current hour
    /// minus `hours - 1`.
    static func windowStart(
        for now: Date,
        hours: Int = defaultWindowHours,
        calendar: Calendar = .current
    ) -> Date {
        let currentHour = hourStart(for: now, calendar: calendar)
        return calendar.date(byAdding: .hour, value: -(hours - 1), to: currentHour) ?? currentHour
    }

    /// End of the visible window: the start of the next hour.
    static func windowEnd(
        for now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let currentHour = hourStart(for: now, calendar: calendar)
        return calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? currentHour
    }

    static func snapshot(
        events: [CodexUsageEvent],
        now: Date,
        hours: Int = defaultWindowHours,
        calendar: Calendar = .current,
        diagnostics: UsageScanDiagnostics
    ) -> UsageSnapshot {
        let start = windowStart(for: now, hours: hours, calendar: calendar)
        let end = windowEnd(for: now, calendar: calendar)

        var buckets: [UsageBucket] = []
        buckets.reserveCapacity(hours)
        for index in 0..<hours {
            let bucketStart = calendar.date(byAdding: .hour, value: index, to: start) ?? start
            buckets.append(UsageBucket(start: bucketStart))
        }

        var total = CodexTokenUsage.zero
        for event in events {
            guard event.timestamp >= start, event.timestamp < end else { continue }
            let eventHour = hourStart(for: event.timestamp, calendar: calendar)
            let offset = calendar.dateComponents([.hour], from: start, to: eventHour).hour ?? -1
            guard offset >= 0, offset < buckets.count else { continue }
            buckets[offset].usage += event.usage
            buckets[offset].eventCount += 1
            total += event.usage
        }

        let (latestSpeed, latestHour) = latestSpeed(in: buckets)
        let state: UsageDataState
        if !diagnostics.rootExists {
            state = .missingRoot
        } else if total.totalTokens == 0 {
            state = .noData
        } else {
            state = .ok
        }

        return UsageSnapshot(
            generatedAt: now,
            windowStart: start,
            windowEnd: end,
            buckets: buckets,
            totalUsage: total,
            latestHourlySpeed: latestSpeed,
            latestSpeedHour: latestHour,
            state: state,
            diagnostics: diagnostics
        )
    }

    /// "Current/latest hourly speed": the current hour when it has usage,
    /// otherwise the most recent hour with usage.
    static func latestSpeed(in buckets: [UsageBucket]) -> (Double, Date?) {
        if let current = buckets.last, current.usage.totalTokens > 0 {
            return (current.tokensPerMinute, current.start)
        }
        if let lastActive = buckets.last(where: { $0.usage.totalTokens > 0 }) {
            return (lastActive.tokensPerMinute, lastActive.start)
        }
        return (0, nil)
    }
}
