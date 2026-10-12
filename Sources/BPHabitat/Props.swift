import BPCore
import CoreGraphics

/// Furniture and speech bubbles, drawn in code like the characters.
public enum Props {
    enum P {
        static let wood: UInt8 = 1, woodDark: UInt8 = 2, woodLight: UInt8 = 3
        static let metal: UInt8 = 4, metalDark: UInt8 = 5, screen: UInt8 = 6
        static let chair: UInt8 = 7, chairDark: UInt8 = 8
        static let lampOn: UInt8 = 9, lampOff: UInt8 = 10, cord: UInt8 = 11
        static let leaf: UInt8 = 12, leafDark: UInt8 = 13, pot: UInt8 = 14
        static let white: UInt8 = 15, ink: UInt8 = 16, accent: UInt8 = 17
    }

    static let palette = Palette([
        P.wood: RGBA(0x9A6B43), P.woodDark: RGBA(0x6E4A2C), P.woodLight: RGBA(0xB98757),
        P.metal: RGBA(0xB9BEC8), P.metalDark: RGBA(0x80858F), P.screen: RGBA(0x7FD3FF),
        P.chair: RGBA(0x3B4253), P.chairDark: RGBA(0x2A2F3C),
        P.lampOn: RGBA(0xFFD86B), P.lampOff: RGBA(0x5B5F6B), P.cord: RGBA(0x2E2E35),
        P.leaf: RGBA(0x4FA35A), P.leafDark: RGBA(0x377A42), P.pot: RGBA(0xC0673E),
        P.white: RGBA(0xFFFFFF), P.ink: RGBA(0x2A2633), P.accent: RGBA(0xFF8A3D),
    ])

    public static let deskWidth = 28, deskHeight = 9

    /// Desk seen from the front with a laptop whose lid faces the person. `glow` lights the lid edge.
    public static func desk(glow: Bool, closed: Bool = false) -> CGImage? {
        var c = PixelCanvas(width: deskWidth, height: deskHeight)
        // Laptop: lid back towards us (closed = lying flat).
        if closed {
            c.rect(9, 2, 10, 1, P.metalDark)
        } else {
            c.rect(9, 0, 10, 3, P.metal)
            c.rect(13, 1, 2, 1, P.white)                // plain mark, no brand
            if glow { c.rect(9, 0, 10, 1, P.screen) }
        }
        c.rect(0, 3, deskWidth, 2, P.woodLight)
        c.rect(1, 5, deskWidth - 2, 4, P.wood)
        c.rect(1, 5, deskWidth - 2, 1, P.woodDark)
        c.rect(12, 6, 4, 1, P.woodDark)               // drawer handle
        return c.image(palette: palette)
    }

    public static let chairWidth = 16, chairHeight = 12

    public static func chair() -> CGImage? {
        var c = PixelCanvas(width: chairWidth, height: chairHeight)
        c.rect(1, 0, 14, 12, P.chair)
        c.rect(1, 0, 14, 1, P.chairDark)
        c.rect(1, 0, 1, 12, P.chairDark)
        return c.image(palette: palette)
    }

    public static let lampWidth = 10, lampHeight = 12

    public static func lamp(on: Bool) -> CGImage? {
        var c = PixelCanvas(width: lampWidth, height: lampHeight)
        c.rect(4, 0, 1, 6, P.cord)
        c.rect(2, 6, 6, 2, on ? P.lampOn : P.lampOff)
        c.rect(1, 8, 8, 2, on ? P.lampOn : P.lampOff)
        c.rect(1, 8, 8, 1, P.metalDark)
        if on { c.rect(3, 10, 4, 1, P.white) }
        return c.image(palette: palette)
    }

    public static func plant() -> CGImage? {
        var c = PixelCanvas(width: 10, height: 16)
        c.stamp([
            "....L.....",
            "...LLL..L.",
            "..LlLL.LL.",
            ".LL.lLLLl.",
            ".Ll..LLl..",
            "..L.LlL...",
            "...LLL..L.",
            ".L..lL.Ll.",
            ".LL.LLLL..",
            "..LLlLL...",
        ], at: 0, 0, key: ["L": P.leaf, "l": P.leafDark])
        c.rect(2, 10, 6, 6, P.pot)
        c.rect(1, 10, 8, 1, P.woodDark)
        return c.image(palette: palette)
    }

    public static func coffeeMachine() -> CGImage? {
        var c = PixelCanvas(width: 10, height: 14)
        c.rect(0, 0, 10, 14, P.metalDark)
        c.rect(1, 1, 8, 4, P.ink)
        c.rect(2, 2, 2, 1, P.accent)
        c.rect(3, 8, 4, 1, P.metal)
        c.rect(4, 10, 2, 3, P.white)
        return c.image(palette: palette)
    }

    // MARK: Bubbles

    public enum Bubble: Sendable { case thinking, alert, done, sleep, error, unknown }

    public static func bubble(for state: AgentState) -> Bubble? {
        switch state {
        case .thinking: .thinking
        case .needsYou: .alert
        case .done: .done
        case .idle: .sleep
        case .error: .error
        case .unknown: .unknown
        case .working, .starting, .dead: nil
        }
    }

    public static let bubbleSize = 11

    public static func bubble(_ kind: Bubble) -> CGImage? {
        var c = PixelCanvas(width: bubbleSize, height: bubbleSize)
        let fill: UInt8 = kind == .alert ? P.accent : P.white
        c.rect(1, 0, 9, 9, fill)
        c.rect(0, 1, 11, 7, fill)
        c.rect(3, 9, 2, 1, fill)
        c.dot(2, 10, fill)
        let mark: [String]
        switch kind {
        case .thinking: mark = [".......", ".......", ".......", "X.X.X..", "......."]
        case .alert: mark = ["...W...", "...W...", "...W...", ".......", "...W..."]
        case .done: mark = ["......G", ".....G.", "G...G..", ".G.G...", "..G...."]
        case .sleep: mark = ["XXXX...", "..X....", ".X.....", "XXXX...", "......."]
        case .error: mark = ["R...R..", ".R.R...", "..R....", ".R.R...", "R...R.."]
        case .unknown: mark = [".XXX...", "X...X..", "...X...", "..X....", "..X...."]
        }
        c.stamp(mark, at: 2, 2, key: ["X": P.ink, "W": P.white, "G": P.leafDark, "R": 18])
        var palette = Self.palette
        palette.colors[18] = RGBA(0xD83A3A)
        return c.image(palette: palette)
    }
}
