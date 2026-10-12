import BPCore
import QuartzCore
import AppKit

/// One person at a desk = one worktree.
public struct DeskModel: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var state: AgentState
    public var detail: String?
    public var look: CharacterLook
    /// ⚡ on the desk: this worktree overlaps (yellow) or conflicts (red) with another one.
    public var warning: DeskWarning?

    public init(id: UUID, name: String, state: AgentState, detail: String? = nil, look: CharacterLook, warning: DeskWarning? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
        self.look = look
        self.warning = warning
    }
}

public enum DeskWarning: Sendable {
    case overlap, conflict
}

/// An office = a project, drawn as one floor of the building (PLAN §9).
public struct OfficeModel: Equatable, Sendable {
    public var desks: [DeskModel]
    public var lighting: OfficeLighting { OfficeLighting(activeWorktrees: desks.count) }

    public init(desks: [DeskModel]) { self.desks = desks }
}

/// Core Animation scene for one office. Sprite animations run in the render server, so a
/// visible office costs almost no CPU; `isPaused` freezes everything when nobody is looking.
public final class OfficeLayer: CALayer {
    /// Points per art pixel.
    public static let scale: CGFloat = 3
    static let slot = 34, margin = 8, wallHeight = 38, floorHeight = 10, decorWidth = 30
    public static var openHeight: CGFloat { CGFloat(wallHeight + floorHeight) * scale }
    public static var closedHeight: CGFloat { 16 * scale }

    public private(set) var model = OfficeModel(desks: [])
    private var nodes: [UUID: DeskNode] = [:]
    private let wall = CALayer(), floorLayer = CALayer(), darkness = CAShapeLayer()
    private let decor = CALayer(), closedSign = CATextLayer()
    private var reduceMotion = false

    public override init() {
        super.init()
        isGeometryFlipped = true
        masksToBounds = true
        wall.backgroundColor = CGColor(srgbRed: 0.84, green: 0.80, blue: 0.72, alpha: 1)
        floorLayer.backgroundColor = CGColor(srgbRed: 0.55, green: 0.42, blue: 0.32, alpha: 1)
        darkness.fillColor = CGColor(srgbRed: 0.05, green: 0.06, blue: 0.14, alpha: 0.72)
        darkness.fillRule = .evenOdd
        darkness.zPosition = 10
        closedSign.string = "cerrado"
        closedSign.fontSize = 11
        closedSign.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        closedSign.foregroundColor = CGColor(srgbRed: 0.75, green: 0.78, blue: 0.9, alpha: 0.8)
        closedSign.alignmentMode = .left
        closedSign.zPosition = 11
        closedSign.contentsScale = 2
        [wall, floorLayer, decor, darkness, closedSign].forEach(addSublayer)
    }

    public override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width the office needs for its desks.
    public static func preferredWidth(desks: Int) -> CGFloat {
        CGFloat(margin * 2 + max(desks, 1) * slot + decorWidth) * scale
    }

    public static func preferredHeight(desks: Int) -> CGFloat { desks == 0 ? closedHeight : openHeight }

    /// Mini version for the sidebar: drawn at 1 point per art pixel, without names.
    public var isCompact = false

    public func update(_ model: OfficeModel, reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        let old = self.model
        self.model = model
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let s = Self.scale
        wall.frame = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(Self.wallHeight) * s)
        floorLayer.frame = CGRect(x: 0, y: CGFloat(Self.wallHeight) * s, width: bounds.width, height: CGFloat(Self.floorHeight) * s)

        // Desks: keep existing nodes so running animations are not restarted for no reason.
        let ids = Set(model.desks.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            node.remove()
            nodes[id] = nil
        }
        for (index, desk) in model.desks.enumerated() {
            let node = nodes[desk.id] ?? DeskNode(parent: self)
            let previous = old.desks.first { $0.id == desk.id }
            node.place(at: CGFloat(Self.margin + index * Self.slot) * s)
            node.apply(desk, previous: previous, lit: model.lighting != .off, reduceMotion: reduceMotion)
            node.label.isHidden = isCompact
            nodes[desk.id] = node
        }

