import BPCore
import QuartzCore
import AppKit

/// One person at a desk = one worktree.
public struct DeskModel: Equatable, Sendable, Identifiable {
    /// What hovering the desk says: the full branch (and ticket), then what the agent is doing.
    public var tooltip: String {
        let title = branch.map { $0 == name ? $0 : "\(name) · \($0)" } ?? name
        return [title, detail].compactMap { $0 }.joined(separator: "\n")
    }

    public var id: UUID
    public var name: String
    public var state: AgentState
    public var detail: String?
    public var look: CharacterLook
    /// ⚡ on the desk: this worktree overlaps (yellow) or conflicts (red) with another one.
    public var warning: DeskWarning?
    /// Waiting with nothing to do for a while: the person has left their jacket and gone.
    public var away: Bool
    /// What they are doing, in a few words, for the speech card over their head.
    public var summary: String?
    /// Finished turns so far: sticky notes from 3, books from 6.
    public var turns: Int
    /// Its PR was merged: a beer on the desk.
    public var merged: Bool
    /// The full branch, for the tooltip (the card under the desk cuts it short).
    public var branch: String?

    public init(id: UUID, name: String, state: AgentState, detail: String? = nil, look: CharacterLook, warning: DeskWarning? = nil,
                away: Bool = false, summary: String? = nil, turns: Int = 0, merged: Bool = false, branch: String? = nil) {
        self.branch = branch
        self.turns = turns
        self.merged = merged
        self.away = away
        self.summary = summary
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
    /// The project's office style.
    public var theme: OfficeTheme
    public var lighting: OfficeLighting { OfficeLighting(activeWorktrees: desks.count) }

    public init(desks: [DeskModel], theme: OfficeTheme = .basic) {
        self.desks = desks
        self.theme = theme
    }
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
    private var room: (width: Int, boardSlot: Int, theme: OfficeTheme) = (0, 0, .basic)
    /// Cubicle panels or bars between desks, for themes that have them.
    private let partitions = CALayer()
    private var vacantTheme: OfficeTheme = .basic
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
        [wall, floorLayer, decor, partitions, beams, darkness, penumbra, closedSign].forEach(addSublayer)
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
    /// People walking in or out, in front of the desks.
    let walkers = CALayer()
    /// Someone is walking in or out right now: the scene must keep running until they arrive.
    public var isWalking: Bool { !(walkers.sublayers?.isEmpty ?? true) }
    /// Called when the last walker has arrived (the view may pause the scene again).
    public var onWalksFinished: (() -> Void)?
    /// The first update draws the office as it is; only later changes are walked.
    private var hasRendered = false

    public func update(_ model: OfficeModel, reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        let old = self.model
        self.model = model
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layoutRoom()

        if walkers.superlayer == nil {
            walkers.zPosition = 5
            addSublayer(walkers)
        }
        let walks = hasRendered && !reduceMotion && !isCompact

        // Desks: keep existing nodes so running animations are not restarted for no reason.
        let ids = Set(model.desks.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            if walks, let index = old.desks.firstIndex(where: { $0.id == id }), !old.desks[index].away, old.desks[index].state != .dead {
                walk(look: old.desks[index].look, slot: index, entering: false)
            }
            node.remove()
            nodes[id] = nil
        }
        for (index, desk) in model.desks.enumerated() {
            let isNew = nodes[desk.id] == nil
            let node = nodes[desk.id] ?? DeskNode(parent: self)
            let previous = old.desks.first { $0.id == desk.id }
            node.place(at: Self.slotX(index))
            node.compact = isCompact
            node.setTheme(model.theme, state: desk.state)
            node.apply(desk, previous: previous, reduceMotion: reduceMotion)
            node.card.isHidden = isCompact
            nodes[desk.id] = node
            guard walks, desk.state != .dead else { continue }
            let present = !desk.away, wasPresent = isNew ? false : !(previous?.away ?? true) && previous?.state != .dead
            if present, !wasPresent {
                let arrival = walk(look: desk.look, slot: index, entering: true)
                node.revealPerson(after: arrival)
            } else if !present, wasPresent {
                // Nothing to do for a while: out for a smoke.
                walk(look: desk.look, slot: index, entering: false, smoking: true)
            }
        }
        hasRendered = true
        layoutVacantDesks()

        layoutDecor()
        layoutLighting()
        CATransaction.commit()
    }

    static func slotX(_ index: Int) -> CGFloat { CGFloat(margin + index * slot) * scale }

    /// Walks someone along the front of the office between the right-hand edge and their desk.
    /// Returns how long it takes.
    @discardableResult
    private func walk(look: CharacterLook, slot index: Int, entering: Bool, smoking: Bool = false) -> CFTimeInterval {
        let s = Self.scale
        // The door is on the right: coming in they walk left, going out they walk right.
        let frames = [0, 1].compactMap { SpriteCache.walking($0, look: look, leftwards: entering, smoking: smoking) }
        let walker = CALayer()
        walker.magnificationFilter = .nearest
        walker.minificationFilter = .nearest
        walker.anchorPoint = .zero
        walker.bounds = CGRect(x: 0, y: 0, width: CGFloat(CharacterSprite.width) * s, height: CGFloat(CharacterSprite.walkHeight) * s)
        walker.contents = frames.first
        let desk = Self.slotX(index) + 5 * s, door = bounds.width + 2 * s
        let y = CGFloat(Self.wallHeight + Self.floorHeight - CharacterSprite.walkHeight - 1) * s
        let (from, to) = entering ? (door, desk) : (desk, door)
        walker.position = CGPoint(x: to, y: y)
        let duration = min(max(abs(door - desk) / (45 * s), 0.6), 3.5)

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = from
        move.toValue = to
        move.duration = duration
        let steps = CAKeyframeAnimation(keyPath: "contents")
        steps.values = frames
        steps.calculationMode = .discrete
        steps.duration = 0.32
        // Only for the walk: an endless animation would keep the walker (and its completion) alive.
        steps.repeatDuration = duration
        let bob = CABasicAnimation(keyPath: "position.y")
        bob.byValue = -s
        bob.duration = 0.16
        bob.autoreverses = true
        bob.repeatDuration = duration

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            walker.removeFromSuperlayer()
            if self?.isWalking == false { self?.onWalksFinished?() }
        }
        walkers.addSublayer(walker)
        walker.add(move, forKey: "walk")
        walker.add(steps, forKey: "steps")
        walker.add(bob, forKey: "bob")
        CATransaction.commit()
        return duration
    }

