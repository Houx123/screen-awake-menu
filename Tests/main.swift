import Foundation

// Deterministic test harness for the Codex usage parsing/aggregation logic.
//
// It never reads the developer's real ~/.codex data: every input is built in
// memory or in a throwaway temporary directory.

var totalChecks = 0
var failures = 0
var tempRoots: [URL] = []

func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    totalChecks += 1
    if !condition {
        failures += 1
        print("    ✗ \(message)  [\(file):\(line)]")
    }
}

func expectEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    totalChecks += 1
    if lhs != rhs {
        failures += 1
        print("    ✗ \(message): expected \(rhs), got \(lhs)  [\(file):\(line)]")
    }
}

func run(_ name: String, _ body: () -> Void) {
    let before = failures
    print("▶︎ \(name)")
    body()
    if failures == before {
        print("    ✓ pass")
    }
}

// MARK: - Helpers

let isoParser = ISO8601DateFormatter()
isoParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

let isoParserPlain = ISO8601DateFormatter()
isoParserPlain.formatOptions = [.withInternetDateTime]

func date(_ string: String) -> Date {
    guard let value = isoParser.date(from: string) ?? isoParserPlain.date(from: string) else {
        fatalError("bad test date: \(string)")
    }
    return value
}

func isoString(_ value: Date) -> String {
    isoParser.string(from: value)
}

func json(_ object: [String: Any]) -> Data {
    // A fixed, small object; failure here is a test bug.
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func usageDict(
    input: Int64 = 0,
    cached: Int64 = 0,
    cacheWrite: Int64 = 0,
    output: Int64 = 0,
    reasoning: Int64 = 0,
    total: Int64? = nil
) -> [String: Any] {
    var dictionary: [String: Any] = [
        "input_tokens": input,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": cacheWrite,
        "output_tokens": output,
        "reasoning_output_tokens": reasoning
    ]
    if let total {
        dictionary["total_tokens"] = total
    }
    return dictionary
}

func tokenUsageRecordLine(
    at timestamp: Date,
    usage: [String: Any]?,
    cumulative: Int64?,
    useTurnCounter: Bool = false
) -> Data {
    var payload: [String: Any] = [:]
    if let usage { payload["usage"] = usage }
    if let cumulative {
        payload[useTurnCounter ? "turn_token_usage" : "thread_token_usage"] = ["total_tokens": cumulative]
    }
    return json([
        "type": "token_usage_record",
        "timestamp": isoString(timestamp),
        "ordinal": 1,
        "payload": payload
    ])
}

func tokenCountLine(at timestamp: Date, last: [String: Any]?, total: Int64?) -> Data {
    var info: [String: Any] = [:]
    if let last { info["last_token_usage"] = last }
    if let total { info["total_token_usage"] = ["total_tokens": total] }
    return json([
        "type": "event_msg",
        "timestamp": isoString(timestamp),
        "payload": ["type": "token_count", "info": info]
    ])
}

func usage(_ total: Int64) -> CodexTokenUsage {
    CodexTokenUsage(dictionary: ["total_tokens": total])
}

func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexUsageTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    tempRoots.append(url)
    return url
}

func write(_ lines: [Data], to url: URL) {
    var data = Data()
    for line in lines {
        data.append(line)
        data.append(0x0A)
    }
    try! data.write(to: url)
}

func append(_ line: Data, to url: URL) {
    let handle = try! FileHandle(forWritingTo: url)
    defer { try! handle.close() }
    try! handle.seekToEnd()
    var data = line
    data.append(0x0A)
    try! handle.write(contentsOf: data)
}

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!

// MARK: - Parser tests

