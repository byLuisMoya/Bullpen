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
            return DeskModel(id: id, name: "wt-\(i)", state: state, look: .make(worktreeID: id, agent: i % 2 == 0 ? "claude" : "codex"))
        }
    }

    @Test func lightingFollowsDeskCount() {
        #expect(OfficeModel(desks: []).lighting == .off)
        #expect(OfficeModel(desks: desks([.working])).lighting == .singleDesk)
        #expect(OfficeModel(desks: desks([.working, .idle])).lighting == .allOn)
        #expect(OfficeLayer.preferredHeight(desks: 0) < OfficeLayer.preferredHeight(desks: 1))
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
            layer.update(OfficeModel(desks: desks(states)))
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
