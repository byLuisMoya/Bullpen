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

/// Core Animation scene for one office: a back wall with windows, a wooden floor and one
/// workstation per worktree, each on a floor zone tinted by the agent's state. Sprite animations
/// run in the render server, so a visible office costs almost no CPU; `isPaused` freezes
/// everything when nobody is looking.
public final class OfficeLayer: CALayer {
    /// Points per art pixel.
    public static let scale: CGFloat = 3
    static let slot = 34, margin = 8, wallHeight = 20, floorHeight = 42, decorWidth = 34
    /// Every office has at least this many desks; the ones without a worktree stand empty.
    public static let minimumDesks = 4
    public static var openHeight: CGFloat { CGFloat(wallHeight + floorHeight) * scale }

    public private(set) var model = OfficeModel(desks: [])
    private var nodes: [UUID: DeskNode] = [:]
    private let wall = CALayer(), floorLayer = CALayer(), darkness = CAShapeLayer()
    private let decor = CALayer(), closedSign = CATextLayer()
    /// Furnished desks nobody uses yet, so even a closed office reads as an office.
    private var vacant: [CALayer] = []
    private var room: (width: Int, boardSlot: Int) = (0, 0)
    private var reduceMotion = false

    public override init() {
        super.init()
        isGeometryFlipped = true
        masksToBounds = true
        [wall, floorLayer].forEach {
            $0.magnificationFilter = .nearest
            $0.minificationFilter = .nearest
        }
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
        CGFloat(margin * 2 + slots(desks) * slot + decorWidth) * scale
    }

    /// Desks drawn for `desks` worktrees, counting the empty ones.
    static func slots(_ desks: Int) -> Int { max(desks, minimumDesks) }

    /// Same for every office: a closed one is the full room with the lights off, not a strip.
    public static func preferredHeight(desks: Int) -> CGFloat { openHeight }

    /// Mini version for the sidebar: drawn at 1 point per art pixel, without names.
    public var isCompact = false

    public func update(_ model: OfficeModel, reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        let old = self.model
        self.model = model
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layoutRoom()

        // Desks: keep existing nodes so running animations are not restarted for no reason.
        let ids = Set(model.desks.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            node.remove()
            nodes[id] = nil
        }
        for (index, desk) in model.desks.enumerated() {
            let node = nodes[desk.id] ?? DeskNode(parent: self)
            let previous = old.desks.first { $0.id == desk.id }
            node.place(at: Self.slotX(index))
            node.apply(desk, previous: previous, lit: model.lighting != .off, reduceMotion: reduceMotion)
            node.label.isHidden = isCompact
            nodes[desk.id] = node
        }
        layoutVacantDesks()

        layoutDecor()
        layoutLighting()
        CATransaction.commit()
    }

    static func slotX(_ index: Int) -> CGFloat { CGFloat(margin + index * slot) * scale }

    /// Wall and floor art, redrawn only when the office changes width.
    private func layoutRoom() {
        let s = Self.scale
        let width = max(Int((bounds.width / s).rounded(.up)), 1)
        wall.frame = CGRect(x: 0, y: 0, width: CGFloat(width) * s, height: CGFloat(Self.wallHeight) * s)
        floorLayer.frame = CGRect(x: 0, y: CGFloat(Self.wallHeight) * s, width: CGFloat(width) * s, height: CGFloat(Self.floorHeight) * s)
        let boardSlot = Self.slots(model.desks.count)
        guard width != room.width || boardSlot != room.boardSlot else { return }
        room = (width, boardSlot)
        let windows = max((width - Self.margin * 2) / Self.slot, 1)
        wall.contents = Props.wall(width: width, height: Self.wallHeight, windows: windows, skipping: boardSlot, margin: Self.margin, slot: Self.slot)
        floorLayer.contents = Props.floor(width: width, height: Self.floorHeight)
    }

