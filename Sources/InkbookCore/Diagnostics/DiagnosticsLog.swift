import Foundation

/// App-wide error and event log, persisted as JSON lines so entries written just before a crash
/// survive it. Read by the Diagnostics screen and by the agent's `read_diagnostics` tool.
public final class DiagnosticsLog: @unchecked Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable { case info, warning, error }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var date: Date
        public var level: Level
        public var category: String
        public var message: String

        public init(id: UUID = UUID(), date: Date = Date(), level: Level, category: String, message: String) {
            self.id = id; self.date = date; self.level = level; self.category = category; self.message = message
        }

        public var line: String {
            "\(DiagnosticsLog.timestamp(date)) \(level.rawValue.uppercased()) [\(category)] \(message)"
        }
    }

    /// Process-wide log. The app points it at a file at launch; until then it is memory-only.
    public static let shared = DiagnosticsLog(fileURL: nil)

    public let capacity: Int
    private let lock = NSLock()
    private var fileURL: URL?
    private var items: [Entry] = []
    private var linesOnDisk = 0
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(fileURL: URL?, capacity: Int = 400) {
        self.capacity = capacity
        if let fileURL { attach(fileURL) }
    }

    /// Loads existing entries from `url` and appends new ones to it.
    public func attach(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        let loaded = lines.compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        items = Array((loaded + items).suffix(capacity))
        linesOnDisk = lines.count
        if linesOnDisk > capacity * 2 || loaded.count != lines.count { rewriteLocked() }
    }

    public func log(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(level: level, category: category, message: message)
        lock.lock()
        items.append(entry)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        appendLocked(entry)
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }

    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func clear() {
        lock.lock()
        items.removeAll()
        rewriteLocked()
        lock.unlock()
    }

    /// Called (on the logging thread) after every new entry.
    @discardableResult
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = callback; lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    /// Plain-text report: counts, then the newest `limit` entries at or above `minimum` level.
    public func report(limit: Int = 80, minimum: Level = .info) -> String {
        let all = entries
        let order = Level.allCases
        let shown = all.filter { order.firstIndex(of: $0.level)! >= order.firstIndex(of: minimum)! }.suffix(limit)
        let errors = all.filter { $0.level == .error }.count, warnings = all.filter { $0.level == .warning }.count
        var lines = ["Inkbook diagnostics: \(all.count) entries, \(errors) errors, \(warnings) warnings."]
        lines += shown.map(\.line)
        if shown.isEmpty { lines.append("(no entries)") }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func encode(_ entry: Entry) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(entry)
    }

    private func appendLocked(_ entry: Entry) {
        guard let fileURL, var data = Self.encode(entry) else { return }
        data.append(0x0A)
        if linesOnDisk >= capacity * 2 { rewriteLocked(); return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
        linesOnDisk += 1
    }

    private func rewriteLocked() {
        guard let fileURL else { return }
        var data = Data()
        for entry in items {
            if let line = Self.encode(entry) { data.append(line); data.append(0x0A) }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        linesOnDisk = items.count
    }
}

/// Rolling timing samples (milliseconds) per named metric, for the ink HUD and self-test.
public final class PerfRecorder: @unchecked Sendable {
    public struct Summary: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var p50: Double
        public var p95: Double
        public var max: Double

        public var line: String {
            String(format: "%@: p50 %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)", name, p50, p95, max, count)
        }
    }

    public static let shared = PerfRecorder()

    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]
    private let window: Int

    public init(window: Int = 600) { self.window = window }

    public func record(_ name: String, ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        var list = samples[name, default: []]
        list.append(ms)
        if list.count > window { list.removeFirst(list.count - window) }
        samples[name] = list
    }

    public func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    public func summary(_ name: String) -> Summary? {
        lock.lock()
        let list = samples[name] ?? []
        lock.unlock()
        return Self.summarize(name, list)
    }

    public func summaries() -> [Summary] {
        lock.lock()
        let all = samples
        lock.unlock()
        return all.keys.sorted().compactMap { Self.summarize($0, all[$0]!) }
    }

    public static func summarize(_ name: String, _ values: [Double]) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Summary(name: name, count: sorted.count, p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95),
                       max: sorted[sorted.count - 1])
    }

    /// Nearest-rank percentile of an ascending array.
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((q.clamped(0, 1) * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
