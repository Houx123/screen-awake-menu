import Foundation

struct UsageScanResult {
    var events: [CodexUsageEvent]
    var diagnostics: UsageScanDiagnostics
}

/// Reads local Codex token metadata without ever loading prompt/response text.
///
/// Discovery is bounded: only the `sessions/<year>/<month>/<day>` directories
/// close to the visible window plus the flat `archived_sessions` directory are
/// enumerated, and files whose modification date predates the window are
/// skipped. Each file is read incrementally from the last byte offset, so a
/// long-lived menu-bar app does not rescan or reparse unchanged history.
///
/// The scanner is **not** thread-safe; callers must confine it to one queue
/// (the app uses a dedicated serial utility queue).
final class CodexUsageScanner {
    let codexRoot: URL
    var calendar: Calendar

    /// Upper bound for a single unterminated JSONL line; anything larger is
    /// discarded rather than buffered forever.
    let maxLineBufferBytes = 16 * 1024 * 1024

    private var fileStates: [String: FileScanState] = [:]
    private let fileManager = FileManager.default

    init(codexRoot: URL? = nil, calendar: Calendar = .current) {
        self.codexRoot = codexRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.calendar = calendar
    }

    func scan(windowStart: Date, windowEnd: Date) -> UsageScanResult {
        var diagnostics = UsageScanDiagnostics()
        let rootValues = try? codexRoot.resourceValues(forKeys: [.isDirectoryKey])
        diagnostics.rootExists = rootValues?.isDirectory == true

        guard diagnostics.rootExists else {
            fileStates.removeAll()
            return UsageScanResult(events: [], diagnostics: diagnostics)
        }

        let candidates = candidateFiles(windowStart: windowStart)
        let candidatePaths = Set(candidates.map(\.path))
        for path in Array(fileStates.keys) where !candidatePaths.contains(path) {
            fileStates.removeValue(forKey: path)
        }

        var events: [CodexUsageEvent] = []
        for url in candidates {
            diagnostics.filesConsidered += 1
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                diagnostics.unreadableFiles += 1
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attributes[.modificationDate] as? Date) ?? .distantPast

            // The last token event can never be newer than the file mtime, so a
            // file untouched since before the window cannot contribute.
            if mtime < windowStart {
                fileStates.removeValue(forKey: url.path)
                continue
            }

            let state = fileStates[url.path] ?? FileScanState()
            let previousMtime = state.mtime
            state.mtime = mtime

            if size < state.offset {
                // Truncated or rotated: forget the old baseline and re-read.
                state.reset()
            } else if size == state.offset, size > 0, mtime != previousMtime {
                // Rewritten in place without a length change: re-read safely.
                state.reset()
            }

            if size > state.offset {
                let bytesRead = readNewData(from: url, state: state, diagnostics: &diagnostics)
                state.offset += UInt64(bytesRead)
            }

            state.accumulator.prune(before: windowStart)
            state.accumulator.prune(after: windowEnd)
            diagnostics.filesScanned += 1
            diagnostics.malformedLines += state.accumulator.malformedLineCount
            fileStates[url.path] = state
            events.append(contentsOf: state.accumulator.events)
        }

        return UsageScanResult(events: events, diagnostics: diagnostics)
    }

    // MARK: - Discovery

    private func candidateFiles(windowStart: Date) -> [URL] {
        var result: [URL] = []
        // A session copied into both `sessions` and `archived_sessions` must be
        // counted once; the rollout file name carries the unique session UUID.
        var seenSessionNames = Set<String>()
        let sessionsRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        // Keep a couple of extra days of day-directories so a session that
        // started before the window but is still being appended is discovered.
        let earliestDay = calendar.startOfDay(for: windowStart.addingTimeInterval(-48 * 3600))

        let years = (try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for yearURL in years {
            guard let year = Int(yearURL.lastPathComponent) else { continue }
            let months = (try? fileManager.contentsOfDirectory(
                at: yearURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for monthURL in months {
                guard let month = Int(monthURL.lastPathComponent) else { continue }
                let days = (try? fileManager.contentsOfDirectory(
                    at: monthURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for dayURL in days {
                    guard let day = Int(dayURL.lastPathComponent) else { continue }
                    var components = DateComponents()
                    components.year = year
                    components.month = month
                    components.day = day
                    guard let dayStart = calendar.date(from: components), dayStart >= earliestDay else {
                        continue
                    }
                    for file in jsonlFiles(in: dayURL) where seenSessionNames.insert(file.lastPathComponent).inserted {
                        result.append(file)
                    }
                }
            }
        }

        let archivedRoot = codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        for file in jsonlFiles(in: archivedRoot) where seenSessionNames.insert(file.lastPathComponent).inserted {
            result.append(file)
        }
        return result
    }

    private func jsonlFiles(in directory: URL) -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jsonl" }
    }

    // MARK: - Incremental reading

    private func readNewData(
        from url: URL,
        state: FileScanState,
        diagnostics: inout UsageScanDiagnostics
    ) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            diagnostics.unreadableFiles += 1
            return 0
        }
        defer { try? handle.close() }

        if let currentOffset = try? handle.offset(), currentOffset != state.offset {
            do {
                try handle.seek(toOffset: state.offset)
            } catch {
                diagnostics.unreadableFiles += 1
                return 0
            }
        }

        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            diagnostics.unreadableFiles += 1
            return 0
        }
        guard !data.isEmpty else { return 0 }
        ingest(data: data, state: state)
        return data.count
    }

    private func ingest(data: Data, state: FileScanState) {
        state.buffer.append(data)

        var lineStart = state.buffer.startIndex
        while let newline = state.buffer[lineStart...].firstIndex(of: 0x0A) {
            let line = state.buffer.subdata(in: lineStart..<newline)
            ingest(line: line, state: state)
            lineStart = state.buffer.index(after: newline)
        }
        if lineStart > state.buffer.startIndex {
            state.buffer.removeSubrange(state.buffer.startIndex..<lineStart)
        }

        if state.buffer.count > maxLineBufferBytes {
            // Unterminated/oversized line: drop it instead of growing forever.
            state.buffer.removeAll(keepingCapacity: false)
            state.accumulator.malformedLineCount += 1
        }
    }

    /// Cheap marker pre-filter so large unrelated JSONL lines (tool output,
    /// images, prompts) are never handed to the JSON decoder.
    private func ingest(line: Data, state: FileScanState) {
        guard !line.isEmpty else { return }
        let hasUsageRecord = line.range(of: CodexUsageParser.tokenUsageRecordMarker) != nil
        let hasTokenCount = line.range(of: CodexUsageParser.tokenCountMarker) != nil
        guard hasUsageRecord || hasTokenCount else { return }
        state.accumulator.ingest(line: line)
    }
}

/// Mutable per-file incremental state, cached between refreshes.
private final class FileScanState {
    var offset: UInt64 = 0
    var buffer = Data()
    var mtime: Date = .distantPast
    var accumulator = CodexSessionAccumulator()

    func reset() {
        offset = 0
        buffer.removeAll(keepingCapacity: false)
        accumulator.reset()
    }
}
