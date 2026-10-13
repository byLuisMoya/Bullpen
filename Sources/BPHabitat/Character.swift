import BPCore
import CoreGraphics
import Foundation

/// Palette slots used by character sprites.
enum Ink {
    static let skin: UInt8 = 1, skinShade: UInt8 = 2, hair: UInt8 = 3, hairShade: UInt8 = 4
    static let shirt: UInt8 = 5, shirtShade: UInt8 = 6, eye: UInt8 = 7, mouth: UInt8 = 8
    static let outline: UInt8 = 9, eyeLight: UInt8 = 10, blush: UInt8 = 11, hairLight: UInt8 = 12, collar: UInt8 = 13
    static let jacket: UInt8 = 14, jacketShade: UInt8 = 15, jacketDark: UInt8 = 16, lining: UInt8 = 17, button: UInt8 = 18
}

/// How a worktree's person looks. Derived deterministically from the worktree id, with the
/// shirt colour coming from the agent (PLAN §9.4). No brand logos, just colours.
public struct CharacterLook: Equatable, Sendable {
    public var skin: Int
    public var hair: Int
    public var hairStyle: Int
    public var shirt: UInt32
    /// The jacket left on the chair when the person is away: a sober base colour, a slightly
    /// lighter or darker tone of it, and its own lining, so no two look alike.
    public var jacketBase: Int
    public var jacketTone: Int
    public var liningIndex: Int

    static let skins: [(UInt32, UInt32)] = [
        (0xF6D3B3, 0xE2B48F), (0xEDB98A, 0xD39A6A), (0xD08B5B, 0xB57148), (0xAE5D29, 0x91481C), (0x7A4424, 0x5E3118),
    ]
    static let hairs: [(UInt32, UInt32)] = [
        (0x2B1B12, 0x1A100A), (0x5A3825, 0x452A1B), (0xB7793F, 0x9A6230), (0xE5C27A, 0xCDA65C),
        (0x8C8C8C, 0x6E6E6E), (0xA6402F, 0x86301F),
    ]
    static let hairStyles = 4
    /// Sober jacket colours: navy, charcoal, camel, olive, denim, burgundy, brown, grey,
    /// forest green, sand, slate blue, rust.
    static let jackets: [UInt32] = [0x2F3E5C, 0x45474D, 0xB08A5A, 0x5E6B3F, 0x4D6A8C, 0x6E2F3A,
                                    0x6B4A33, 0x8A8F96, 0x2F4F3E, 0xC2B08E, 0x5A6378, 0x8C4A2F]
    /// Satin linings: burgundy, navy, old gold, grey, teal.
    static let linings: [UInt32] = [0x9B3B45, 0x2C3E66, 0xB8963E, 0x6A6E76, 0x2F5E57]
    /// Tone steps either side of the base colour (each 6 % towards white or black).
    static let tones = -2...2

    /// The jacket colour: its base, lighter or darker by its tone.
    public var jacket: UInt32 {
        let base = Self.jackets[jacketBase % Self.jackets.count]
        return jacketTone >= 0 ? Self.mix(base, 0xFFFFFF, 0.06 * Double(jacketTone))
                               : Self.mix(base, 0x000000, 0.06 * Double(-jacketTone))
    }

    public var lining: UInt32 {
        var index = liningIndex % Self.linings.count
        // A burgundy lining would vanish inside a burgundy or rust jacket.
        if index == 0, [5, 11].contains(jacketBase % Self.jackets.count) { index = 2 }
        return Self.linings[index]
    }

    /// Gives every person in `looks` a different base colour where possible (in order, the
    /// first keeps its own), so an office never has two identical jackets on its chairs.
    public static func distinctJackets(_ looks: [CharacterLook]) -> [CharacterLook] {
        var used = Set<Int>()
        return looks.map { look in
            var look = look
            if used.contains(look.jacketBase), used.count < jackets.count {
                while used.contains(look.jacketBase) { look.jacketBase = (look.jacketBase + 5) % jackets.count }
            }
            used.insert(look.jacketBase)
            return look
        }
    }

