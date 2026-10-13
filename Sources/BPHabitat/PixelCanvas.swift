import CoreGraphics
import Foundation

/// A tiny indexed-colour bitmap. All Bullpen art is drawn in code with it, so the sprites are
/// ours (MIT/CC BY like the rest of the repo), weigh nothing and can be recoloured per character.
public struct PixelCanvas: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Palette index per pixel; 0 is transparent.
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height)
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { (0..<width).contains(x) && (0..<height).contains(y) ? pixels[y * width + x] : 0 }
        set { if (0..<width).contains(x), (0..<height).contains(y) { pixels[y * width + x] = newValue } }
    }

    public mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt8) {
        for yy in y..<(y + h) { for xx in x..<(x + w) { self[xx, yy] = color } }
    }

    public mutating func dot(_ x: Int, _ y: Int, _ color: UInt8) { self[x, y] = color }

    /// Draws `rows` ("." = transparent, other characters looked up in `key`) with its top-left at x, y.
    public mutating func stamp(_ rows: [String], at x: Int, _ y: Int, key: [Character: UInt8]) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch != "." {
                if let c = key[ch] { self[x + dx, y + dy] = c }
            }
        }
    }

    /// Surrounds every drawn shape with a 1-pixel `color` border (the outlined pixel-art look).
    /// `diagonals` also closes corners, for ragged shapes like leaves.
    public mutating func outline(_ color: UInt8, diagonals: Bool = false) {
        let source = self
        let around = diagonals
            ? [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
            : [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for y in 0..<height {
            for x in 0..<width where source[x, y] == 0 {
                if around.contains(where: { source[x + $0.0, y + $0.1] != 0 }) { self[x, y] = color }
            }
        }
    }

    /// Flipped left to right (a person walking the other way).
    public func mirrored() -> PixelCanvas {
        var copy = self
        for y in 0..<height { for x in 0..<width { copy[x, y] = self[width - 1 - x, y] } }
        return copy
    }

    public var isEmpty: Bool { !pixels.contains { $0 != 0 } }

    /// Renders at 1 pixel per cell; layers scale it up with nearest-neighbour filtering.
    public func image(palette: Palette) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixels.count where pixels[i] != 0 {
            let c = palette[pixels[i]]
            rgba[i * 4] = c.r
            rgba[i * 4 + 1] = c.g
            rgba[i * 4 + 2] = c.b
            rgba[i * 4 + 3] = c.a
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(_ hex: UInt32, alpha: UInt8 = 255) {
        // Premultiplied alpha.
        func pm(_ v: UInt32) -> UInt8 { UInt8((v * UInt32(alpha)) / 255) }
        r = pm((hex >> 16) & 0xFF)
        g = pm((hex >> 8) & 0xFF)
        b = pm(hex & 0xFF)
        a = alpha
    }
}

public struct Palette: Sendable {
    var colors: [UInt8: RGBA]
    public init(_ colors: [UInt8: RGBA]) { self.colors = colors }
    public subscript(_ index: UInt8) -> RGBA { colors[index] ?? RGBA(0xFF00FF) }
}
