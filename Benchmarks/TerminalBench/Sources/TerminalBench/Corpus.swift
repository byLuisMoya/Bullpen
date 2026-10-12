import Foundation

/// Deterministic terminal output resembling what coding agents print:
/// plain logs, coloured diffs/test output, Unicode, and TUI-style redraws.
enum Corpus {
    static func make(megabytes: Int) -> [UInt8] {
        let target = megabytes * 1_048_576
        var out = [UInt8]()
        out.reserveCapacity(target + 4096)
        var rng = SplitMix64(seed: 42)
        var line = 0
        while out.count < target {
            line += 1
            let pick = rng.next() % 100
            let text: String
            switch pick {
            case 0..<55:
                text = "[\(line)] info  compiling module_\(rng.next() % 500).swift (\(rng.next() % 9999) ms)\r\n"
            case 55..<75:
                let color = 31 + Int(rng.next() % 6)
                text = "\u{1B}[\(color)m\(rng.next() % 2 == 0 ? "+" : "-")  let value\(line) = compute(\(line))\u{1B}[0m\r\n"
            case 75..<85:
                text = "✓ test_\(line) passed — 日本語テスト — 🚀 emoji ok — Ñandú\r\n"
            case 85..<95:
                text = String(repeating: "wrap-long-line-\(line % 10) ", count: 18) + "\r\n"
            default:
                // TUI redraw: save cursor, jump to top, rewrite status bar, restore.
                text = "\u{1B}7\u{1B}[1;1H\u{1B}[2K\u{1B}[7m ✳ Working… \(line) tokens \u{1B}[0m\u{1B}8"
            }
            out.append(contentsOf: Array(text.utf8))
        }
        return out
    }

    /// Exactly `lines` short log lines, to fill scrollback.
    static func lines(_ lines: Int) -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<lines {
            out.append(contentsOf: Array("\u{1B}[32m[\(i)]\u{1B}[0m scrollback filler line with some text\r\n".utf8))
        }
        return out
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