    public static func make(worktreeID: UUID, agent: String?) -> CharacterLook {
        var hash: UInt64 = 1469598103934665603
        for byte in withUnsafeBytes(of: worktreeID.uuid, Array.init) {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return CharacterLook(
            skin: Int(hash % UInt64(skins.count)),
            hair: Int((hash >> 8) % UInt64(hairs.count)),
            hairStyle: Int((hash >> 16) % UInt64(hairStyles)),
            shirt: shirtColor(agent: agent),
            jacketBase: Int((hash >> 24) % UInt64(jackets.count)),
            jacketTone: Int((hash >> 32) % UInt64(tones.count)) + tones.lowerBound,
            liningIndex: Int((hash >> 40) % UInt64(linings.count))
        )
    }

    public static func shirtColor(agent: String?) -> UInt32 {
        switch agent {
        case "claude": 0xD97A4A   // warm orange
        case "codex": 0x3E9E7E    // teal green
        case nil: 0x6B7A99        // plain terminal: slate
        default: 0x8E6BC2
        }
    }

    var palette: Palette {
        let s = Self.skins[skin], h = Self.hairs[hair]
        return Palette([
            Ink.skin: RGBA(s.0), Ink.skinShade: RGBA(s.1),
            Ink.hair: RGBA(h.0), Ink.hairShade: RGBA(h.1),
            Ink.shirt: RGBA(shirt), Ink.shirtShade: RGBA(shade(shirt)),
            Ink.eye: RGBA(0x23202A), Ink.mouth: RGBA(0x9C4A4A),
            Ink.outline: RGBA(0x2A2230), Ink.eyeLight: RGBA(0xFFFFFF), Ink.blush: RGBA(0xF09A8C),
            Ink.hairLight: RGBA(Self.mix(h.0, 0xFFFFFF, 0.3)), Ink.collar: RGBA(Self.mix(shirt, 0xFFFFFF, 0.55)),
            Ink.jacket: RGBA(jacket), Ink.jacketShade: RGBA(Self.mix(jacket, 0x000000, 0.22)),
            Ink.jacketDark: RGBA(Self.mix(jacket, 0x000000, 0.4)),
            Ink.lining: RGBA(lining), Ink.button: RGBA(0xC9A45C),
        ])
    }

    private func shade(_ c: UInt32) -> UInt32 { Self.mix(c, 0x000000, 0.25) }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

/// Body poses; each animation is a short list of them.
public enum Pose: CaseIterable, Sendable {
    case rest, typeA, typeB, chin, chinBlink, raised, wave, cheer, sleep
}

public enum CharacterSprite {
    /// Canvas size in pixels. The bottom row lines up with the desk top: the desk hides the rest.
    public static let width = 24, height = 23
    /// Where the face starts inside the canvas; hair and buns sit above it.
    static let headX = 5, faceY = 4

    public static func canvas(_ pose: Pose, look: CharacterLook) -> PixelCanvas {
        var c = PixelCanvas(width: width, height: height)
        let dy = pose == .sleep ? 6 : 0
        if pose != .sleep { torso(&c) }
        face(&c, dy: dy, pose: pose)
        hair(&c, dy: dy, style: look.hairStyle)
        arms(&c, pose)
        c.outline(Ink.outline)
        return c
    }

    private static func face(_ c: inout PixelCanvas, dy: Int, pose: Pose) {
        let x = headX, y = faceY + dy
        c.stamp([
            "..ssssssssss..",
            ".ssssssssssss.",
            ".ssssssssssss.",
            ".ssssssssssss.",
            "ssssssssssssss",
            "sSssssssssssSs",
            ".ssssssssssss.",
            ".ssssssssssss.",
            "..ssssssssss..",
            "...SSSSSSSS...",
        ], at: x, y, key: ["s": Ink.skin, "S": Ink.skinShade])
        c.rect(x + 5, y + 10, 4, 1, Ink.skinShade)                          // neck
        switch pose {
        case .chinBlink, .sleep:
            c.rect(x + 4, y + 5, 2, 1, Ink.eye)
            c.rect(x + 8, y + 5, 2, 1, Ink.eye)
        case .cheer:                                                        // ^ ^
            for ex in [x + 3, x + 8] {
                c.dot(ex, y + 5, Ink.eye); c.dot(ex + 1, y + 4, Ink.eye); c.dot(ex + 2, y + 5, Ink.eye)
            }
        default:
            for ex in [x + 4, x + 8] {
                c.rect(ex, y + 4, 2, 2, Ink.eye)
                c.dot(ex, y + 4, Ink.eyeLight)
            }
        }
        c.rect(x + 2, y + 6, 2, 1, Ink.blush)
        c.rect(x + 10, y + 6, 2, 1, Ink.blush)
        switch pose {
        case .cheer, .wave:
            c.rect(x + 5, y + 7, 4, 1, Ink.mouth)
            c.rect(x + 6, y + 8, 2, 1, Ink.mouth)
        case .raised:
            c.rect(x + 6, y + 7, 2, 2, Ink.mouth)
        case .sleep:
            c.dot(x + 7, y + 7, Ink.mouth)
        default:
            c.rect(x + 6, y + 7, 2, 1, Ink.mouth)
        }
    }

    private static func hair(_ c: inout PixelCanvas, dy: Int, style: Int) {
        let key: [Character: UInt8] = ["h": Ink.hair, "H": Ink.hairShade, "l": Ink.hairLight]
        let x = headX, y = faceY + dy
        switch style {
        case 1:   // long
            c.stamp([
                "....hhhhhh....",
                "..hhhhhlhhhh..",
                ".hhhhhhlhhhhh.",
                "hhhhhhhhlhhhhh",
                "hhHhhhHhhhHhhh",
                "hH..........Hh",
                "hH..........Hh",
                "hH..........Hh",
                "hH..........Hh",
                "hH..........Hh",
                "HH..........HH",
                "HH..........HH",
                "HH..........HH",
            ], at: x, y - 2, key: key)
        case 2:   // bun
            c.stamp([
                ".....hhhh.....",
                "....hhllhh....",
                ".....HHHH.....",
                "...hhhhhhhh...",
                "..hhhhhhlhhh..",
                ".hhhhhhhhlhhh.",
                ".hhhhhhhhhhhh.",
                ".hH........Hh.",
            ], at: x, y - 4, key: key)
        case 3:   // curly
            c.stamp([
                "..h.hh.hh.h...",
                ".hhhhhhhhhhhh.",
                "hhhhhlhhhhlhhh",
                "hhlhhhhhlhhhhh",
                "hhhhhhhhhhhhhh",
                "hHhHhHhHhHhHhh",
                "hH..........Hh",
            ], at: x, y - 3, key: key)
        default:  // short, fringe swept to one side
            c.stamp([
                "....hhhhhh....",
                "..hhhhhhlhhh..",
                ".hhhhhhhhlhhh.",
                ".hhhhhhhhhhhh.",
                ".hHhHhhhhhhhh.",
                ".h.....HhhhHh.",
            ], at: x, y - 2, key: key)
        }
    }

    private static func torso(_ c: inout PixelCanvas) {
        let y = faceY + 11
        c.stamp([
            "..tttCSSSSCttt..",
            ".tttttCSSCttttT.",
            "ttttttttttttttTT",
            "ttttttttttttttTT",
            "ttttttttttttttTT",
        ], at: headX - 1, y, key: ["t": Ink.shirt, "T": Ink.shirtShade, "C": Ink.collar, "S": Ink.skinShade])
    }

    private static func arms(_ c: inout PixelCanvas, _ pose: Pose) {
        let sleeve = Ink.shirtShade, hand = Ink.skin
        func leftDown() { c.rect(2, 16, 2, 4, sleeve); c.rect(2, 20, 2, 1, hand) }
        func rightDown() { c.rect(20, 16, 2, 4, sleeve); c.rect(20, 20, 2, 1, hand) }
        switch pose {
        case .rest:
            leftDown(); rightDown()
        case .typeA, .typeB:
            let (l, r) = pose == .typeA ? (0, 1) : (1, 0)
            // Hands on the keyboard either side of the monitor.
            c.rect(2, 16, 2, 4, sleeve); c.rect(4, 20 + l, 2, 2, hand)
            c.rect(20, 16, 2, 4, sleeve); c.rect(18, 20 + r, 2, 2, hand)
        case .chin, .chinBlink:
            leftDown()
            c.rect(20, 16, 2, 3, sleeve)
            c.rect(17, 14, 4, 2, sleeve)
            c.rect(15, 12, 2, 3, hand)
        case .raised:
            leftDown()
            c.rect(20, 8, 2, 8, sleeve)
            c.rect(20, 5, 2, 3, hand)
        case .wave:
            leftDown()
            c.rect(20, 9, 2, 7, sleeve)
            c.rect(21, 6, 2, 3, hand)
        case .cheer:
            c.rect(2, 8, 2, 8, sleeve); c.rect(2, 5, 2, 3, hand)
            c.rect(20, 8, 2, 8, sleeve); c.rect(20, 5, 2, 3, hand)
        case .sleep:
            c.rect(4, 18, 16, 3, Ink.shirt)     // folded arms on the desk, head resting on them
            c.rect(4, 18, 16, 1, sleeve)
            c.rect(4, 21, 2, 1, hand); c.rect(18, 21, 2, 1, hand)
        }
    }

    /// Just the head (12×11 px), for the menu bar strip: a simpler drawing that reads at that size.
    public static func head(look: CharacterLook, eyesClosed: Bool = false) -> CGImage? {
        var c = PixelCanvas(width: 12, height: 11)
        if look.hairStyle == 1 { c.rect(1, 4, 10, 7, Ink.hairShade) }
        c.rect(2, 4, 8, 7, Ink.skin)
        c.rect(2, 10, 8, 1, Ink.skinShade)
        c.dot(1, 7, Ink.skin)
        c.dot(10, 7, Ink.skin)
        if eyesClosed {
            c.rect(3, 7, 2, 1, Ink.skinShade)
            c.rect(7, 7, 2, 1, Ink.skinShade)
        } else {
            c.rect(4, 7, 1, 2, Ink.eye)
            c.rect(7, 7, 1, 2, Ink.eye)
        }
        c.rect(5, 9, 2, 1, Ink.mouth)
        c.rect(2, 2, 8, 3, Ink.hair)
        c.rect(1, 3, 1, 3, Ink.hair)
        c.rect(10, 3, 1, 3, Ink.hair)
        c.rect(3, 1, 6, 1, Ink.hair)
        switch look.hairStyle {
        case 1: c.rect(1, 6, 1, 5, Ink.hair); c.rect(10, 6, 1, 5, Ink.hair)
        case 2: c.rect(4, 0, 4, 1, Ink.hairShade)
        case 3: for x in stride(from: 2, through: 9, by: 2) { c.dot(x, 0, Ink.hair) }
        default: c.rect(7, 4, 3, 1, Ink.hair)
        }
        c.rect(2, 2, 8, 1, Ink.hairShade)
        return c.image(palette: look.palette)
    }

    /// The person's jacket thrown over the chair's backrest from behind, open: the shoulders
    /// over the top edge, the two fronts hanging either side with their lining showing, and the
    /// backrest visible down the middle. Shown when they have left (agent idle for a while, or
    /// not running). Drawn in the person's canvas, over the backrest, above the desk.
    public static func jacket(look: CharacterLook) -> PixelCanvas {
        var c = PixelCanvas(width: width, height: height)
        c.stamp([
            "...CCCCCCCCCCCCCCCC...",
            ".jjjjjjjjjjjjjjjjjjjj.",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "sjjjjll........lljjjjs",
            "cDDDDDD........DDDDDDc",
        ], at: 1, 5, key: ["j": Ink.jacket, "s": Ink.jacketShade, "C": Ink.jacketDark,
                           "D": Ink.jacketDark, "l": Ink.lining, "c": Ink.jacketDark])
        // Light from the left: the right front in shade.
        for y in 5..<16 {
            for x in 18...21 where c[x, y] == Ink.jacket { c[x, y] = Ink.jacketShade }
        }
        c.outline(Ink.outline)
        return c
    }

    /// Frames and speed for each state (PLAN §9.3). nil = nobody at the desk.
    public static func animation(for state: AgentState) -> (poses: [Pose], fps: Double)? {
        switch state {
        case .working: ([.typeA, .typeB], 6)
        case .thinking: ([.chin, .chin, .chin, .chinBlink], 3)
        case .needsYou: ([.raised, .wave], 3)
        case .done: ([.cheer, .rest], 1.5)
        case .idle: ([.sleep], 1)
        case .starting, .error, .unknown: ([.rest], 1)
        case .dead: nil
        }
    }
}