        layoutDecor()
        layoutLighting()
        CATransaction.commit()
    }

    private func layoutDecor() {
        decor.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard model.lighting == .allOn else { return }
        let s = Self.scale
        let x = CGFloat(Self.margin + model.desks.count * Self.slot + 4) * s
        let plant = sprite(Props.plant(), x: x, y: CGFloat(Self.wallHeight - 16 + 2) * s, w: 10, h: 16)
        let coffee = sprite(Props.coffeeMachine(), x: x + 12 * s, y: CGFloat(Self.wallHeight - 14 + 1) * s, w: 10, h: 14)
        decor.addSublayer(plant)
        decor.addSublayer(coffee)
    }

    /// 0 worktrees: dark and empty. 1: only that desk's lamp. 2+: all lights on (PLAN §9.2).
    private func layoutLighting() {
        let s = Self.scale
        darkness.frame = bounds
        closedSign.isHidden = model.lighting != .off || isCompact
        closedSign.frame = CGRect(x: 12, y: (bounds.height - 16) / 2, width: 120, height: 16)
        switch model.lighting {
        case .allOn:
            darkness.isHidden = true
        case .off:
            darkness.isHidden = false
            darkness.path = CGPath(rect: bounds, transform: nil)
        case .singleDesk:
            darkness.isHidden = false
            let path = CGMutablePath()
            path.addRect(bounds)
            let cx = CGFloat(Self.margin + Self.slot / 2) * s
            path.addEllipse(in: CGRect(x: cx - 21 * s, y: 2 * s, width: 42 * s, height: 44 * s))
            darkness.path = path
        }
    }

    // MARK: Pausing

    /// Freezes all animations (hidden/occluded window, Reduce Motion) without losing their phase.
    public var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                let paused = convertTime(CACurrentMediaTime(), from: nil)
                speed = 0
                timeOffset = paused
            } else {
                let paused = timeOffset
                speed = 1
                timeOffset = 0
                beginTime = 0
                beginTime = convertTime(CACurrentMediaTime(), from: nil) - paused
            }
        }
    }

    // MARK: Hit testing

    public func deskID(at point: CGPoint) -> UUID? {
        let slotWidth = CGFloat(Self.slot) * Self.scale
        let x = point.x - CGFloat(Self.margin) * Self.scale
        guard x >= 0 else { return nil }
        let index = Int(x / slotWidth)
        return model.desks.indices.contains(index) ? model.desks[index].id : nil
    }

    public func deskRect(at index: Int) -> CGRect {
        let s = Self.scale
        return CGRect(x: CGFloat(Self.margin + index * Self.slot) * s, y: 0, width: CGFloat(Self.slot) * s, height: bounds.height)
    }
}

func sprite(_ image: CGImage?, x: CGFloat, y: CGFloat, w: Int, h: Int) -> CALayer {
    let layer = CALayer()
    layer.contents = image
    layer.magnificationFilter = .nearest
    layer.minificationFilter = .nearest
    layer.frame = CGRect(x: x, y: y, width: CGFloat(w) * OfficeLayer.scale, height: CGFloat(h) * OfficeLayer.scale)
    return layer
}

/// The layers of one desk: lamp, glow, chair, person, desk, bubble and name.
final class DeskNode {
    let root = CALayer()
    let glow = CAGradientLayer()
    let lamp = CALayer(), chair = CALayer(), person = CALayer(), desk = CALayer(), bubble = CALayer()
    let label = CATextLayer()
    let bolt = CALayer()