    private func layoutVacantDesks() {
        let wanted = Self.slots(model.desks.count) - model.desks.count
        while vacant.count < wanted {
            let layer = CALayer()
            DeskNode.furnish(layer, lit: false)
            insertSublayer(layer, below: darkness)
            vacant.append(layer)
        }
        while vacant.count > wanted { vacant.removeLast().removeFromSuperlayer() }
        for (i, layer) in vacant.enumerated() {
            layer.frame = CGRect(x: Self.slotX(model.desks.count + i), y: 0, width: CGFloat(Self.slot) * Self.scale, height: Self.openHeight)
        }
    }

    /// Cork board on the wall, a plant and a water cooler after the last desk.
    private func layoutDecor() {
        decor.sublayers?.forEach { $0.removeFromSuperlayer() }
        let s = Self.scale
        let x = Self.slotX(Self.slots(model.desks.count)) + 2 * s
        decor.addSublayer(sprite(Props.board(), x: x + 4 * s, y: 3 * s, w: Props.boardWidth, h: Props.boardHeight))
        decor.addSublayer(sprite(Props.plant(), x: x, y: 31 * s, w: Props.plantWidth, h: Props.plantHeight))
        decor.addSublayer(sprite(Props.waterCooler(), x: x + 17 * s, y: 29 * s, w: Props.coolerWidth, h: Props.coolerHeight))
    }

    /// 0 worktrees: dark, with nobody at the empty desks. 1: only that desk's lamp. 2+: all lights on (PLAN §9.2).
    private func layoutLighting() {
        let s = Self.scale
        darkness.frame = bounds
        closedSign.isHidden = model.lighting != .off || isCompact
        closedSign.frame = CGRect(x: 12, y: 8, width: 120, height: 16)
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
            let cx = Self.slotX(0) + CGFloat(Self.slot / 2) * s
            path.addEllipse(in: CGRect(x: cx - 24 * s, y: 12 * s, width: 48 * s, height: 50 * s))
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

/// The layers of one desk: floor zone, chair, person, desk, laptop, lamp, mug, bubble and name.
final class DeskNode {
    let root = CALayer()
    let zone = CALayer(), glow = CAGradientLayer()
    let chair = CALayer(), person = CALayer(), desk = CALayer(), laptop = CALayer(), lamp = CALayer(), mug = CALayer()
    let bubble = CALayer(), bolt = CALayer()
    let label = CATextLayer()

    static func setup(_ l: CALayer, x: Int, y: Int, w: Int, h: Int) {
        let s = OfficeLayer.scale
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.frame = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s)
    }

    // Positions inside the slot, in art pixels. The person's last row sits on the desk top.
    static let personY = 22, deskY = 41

    /// Static furniture of a workstation without anybody (also used for the closed office).
    static func furnish(_ layer: CALayer, lit: Bool) {
        layer.addSublayer(sprite(Props.chair(), x: 6 * OfficeLayer.scale, y: 27 * OfficeLayer.scale, w: Props.chairWidth, h: Props.chairHeight))
        layer.addSublayer(sprite(Props.desk(), x: 1 * OfficeLayer.scale, y: CGFloat(deskY) * OfficeLayer.scale, w: Props.deskWidth, h: Props.deskHeight))
        layer.addSublayer(sprite(Props.laptop(glow: false, closed: true), x: 11 * OfficeLayer.scale, y: 36 * OfficeLayer.scale, w: Props.laptopWidth, h: Props.laptopHeight))
        layer.addSublayer(sprite(Props.lamp(on: lit), x: 0, y: 29 * OfficeLayer.scale, w: Props.lampWidth, h: Props.lampHeight))
        layer.addSublayer(sprite(Props.mug(), x: 25 * OfficeLayer.scale, y: 37 * OfficeLayer.scale, w: Props.mugWidth, h: Props.mugHeight))
    }

    init(parent: CALayer) {
        let s = OfficeLayer.scale
        zone.borderWidth = s
        Self.setup(zone, x: 1, y: 22, w: OfficeLayer.slot - 2, h: OfficeLayer.floorHeight - 2)
        glow.type = .radial
        glow.colors = [CGColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 0.5), CGColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        Self.setup(glow, x: -10, y: 18, w: 30, h: 30)
        Self.setup(chair, x: 6, y: 27, w: Props.chairWidth, h: Props.chairHeight)
        Self.setup(person, x: 5, y: Self.personY, w: CharacterSprite.width, h: CharacterSprite.height)
        Self.setup(desk, x: 1, y: Self.deskY, w: Props.deskWidth, h: Props.deskHeight)
        Self.setup(laptop, x: 11, y: 36, w: Props.laptopWidth, h: Props.laptopHeight)
        Self.setup(lamp, x: 0, y: 29, w: Props.lampWidth, h: Props.lampHeight)
        Self.setup(mug, x: 25, y: 37, w: Props.mugWidth, h: Props.mugHeight)
        Self.setup(bubble, x: 21, y: 12, w: Props.bubbleSize, h: Props.bubbleSize)
        Self.setup(bolt, x: 0, y: 17, w: Props.boltWidth, h: Props.boltHeight)
        chair.contents = Props.chair()
        desk.contents = Props.desk()
        mug.contents = Props.mug()
        label.fontSize = 9
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        label.foregroundColor = CGColor(srgbRed: 0.2, green: 0.15, blue: 0.12, alpha: 0.95)
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = 2
        label.frame = CGRect(x: 0, y: CGFloat(Self.deskY + Props.deskHeight) * s, width: CGFloat(OfficeLayer.slot) * s, height: 14)
        // The person sits behind the desk but is drawn over it: their sprite stops at the desk
        // top, so only the arms resting on it overlap. Laptop, lamp and mug are in front of them.
        [zone, glow, chair, desk, person, laptop, lamp, mug, label, bubble, bolt].forEach(root.addSublayer)
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

    /// Floor zone colour per state, like the coloured desk areas of a team map.
    static func zoneColor(_ state: AgentState) -> (CGColor, CGColor) {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch state {
        case .working, .starting: rgb = (0.35, 0.55, 0.95)
        case .thinking: rgb = (0.62, 0.45, 0.92)
        case .needsYou: rgb = (1.0, 0.55, 0.25)
        case .done: rgb = (0.3, 0.75, 0.45)
        case .error: rgb = (0.9, 0.3, 0.3)
        case .idle, .unknown, .dead: rgb = (0.55, 0.55, 0.6)
        }
        return (CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.2),
                CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.55))
    }