run("explicit total is used once and cached/reasoning are not re-added") {
    let timestamp = date("2026-10-15T13:40:31.993Z")
    let line = tokenUsageRecordLine(
        at: timestamp,
        usage: usageDict(input: 100, cached: 40, output: 20, reasoning: 5, total: 120),
        cumulative: 120
    )
    switch CodexUsageParser.parse(line: line) {
    case .sample(let sample):
        expectEqual(sample.usage.totalTokens, 120, "explicit total")
        expectEqual(sample.usage.cachedInputTokens, 40, "cached input")
        expectEqual(sample.usage.reasoningOutputTokens, 5, "reasoning output")
        expect(sample.hasExplicitUsage, "has explicit usage")
        expect(sample.usage.totalTokens != 100 + 40 + 20 + 5, "must not double count subsets")
        expectEqual(sample.cumulativeTotal, 120, "cumulative")
    default:
        expect(false, "expected a sample")
    }
}

run("derived total falls back to input + output when total_tokens is absent") {
    let line = tokenUsageRecordLine(
        at: date("2026-10-15T13:40:31.993Z"),
        usage: usageDict(input: 100, cached: 40, output: 20, reasoning: 5),
        cumulative: nil
    )
    switch CodexUsageParser.parse(line: line) {
    case .sample(let sample):
        expectEqual(sample.usage.totalTokens, 120, "derived total")
    default:
        expect(false, "expected a sample")
    }
}

run("alternate prompt/completion field names are accepted") {
    let line = tokenUsageRecordLine(
        at: date("2026-10-15T13:40:31.993Z"),
        usage: ["prompt_tokens": 70, "completion_tokens": 30, "cached_input_tokens": 10],
        cumulative: nil
    )
    switch CodexUsageParser.parse(line: line) {
    case .sample(let sample):
        expectEqual(sample.usage.totalTokens, 100, "prompt/completion total")
    default:
        expect(false, "expected a sample")
    }
}

run("malformed and unrelated lines are classified, never thrown") {
    if case .malformed = CodexUsageParser.parse(line: Data("{not json".utf8)) {
        expect(true, "")
    } else {
        expect(false, "invalid JSON should be malformed")
    }

    if case .notUsageRecord = CodexUsageParser.parse(line: json(["type": "response_item", "payload": [:]])) {
        expect(true, "")
    } else {
        expect(false, "unrelated type should be notUsageRecord")
    }

    let missingTimestamp = json([
        "type": "token_usage_record",
        "payload": ["usage": usageDict(total: 5)]
    ])
    if case .malformed = CodexUsageParser.parse(line: missingTimestamp) {
        expect(true, "")
    } else {
        expect(false, "missing timestamp should be malformed")
    }
}

// MARK: - Accumulator / delta tests

run("explicit per-event deltas accumulate") {
    let accumulator = CodexSessionAccumulator()
    accumulator.ingest(line: tokenUsageRecordLine(
        at: date("2026-10-15T13:40:31Z"),
        usage: usageDict(input: 100, output: 20, total: 120),
        cumulative: 120
    ))
    accumulator.ingest(line: tokenUsageRecordLine(
        at: date("2026-10-15T13:40:36Z"),
        usage: usageDict(input: 60, output: 20, total: 80),
        cumulative: 200
    ))
    expectEqual(accumulator.events.count, 2, "event count")
    expectEqual(accumulator.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 200, "sum")
}

run("token_usage_record wins over duplicated token_count events") {
    let accumulator = CodexSessionAccumulator()
    let usage = usageDict(input: 100, output: 20, total: 120)
    accumulator.ingest(line: tokenUsageRecordLine(
        at: date("2026-10-15T13:40:31Z"),
        usage: usage,
        cumulative: 120
    ))
    accumulator.ingest(line: tokenCountLine(
        at: date("2026-10-15T13:40:31.100Z"),
        last: usage,
        total: 120
    ))
    expectEqual(accumulator.events.count, 1, "only one family is counted")
    expectEqual(accumulator.events.first?.usage.totalTokens, 120, "value")
}

run("token_count is used when no token_usage_record exists") {
    let accumulator = CodexSessionAccumulator()
    accumulator.ingest(line: tokenCountLine(
        at: date("2026-10-15T13:40:31Z"),
        last: usageDict(input: 100, output: 20, total: 120),
        total: 120
    ))
    accumulator.ingest(line: tokenCountLine(
        at: date("2026-10-15T13:40:32Z"),
        last: usageDict(input: 60, output: 20, total: 80),
        total: 200
    ))
    expectEqual(accumulator.events.count, 2, "token_count event count")
    expectEqual(accumulator.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 200, "sum")
}

