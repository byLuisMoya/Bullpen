import AppKit

/// How often background checks run: their usual pace while Bullpen is in front, a slower one
/// while it is behind other apps (nobody is looking), and back to the usual pace soon after it
/// comes to the front again.
@MainActor
enum Pacing {
    static func pause(active: Double, background: Double) async {
        let start = Date()
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= (NSApp.isActive ? active : background) { return }
            // Short steps, so coming to the front cuts a long background wait short.
            try? await Task.sleep(for: .seconds(min(active, max(background - elapsed, 0.1))))
        }
    }
}
