import Foundation

/// Token counters for one Codex usage sample.
///
/// The locally observed Codex schema (`~/.codex/sessions/**/*.jsonl`) reports a
/// usage object with the following fields:
///
///     input_tokens, cached_input_tokens, cache_write_input_tokens,
///     output_tokens, reasoning_output_tokens, total_tokens
///
/// In that schema the counters are *additive supersets*:
/// `input_tokens` already contains `cached_input_tokens`, and `output_tokens`
/// already contains `reasoning_output_tokens`. Therefore only the supersets may
/// be added together; adding every field would double count tokens.
///
/// `total_tokens` is authoritative when the record provides it. When it is
/// absent the total is derived from the supersets only, so each consumed token
/// is counted exactly once.
struct CodexTokenUsage: Equatable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheWriteInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static let zero = CodexTokenUsage()

    var isEmpty: Bool { totalTokens == 0 }

    static func + (lhs: CodexTokenUsage, rhs: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteInputTokens: lhs.cacheWriteInputTokens + rhs.cacheWriteInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }

    static func += (lhs: inout CodexTokenUsage, rhs: CodexTokenUsage) {
        lhs = lhs + rhs
    }

    /// Derives a total when the record does not carry `total_tokens`.
    ///
    /// `cached_input_tokens`, `cache_write_input_tokens` and
    /// `reasoning_output_tokens` are treated as subsets of the input/output
    /// supersets, matching the observed Codex schema, so they are intentionally
    /// not added again here.
    static func derivedTotal(
        inputTokens: Int64,
        outputTokens: Int64
    ) -> Int64 {
        max(0, inputTokens) + max(0, outputTokens)
    }

    /// Builds a usage value from a decoded JSON dictionary, tolerating missing
    /// or alternate field names and negative/malformed values.
    init(dictionary: [String: Any]? = nil) {
        guard let dictionary else { return }
        inputTokens = CodexTokenUsage.nonNegative(
            CodexTokenUsage.intValue(dictionary["input_tokens"])
                ?? CodexTokenUsage.intValue(dictionary["prompt_tokens"])
        )
        cachedInputTokens = CodexTokenUsage.nonNegative(
            CodexTokenUsage.intValue(dictionary["cached_input_tokens"])
                ?? CodexTokenUsage.intValue(dictionary["cache_read_input_tokens"])
        )
        cacheWriteInputTokens = CodexTokenUsage.nonNegative(
            CodexTokenUsage.intValue(dictionary["cache_write_input_tokens"])
                ?? CodexTokenUsage.intValue(dictionary["cache_creation_input_tokens"])
        )
        outputTokens = CodexTokenUsage.nonNegative(
            CodexTokenUsage.intValue(dictionary["output_tokens"])
                ?? CodexTokenUsage.intValue(dictionary["completion_tokens"])
        )
        reasoningOutputTokens = CodexTokenUsage.nonNegative(
            CodexTokenUsage.intValue(dictionary["reasoning_output_tokens"])
                ?? CodexTokenUsage.intValue(dictionary["reasoning_tokens"])
        )

        if let explicitTotal = CodexTokenUsage.intValue(dictionary["total_tokens"]), explicitTotal >= 0 {
            totalTokens = explicitTotal
        } else {
            totalTokens = CodexTokenUsage.derivedTotal(
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }
    }

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    private static func nonNegative(_ value: Int64?) -> Int64 {
        guard let value, value > 0 else { return 0 }
        return value
    }

    /// JSONSerialization turns every JSON number into `NSNumber`; this also
    /// accepts numeric strings defensively.
    static func intValue(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        case let double as Double:
            guard double.isFinite else { return nil }
            return Int64(double)
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }
}

/// One non-negative token delta attributable to a point in time.
struct CodexUsageEvent: Equatable {
    let timestamp: Date
    let usage: CodexTokenUsage
}

/// One wall-clock hour bucket in the visible window.
struct UsageBucket: Equatable {
    let start: Date
    var usage: CodexTokenUsage = .zero
    var eventCount: Int = 0

    /// Chosen "usage speed" definition: tokens consumed during the full
    /// wall-clock hour divided by 60 minutes, i.e. tokens per minute.
    var tokensPerMinute: Double {
        Double(usage.totalTokens) / 60.0
    }
}

/// Aggregate state shown by the popup.
enum UsageDataState: Equatable {
    case ok
    case noData
    case missingRoot
    case error(String)
}

/// Everything the popup needs to render one refresh.
struct UsageSnapshot: Equatable {
    let generatedAt: Date
    let windowStart: Date
    let windowEnd: Date
    let buckets: [UsageBucket]
    let totalUsage: CodexTokenUsage
    let latestHourlySpeed: Double
    let latestSpeedHour: Date?
    let state: UsageDataState
    let diagnostics: UsageScanDiagnostics

    static func empty(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now,
            windowStart: now,
            windowEnd: now,
            buckets: [],
            totalUsage: .zero,
            latestHourlySpeed: 0,
            latestSpeedHour: nil,
            state: .noData,
            diagnostics: UsageScanDiagnostics()
        )
    }
}

/// Lightweight counters describing what a scan touched; used for empty/error
/// hints and for tests.
struct UsageScanDiagnostics: Equatable {
    var rootExists = false
    var filesConsidered = 0
    var filesScanned = 0
    var malformedLines = 0
    var unreadableFiles = 0
}

/// Compact, locale-independent number formatting for the popup.
enum TokenFormat {
    /// 1234 -> "1.2K", 2_500_000 -> "2.5M", 42 -> "42".
    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 {
            return trim(String(format: "%.1fM", value / 1_000_000))
        }
        if magnitude >= 1_000 {
            return trim(String(format: "%.1fK", value / 1_000))
        }
        if magnitude >= 100 {
            return String(format: "%.0f", value)
        }
        if magnitude >= 10 {
            return trim(String(format: "%.1f", value))
        }
        if magnitude > 0 {
            return trim(String(format: "%.2f", value))
        }
        return "0"
    }

    /// 1234567 -> "1,234,567" (stable grouping, independent of user locale).
    static func grouped(_ value: Int64) -> String {
        let negative = value < 0
        var digits = String(abs(value))
        var result = ""
        while digits.count > 3 {
            let suffix = String(digits.suffix(3))
            digits.removeLast(3)
            result = "," + suffix + result
        }
        result = digits + result
        return negative ? "-" + result : result
    }

    static func speed(_ tokensPerMinute: Double) -> String {
        if tokensPerMinute >= 100 {
            return String(format: "%.0f", tokensPerMinute)
        }
        if tokensPerMinute >= 10 {
            return String(format: "%.1f", tokensPerMinute)
        }
        if tokensPerMinute > 0 {
            return String(format: "%.2f", tokensPerMinute)
        }
        return "0"
    }

    private static func trim(_ string: String) -> String {
        var result = string
        if result.contains(".") {
            while result.hasSuffix("0") {
                result.removeLast()
            }
            if result.hasSuffix(".") {
                result.removeLast()
            }
        }
        return result
    }
}
