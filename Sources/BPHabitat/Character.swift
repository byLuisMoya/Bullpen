import BPCore
import CoreGraphics
import Foundation

/// Palette slots used by character sprites.
enum Ink {
    static let skin: UInt8 = 1, skinShade: UInt8 = 2, hair: UInt8 = 3, hairShade: UInt8 = 4
    static let shirt: UInt8 = 5, shirtShade: UInt8 = 6, eye: UInt8 = 7, mouth: UInt8 = 8
}

/// How a worktree's person looks. Derived deterministically from the worktree id, with the
/// shirt colour coming from the agent (PLAN §9.4). No brand logos, just colours.
public struct CharacterLook: Equatable, Sendable {
    public var skin: Int
    public var hair: Int
    public var hairStyle: Int
    public var shirt: UInt32

    static let skins: [(UInt32, UInt32)] = [
        (0xF6D3B3, 0xE2B48F), (0xEDB98A, 0xD39A6A), (0xD08B5B, 0xB57148), (0xAE5D29, 0x91481C), (0x7A4424, 0x5E3118),
    ]
    static let hairs: [(UInt32, UInt32)] = [
        (0x2B1B12, 0x1A100A), (0x5A3825, 0x452A1B), (0xB7793F, 0x9A6230), (0xE5C27A, 0xCDA65C),
        (0x8C8C8C, 0x6E6E6E), (0xA6402F, 0x86301F),
    ]
    static let hairStyles = 4

    public static func make(worktreeID: UUID, agent: String?) -> CharacterLook {
        var hash: UInt64 = 1469598103934665603
        for byte in withUnsafeBytes(of: worktreeID.uuid, Array.init) {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return CharacterLook(
            skin: Int(hash % UInt64(skins.count)),
            hair: Int((hash >> 8) % UInt64(hairs.count)),
            hairStyle: Int((hash >> 16) % UInt64(hairStyles)),
            shirt: shirtColor(agent: agent)
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
        ])
    }

    private func shade(_ c: UInt32) -> UInt32 {
        let r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF
        return (r * 3 / 4) << 16 | (g * 3 / 4) << 8 | (b * 3 / 4)
    }
}

/// Body poses; each animation is a short list of them.
public enum Pose: CaseIterable, Sendable {
    case rest, typeA, typeB, chin, chinBlink, raised, wave, cheer, sleep
}

public enum CharacterSprite {
    /// Canvas size in pixels. The desk covers the bottom rows.
    public static let width = 18, height = 22

    public static func canvas(_ pose: Pose, look: CharacterLook) -> PixelCanvas {
        var c = PixelCanvas(width: width, height: height)
        let dy = pose == .sleep ? 4 : 0
        torso(&c)
        head(&c, dy: dy, style: look.hairStyle, eyesClosed: pose == .chinBlink || pose == .sleep)
        arms(&c, pose)
        return c
    }

    private static func head(_ c: inout PixelCanvas, dy: Int, style: Int, eyesClosed: Bool) {
        // Hair behind the head (long styles).
        if style == 1 { c.rect(4, 5 + dy, 10, 8, Ink.hairShade) }
        // Face.
        c.rect(5, 5 + dy, 8, 7, Ink.skin)
        c.rect(5, 11 + dy, 8, 1, Ink.skinShade)
        c.dot(4, 8 + dy, Ink.skin)        // ears
        c.dot(13, 8 + dy, Ink.skin)
        // Eyes and mouth.
        if eyesClosed {
            c.rect(6, 8 + dy, 2, 1, Ink.skinShade)
            c.rect(10, 8 + dy, 2, 1, Ink.skinShade)
        } else {
            c.rect(7, 8 + dy, 1, 2, Ink.eye)
            c.rect(10, 8 + dy, 1, 2, Ink.eye)
        }
        c.rect(8, 10 + dy, 2, 1, Ink.mouth)
        // Hair on top.
        c.rect(5, 3 + dy, 8, 3, Ink.hair)
        c.rect(4, 4 + dy, 1, 3, Ink.hair)
        c.rect(13, 4 + dy, 1, 3, Ink.hair)
        c.rect(6, 2 + dy, 6, 1, Ink.hair)
        switch style {
        case 1: c.rect(4, 7 + dy, 1, 5, Ink.hair); c.rect(13, 7 + dy, 1, 5, Ink.hair)   // long
        case 2: c.rect(7, 0 + dy, 4, 2, Ink.hairShade)                                      // bun
        case 3: for x in stride(from: 5, through: 12, by: 2) { c.dot(x, 1 + dy, Ink.hair) }  // spiky
        default: c.rect(10, 5 + dy, 3, 1, Ink.hair)                                         // side fringe
        }
        c.rect(5, 3 + dy, 8, 1, Ink.hairShade)
    }

