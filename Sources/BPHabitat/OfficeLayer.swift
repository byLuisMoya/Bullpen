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
    /// Waiting with nothing to do for a while: the person has left their jacket and gone.
    public var away: Bool

    public init(id: UUID, name: String, state: AgentState, detail: String? = nil, look: CharacterLook, warning: DeskWarning? = nil,
                away: Bool = false) {
        self.away = away
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
/// workstation per worktree, its branch on a name card under the desk. Sprite animations
/// run in the render server, so a visible office costs almost no CPU; `isPaused` freezes
/// everything when nobody is looking.
public final class OfficeLayer: CALayer {
    /// Points per art pixel.
    public static let scale: CGFloat = 3
    static let slot = 34, margin = 8, wallHeight = 20, floorHeight = 48, decorWidth = 34
    /// Every office has at least this many desks; the ones without a worktree stand empty.
    public static let minimumDesks = 4
    public static var openHeight: CGFloat { CGFloat(wallHeight + floorHeight) * scale }

    public private(set) var model = OfficeModel(desks: [])
    private var nodes: [UUID: DeskNode] = [:]
    private let wall = CALayer(), floorLayer = CALayer(), darkness = CAShapeLayer()
    private let decor = CALayer(), closedSign = CATextLayer()
    /// One pendant lamp per desk slot, and the cones of light under the lit ones.
    private var lamps: [CALayer] = []
    private let beams = CALayer(), penumbra = CAShapeLayer()
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
        penumbra.fillColor = CGColor(srgbRed: 0.05, green: 0.06, blue: 0.14, alpha: 0.4)
        penumbra.fillRule = .evenOdd
        penumbra.zPosition = 10
        beams.zPosition = 9
        closedSign.string = "cerrado"
        closedSign.fontSize = 11
        closedSign.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        closedSign.foregroundColor = CGColor(srgbRed: 0.75, green: 0.78, blue: 0.9, alpha: 0.8)
        closedSign.alignmentMode = .left
        closedSign.zPosition = 11
        closedSign.contentsScale = 2
        [wall, floorLayer, decor, beams, darkness, penumbra, closedSign].forEach(addSublayer)
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
            node.apply(desk, previous: previous, reduceMotion: reduceMotion)
            node.card.isHidden = isCompact
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
            DeskNode.furnish(layer)
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
        decor.addSublayer(sprite(Props.plant(), x: x - s, y: 34 * s, w: Props.plantWidth, h: Props.plantHeight))
        decor.addSublayer(sprite(Props.waterCooler(), x: x + 17 * s, y: 33 * s, w: Props.coolerWidth, h: Props.coolerHeight))
    }

    /// Ceiling lamps over every desk (PLAN §9.2). 0 worktrees: all off, the room in the dark.
    /// 1: only that desk's lamp, a lonely cone of light in a dark room. 2+: every lamp on and
    /// the whole room lit.
    private func layoutLighting() {
        let s = Self.scale
        let slots = Self.slots(model.desks.count)
        while lamps.count < slots {
            let lamp = CALayer()
            lamp.magnificationFilter = .nearest
            lamp.minificationFilter = .nearest
            addSublayer(lamp)
            lamps.append(lamp)
        }
        while lamps.count > slots { lamps.removeLast().removeFromSuperlayer() }
        let lit = (0..<slots).map { model.lighting == .allOn || (model.lighting == .singleDesk && $0 == 0) }
        for (i, lamp) in lamps.enumerated() {
            lamp.contents = Props.ceilingLamp(on: lit[i])
            lamp.frame = CGRect(x: Self.slotX(i) + 10 * s, y: 0, width: CGFloat(Props.ceilingLampWidth) * s,
                                height: CGFloat(Props.ceilingLampHeight) * s)
            // A lit lamp shines above the darkness; an unlit one sits in it.
            lamp.zPosition = lit[i] ? 11 : 9
        }

        beams.frame = bounds
        beams.sublayers?.forEach { $0.removeFromSuperlayer() }
        let strength: CGFloat = model.lighting == .singleDesk ? 1 : 0.45
        for i in 0..<slots where lit[i] {
            let beam = CAGradientLayer()
            beam.frame = bounds
            beam.colors = [CGColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 0.42 * strength),
                           CGColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 0.1 * strength)]
            let top = CGFloat(Props.ceilingLampHeight - 2) * s / bounds.height, bottom = Self.openHeight / bounds.height
            beam.startPoint = CGPoint(x: 0.5, y: top)
            beam.endPoint = CGPoint(x: 0.5, y: bottom)
            let mask = CAShapeLayer()
            mask.path = cone(slot: i, spread: 0)
            beam.mask = mask
            beams.addSublayer(beam)
        }

        darkness.frame = bounds
        penumbra.frame = bounds
        closedSign.isHidden = model.lighting != .off || isCompact
        closedSign.frame = CGRect(x: 12, y: 8, width: 120, height: 16)
        switch model.lighting {
        case .allOn:
            darkness.isHidden = true
            penumbra.isHidden = true
        case .off:
            darkness.isHidden = false
            penumbra.isHidden = true
            darkness.path = CGPath(rect: bounds, transform: nil)
        case .singleDesk:
            // Dark everywhere but the cone, with a softer band along its edges.
            let outer = cone(slot: 0, spread: 4)
            let dark = CGMutablePath()
            dark.addRect(bounds)
            dark.addPath(outer)
            darkness.path = dark
            darkness.isHidden = false
            let band = CGMutablePath()
            band.addPath(outer)
            band.addPath(cone(slot: 0, spread: 0))
            penumbra.path = band
            penumbra.isHidden = false
        }
    }

    /// The cone of light under slot `slot`'s lamp: narrow at the shade, as wide as the desk on
    /// the floor. `spread` widens it (art pixels), for the soft edge.
    private func cone(slot: Int, spread: CGFloat) -> CGPath {
        let s = Self.scale, x0 = Self.slotX(slot)
        let top = CGFloat(Props.ceilingLampHeight - 2) * s
        let bottom = CGFloat(Self.wallHeight + Self.floorHeight - 4) * s + spread * s
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0 + (13 - spread / 4) * s, y: top))
        path.addLine(to: CGPoint(x: x0 + (21 + spread / 4) * s, y: top))
        path.addLine(to: CGPoint(x: x0 + (34 + spread) * s, y: bottom))
        path.addLine(to: CGPoint(x: x0 - spread * s, y: bottom))
        path.closeSubpath()
        return path
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