run("cumulative-only counters become non-negative deltas, including a reset") {
    let accumulator = CodexSessionAccumulator()
    for value in [Int64(100), 250, 400, 50] {
        accumulator.ingest(line: tokenUsageRecordLine(
            at: date("2026-10-15T13:40:31Z"),
            usage: nil,
            cumulative: value
        ))
    }
    let totals = accumulator.events.map { $0.usage.totalTokens }
    expectEqual(totals, [100, 150, 150, 50], "cumulative deltas with reset")
    expect(totals.allSatisfy { $0 >= 0 }, "all deltas non-negative")
}

run("turn-scoped cumulative counter resets cleanly between turns") {
    let accumulator = CodexSessionAccumulator()
    for value in [Int64(100), 250, 60, 120] {
        accumulator.ingest(line: tokenUsageRecordLine(
            at: date("2026-10-15T13:40:31Z"),
            usage: nil,
            cumulative: value,
            useTurnCounter: true
        ))
    }
    expectEqual(accumulator.events.map { $0.usage.totalTokens }, [100, 150, 60, 60], "turn resets")
}

// MARK: - Aggregation tests

let fixedNow = date("2026-10-15T12:34:56Z")

func fixedEvent(_ iso: String, tokens: Int64) -> CodexUsageEvent {
    CodexUsageEvent(timestamp: date(iso), usage: usage(tokens))
}

run("events bucket into 24 wall-clock hours including empties") {
    var diagnostics = UsageScanDiagnostics()
    diagnostics.rootExists = true
    let events = [
        fixedEvent("2026-10-14T13:05:00Z", tokens: 60),
        fixedEvent("2026-10-14T13:59:59Z", tokens: 120),
        fixedEvent("2026-10-15T12:10:00Z", tokens: 600),
        fixedEvent("2026-10-15T12:50:00Z", tokens: 0),
        fixedEvent("2026-10-14T12:00:00Z", tokens: 999), // before window
        fixedEvent("2026-10-15T13:00:00Z", tokens: 999)  // at/after window end
    ]
    let snapshot = HourlyUsageAggregator.snapshot(
        events: events,
        now: fixedNow,
        calendar: utcCalendar,
        diagnostics: diagnostics
    )

    expectEqual(snapshot.buckets.count, 24, "bucket count")
    expectEqual(snapshot.buckets.first?.usage.totalTokens, 180, "first bucket")
    expectEqual(snapshot.buckets[0].eventCount, 2, "first bucket event count")
    expectEqual(snapshot.buckets[23].usage.totalTokens, 600, "current bucket")
    expectEqual(snapshot.totalUsage.totalTokens, 780, "window total")
    expectEqual(snapshot.buckets[1].usage.totalTokens, 0, "empty bucket present")
    // 600 tokens over the (current) hour => 10 tokens/minute.
    expectEqual(snapshot.latestHourlySpeed, 10.0, "latest speed")
    expectEqual(snapshot.latestSpeedHour, date("2026-10-15T12:00:00Z"), "latest speed hour")
    expectEqual(snapshot.state, .ok, "state")
}

run("latest speed falls back to the most recent active hour") {
    var diagnostics = UsageScanDiagnostics()
    diagnostics.rootExists = true
    let events = [
        fixedEvent("2026-10-15T11:15:00Z", tokens: 3000)
    ]
    let snapshot = HourlyUsageAggregator.snapshot(
        events: events,
        now: fixedNow,
        calendar: utcCalendar,
        diagnostics: diagnostics
    )
    expectEqual(snapshot.latestHourlySpeed, 50.0, "fallback speed")
    expectEqual(snapshot.latestSpeedHour, date("2026-10-15T11:00:00Z"), "fallback hour")
}

