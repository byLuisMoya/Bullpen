@testable import BPHabitat
import BPCore
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
import UniformTypeIdentifiers

@Suite struct SpriteTests {
    let look = CharacterLook.make(worktreeID: UUID(), agent: "claude")

    @Test func everyPoseDrawsSomethingInsideTheCanvas() throws {
        for pose in Pose.allCases {
            let canvas = CharacterSprite.canvas(pose, look: look)
            #expect(!canvas.isEmpty, "\(pose)")
            #expect(canvas.image(palette: look.palette) != nil)
        }
        #expect(!CharacterSprite.jacket(look: look).isEmpty)
    }

    @Test func jacketsDifferWithinAnOffice() {
        let looks = CharacterLook.distinctJackets((0..<6).map { _ in CharacterLook.make(worktreeID: UUID(), agent: "claude") })
        #expect(Set(looks.map(\.jacketBase)).count == 6)
        // Over many people, tones and linings vary too.
        let many = (0..<200).map { _ in CharacterLook.make(worktreeID: UUID(), agent: "claude") }
        #expect(Set(many.map(\.jacketTone)).count > 1)
        #expect(Set(many.map(\.lining)).count > 1)
    }

    @Test func looksAreDeterministicAndShirtFollowsAgent() {
        let id = UUID()
        #expect(CharacterLook.make(worktreeID: id, agent: "claude") == CharacterLook.make(worktreeID: id, agent: "claude"))
        #expect(CharacterLook.make(worktreeID: id, agent: "codex").shirt != CharacterLook.make(worktreeID: id, agent: "claude").shirt)
    }

    @Test func statesMapToAnimationsAndBubbles() {
        #expect(CharacterSprite.animation(for: .dead) == nil, "empty chair")
        #expect(CharacterSprite.animation(for: .working)?.poses.count == 2)
        #expect(Props.bubble(for: .needsYou) == .alert)
        #expect(Props.bubble(for: .working) == nil)
        for kind in [Props.Bubble.thinking, .alert, .done, .sleep, .error, .unknown] {
            #expect(Props.bubble(kind) != nil)
        }
    }
}

@MainActor
@Suite struct OfficeLayerTests {
    func desks(_ states: [AgentState]) -> [DeskModel] {
        states.enumerated().map { i, state in
            let id = UUID()
            return DeskModel(id: id, name: i == 2 ? "feature/FKPI-1234-una-rama-con-nombre-muy-largo" : "wt-\(i)", state: state, look: .make(worktreeID: id, agent: i % 2 == 0 ? "claude" : "codex"),
                             warning: i == 0 ? .conflict : i == 1 ? .overlap : nil, away: i == 4,
                             summary: i == 0 ? "Arregla el timeout del login" : i == 1 ? "Edita LoginForm.vue" : i == 3 ? "Tests de pagos en verde" : nil,
                             turns: [0, 3, 7, 12, 0, 1, 0, 6][i % 8], merged: i == 3)
        }
    }

    @Test func lightingFollowsDeskCount() {
        #expect(OfficeModel(desks: []).lighting == .off)
        #expect(OfficeModel(desks: desks([.working])).lighting == .singleDesk)
        #expect(OfficeModel(desks: desks([.working, .idle])).lighting == .allOn)
        #expect(OfficeLayer.preferredHeight(desks: 0) == OfficeLayer.preferredHeight(desks: 1))
    }

    @Test func clicksMapToDesks() {
        let layer = OfficeLayer()
        let model = OfficeModel(desks: desks([.working, .needsYou, .done]))
        layer.frame = CGRect(x: 0, y: 0, width: OfficeLayer.preferredWidth(desks: 3), height: OfficeLayer.openHeight)
        layer.update(model)
        #expect(layer.deskID(at: layer.deskRect(at: 1).offsetBy(dx: 10, dy: 10).origin) == model.desks[1].id)
        #expect(layer.deskID(at: CGPoint(x: 2, y: 2)) == nil)
        #expect(layer.deskID(at: CGPoint(x: layer.deskRect(at: 2).maxX + 5, y: 10)) == nil)
    }