    func apply(_ model: DeskModel, previous: DeskModel?, lit: Bool, reduceMotion: Bool) {
        label.string = model.name
        lamp.contents = Props.lamp(on: lit)
        glow.isHidden = !lit
        bolt.isHidden = model.warning == nil
        if let warning = model.warning { bolt.contents = Props.bolt(conflict: warning == .conflict) }
        let (fill, border) = Self.zoneColor(model.state)
        zone.backgroundColor = fill
        zone.borderColor = border
        guard previous?.state != model.state || previous?.look != model.look || person.contents == nil else { return }

        let animation = CharacterSprite.animation(for: model.state)
        let frames = animation?.poses.compactMap { SpriteCache.character($0, look: model.look) } ?? []
        person.removeAllAnimations()
        person.contents = animation == nil ? SpriteCache.jacket(look: model.look) : frames.last
        person.opacity = model.state == .unknown ? 0.5 : 1
        laptop.contents = Props.laptop(glow: model.state == .working, closed: model.state == .dead)
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
    /// `width` (in those points) widens the room to fill the space it is shown in.
    @MainActor
    public static func image(_ model: OfficeModel, desks: Int, width fill: CGFloat? = nil, scale: CGFloat = 2) -> CGImage? {
        let layer = OfficeLayer()
        layer.isCompact = true
        let natural = OfficeLayer.preferredWidth(desks: desks)
        let width = max(natural, (fill ?? 0) * OfficeLayer.scale).rounded(), height = OfficeLayer.openHeight
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