run("empty data yields a noData state") {
    var diagnostics = UsageScanDiagnostics()
    diagnostics.rootExists = true
    let snapshot = HourlyUsageAggregator.snapshot(
        events: [],
        now: fixedNow,
        calendar: utcCalendar,
        diagnostics: diagnostics
    )
    expectEqual(snapshot.state, .noData, "noData")
    expectEqual(snapshot.latestHourlySpeed, 0, "zero speed")
    expectEqual(snapshot.totalUsage.totalTokens, 0, "zero total")
}

run("missing root yields a missingRoot state") {
    let snapshot = HourlyUsageAggregator.snapshot(
        events: [],
        now: fixedNow,
        calendar: utcCalendar,
        diagnostics: UsageScanDiagnostics()
    )
    expectEqual(snapshot.state, .missingRoot, "missingRoot")
}

// MARK: - Formatting tests

run("compact/grouped/speed formatting stays legible at extremes") {
    expectEqual(TokenFormat.compact(0), "0", "zero")
    expectEqual(TokenFormat.compact(42), "42", "small")
    expectEqual(TokenFormat.compact(1500), "1.5K", "thousands")
    expectEqual(TokenFormat.compact(2_500_000), "2.5M", "millions")
    expectEqual(TokenFormat.grouped(1_234_567), "1,234,567", "grouped")
    expectEqual(TokenFormat.grouped(0), "0", "grouped zero")
    expectEqual(TokenFormat.speed(10), "10.0", "speed")
    expectEqual(TokenFormat.speed(0), "0", "speed zero")
}

// MARK: - Scanner tests

