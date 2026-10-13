import BPCore
import CoreGraphics

/// The room, furniture and speech bubbles, drawn in code like the characters: a 3/4 top-down
/// view with outlined shapes, the look of a pixel-art office.
public enum Props {
    enum P {
        static let wood: UInt8 = 1, woodDark: UInt8 = 2, woodTop: UInt8 = 3, woodTopLight: UInt8 = 4
        static let metal: UInt8 = 5, metalDark: UInt8 = 6, screen: UInt8 = 7
        static let chair: UInt8 = 8, chairDark: UInt8 = 9, chairLight: UInt8 = 10
        static let lampOn: UInt8 = 11, lampOff: UInt8 = 12, lampBody: UInt8 = 13
        static let leaf: UInt8 = 14, leafDark: UInt8 = 15, leafLight: UInt8 = 16, pot: UInt8 = 17, potDark: UInt8 = 18
        static let white: UInt8 = 19, ink: UInt8 = 20, accent: UInt8 = 21, outline: UInt8 = 22
        static let wall: UInt8 = 23, wallShade: UInt8 = 24, trim: UInt8 = 25, baseboard: UInt8 = 26, baseboardDark: UInt8 = 27
        static let frame: UInt8 = 28, frameShade: UInt8 = 29, glass: UInt8 = 30, glassLight: UInt8 = 31, glassDark: UInt8 = 32
        static let plank: UInt8 = 33, plankAlt: UInt8 = 34, seam: UInt8 = 35, plankLight: UInt8 = 36, floorShadow: UInt8 = 37
        static let coffee: UInt8 = 38, water: UInt8 = 39, cork: UInt8 = 40, corkDark: UInt8 = 41
        static let noteYellow: UInt8 = 42, notePink: UInt8 = 43, noteBlue: UInt8 = 44, plastic: UInt8 = 45, joint: UInt8 = 46
        /// Recoloured per sprite (bolt, bubble marks).
        static let special: UInt8 = 60
    }

    static let palette = Palette([
        P.wood: RGBA(0xB0743F), P.woodDark: RGBA(0x84542C), P.woodTop: RGBA(0xE0A464), P.woodTopLight: RGBA(0xF0C084),
        P.metal: RGBA(0xC3C8D2), P.metalDark: RGBA(0x8D93A0), P.screen: RGBA(0x8FDCFF),
        P.chair: RGBA(0x3E4555), P.chairDark: RGBA(0x2B303C), P.chairLight: RGBA(0x5A6377),
        P.lampOn: RGBA(0xFFE08A), P.lampOff: RGBA(0x6B7180), P.lampBody: RGBA(0x3F7F86),
        P.leaf: RGBA(0x5DAE4B), P.leafDark: RGBA(0x3E8A3A), P.leafLight: RGBA(0x8FD06B), P.pot: RGBA(0xD9774A), P.potDark: RGBA(0xA9542F),
        P.white: RGBA(0xFFFFFF), P.ink: RGBA(0x2A2633), P.accent: RGBA(0xFF8A3D), P.outline: RGBA(0x2A2230),
        P.wall: RGBA(0xEDE5D6), P.wallShade: RGBA(0xD9CEBB), P.trim: RGBA(0x6A5A50), P.baseboard: RGBA(0xB89C7C), P.baseboardDark: RGBA(0x8E7559),
        P.frame: RGBA(0xF8F5EF), P.frameShade: RGBA(0xC8C0B2), P.glass: RGBA(0x9CCBE6), P.glassLight: RGBA(0xD6EDF9), P.glassDark: RGBA(0x7AAED2),
        P.plank: RGBA(0xD6AB7B), P.plankAlt: RGBA(0xCDA172), P.seam: RGBA(0xB3875A), P.plankLight: RGBA(0xE0B88A), P.floorShadow: RGBA(0xB58E62),
        P.coffee: RGBA(0x6B3E26), P.water: RGBA(0x86C9F0), P.cork: RGBA(0xCF9C62), P.corkDark: RGBA(0xAA7944),
        P.noteYellow: RGBA(0xF8E27A), P.notePink: RGBA(0xF4A6C0), P.noteBlue: RGBA(0x9FD3F2), P.plastic: RGBA(0xE4E7EC),
        P.joint: RGBA(0xC09264),
    ])

