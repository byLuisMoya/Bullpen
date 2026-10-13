import CoreGraphics

/// What each office theme puts on the wall and on the floor after the last desk, and between desks.
extension Props {
    /// The sprite for `decor`, with its size in art pixels.
    static func decor(_ decor: OfficeTheme.Decor, theme: OfficeTheme) -> (image: CGImage?, width: Int, height: Int) {
        switch decor {
        case .board: (board(theme: theme), boardWidth, boardHeight)
        case .plant: (plant(theme: theme), plantWidth, plantHeight)
        case .cooler: (waterCooler(theme: theme), coolerWidth, coolerHeight)
        case .clock: draw(14, 14, theme) { c in
            c.stamp([
                "..wwwwwwww..",
                ".wwwwwwwwww.",
                "wwwwwiwwwwww",
                "wwwwwiwwwwww",
                "wwwwwiwwwwww",
                "wwwwwiiiiwww",
                "wwwwwwwwwwww",
                "wwwwwwwwwwww",
                ".wwwwwwwwww.",
                "..wwwwwwww..",
            ], at: 1, 2, key: ["w": P.white, "i": P.ink])
            c.rect(3, 1, 8, 1, P.red)
        }
        case .cabinet: draw(14, 26, theme) { c in
            c.rect(1, 1, 12, 24, P.steel)
            c.rect(11, 1, 2, 24, P.metalDark)
            for y in [2, 10, 18] {
                c.rect(2, y, 9, 7, P.steelLight)
                c.rect(4, y + 3, 5, 1, P.metalDark)
            }
        }
        case .printer: draw(18, 16, theme) { c in
            c.rect(3, 1, 12, 3, P.paper)
            c.rect(1, 4, 16, 9, P.plastic)
            c.rect(1, 4, 16, 1, P.white)
            c.rect(15, 5, 2, 8, P.frameShade)
            c.rect(3, 8, 8, 1, P.ink)
            c.dot(13, 6, P.led)
            c.rect(2, 13, 14, 2, P.metalDark)
        }
        case .sign: draw(20, 10, theme) { c in
            c.rect(1, 1, 18, 8, P.noteYellow)
            for x in stride(from: 1, to: 19, by: 4) { c.rect(x, 1, 2, 8, P.ink) }
            c.rect(5, 3, 10, 4, P.white)
            c.rect(7, 4, 6, 2, P.ink)
        }
        case .toilet: draw(14, 18, theme) { c in
            c.rect(3, 1, 8, 6, P.steel)
            c.rect(3, 1, 8, 1, P.steelLight)
            c.rect(2, 8, 10, 3, P.steelLight)
            c.rect(3, 9, 8, 1, P.metalDark)
            c.rect(4, 11, 6, 5, P.steel)
            c.rect(9, 11, 1, 5, P.metalDark)
        }
        case .bucket: draw(12, 20, theme) { c in
            c.rect(7, 1, 1, 11, P.woodDark)                                   // mop handle
            c.rect(2, 11, 8, 7, P.noteYellow)
            c.rect(2, 11, 8, 1, P.white)
            c.rect(8, 12, 2, 6, P.accent)
            c.rect(5, 9, 5, 2, P.plastic)
        }
        case .neon: draw(24, 12, theme) { c in
            c.rect(1, 1, 22, 10, P.ink)
            c.stamp([
                "...n.......n....n...",
                "..n.......n......n..",
                ".n.......n........n.",
                "..n.....n........n..",
                "...n...n........n...",
            ], at: 2, 3, key: ["n": P.neon])
        }
        case .beanbag: draw(20, 14, theme) { c in
            c.stamp([
                ".....rrrrrrrr.....",
                "...rrrrrrrrrrrr...",
                "..rrrlllrrrrrrrr..",
                ".rrrllrrrrrrrrrrr.",
                ".rrrrrrrrrrrrrrRr.",
                "rrrrrrrrrrrrrrRRrr",
                "rrrrrrrrrrrrrRRRrr",
                ".RrrrrrrrrrrRRRRR.",
                "..RRRRRRRRRRRRRR..",
            ], at: 1, 3, key: ["r": P.red, "l": P.white, "R": P.redDark])
        }
        case .painting: draw(22, 15, theme) { c in
            c.rect(1, 1, 20, 13, P.gold)
            c.rect(2, 2, 18, 11, P.sky)
            c.rect(2, 8, 18, 5, P.sea)
            c.stamp(["...gg.......", "..gggg...ggg", ".gggggggggggg"], at: 4, 6, key: ["g": P.leafDark])
            c.rect(15, 3, 3, 3, P.noteYellow)                                 // sun
        }
        case .bookshelf: draw(18, 30, theme) { c in
            c.rect(1, 1, 16, 28, P.woodDark)
            c.rect(2, 2, 14, 26, P.wood)
            let colors = [P.red, P.noteBlue, P.leafDark, P.noteYellow, P.pot, P.notePink, P.sea]
            for (shelf, y) in [3, 10, 17].enumerated() {
                var x = 3
                while x < 15 {
                    let w = (x + shelf) % 3 == 0 ? 2 : 1
                    c.rect(x, y, w, 6, colors[(x * 3 + shelf) % colors.count])
                    x += w + ((x + shelf) % 5 == 0 ? 1 : 0)
                }
                c.rect(2, y + 6, 14, 1, P.woodDark)
            }
            c.rect(2, 24, 14, 4, P.woodDark)
        }
        case .globe: draw(14, 20, theme) { c in
            c.stamp([
                "...bbbbb...",
                "..bbggbbbb.",
                ".bbgggbbbbb",
                ".bbbggbbgbb",
                ".bbbbbbgggb",
                ".bbbbbbbggb",
                "..bbgbbbbb.",
                "...bbbbb...",
            ], at: 1, 1, key: ["b": P.sea, "g": P.leaf])
            c.rect(5, 9, 2, 2, P.gold)
            c.rect(6, 11, 1, 5, P.woodDark)
            c.rect(3, 16, 7, 2, P.woodDark)
        }
        case .screen: draw(24, 15, theme) { c in
            c.rect(1, 1, 22, 13, P.frameShade)
            c.rect(2, 2, 20, 11, P.ink)
            c.dot(4, 4, P.white); c.dot(18, 3, P.white); c.dot(15, 10, P.white); c.dot(6, 11, P.white)
            c.stamp([".ooo.", "ooooo", "ooOoo", ".ooo."], at: 9, 5, key: ["o": P.accent, "O": P.noteYellow])
            c.rect(7, 7, 9, 1, P.neon)                                        // ring
        }
        case .console: draw(20, 20, theme) { c in
            c.rect(1, 6, 18, 13, P.frameShade)
            c.rect(2, 1, 16, 6, P.ink)
            c.rect(3, 2, 14, 4, P.glassDark)
            c.rect(4, 3, 6, 1, P.screen); c.rect(4, 4, 9, 1, P.screen)
            for (i, color) in [P.red, P.led, P.noteYellow, P.screen].enumerated() { c.rect(3 + i * 4, 9, 2, 2, color) }
            c.rect(3, 13, 14, 2, P.metalDark)
        }
        case .capsule: draw(14, 24, theme) { c in
            c.stamp([
                "...gggggg...",
                "..g......g..",
                ".g..lL.l..g.",
                ".g.LLlLLL.g.",
                ".g.lLLlLl.g.",
                ".g..LLLL..g.",
                ".g...LL...g.",
                ".g...LL...g.",
            ], at: 1, 1, key: ["g": P.glassLight, "l": P.leafLight, "L": P.leaf])
            c.rect(2, 9, 10, 4, P.pot)
            c.rect(1, 13, 12, 8, P.steel)
            c.rect(1, 13, 12, 1, P.steelLight)
            c.dot(6, 16, P.screen)
        }
        }
    }

    /// Between two desks: a cubicle panel, or prison bars. Art pixels wide × floor-to-desk tall.
    public static let partitionWidth = 5, partitionHeight = 34

    static func partition(_ kind: OfficeTheme.Partition, theme: OfficeTheme) -> CGImage? {
        var c = PixelCanvas(width: partitionWidth, height: partitionHeight)
        switch kind {
        case .cubicle:
            c.rect(1, 1, 3, 32, P.partition)
            c.rect(1, 1, 3, 2, P.partitionLight)
            c.rect(3, 3, 1, 30, P.partitionDark)
        case .bars:
            c.rect(1, 1, 3, 1, P.partitionLight)
            c.rect(1, 1, 1, 32, P.partition)
            c.rect(3, 1, 1, 32, P.partition)
            c.rect(1, 32, 3, 1, P.partitionDark)
        }
        c.outline(P.outline)
        return paint(c, theme)
    }

    private static func draw(_ width: Int, _ height: Int, _ theme: OfficeTheme, _ body: (inout PixelCanvas) -> Void) -> (CGImage?, Int, Int) {
        var c = PixelCanvas(width: width, height: height)
        body(&c)
        c.outline(P.outline)
        return (paint(c, theme), width, height)
    }
}
