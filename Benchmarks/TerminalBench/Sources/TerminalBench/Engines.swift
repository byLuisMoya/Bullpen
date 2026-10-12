import AppKit
import SwiftTerm

/// One terminal implementation under test. libghostty will be a third conformance (needs Xcode).
@MainActor
protocol TerminalEngine {
    var name: String { get }
    /// Parser/emulator only, no drawing.
    func makeHeadless(cols: Int, rows: Int, scrollback: Int) -> any HeadlessTerminal
    /// Real view that renders.
    func makeView(frame: NSRect, scrollback: Int) throws -> any RenderedTerminal
}

protocol HeadlessTerminal {
    func feed(_ bytes: ArraySlice<UInt8>)
}

@MainActor
protocol RenderedTerminal {
    var view: NSView { get }
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Draw a complete frame synchronously, now.
    func drawFrame()
}

// MARK: - SwiftTerm

final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

struct SwiftTermHeadless: HeadlessTerminal {
    let terminal: Terminal
    let delegate: NullDelegate
    func feed(_ bytes: ArraySlice<UInt8>) { terminal.feed(buffer: bytes) }
}

@MainActor
struct SwiftTermRendered: RenderedTerminal {
    let terminalView: TerminalView
    let metal: Bool
    var view: NSView { terminalView }
    func feed(_ bytes: ArraySlice<UInt8>) { terminalView.feed(byteArray: bytes) }
    func drawFrame() {
        #if SWIFTTERM_METAL
        if metal {
            terminalView.drawMetalFrameNow()
            return
        }
        #endif
        terminalView.needsDisplay = true
        terminalView.display()
    }
}

struct SwiftTermEngine: TerminalEngine {
    /// Engines available in this build (Metal needs SwiftTerm >= 1.12, i.e. full Xcode).
    static var available: [SwiftTermEngine] {
        #if SWIFTTERM_METAL
        [SwiftTermEngine(metal: false), SwiftTermEngine(metal: true)]
        #else
        [SwiftTermEngine(metal: false)]
        #endif
    }

    let metal: Bool
    var name: String { metal ? "SwiftTerm (Metal)" : "SwiftTerm (CoreGraphics)" }

    func makeHeadless(cols: Int, rows: Int, scrollback: Int) -> any HeadlessTerminal {
        let delegate = NullDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        return SwiftTermHeadless(terminal: terminal, delegate: delegate)
    }

    func makeView(frame: NSRect, scrollback: Int) throws -> any RenderedTerminal {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: frame, font: font)
        view.getTerminal().changeHistorySize(scrollback)
        #if SWIFTTERM_METAL
        if metal { try view.setUseMetal(true) }
        #endif
        return SwiftTermRendered(terminalView: view, metal: metal)
    }
}