    /// Wall and floor art, redrawn only when the office changes width.
    private func layoutRoom() {
        let s = Self.scale
        let width = max(Int((bounds.width / s).rounded(.up)), 1)
        wall.frame = CGRect(x: 0, y: 0, width: CGFloat(width) * s, height: CGFloat(Self.wallHeight) * s)
        floorLayer.frame = CGRect(x: 0, y: CGFloat(Self.wallHeight) * s, width: CGFloat(width) * s, height: CGFloat(Self.floorHeight) * s)
        let boardSlot = Self.slots(model.desks.count)
        guard width != room.width || boardSlot != room.boardSlot || model.theme != room.theme else { return }
        room = (width, boardSlot, model.theme)
        let windows = max((width - Self.margin * 2) / Self.slot, 1)
        wall.contents = Props.wall(width: width, height: Self.wallHeight, windows: windows, skipping: boardSlot,
                                   margin: Self.margin, slot: Self.slot, theme: model.theme)
        floorLayer.contents = Props.floor(width: width, height: Self.floorHeight, theme: model.theme)
    }

    private func layoutVacantDesks() {
        let wanted = Self.slots(model.desks.count) - model.desks.count
        // Another theme: furnish them again.
        if vacantTheme != model.theme {
            vacant.forEach { $0.removeFromSuperlayer() }
            vacant.removeAll()
            vacantTheme = model.theme
        }
        while vacant.count < wanted {
            let layer = CALayer()
            DeskNode.furnish(layer, theme: model.theme)
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
        let theme = model.theme
        let onWall = Props.decor(theme.wallDecor, theme: theme)
        decor.addSublayer(sprite(onWall.image, x: x + 4 * s, y: CGFloat(max(2, 18 - onWall.height)) * s, w: onWall.width, h: onWall.height))
        // Standing on the floor, bottoms level with the desks' feet.
        var left = x - s
        for item in theme.floorDecor {
            let piece = Props.decor(item, theme: theme)
            decor.addSublayer(sprite(piece.image, x: left, y: CGFloat(Self.wallHeight + Self.floorHeight - 7 - piece.height) * s, w: piece.width, h: piece.height))
            left += CGFloat(piece.width + 1) * s
        }
        layoutPartitions()
    }

    /// Between neighbouring desks (and before the first), for cubicle and prison themes.
    private func layoutPartitions() {
        partitions.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let kind = model.theme.partition else { return }
        let s = Self.scale
        let image = Props.partition(kind, theme: model.theme)
        for boundary in 0...Self.slots(model.desks.count) {
            partitions.addSublayer(sprite(image, x: Self.slotX(boundary) - 3 * s, y: 24 * s, w: Props.partitionWidth, h: Props.partitionHeight))
        }
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
            lamp.contents = Props.ceilingLamp(on: lit[i], theme: model.theme)
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
    /// Things earned with the work done in this worktree.
    let notes = CALayer(), books = CALayer(), beer = CALayer()
    let bubble = CALayer(), bolt = CALayer()
    /// White speech card with the summary, over the head.
    let speech = CALayer(), speechText = CATextLayer()
    /// Black pixel-art card under the desk with the branch name in white.
    let card = CALayer(), label = CATextLayer()

    static let speaks: Set<AgentState> = [.working, .thinking, .done]
    /// Sidebar size: no text on the desks.
    var compact = false

    static func setup(_ l: CALayer, x: Int, y: Int, w: Int, h: Int) {
        let s = OfficeLayer.scale
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.frame = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s)
    }

    // Positions inside the slot, in art pixels. The person's last row sits on the desk top.
    static let personY = 22, deskY = 41

    /// Static furniture of a workstation without anybody (also used for the closed office).
    static func furnish(_ layer: CALayer, theme: OfficeTheme = .basic) {
        let s = OfficeLayer.scale
        layer.addSublayer(sprite(Props.chair(theme: theme), x: 6 * s, y: 26 * s, w: Props.chairWidth, h: Props.chairHeight))
        layer.addSublayer(sprite(Props.desk(theme: theme), x: 1 * s, y: CGFloat(deskY) * s, w: Props.deskWidth, h: Props.deskHeight))
        layer.addSublayer(sprite(Props.monitor(on: false, glow: false, theme: theme), x: 9 * s, y: 37 * s, w: Props.monitorWidth, h: Props.monitorHeight))
        layer.addSublayer(sprite(Props.mug(theme: theme), x: 24 * s, y: 34 * s, w: Props.mugWidth, h: Props.mugHeight))
        layer.addSublayer(sprite(Props.deskPlant(theme: theme), x: 22 * s, y: 43 * s, w: Props.deskPlantWidth, h: Props.deskPlantHeight))
        layer.addSublayer(sprite(Props.notepad(theme: theme), x: 4 * s, y: 47 * s, w: Props.notepadWidth, h: Props.notepadHeight))
    }

    /// The office's style for this desk's furniture.
    private(set) var theme: OfficeTheme = .basic

    func setTheme(_ theme: OfficeTheme, state: AgentState) {
        guard theme != self.theme || desk.contents == nil else { return }
        self.theme = theme
        chair.contents = Props.chair(theme: theme)
        desk.contents = Props.desk(theme: theme)
        plant.contents = Props.deskPlant(theme: theme)
        mug.contents = Props.mug(theme: theme)
        notepad.contents = Props.notepad(theme: theme)
        monitor.contents = Props.monitor(on: state != .dead, glow: state == .working, theme: theme)
    }

    init(parent: CALayer) {
        let s = OfficeLayer.scale
        Self.setup(chair, x: 6, y: 26, w: Props.chairWidth, h: Props.chairHeight)
        Self.setup(person, x: 5, y: Self.personY, w: CharacterSprite.width, h: CharacterSprite.height)
        Self.setup(desk, x: 1, y: Self.deskY, w: Props.deskWidth, h: Props.deskHeight)
        Self.setup(monitor, x: 9, y: 37, w: Props.monitorWidth, h: Props.monitorHeight)
        // Mug at the back by the screen, plant at the front corner.
        Self.setup(mug, x: 24, y: 34, w: Props.mugWidth, h: Props.mugHeight)
        Self.setup(plant, x: 22, y: 43, w: Props.deskPlantWidth, h: Props.deskPlantHeight)
        Self.setup(notepad, x: 4, y: 47, w: Props.notepadWidth, h: Props.notepadHeight)
        Self.setup(bubble, x: 21, y: 12, w: Props.bubbleSize, h: Props.bubbleSize)
        Self.setup(bolt, x: 0, y: 25, w: Props.boltWidth, h: Props.boltHeight)
        chair.contents = Props.chair()
        desk.contents = Props.desk()
        plant.contents = Props.deskPlant()
        Self.setup(notes, x: 10, y: 37, w: Props.notesWidth, h: Props.notesHeight)
        Self.setup(books, x: 1, y: 39, w: Props.booksWidth, h: Props.booksHeight)
        Self.setup(beer, x: 12, y: 43, w: Props.beerWidth, h: Props.beerHeight)
        notes.contents = Props.stickyNotes()
        books.contents = Props.books()
        beer.contents = Props.beer()
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
        Self.setup(speech, x: 1, y: 15, w: OfficeLayer.slot - 2, h: Props.speechCardHeight)
        speech.contents = Props.speechCard(width: OfficeLayer.slot - 2)
        speechText.fontSize = 9
        speechText.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        speechText.foregroundColor = CGColor(srgbRed: 0.16, green: 0.14, blue: 0.2, alpha: 1)
        speechText.alignmentMode = .center
        speechText.truncationMode = .end
        speechText.isWrapped = false
        speechText.contentsScale = 2
        speechText.frame = CGRect(x: 2 * s, y: 4, width: speech.bounds.width - 4 * s, height: 12)
        speech.addSublayer(speechText)
        speech.isHidden = true
        // The person sits behind the desk but is drawn over it: their sprite stops at the desk
        // top, so only the arms resting on it overlap. Everything on the desk is in front of them.
        [chair, desk, person, monitor, notes, mug, books, notepad, beer, plant, card, bubble, speech, bolt].forEach(root.addSublayer)
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
        notes.isHidden = model.turns < 3
        books.isHidden = model.turns < 6
        beer.isHidden = !model.merged
        // The summary replaces the icon bubble while they work, think or have just finished.
        let says = model.away || !Self.speaks.contains(model.state) ? nil : model.summary
        speech.isHidden = says == nil || compact
        speechText.string = says
        bubble.opacity = says == nil ? 1 : 0
        guard previous?.state != model.state || previous?.look != model.look || previous?.away != model.away
                || person.contents == nil else { return }

        // Away (idle for a while) or not running: only the jacket on the chair is left.
        let animation = model.away ? nil : CharacterSprite.animation(for: model.state)
        let frames = animation?.poses.compactMap { SpriteCache.character($0, look: model.look) } ?? []
        person.removeAllAnimations()
        person.contents = animation == nil ? SpriteCache.jacket(look: model.look) : frames.last
        person.opacity = model.state == .unknown ? 0.5 : 1
        monitor.contents = Props.monitor(on: model.state != .dead, glow: model.state == .working, theme: theme)
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

    /// Keeps the seat empty until the person walking in reaches it.
    func revealPerson(after delay: CFTimeInterval) {
        let appear = CAKeyframeAnimation(keyPath: "opacity")
        appear.values = [0, 0, 1]
        appear.keyTimes = [0, NSNumber(value: delay / (delay + 0.2)), 1]
        appear.duration = delay + 0.2
        person.add(appear, forKey: "arrive")
        for layer in [speech, bubble] { layer.add(appear, forKey: "arrive") }
    }
}

enum SpriteCache {
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]

    static func walking(_ frame: Int, look: CharacterLook, leftwards: Bool, smoking: Bool) -> CGImage? {
        let key = "walk\(frame)-\(leftwards)-\(smoking)-\(look.skin)-\(look.hair)-\(look.hairStyle)-\(look.shirt)-\(look.jacket)"
        if let cached = images[key] { return cached }
        let canvas = CharacterSprite.walking(frame: frame, look: look, smoking: smoking)
        let image = (leftwards ? canvas.mirrored() : canvas).image(palette: look.palette)
        images[key] = image
        return image
    }

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
        // The sidebar asks again on every redraw; most of the time nothing in the room changed.
        let key = Key(model: model, desks: desks, width: fill, scale: scale)
        if let hit = cache.first(where: { $0.key == key }) { return hit.image }
        let image = render(model, desks: desks, width: fill, scale: scale)
        if let image {
            cache.removeAll { $0.key.model.desks.map(\.id) == model.desks.map(\.id) && $0.key.width == fill }
            cache.append((key, image))
            if cache.count > 24 { cache.removeFirst(cache.count - 24) }
        }
        return image
    }

    private struct Key: Equatable {
        var model: OfficeModel
        var desks: Int
        var width: CGFloat?
        var scale: CGFloat
    }

    @MainActor private static var cache: [(key: Key, image: CGImage)] = []

    @MainActor
    private static func render(_ model: OfficeModel, desks: Int, width fill: CGFloat?, scale: CGFloat) -> CGImage? {
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