run("scanner discovers sessions layout and parses metadata only") {
    let root = makeTempRoot()
    let dayDirectory = root.appendingPathComponent("sessions/2026/10/15", isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
    let sessionFile = dayDirectory.appendingPathComponent("rollout-test.jsonl")

    let eventTime = fixedNow.addingTimeInterval(-3600)
    write([
        json(["type": "session_meta", "timestamp": isoString(eventTime), "payload": ["base_instructions": "SECRET"]]),
        tokenUsageRecordLine(
            at: eventTime,
            usage: usageDict(input: 100, output: 20, total: 120),
            cumulative: 120
        ),
        Data("{\"type\":\"token_usage_record\", broken".utf8),
        json(["type": "response_item", "timestamp": isoString(eventTime), "payload": ["content": "SECRET"]])
    ], to: sessionFile)

    let scanner = CodexUsageScanner(codexRoot: root, calendar: utcCalendar)
    let result = scanner.scan(
        windowStart: HourlyUsageAggregator.windowStart(for: fixedNow, calendar: utcCalendar),
        windowEnd: HourlyUsageAggregator.windowEnd(for: fixedNow, calendar: utcCalendar)
    )

    expect(result.diagnostics.rootExists, "root exists")
    expectEqual(result.diagnostics.filesScanned, 1, "scanned file count")
    expectEqual(result.events.count, 1, "one usage event")
    expectEqual(result.events.first?.usage.totalTokens, 120, "event total")
    expect(result.diagnostics.malformedLines >= 1, "malformed line counted")
}

run("scanner reads increments without duplicating and handles truncation") {
    let root = makeTempRoot()
    let dayDirectory = root.appendingPathComponent("sessions/2026/10/15", isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
    let sessionFile = dayDirectory.appendingPathComponent("rollout-incremental.jsonl")

    let windowStart = HourlyUsageAggregator.windowStart(for: fixedNow, calendar: utcCalendar)
    let windowEnd = HourlyUsageAggregator.windowEnd(for: fixedNow, calendar: utcCalendar)
    let scanner = CodexUsageScanner(codexRoot: root, calendar: utcCalendar)

    let firstTime = fixedNow.addingTimeInterval(-7200)
    write([
        tokenUsageRecordLine(at: firstTime, usage: usageDict(input: 100, output: 0, total: 100), cumulative: 100)
    ], to: sessionFile)

    let firstScan = scanner.scan(windowStart: windowStart, windowEnd: windowEnd)
    expectEqual(firstScan.events.count, 1, "first scan events")
    expectEqual(firstScan.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 100, "first scan total")

    append(
        tokenUsageRecordLine(at: fixedNow.addingTimeInterval(-3600), usage: usageDict(input: 50, output: 0, total: 50), cumulative: 150),
        to: sessionFile
    )
    let secondScan = scanner.scan(windowStart: windowStart, windowEnd: windowEnd)
    expectEqual(secondScan.events.count, 2, "second scan events")
    expectEqual(secondScan.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 150, "second scan total")

    // Truncate/replace the file with a single smaller record.
    write([
        tokenUsageRecordLine(at: fixedNow.addingTimeInterval(-1800), usage: usageDict(input: 70, output: 0, total: 70), cumulative: 70)
    ], to: sessionFile)
    let thirdScan = scanner.scan(windowStart: windowStart, windowEnd: windowEnd)
    expectEqual(thirdScan.events.count, 1, "after truncation events")
    expectEqual(thirdScan.events.first?.usage.totalTokens, 70, "after truncation total")
}

run("scanner handles token_count-only sessions and missing roots") {
    let root = makeTempRoot()
    let dayDirectory = root.appendingPathComponent("sessions/2026/10/15", isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
    let sessionFile = dayDirectory.appendingPathComponent("rollout-token-count.jsonl")
    write([
        tokenCountLine(
            at: fixedNow.addingTimeInterval(-3600),
            last: usageDict(input: 100, output: 20, total: 120),
            total: 120
        ),
        tokenCountLine(
            at: fixedNow.addingTimeInterval(-3500),
            last: usageDict(input: 60, output: 20, total: 80),
            total: 200
        )
    ], to: sessionFile)

    let windowStart = HourlyUsageAggregator.windowStart(for: fixedNow, calendar: utcCalendar)
    let windowEnd = HourlyUsageAggregator.windowEnd(for: fixedNow, calendar: utcCalendar)
    let scanner = CodexUsageScanner(codexRoot: root, calendar: utcCalendar)
    let result = scanner.scan(windowStart: windowStart, windowEnd: windowEnd)
    expectEqual(result.events.count, 2, "token_count events")
    expectEqual(result.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 200, "token_count total")

    let missingRoot = root.appendingPathComponent("does-not-exist", isDirectory: true)
    let missingScanner = CodexUsageScanner(codexRoot: missingRoot, calendar: utcCalendar)
    let missingResult = missingScanner.scan(windowStart: windowStart, windowEnd: windowEnd)
    expect(!missingResult.diagnostics.rootExists, "missing root flag")
    expectEqual(missingResult.events.count, 0, "missing root events")
}

run("scanner counts a session copied to both sessions and archived_sessions once") {
    let root = makeTempRoot()
    let dayDirectory = root.appendingPathComponent("sessions/2026/10/15", isDirectory: true)
    let archivedDirectory = root.appendingPathComponent("archived_sessions", isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)

    let line = tokenUsageRecordLine(
        at: fixedNow.addingTimeInterval(-3600),
        usage: usageDict(input: 100, output: 0, total: 100),
        cumulative: 100
    )
    let name = "rollout-duplicate-session.jsonl"
    write([line], to: dayDirectory.appendingPathComponent(name))
    write([line], to: archivedDirectory.appendingPathComponent(name))

    let scanner = CodexUsageScanner(codexRoot: root, calendar: utcCalendar)
    let result = scanner.scan(
        windowStart: HourlyUsageAggregator.windowStart(for: fixedNow, calendar: utcCalendar),
        windowEnd: HourlyUsageAggregator.windowEnd(for: fixedNow, calendar: utcCalendar)
    )
    expectEqual(result.events.count, 1, "deduplicated event count")
    expectEqual(result.events.reduce(Int64(0)) { $0 + $1.usage.totalTokens }, 100, "deduplicated total")
}

// MARK: - Cleanup & summary

for root in tempRoots {
    try? FileManager.default.removeItem(at: root)
}

print("")
if failures == 0 {
    print("✅ All \(totalChecks) checks passed")
    exit(0)
} else {
    print("❌ \(failures) of \(totalChecks) checks failed")
    exit(1)
}
