import AppKit

// Usage: terminal-bench [--mb 100] [--terminals 10] [--idle 10] [--out docs/bench]
struct Options {
    var megabytes = 100
    var terminals = 10
    var idleSeconds = 10.0
    var outDir: String?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--mb": megabytes = Int(it.next() ?? "") ?? megabytes
            case "--terminals": terminals = Int(it.next() ?? "") ?? terminals
            case "--idle": idleSeconds = Double(it.next() ?? "") ?? idleSeconds
            case "--out": outDir = it.next()
            default: break
            }
        }
    }
}

struct Result {
    var engine: String
    var parseMBs: Double
    var renderMBs: Double
    var frameMs: Double = 0
    var renderSeconds: Double
    var memoryMB: Double
    var idleCPU: Double
    var note: String = ""
}

@MainActor
final class Bench {
    let options: Options
    let corpus: [UInt8]
    let chunk = 64 * 1024
    let window: NSWindow

    init(options: Options) {
        self.options = options
        corpus = Corpus.make(megabytes: options.megabytes)
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Bullpen terminal benchmark"
        window.level = .floating  // stay in front so the view is never occluded (occluded views skip drawing)
        window.orderFrontRegardless()
    }

    /// Let AppKit/Core Animation process pending work.
    func pump(_ seconds: Double = 0) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func run(_ engine: any TerminalEngine) -> Result {
        log("▶ \(engine.name)")
        var result = Result(engine: engine.name, parseMBs: 0, renderMBs: 0, renderSeconds: 0, memoryMB: 0, idleCPU: 0)
        let mb = Double(corpus.count) / 1_048_576

        // 1. Parser throughput (no drawing).
        let headless = engine.makeHeadless(cols: 120, rows: 40, scrollback: 10_000)
        var start = Metrics.now()
        feed(corpus) { headless.feed($0) }
        result.parseMBs = mb / (Metrics.now() - start)
        log("  parse  \(fmt(result.parseMBs)) MB/s")

        // 2. Rendering, with one visible terminal.
        do {
            let term = try engine.makeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), scrollback: 10_000)
            window.contentView = term.view
            pump(0.3)
            if !window.occlusionState.contains(.visible) {
                result.note = "Window occluded (screen locked or asleep?): frame/stream numbers are not reliable"
                log("  ⚠︎ \(result.note)")
            }

            // 2a. Cost of one full frame with a screen full of coloured text.
            feed(Array(corpus.prefix(512 * 1024))) { term.feed($0) }
            pump(0.1)
            let frames = 300
            start = Metrics.now()
            for _ in 0..<frames { term.drawFrame() }
            result.frameMs = (Metrics.now() - start) / Double(frames) * 1000
            log("  frame  \(fmt(result.frameMs)) ms per full redraw")

            // 2b. End to end: stream the corpus, letting the view redraw as it normally would.
            start = Metrics.now()
            feed(corpus) { slice in
                term.feed(slice)
                pump()
            }
            term.drawFrame()
            result.renderSeconds = Metrics.now() - start
            result.renderMBs = mb / result.renderSeconds
            log("  stream \(fmt(result.renderMBs)) MB/s (\(fmt(result.renderSeconds)) s for \(Int(mb)) MB)")
        } catch {
            result.note = "render: \(error)"
            log("  render failed: \(error)")
            return result
        }

        // 3. Memory and 4. idle CPU with N terminals, each holding 10k lines of scrollback.
        window.contentView = NSView()
        pump(0.3)
        let baseline = Metrics.footprintMB()
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = grid
        let filler = Corpus.lines(10_000)
        var terms: [any RenderedTerminal] = []
        // Same size as a real agent pane (~120×40) so memory is comparable; they overlap on screen.
        for i in 0..<options.terminals {
            guard let term = try? engine.makeView(
                frame: NSRect(x: Double(i) * 10, y: Double(i) * 10, width: 1000, height: 700),
                scrollback: 10_000
            ) else { continue }
            grid.addSubview(term.view)
            feed(filler) { term.feed($0) }
            term.drawFrame()
            terms.append(term)
        }
        pump(1)
        result.memoryMB = (Metrics.footprintMB() - baseline) / Double(max(terms.count, 1))
        log("  memory \(fmt(result.memoryMB)) MB per terminal (10k lines scrollback)")

        let cpuStart = Metrics.cpuSeconds(), wallStart = Metrics.now()
        pump(options.idleSeconds)
        result.idleCPU = (Metrics.cpuSeconds() - cpuStart) / (Metrics.now() - wallStart) * 100
        log("  idle   \(fmt(result.idleCPU)) % CPU with \(terms.count) terminals")

        window.contentView = NSView()
        terms.removeAll()
        pump(0.5)
        return result
    }

    func feed(_ bytes: [UInt8], _ sink: (ArraySlice<UInt8>) -> Void) {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            sink(bytes[offset..<end])
            offset = end
        }
    }
}

func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func report(_ results: [Result], options: Options) -> String {
    let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    var md = """
    # Terminal benchmark — \(date)

    - Machine: \(Metrics.machine)
    - Corpus: \(options.megabytes) MB of agent-like output (logs, colours, Unicode, TUI redraws), 64 KB chunks
    - Parse: emulator only, no drawing. Full frame: synchronous redraw of a 1000×700 pt terminal full of text.
      Stream: corpus fed chunk by chunk while the view redraws on its own schedule (real-world case).
    - Terminals for memory/idle: \(options.terminals), each with 10k lines of scrollback; idle window \(Int(options.idleSeconds)) s

    | Engine | Parse (MB/s) | Full frame (ms) | Stream (MB/s) | Stream time (s) | Memory / terminal (MB) | Idle CPU (%) | Notes |
    |---|---:|---:|---:|---:|---:|---:|---|

    """
    for r in results {
        md += "| \(r.engine) | \(fmt(r.parseMBs)) | \(fmt(r.frameMs)) | \(fmt(r.renderMBs)) | \(fmt(r.renderSeconds)) | \(fmt(r.memoryMB)) | \(fmt(r.idleCPU)) | \(r.note) |\n"
    }
    #if !SWIFTTERM_METAL
    md += "| SwiftTerm (Metal) | — | — | — | — | — | — | Not built: SwiftTerm >= 1.12 needs full Xcode. This run used SwiftTerm 1.11.2 |\n"
    #endif
    md += "| libghostty | — | — | — | — | — | — | Not built: needs full Xcode + Metal Toolchain + Zig |\n"
    return md
}

let options = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

MainActor.assumeIsolated {
    let bench = Bench(options: options)
    bench.pump(0.5)
    let engines: [any TerminalEngine] = SwiftTermEngine.available
    let results = engines.map { bench.run($0) }
    let md = report(results, options: options)
    print(md)
    if let dir = options.outDir {
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let model = Metrics.sysctlString("hw.model").replacingOccurrences(of: ",", with: "-")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(date)-terminal-\(model)-\(Metrics.arch).md")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        log("Saved \(url.path)")
    }
}
exit(0)