    init(parent: CALayer) {
        let s = OfficeLayer.scale
        func setup(_ l: CALayer, x: Int, y: Int, w: Int, h: Int) {
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
            l.frame = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s)
        }
        glow.type = .radial
        glow.colors = [CGColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 0.55), CGColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        setup(glow, x: -2, y: 2, w: 38, h: 38)
        setup(lamp, x: 12, y: 0, w: Props.lampWidth, h: Props.lampHeight)
        setup(chair, x: 9, y: 19, w: Props.chairWidth, h: Props.chairHeight)
        setup(person, x: 8, y: 12, w: CharacterSprite.width, h: CharacterSprite.height)
        setup(desk, x: 3, y: 30, w: Props.deskWidth, h: Props.deskHeight)
        setup(bubble, x: 23, y: 6, w: Props.bubbleSize, h: Props.bubbleSize)
        setup(bolt, x: 1, y: 24, w: Props.boltWidth, h: Props.boltHeight)
        chair.contents = Props.chair()
        label.fontSize = 9
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        label.foregroundColor = CGColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 0.95)
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = 2
        label.frame = CGRect(x: 0, y: CGFloat(OfficeLayer.wallHeight + 1) * s, width: CGFloat(OfficeLayer.slot) * s, height: 14)
        [glow, lamp, chair, person, desk, bubble, label, bolt].forEach(root.addSublayer)
        root.frame = CGRect(x: 0, y: 0, width: CGFloat(OfficeLayer.slot) * s, height: OfficeLayer.openHeight)
        parent.addSublayer(root)
        root.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.4
        root.add(fade, forKey: "appear")
        root.opacity = 1
    }

    func place(at x: CGFloat) {
        root.frame.origin = CGPoint(x: x, y: 0)
    }

    func apply(_ model: DeskModel, previous: DeskModel?, lit: Bool, reduceMotion: Bool) {
        label.string = model.name
        lamp.contents = Props.lamp(on: lit)
        bolt.isHidden = model.warning == nil
        if let warning = model.warning { bolt.contents = Props.bolt(conflict: warning == .conflict) }
        glow.isHidden = !lit
        guard previous?.state != model.state || previous?.look != model.look || person.contents == nil else { return }

        let animation = CharacterSprite.animation(for: model.state)
        let frames = animation?.poses.compactMap { SpriteCache.character($0, look: model.look) } ?? []
        person.removeAllAnimations()
        person.contents = animation == nil ? SpriteCache.jacket(look: model.look) : frames.last
        person.opacity = model.state == .unknown ? 0.5 : 1
        desk.contents = Props.desk(glow: model.state == .working, closed: model.state == .dead)
        if let animation, frames.count > 1, !reduceMotion {
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.values = frames
            anim.calculationMode = .discrete
            anim.duration = Double(frames.count) / animation.fps
            // Celebrate a few times, then sit back (the static contents are the last frame).
            anim.repeatCount = model.state == .done ? 3 : .infinity
            anim.isRemovedOnCompletion = true
            person.add(anim, forKey: "frames")
        }

        bubble.removeAllAnimations()
        if let kind = Props.bubble(for: model.state) {
            bubble.isHidden = false
            bubble.contents = Props.bubble(kind)
            if kind == .alert, !reduceMotion {
                let bounce = CABasicAnimation(keyPath: "position.y")
                bounce.byValue = -2 * OfficeLayer.scale
                bounce.duration = 0.35
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bubble.add(bounce, forKey: "bounce")
            }
        } else {
            bubble.isHidden = true
        }
    }

    func remove() {
        root.removeFromSuperlayer()
    }
}

enum SpriteCache {
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]

    static func jacket(look: CharacterLook) -> CGImage? {
        let key = "jacket-\(look.shirt)"
        if let cached = images[key] { return cached }
        let image = CharacterSprite.jacket(look: look).image(palette: look.palette)
        images[key] = image
        return image
    }

    static func character(_ pose: Pose, look: CharacterLook) -> CGImage? {
        let key = "\(pose)-\(look.skin)-\(look.hair)-\(look.hairStyle)-\(look.shirt)"
        if let cached = images[key] { return cached }
        let image = CharacterSprite.canvas(pose, look: look).image(palette: look.palette)
        images[key] = image
        return image
    }
}

/// A still picture of an office, for places that must be plain images (the sidebar): Core
/// Animation layers inside an NSView escape SwiftUI's clipping while the sidebar animates.
public enum OfficeSnapshot {
    /// Renders `model` at one point per art pixel (the compact size), at `scale` pixels per point.
    @MainActor
    public static func image(_ model: OfficeModel, desks: Int, scale: CGFloat = 2) -> CGImage? {
        let layer = OfficeLayer()
        layer.isCompact = true
        let width = OfficeLayer.preferredWidth(desks: max(desks, 1)), height = OfficeLayer.openHeight
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        layer.update(model, reduceMotion: true)
        let zoom = scale / OfficeLayer.scale
        let pw = Int((width * zoom).rounded()), ph = Int((height * zoom).rounded())
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // The layer lays out top-down; flip into Core Graphics' bottom-up space.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: zoom, y: -zoom)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
