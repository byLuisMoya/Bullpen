import AppKit
import Foundation
import SwiftUI

/// Development aid: with `BULLPEN_SNAPSHOT_DIR` set, the app saves PNGs of its own main window
/// (no screen-recording permission needed), first on the building and then on each worktree.
/// `BULLPEN_SNAPSHOT_DELAY` (seconds, default 6) is the wait before each picture.
@MainActor
enum DebugSnapshots {
    static func run(store: BuildingStore, navigation: Navigation) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["BULLPEN_SNAPSHOT_DIR"] else { return }
        let delay = Double(env["BULLPEN_SNAPSHOT_DELAY"] ?? "") ?? 6
        // BULLPEN_SNAPSHOT_DEMO=1: load the demo through the same code as the button, remove it at the end.
        let withDemo = env["BULLPEN_SNAPSHOT_DEMO"] == "1"
        try? await Task.sleep(for: .seconds(1))
        save(to: dir, name: "00-start")
        if withDemo {
            do { try await AppActions.demo("start") } catch { print("demo start failed: \(error)") }
        }
        try? await Task.sleep(for: .seconds(delay))
        save(to: dir, name: "01-building")
        // BULLPEN_SNAPSHOT_SIDEBAR=1: frames while the sidebar collapses and expands.
        if env["BULLPEN_SNAPSHOT_SIDEBAR"] == "1" {
            for (target, label) in [(NavigationSplitViewVisibility.detailOnly, "collapse"), (.all, "expand")] {
                withAnimation { navigation.columnVisibility = target }
                for frame in 0..<14 {
                    try? await Task.sleep(for: .milliseconds(20))
                    save(to: dir, name: "sidebar-\(label)-\(frame)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if withDemo { try? await AppActions.demo("stop") }
            return
        }
        for (index, worktree) in store.offices.flatMap(\.worktrees).enumerated() {
            navigation.selection = worktree.id
            try? await Task.sleep(for: .seconds(delay))
            save(to: dir, name: String(format: "%02d-%@", index + 2, worktree.branch.replacingOccurrences(of: "/", with: "-")))
        }
        navigation.selection = nil
        try? await Task.sleep(for: .seconds(1))
        save(to: dir, name: "99-building-again")
        if withDemo {
            do { try await AppActions.demo("stop") } catch { print("demo stop failed: \(error)") }
            try? await Task.sleep(for: .seconds(4))
            save(to: dir, name: "99-after-demo")
        }
    }

    private static func save(to dir: String, name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        // "-screen": the window as the window server composited it (true to what you see; low
        // resolution without screen-recording permission). The plain file is sharp but drawn by
        // `cacheDisplay`, which renders flipped Core Animation layers (the offices) upside down.
        if let image = composited(window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-screen.png"))
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `CGWindowListCreateImage` is hidden from Swift in recent SDKs; look it up at runtime.
    private static func composited(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Fn.self)
        // .null rect = window bounds; list option 8 = including window; image options 1|8 = ignore framing, best resolution.
        return create(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue()
    }
}