/// The layers of one desk: chair, person, desk, monitor, plant, mug, notepad, bubble and name card.
final class DeskNode {
    let root = CALayer()
    let chair = CALayer(), person = CALayer(), desk = CALayer(), monitor = CALayer(), plant = CALayer()
    let mug = CALayer(), notepad = CALayer()
    let bubble = CALayer(), bolt = CALayer()
    /// Black pixel-art card under the desk with the branch name in white.
    let card = CALayer(), label = CATextLayer()

    static func setup(_ l: CALayer, x: Int, y: Int, w: Int, h: Int) {
        let s = OfficeLayer.scale
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.frame = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s)
    }

    // Positions inside the slot, in art pixels. The person's last row sits on the desk top.
    static let personY = 22, deskY = 41

    /// Static furniture of a workstation without anybody (also used for the closed office).
    static func furnish(_ layer: CALayer) {
        layer.addSublayer(sprite(Props.chair(), x: 6 * OfficeLayer.scale, y: 26 * OfficeLayer.scale, w: Props.chairWidth, h: Props.chairHeight))
        layer.addSublayer(sprite(Props.desk(), x: 1 * OfficeLayer.scale, y: CGFloat(deskY) * OfficeLayer.scale, w: Props.deskWidth, h: Props.deskHeight))
        layer.addSublayer(sprite(Props.monitor(on: false, glow: false), x: 9 * OfficeLayer.scale, y: 37 * OfficeLayer.scale, w: Props.monitorWidth, h: Props.monitorHeight))
        layer.addSublayer(sprite(Props.deskPlant(), x: 23 * OfficeLayer.scale, y: 35 * OfficeLayer.scale, w: Props.deskPlantWidth, h: Props.deskPlantHeight))
        layer.addSublayer(sprite(Props.mug(), x: 23 * OfficeLayer.scale, y: 47 * OfficeLayer.scale, w: Props.mugWidth, h: Props.mugHeight))
        layer.addSublayer(sprite(Props.notepad(), x: 4 * OfficeLayer.scale, y: 47 * OfficeLayer.scale, w: Props.notepadWidth, h: Props.notepadHeight))
    }

    init(parent: CALayer) {
        let s = OfficeLayer.scale
        Self.setup(chair, x: 6, y: 26, w: Props.chairWidth, h: Props.chairHeight)
        Self.setup(person, x: 5, y: Self.personY, w: CharacterSprite.width, h: CharacterSprite.height)
        Self.setup(desk, x: 1, y: Self.deskY, w: Props.deskWidth, h: Props.deskHeight)
        Self.setup(monitor, x: 9, y: 37, w: Props.monitorWidth, h: Props.monitorHeight)
        Self.setup(plant, x: 23, y: 35, w: Props.deskPlantWidth, h: Props.deskPlantHeight)
        Self.setup(mug, x: 23, y: 47, w: Props.mugWidth, h: Props.mugHeight)
        Self.setup(notepad, x: 4, y: 47, w: Props.notepadWidth, h: Props.notepadHeight)
        Self.setup(bubble, x: 21, y: 12, w: Props.bubbleSize, h: Props.bubbleSize)
        Self.setup(bolt, x: 0, y: 17, w: Props.boltWidth, h: Props.boltHeight)
        chair.contents = Props.chair()
        desk.contents = Props.desk()
        plant.contents = Props.deskPlant()
        mug.contents = Props.mug()
        notepad.contents = Props.notepad()
        Self.setup(card, x: 1, y: Self.deskY + Props.deskHeight - 1, w: OfficeLayer.slot - 2, h: Props.nameCardHeight)
        card.contents = Props.nameCard(width: OfficeLayer.slot - 2)
        label.fontSize = 10
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.foregroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        label.alignmentMode = .center
        label.truncationMode = .end
        label.isWrapped = false
        label.contentsScale = 2
        label.frame = CGRect(x: 2 * s, y: (card.bounds.height - 13) / 2, width: card.bounds.width - 4 * s, height: 13)
        card.addSublayer(label)
        // The person sits behind the desk but is drawn over it: their sprite stops at the desk
        // top, so only the arms resting on it overlap. Everything on the desk is in front of them.
        [chair, desk, person, monitor, plant, mug, notepad, card, bubble, bolt].forEach(root.addSublayer)
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

    func apply(_ model: DeskModel, previous: DeskModel?, reduceMotion: Bool) {
        label.string = model.name
        bolt.isHidden = model.warning == nil
        if let warning = model.warning { bolt.contents = Props.bolt(conflict: warning == .conflict) }
        guard previous?.state != model.state || previous?.look != model.look || previous?.away != model.away
                || person.contents == nil else { return }

        // Away (idle for a while) or not running: only the jacket on the chair is left.
        let animation = model.away ? nil : CharacterSprite.animation(for: model.state)
        let frames = animation?.poses.compactMap { SpriteCache.character($0, look: model.look) } ?? []
        person.removeAllAnimations()
        person.contents = animation == nil ? SpriteCache.jacket(look: model.look) : frames.last
        person.opacity = model.state == .unknown ? 0.5 : 1
        monitor.contents = Props.monitor(on: model.state != .dead, glow: model.state == .working)
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
        if !model.away, let kind = Props.bubble(for: model.state) {
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
        let key = "jacket-\(look.jacket)-\(look.lining)"
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