    // MARK: Room

    /// Back wall with a window behind every slot but `skipping` (where the board hangs).
    static func wall(width: Int, height: Int, windows: Int, skipping: Int, margin: Int, slot: Int) -> CGImage? {
        var c = PixelCanvas(width: width, height: height)
        c.rect(0, 0, width, height, P.wall)
        c.rect(0, 0, width, 2, P.trim)
        c.rect(0, 2, width, 1, P.wallShade)
        c.rect(0, height - 3, width, 1, P.wallShade)
        c.rect(0, height - 2, width, 1, P.baseboard)
        c.rect(0, height - 1, width, 1, P.baseboardDark)
        for i in 0..<windows where i != skipping {
            let x = margin + i * slot + 9
            c.rect(x, 3, 16, 12, P.frame)
            c.rect(x - 1, 14, 18, 1, P.frameShade)                 // sill
            c.rect(x + 1, 4, 6, 9, P.glass)
            c.rect(x + 9, 4, 6, 9, P.glass)
            for pane in [x + 1, x + 9] {
                c.rect(pane, 12, 6, 1, P.glassDark)
                c.dot(pane + 3, 5, P.glassLight); c.dot(pane + 2, 6, P.glassLight); c.dot(pane + 1, 7, P.glassLight)
                c.dot(pane + 5, 6, P.glassLight); c.dot(pane + 4, 7, P.glassLight)
            }
            c.rect(x + 1, 8, 14, 1, P.frame)                       // transom
        }
        return c.image(palette: palette)
    }

    /// Wooden floor in staggered planks, with the wall's shadow along the top.
    static func floor(width: Int, height: Int) -> CGImage? {
        var c = PixelCanvas(width: width, height: height)
        let plankHeight = 5, plankLength = 30
        for y in 0..<height {
            let band = y / plankHeight, row = y % plankHeight
            for x in 0..<width {
                let along = x + band * 13 + (band % 3) * 7
                let color: UInt8
                if row == plankHeight - 1 {
                    color = P.seam
                } else if along % plankLength == 0 {
                    color = P.joint
                } else if row == 0 {
                    color = P.plankLight
                } else {
                    color = (along / plankLength + band) % 2 == 0 ? P.plank : P.plankAlt
                }
                c[x, y] = color
            }
        }
        c.rect(0, 0, width, 1, P.seam)
        c.rect(0, 1, width, 1, P.floorShadow)
        return c.image(palette: palette)
    }

    // MARK: Workstation

    public static let deskWidth = 32, deskHeight = 15