    private static func torso(_ c: inout PixelCanvas) {
        c.rect(8, 12, 2, 1, Ink.skinShade)   // neck
        c.rect(4, 13, 10, 9, Ink.shirt)
        c.rect(4, 13, 1, 9, Ink.shirtShade)
        c.rect(5, 13, 8, 1, Ink.shirtShade)  // collar line
    }

    private static func arms(_ c: inout PixelCanvas, _ pose: Pose) {
        func leftDown() { c.rect(2, 14, 2, 6, Ink.shirtShade); c.rect(2, 20, 2, 1, Ink.skin) }
        func rightDown() { c.rect(14, 14, 2, 6, Ink.shirtShade); c.rect(14, 20, 2, 1, Ink.skin) }
        switch pose {
        case .rest:
            leftDown(); rightDown()
        case .typeA, .typeB:
            let (l, r) = pose == .typeA ? (0, 1) : (1, 0)
            c.rect(3, 15, 2, 4, Ink.shirtShade); c.rect(5, 18 + l, 2, 1, Ink.skin)
            c.rect(13, 15, 2, 4, Ink.shirtShade); c.rect(11, 18 + r, 2, 1, Ink.skin)
        case .chin, .chinBlink:
            leftDown()
            c.rect(14, 14, 2, 3, Ink.shirtShade)
            c.rect(12, 13, 2, 2, Ink.shirtShade)
            c.rect(11, 11, 2, 2, Ink.skin)
        case .raised, .wave:
            leftDown()
            let x = pose == .raised ? 14 : 15
            c.rect(14, 8, 2, 6, Ink.shirtShade)
            c.rect(x, 5, 2, 3, Ink.skin)
        case .cheer:
            c.rect(2, 7, 2, 7, Ink.shirtShade); c.rect(2, 4, 2, 3, Ink.skin)
            c.rect(14, 7, 2, 7, Ink.shirtShade); c.rect(14, 4, 2, 3, Ink.skin)
        case .sleep:
            c.rect(3, 17, 12, 3, Ink.shirtShade)   // folded arms under the head
            c.rect(3, 19, 2, 1, Ink.skin); c.rect(13, 19, 2, 1, Ink.skin)
        }
    }

    /// Just the head (12×11 px), for the menu bar strip.
    public static func head(look: CharacterLook, eyesClosed: Bool = false) -> CGImage? {
        let full = canvas(eyesClosed ? .chinBlink : .rest, look: look)
        var c = PixelCanvas(width: 12, height: 11)
        for y in 0..<11 { for x in 0..<12 { c[x, y] = full[x + 3, y + 1] } }
        // chinBlink raises a hand to the chin; keep the face clean.
        if eyesClosed { c.rect(8, 10, 2, 1, 0) }
        return c.image(palette: look.palette)
    }

    /// A jacket hanging on the empty chair: the person has left (agent not running).
    public static func jacket(look: CharacterLook) -> PixelCanvas {
        var c = PixelCanvas(width: width, height: height)
        c.rect(4, 12, 10, 7, Ink.shirt)
        c.rect(4, 12, 10, 1, Ink.shirtShade)
        c.rect(8, 13, 2, 6, Ink.shirtShade)     // opening
        c.rect(3, 13, 1, 6, Ink.shirtShade)     // sleeves hanging down
        c.rect(14, 13, 1, 6, Ink.shirtShade)
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