    @Test func updatesReuseAndRemoveDesks() {
        let layer = OfficeLayer()
        var model = OfficeModel(desks: desks([.working, .idle]))
        layer.frame = CGRect(x: 0, y: 0, width: 600, height: OfficeLayer.openHeight)
        layer.update(model)
        model.desks.removeFirst()
        model.desks[0].state = .needsYou
        layer.update(model)
        #expect(layer.model.desks.count == 1)
        #expect(layer.model.lighting == .singleDesk)
    }

    /// Renders the building to PNG for a visual check: `BULLPEN_PREVIEW=/some/dir make test`.
    @Test func renderPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["BULLPEN_PREVIEW"] else { return }
        let floors: [[AgentState]] = [
            [.working, .thinking, .needsYou, .done, .idle, .error, .unknown, .dead],
            [.working],
            [.idle, .idle, .idle, .idle, .idle, .idle, .idle, .idle],
            [],
        ]
        let width = OfficeLayer.preferredWidth(desks: 8)
        let heights = floors.map { OfficeLayer.preferredHeight(desks: $0.count) }
        let total = heights.reduce(0, +) + CGFloat(floors.count - 1) * 6
        let scale: CGFloat = 2
        let ctx = try #require(CGContext(
            data: nil, width: Int(width * scale), height: Int(total * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width * scale, height: total * scale))
        ctx.scaleBy(x: scale, y: scale)
        var y: CGFloat = 0
        for (states, height) in zip(floors, heights) {
            let layer = OfficeLayer()
            layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let everyoneAway = states.count == 8 && states.allSatisfy { $0 == .idle }
            var floor = desks(states)
            if everyoneAway {
                let looks = CharacterLook.distinctJackets(floor.map(\.look))
                for i in floor.indices { floor[i].away = true; floor[i].look = looks[i] }
            }
            layer.update(OfficeModel(desks: floor))
            ctx.saveGState()
            // Flip to top-left origin and move to this floor.
            ctx.translateBy(x: 0, y: total - y)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            ctx.restoreGState()
            y += height + 6
        }
        let image = try #require(ctx.makeImage())
        let url = URL(fileURLWithPath: dir).appendingPathComponent("building.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}

@MainActor
@Suite struct CompactPreviewTests {
    /// Sidebar strip and menu bar heads at their real size, magnified 4× for inspection.
    @Test func renderCompactPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["BULLPEN_PREVIEW"] else { return }
        let states: [AgentState] = [.working, .needsYou, .done, .dead]
        let models = states.map { state -> DeskModel in
            let id = UUID()
            return DeskModel(id: id, name: "x", state: state, look: .make(worktreeID: id, agent: "claude"))
        }
        let office = OfficeLayer()
        office.isCompact = true
        office.frame = CGRect(x: 0, y: 0, width: OfficeLayer.preferredWidth(desks: 4), height: OfficeLayer.openHeight)
        office.update(OfficeModel(desks: models))
        let w = office.bounds.width / OfficeLayer.scale, h = office.bounds.height / OfficeLayer.scale
        let zoom: CGFloat = 4
        let ctx = try #require(CGContext(
            data: nil, width: Int(w * zoom), height: Int((h + 20) * zoom), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w * zoom, height: (h + 20) * zoom))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: (h + 20) * zoom)
        ctx.scaleBy(x: zoom / OfficeLayer.scale, y: -zoom / OfficeLayer.scale)
        office.render(in: ctx)
        ctx.restoreGState()
        for (i, model) in models.enumerated() {
            let head = try #require(CharacterSprite.head(look: model.look))
            ctx.draw(head, in: CGRect(x: CGFloat(i * 15) * zoom + 4, y: 4, width: 12 * zoom, height: 11 * zoom))
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("compact.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}

@MainActor
@Suite struct SnapshotTests {
    @Test func compactSnapshotHasTheRightSize() throws {
        let desks = (0..<3).map { i -> DeskModel in
            let id = UUID()
            return DeskModel(id: id, name: "w\(i)", state: [.working, .needsYou, .done][i], look: .make(worktreeID: id, agent: "claude"))
        }
        let image = try #require(OfficeSnapshot.image(OfficeModel(desks: desks), desks: 3))
        #expect(image.width == Int(OfficeLayer.preferredWidth(desks: 3) / OfficeLayer.scale * 2))
        #expect(image.height == Int(OfficeLayer.openHeight / OfficeLayer.scale * 2))
        if let dir = ProcessInfo.processInfo.environment["BULLPEN_PREVIEW"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("snapshot.png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }
}

@Suite struct WalkingTests {
    @Test func walkingFramesDrawAWholePerson() throws {
        for frame in 0..<2 {
            let look = CharacterLook.make(worktreeID: UUID(), agent: "claude")
            let canvas = CharacterSprite.walking(frame: frame, look: look)
            #expect(!canvas.isEmpty)
            // Shoes at the bottom: something is drawn in the last rows.
            #expect((0..<canvas.width).contains { canvas[$0, CharacterSprite.walkHeight - 2] != 0 })
        }
        guard let dir = ProcessInfo.processInfo.environment["BULLPEN_PREVIEW"] else { return }
        let zoom = 8, w = CharacterSprite.width, h = CharacterSprite.walkHeight
        let ctx = try #require(CGContext(data: nil, width: w * zoom * 6, height: h * zoom, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.67, blue: 0.48, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w * zoom * 6, height: h * zoom))
        for i in 0..<6 {
            let look = CharacterLook.make(worktreeID: UUID(), agent: i % 2 == 0 ? "claude" : "codex")
            let canvas = CharacterSprite.walking(frame: i % 2, look: look, smoking: i >= 3)
            let image = try #require((i == 1 || i == 4 ? canvas.mirrored() : canvas).image(palette: look.palette))
            ctx.draw(image, in: CGRect(x: i * w * zoom, y: 0, width: w * zoom, height: h * zoom))
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("walking.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}

@MainActor
@Suite struct ArrivalTests {
    func desk(_ id: UUID, away: Bool = false) -> DeskModel {
        DeskModel(id: id, name: "wt", state: .working, look: .make(worktreeID: id, agent: "claude"), away: away)
    }

    @Test func peopleWalkInAndOutButNotOnTheFirstDraw() {
        let layer = OfficeLayer()
        layer.frame = CGRect(x: 0, y: 0, width: OfficeLayer.preferredWidth(desks: 4), height: OfficeLayer.openHeight)
        let a = UUID(), b = UUID()
        layer.update(OfficeModel(desks: [desk(a)]))
        #expect(layer.walkers.sublayers?.isEmpty ?? true, "opening the app draws everyone seated")
        layer.update(OfficeModel(desks: [desk(a), desk(b)]))
        #expect(layer.walkers.sublayers?.count == 1, "a new worktree walks in")
        layer.update(OfficeModel(desks: [desk(a), desk(b, away: true)]))
        #expect(layer.walkers.sublayers?.count == 2, "leaving the jacket, they walk out")
        layer.update(OfficeModel(desks: [desk(b, away: true)]))
        #expect(layer.walkers.sublayers?.count == 3, "a removed worktree walks out")
        layer.update(OfficeModel(desks: [desk(b, away: true)]), reduceMotion: true)
        #expect(layer.walkers.sublayers?.count == 3)
        // Every walker's animations end with the walk, so it is removed once there.
        for walker in layer.walkers.sublayers ?? [] {
            let walk = try! #require(walker.animation(forKey: "walk"))
            for key in walker.animationKeys() ?? [] {
                let animation = try! #require(walker.animation(forKey: key))
                #expect(animation.repeatCount != .infinity, "\(key) never ends")
                #expect(max(animation.repeatDuration, animation.duration) <= walk.duration + 0.001, "\(key) outlasts the walk")
            }
        }
    }
}