    /// Desk seen from above and in front: wide top, drawer panel and legs.
    public static func desk() -> CGImage? {
        var c = PixelCanvas(width: deskWidth, height: deskHeight)
        c.rect(1, 1, 30, 1, P.woodTopLight)
        c.rect(1, 2, 30, 4, P.woodTop)
        c.rect(1, 6, 30, 1, P.woodDark)
        c.rect(1, 7, 30, 5, P.wood)
        c.rect(19, 8, 10, 3, P.woodDark)                           // drawer
        c.rect(20, 9, 8, 1, P.wood)
        c.rect(23, 9, 2, 1, P.metal)
        c.rect(2, 12, 2, 2, P.woodDark)                            // legs
        c.rect(28, 12, 2, 2, P.woodDark)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    public static let chairWidth = 22, chairHeight = 16

    /// The office chair's backrest, behind the person.
    public static func chair() -> CGImage? {
        var c = PixelCanvas(width: chairWidth, height: chairHeight)
        c.rect(2, 1, 18, 1, P.chair)
        c.rect(1, 2, 20, 13, P.chair)
        c.rect(3, 2, 16, 1, P.chairLight)
        c.rect(2, 3, 1, 9, P.chairLight)
        c.rect(1, 12, 20, 3, P.chairDark)
        c.rect(19, 3, 1, 9, P.chairDark)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    public static let laptopWidth = 12, laptopHeight = 9

    /// Laptop with its lid towards us. `glow` lights the lid edge; `closed` lies it flat.
    public static func laptop(glow: Bool, closed: Bool = false) -> CGImage? {
        var c = PixelCanvas(width: laptopWidth, height: laptopHeight)
        if closed {
            c.rect(2, 5, 8, 1, P.metal)
            c.rect(1, 6, 10, 1, P.metalDark)
        } else {
            c.rect(2, 1, 8, 6, P.metal)
            c.rect(2, 1, 8, 1, glow ? P.screen : P.metalDark)
            c.rect(9, 2, 1, 5, P.metalDark)
            c.rect(5, 3, 2, 2, P.white)                            // plain mark, no brand
            c.rect(1, 7, 10, 1, P.metalDark)
        }
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    public static let lampWidth = 10, lampHeight = 15

    /// Desk lamp; its bulb is lit while somebody works in the office.
    public static func lamp(on: Bool) -> CGImage? {
        var c = PixelCanvas(width: lampWidth, height: lampHeight)
        c.stamp([
            "..........",
            "...bbbb...",
            "..bbbbbB..",
            ".bbbbbbBB.",
            "...LLLL...",
            "...p......",
            "...p......",
            "...p......",
            "....p.....",
            "....p.....",
            "....p.....",
            "....p.....",
            "..bbbbb...",
            "..BBBBB...",
        ], at: 0, 0, key: ["b": P.lampBody, "B": P.chairDark, "p": P.metalDark, "L": on ? P.lampOn : P.lampOff])
        c.outline(P.outline)
        if on { c.rect(3, 4, 4, 1, P.lampOn) }
        return c.image(palette: palette)
    }

    public static let mugWidth = 7, mugHeight = 7

    public static func mug() -> CGImage? {
        var c = PixelCanvas(width: mugWidth, height: mugHeight)
        c.rect(1, 1, 4, 5, P.white)
        c.rect(1, 1, 4, 1, P.coffee)
        c.rect(5, 2, 1, 1, P.white)
        c.rect(5, 4, 1, 1, P.white)
        c.rect(4, 2, 1, 4, P.plastic)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    // MARK: Decor

    public static let plantWidth = 16, plantHeight = 26

    public static func plant() -> CGImage? {
        var c = PixelCanvas(width: plantWidth, height: plantHeight)
        c.stamp([
            ".......l........",
            "......lLl...l...",
            "..l..lLLl..lL...",
            ".lLl.lLLL.lLL...",
            ".LLLllLLLlLLl.l.",
            "..LLLLLdLLLL.lL.",
            "l..dLLLLLdLLLLL.",
            "Ll..LLdLLLLLdL..",
            "LLLLLLLLdLLLL...",
            ".dLLLdLLLLLLLLl.",
            "..LLLLLdLLdLLLL.",
            ".LLdLLLLLLLLdL..",
            "..LLLLdLLLLLL...",
            "...dLLLLLdLL....",
            "....LLLdLLL.....",
        ], at: 0, 0, key: ["l": P.leafLight, "L": P.leaf, "d": P.leafDark])
        c.rect(2, 15, 12, 2, P.pot)
        c.rect(2, 16, 12, 1, P.potDark)
        c.rect(3, 17, 10, 7, P.pot)
        c.rect(11, 17, 2, 7, P.potDark)
        c.rect(4, 18, 1, 4, P.accent)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    public static let coolerWidth = 12, coolerHeight = 28

    public static func waterCooler() -> CGImage? {
        var c = PixelCanvas(width: coolerWidth, height: coolerHeight)
        c.rect(4, 1, 4, 1, P.glassDark)
        c.rect(2, 2, 8, 8, P.water)
        c.rect(3, 3, 1, 5, P.glassLight)
        c.rect(1, 10, 10, 16, P.plastic)
        c.rect(9, 10, 2, 16, P.frameShade)
        c.rect(1, 10, 10, 1, P.frameShade)
        c.dot(3, 13, P.accent)
        c.dot(7, 13, P.glassDark)
        c.rect(3, 17, 6, 1, P.metalDark)
        c.rect(2, 24, 8, 2, P.metalDark)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    public static let boardWidth = 24, boardHeight = 13

    /// Cork board with sticky notes, hung on the wall.
    public static func board() -> CGImage? {
        var c = PixelCanvas(width: boardWidth, height: boardHeight)
        c.rect(1, 1, 22, 11, P.woodDark)
        c.rect(2, 2, 20, 9, P.cork)
        c.rect(2, 10, 20, 1, P.corkDark)
        c.rect(4, 3, 4, 4, P.noteYellow); c.rect(5, 5, 2, 1, P.ink)
        c.rect(10, 4, 4, 4, P.notePink); c.rect(11, 6, 2, 1, P.ink)
        c.rect(16, 3, 4, 3, P.noteBlue)
        c.rect(15, 7, 5, 3, P.noteYellow)
        c.dot(5, 3, P.accent); c.dot(11, 4, P.accent); c.dot(17, 3, P.accent)
        c.outline(P.outline)
        return c.image(palette: palette)
    }

    // MARK: Signals

    public static let boltWidth = 9, boltHeight = 11

    /// ⚡ next to a desk: yellow when files overlap with another worktree, red on a merge conflict.
    public static func bolt(conflict: Bool) -> CGImage? {
        var c = PixelCanvas(width: boltWidth, height: boltHeight)
        c.stamp([
            "...XXX.",
            "..XXX..",
            ".XXX...",
            "XXXXXX.",
            "..XXX..",
            ".XXX...",
            ".XX....",
            "XX.....",
            "X......",
        ], at: 1, 1, key: ["X": P.special])
        c.outline(P.outline)
        var palette = Self.palette
        palette.colors[P.special] = conflict ? RGBA(0xE5484D) : RGBA(0xF5C842)
        return c.image(palette: palette)
    }

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

    public static let bubbleSize = 13

    public static func bubble(_ kind: Bubble) -> CGImage? {
        var c = PixelCanvas(width: bubbleSize, height: bubbleSize)
        let fill: UInt8 = kind == .alert ? P.accent : P.white
        c.rect(2, 1, 9, 9, fill)
        c.rect(1, 2, 11, 7, fill)
        c.rect(4, 10, 2, 1, fill)
        c.dot(3, 11, fill)
        c.outline(P.outline)
        let mark: [String]
        switch kind {
        case .thinking: mark = [".......", ".......", ".......", "X.X.X..", "......."]
        case .alert: mark = ["...W...", "...W...", "...W...", ".......", "...W..."]
        case .done: mark = ["......G", ".....G.", "G...G..", ".G.G...", "..G...."]
        case .sleep: mark = ["XXXX...", "..X....", ".X.....", "XXXX...", "......."]
        case .error: mark = ["R...R..", ".R.R...", "..R....", ".R.R...", "R...R.."]
        case .unknown: mark = [".XXX...", "X...X..", "...X...", "..X....", "..X...."]
        }
        c.stamp(mark, at: 3, 3, key: ["X": P.ink, "W": P.white, "G": P.leafDark, "R": P.special])
        var palette = Self.palette
        palette.colors[P.special] = RGBA(0xD83A3A)
        return c.image(palette: palette)
    }
}
