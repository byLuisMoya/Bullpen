import Foundation

/// Tokens used by an agent session (PLAN §7.3).
public struct UsageTotals: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    /// Estimated cost at API prices (subscriptions don't pay per token; it's a yardstick).
    public var costUSD = 0.0
    public var messages = 0

    public init() {}

    public var totalTokens: Int { input + output + cacheWrite + cacheRead }

    public static func + (a: Self, b: Self) -> Self {
        var r = a
        r.input += b.input; r.output += b.output; r.cacheWrite += b.cacheWrite; r.cacheRead += b.cacheRead
        r.costUSD += b.costUSD; r.messages += b.messages
        return r
    }
}

/// API list prices per million tokens (input, output, cache read). Cache writes cost 1.25× input.
public enum Pricing {
    static let table: [(prefix: String, input: Double, output: Double, cacheRead: Double?)] = [
        ("claude-fable-5-1", 10, 50, 0.25), ("claude-fable-5", 10, 50, nil), ("claude-mythos", 10, 50, nil),
        ("claude-opus-5-5", 4, 20, 0.20), ("claude-opus-5", 5, 25, nil), ("claude-opus-4", 5, 25, nil),
        ("claude-sonnet-5-5", 2, 10, 0.20), ("claude-sonnet-5", 2, 10, nil), ("claude-sonnet-4-6", 3, 15, nil),
        ("claude-haiku-5-5", 0.10, 0.50, nil), ("claude-haiku-4-5", 1, 5, nil),
    ]

    public static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        guard let p = table.first(where: { model.hasPrefix($0.prefix) }) else { return 0 }
        let readPrice = p.cacheRead ?? p.input * 0.1
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheWrite) * p.input * 1.25
                + Double(cacheRead) * readPrice) / 1_000_000
    }
}

/// Reads Claude Code transcripts incrementally: only new bytes since the last call are parsed, and
/// each API message counts once (the transcript repeats it for every content block).
public final class TranscriptUsageReader: @unchecked Sendable {
    private var offsets: [String: UInt64] = [:]
    private var perMessage: [String: [String: (UsageTotals, Date?)]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Totals for `path`, optionally only messages since `since`.
    public func totals(for path: String, since: Date? = nil) -> UsageTotals {
        lock.lock(); defer { lock.unlock() }
        readNewLines(path)
        return (perMessage[path] ?? [:]).values.reduce(UsageTotals()) { sum, entry in
            if let since, let at = entry.1, at < since { return sum }
            return sum + entry.0
        }
    }

    private func readNewLines(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let start = offsets[path] ?? 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only consume complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[path] = start + UInt64(complete.count)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in complete.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let id = message["id"] as? String ?? UUID().uuidString
            let model = message["model"] as? String ?? ""
            var t = UsageTotals()
            t.input = usage["input_tokens"] as? Int ?? 0
            t.output = usage["output_tokens"] as? Int ?? 0
            t.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            t.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            t.messages = 1
            t.costUSD = Pricing.cost(model: model, input: t.input, output: t.output, cacheWrite: t.cacheWrite, cacheRead: t.cacheRead)
            let at = (json["timestamp"] as? String).flatMap { iso.date(from: $0) }
            // Later lines of the same message carry the final output count: keep the largest.
            if let existing = perMessage[path]?[id], existing.0.output >= t.output { continue }
            perMessage[path, default: [:]][id] = (t, at)
        }
    }
}
