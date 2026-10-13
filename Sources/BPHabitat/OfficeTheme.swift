import Foundation

/// How a project's office looks: colours, walls, windows, floor, partitions between desks and
/// what stands after the last desk. Chosen per project in Settings.
public enum OfficeTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case basic, cubicles, prison, startup, classic, space

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .basic: "Básica"
        case .cubicles: "Cubículos"
        case .prison: "Prisión"
        case .startup: "Startup"
        case .classic: "Despacho clásico"
        case .space: "Nave espacial"
        }
    }

    public var summary: String {
        switch self {
        case .basic: "Tarima, ventanas y una fuente de agua."
        case .cubicles: "Gris corporativo: moqueta, persianas y mamparas entre puestos."
        case .prison: "Hormigón, barrotes y sillas naranjas."
        case .startup: "Blanco, neón, puf y mucho color."
        case .classic: "Madera noble, moqueta verde, librería y globo terráqueo."
        case .space: "Paneles metálicos, ojos de buey con estrellas y consolas."
        }
    }

    enum Floor { case planks, carpet, concrete, polished, grating }
    enum Wall { case plain, blocks, panels, metal, mural }
    enum Windows { case panes, blinds, bars, portholes }
    enum Partition { case cubicle, bars }
    enum Decor { case board, plant, cooler, clock, cabinet, printer, sign, toilet, bucket, neon, beanbag, painting, bookshelf, globe, screen, console, capsule }

    var floor: Floor {
        switch self {
        case .basic: .planks
        case .cubicles, .classic: .carpet
        case .prison: .concrete
        case .startup: .polished
        case .space: .grating
        }
    }

    var wall: Wall {
        switch self {
        case .basic, .cubicles: .plain
        case .prison: .blocks
        case .classic: .panels
        case .space: .metal
        case .startup: .mural
        }
    }

    var windows: Windows {
        switch self {
        case .basic, .classic, .startup: .panes
        case .cubicles: .blinds
        case .prison: .bars
        case .space: .portholes
        }
    }

    var partition: Partition? {
        switch self {
        case .cubicles: .cubicle
        case .prison: .bars
        default: nil
        }
    }

    /// On the wall after the last desk, and on the floor next to it.
    var wallDecor: Decor {
        switch self {
        case .basic: .board
        case .cubicles: .clock
        case .prison: .sign
        case .startup: .neon
        case .classic: .painting
        case .space: .screen
        }
    }

    var floorDecor: [Decor] {
        switch self {
        case .basic: [.plant, .cooler]
        case .cubicles: [.cabinet, .printer]
        case .prison: [.toilet, .bucket]
        case .startup: [.beanbag, .plant]
        case .classic: [.bookshelf, .globe]
        case .space: [.console, .capsule]
        }
    }

    /// Replaces colours of the base palette (`Props.P`).
    var colors: [UInt8: RGBA] {
        typealias P = Props.P
        switch self {
        case .basic:
            return [:]
        case .cubicles:
            return [
                P.wall: RGBA(0xD3D6DB), P.wallShade: RGBA(0xBCC0C7), P.trim: RGBA(0x7A7F88), P.baseboard: RGBA(0x8E939B), P.baseboardDark: RGBA(0x6E737B),
                P.frame: RGBA(0xE9EBEE), P.frameShade: RGBA(0xB9BEC5), P.glass: RGBA(0xC4CBD3), P.glassLight: RGBA(0xE1E6EC), P.glassDark: RGBA(0xA4ACB6),
                P.plank: RGBA(0x8A8E96), P.plankAlt: RGBA(0x83878F), P.seam: RGBA(0x7A7E86), P.plankLight: RGBA(0x969AA2), P.floorShadow: RGBA(0x73777F), P.joint: RGBA(0x80848C),
                P.deskTop: RGBA(0xD7D9DD), P.deskRim: RGBA(0xEBEDF0), P.deskFront: RGBA(0xA4A8B0), P.deskMat: RGBA(0x5F656E), P.deskEdge: RGBA(0xBDC0C6),
                P.chair: RGBA(0x3F4654), P.chairLight: RGBA(0x5B6475), P.chairDark: RGBA(0x2B313C), P.chairCushion: RGBA(0x4C5566),
                P.partition: RGBA(0x7F8A99), P.partitionLight: RGBA(0x99A3B1), P.partitionDark: RGBA(0x5F6876),
            ]
        case .prison:
            return [
                P.wall: RGBA(0x9A9C97), P.wallShade: RGBA(0x83857F), P.trim: RGBA(0x4C4E4A), P.baseboard: RGBA(0x6A6C67), P.baseboardDark: RGBA(0x4F514C),
                P.frame: RGBA(0x5A5D60), P.frameShade: RGBA(0x45484B), P.glass: RGBA(0x8EA4B4), P.glassLight: RGBA(0xB5C6D2), P.glassDark: RGBA(0x6C8292),
                P.plank: RGBA(0xA4A6A1), P.plankAlt: RGBA(0x9D9F9A), P.seam: RGBA(0x83857F), P.plankLight: RGBA(0xB0B2AD), P.floorShadow: RGBA(0x8A8C87), P.joint: RGBA(0x8F918C),
                P.deskTop: RGBA(0x8B9298), P.deskRim: RGBA(0xA6ADB3), P.deskFront: RGBA(0x5E656B), P.deskMat: RGBA(0x4C5257), P.deskEdge: RGBA(0x737A80),
                P.chair: RGBA(0xD9772B), P.chairLight: RGBA(0xF0954A), P.chairDark: RGBA(0xAE5C1E), P.chairCushion: RGBA(0xE0843A),
                P.lampBody: RGBA(0x55585B), P.lampShine: RGBA(0x7A7E82),
                P.partition: RGBA(0x4A4D50), P.partitionLight: RGBA(0x6C7074), P.partitionDark: RGBA(0x323538),
            ]
        case .startup:
            return [
                P.wall: RGBA(0xF5F2EC), P.wallShade: RGBA(0xE3DFD7), P.trim: RGBA(0x2F3E46), P.baseboard: RGBA(0xDCD7CE), P.baseboardDark: RGBA(0xBDB7AC),
                P.plank: RGBA(0xCFCBC3), P.plankAlt: RGBA(0xCAC6BE), P.seam: RGBA(0xB8B3AA), P.plankLight: RGBA(0xDAD6CF), P.floorShadow: RGBA(0xBFBAB1), P.joint: RGBA(0xC2BDB4),
                P.deskTop: RGBA(0xF3F3F0), P.deskRim: RGBA(0xFFFFFF), P.deskFront: RGBA(0xD5D3CD), P.deskMat: RGBA(0x31404D), P.deskEdge: RGBA(0xE2E0DA),
                P.chair: RGBA(0xE8B33A), P.chairLight: RGBA(0xF6CB5E), P.chairDark: RGBA(0xB98A23), P.chairCushion: RGBA(0xE0A830),
                P.lampBody: RGBA(0x2F3E46), P.lampShine: RGBA(0x4F6370),
            ]
        case .classic:
            return [
                P.wall: RGBA(0x6E4B33), P.wallShade: RGBA(0x5A3C28), P.trim: RGBA(0x3B2719), P.baseboard: RGBA(0x4A3122), P.baseboardDark: RGBA(0x342116),
                P.frame: RGBA(0x8C6A49), P.frameShade: RGBA(0x6B4E34), P.glass: RGBA(0x9DBBCF), P.glassLight: RGBA(0xC6DBE8), P.glassDark: RGBA(0x7B9AB0),
                P.plank: RGBA(0x3F5A45), P.plankAlt: RGBA(0x3B5541), P.seam: RGBA(0x324A38), P.plankLight: RGBA(0x48654F), P.floorShadow: RGBA(0x30473A), P.joint: RGBA(0x395240),
                P.deskTop: RGBA(0x7A3E2A), P.deskRim: RGBA(0x99523A), P.deskFront: RGBA(0x5A2D1E), P.deskMat: RGBA(0x2F5D3F), P.deskEdge: RGBA(0x6A3524),
                P.chair: RGBA(0x6E3B22), P.chairLight: RGBA(0x8E5434), P.chairDark: RGBA(0x4C2716), P.chairCushion: RGBA(0x7A4327),
                P.lampBody: RGBA(0x2E5E3E), P.lampShine: RGBA(0xC9A45C),
            ]
        case .space:
            return [
                P.wall: RGBA(0x2E3849), P.wallShade: RGBA(0x252D3C), P.trim: RGBA(0x161C27), P.baseboard: RGBA(0x3B4B64), P.baseboardDark: RGBA(0x1F2836),
                P.frame: RGBA(0x8EA2BE), P.frameShade: RGBA(0x5E6F88), P.glass: RGBA(0x0C1230), P.glassLight: RGBA(0xF4F7FF), P.glassDark: RGBA(0x1B2658),
                P.plank: RGBA(0x3B4351), P.plankAlt: RGBA(0x363E4B), P.seam: RGBA(0x262C37), P.plankLight: RGBA(0x4A5462), P.floorShadow: RGBA(0x20262F), P.joint: RGBA(0x2D343F),
                P.deskTop: RGBA(0xDDE4EE), P.deskRim: RGBA(0xF4F7FB), P.deskFront: RGBA(0x95A4B8), P.deskMat: RGBA(0x1B2A40), P.deskEdge: RGBA(0xB8C3D2),
                P.chair: RGBA(0x1F2A3A), P.chairLight: RGBA(0x3D5672), P.chairDark: RGBA(0x131A25), P.chairCushion: RGBA(0x2B3C52),
                P.lampBody: RGBA(0x8EA2BE), P.lampShine: RGBA(0xC9D4E4), P.lampOn: RGBA(0x9BE8FF), P.lampGlow: RGBA(0xE0FAFF),
            ]
        }
    }
}
