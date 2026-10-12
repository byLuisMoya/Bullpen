import AppKit
import BPAgents
import BPCore
import BPHabitat
import SwiftUI

/// Menu bar extra: a strip of tiny heads, one per worktree, underlined with its state colour,
/// and a menu to jump to any worktree (PLAN §9.5).
struct MenuBarContent: View {
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.offices.allSatisfy(\.worktrees.isEmpty) {
            Text("No hay worktrees")
        }
        ForEach(store.offices.filter { !$0.worktrees.isEmpty }) { office in
            Section(office.project.name) {
                ForEach(office.worktrees) { worktree in
                    let status = attention.statuses[worktree.id]
                    Button {
                        navigation.selection = worktree.id
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("\(status?.state.emoji ?? "·") \(worktree.branch) — \(status.map { $0.detail ?? $0.state.label } ?? "…")")
                    }
                }
            }
        }
        Divider()
        Button("Abrir Bullpen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Salir") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    @Environment(BuildingStore.self) private var store
    @Environment(AttentionCenter.self) private var attention

    var body: some View {
        let heads = store.offices.flatMap(\.worktrees).prefix(8).map { worktree in
            (CharacterLook.make(worktreeID: worktree.id, agent: worktree.agentProfileID),
             attention.statuses[worktree.id]?.state ?? .unknown)
        }
        if heads.isEmpty {
            Image(systemName: "building.2")
        } else if let image = Self.strip(Array(heads)) {
            Image(nsImage: image)
        }
    }

    /// Composites the heads into one image (menu bar labels render a single image reliably).
    static func strip(_ heads: [(CharacterLook, AgentState)]) -> NSImage? {
        let headW = 12, headH = 11, gap = 3, scale = 2
        let width = heads.count * headW + (heads.count - 1) * gap
        let height = headH + 3
        guard let ctx = CGContext(
            data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        for (i, (look, state)) in heads.enumerated() {
            let x = i * (headW + gap)
            let asleep = state == .idle || state == .dead
            if let head = CharacterSprite.head(look: look, eyesClosed: asleep) {
                ctx.setAlpha(state == .dead || state == .unknown ? 0.45 : 1)
                ctx.draw(head, in: CGRect(x: x, y: 3, width: headW, height: headH))
                ctx.setAlpha(1)
            }
            ctx.setFillColor(NSColor(state.color).cgColor)
            ctx.fill(CGRect(x: x + 2, y: 0, width: headW - 4, height: 2))
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        image.isTemplate = false
        return image
    }
}

extension AgentState {
    var emoji: String {
        switch self {
        case .needsYou: "✋"
        case .done: "✅"
        case .error: "⚠️"
        case .working, .thinking, .starting: "⚙️"
        case .idle: "💤"
        case .dead: "🪑"
        case .unknown: "❔"
        }
    }
}
