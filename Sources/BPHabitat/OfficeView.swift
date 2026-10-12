import AppKit
import QuartzCore

/// AppKit host for an `OfficeLayer`: clicks select a desk, tooltips explain it, and the scene
/// pauses whenever the window is hidden or covered.
public final class OfficeView: NSView, NSViewToolTipOwner {
    public var onSelect: ((UUID) -> Void)?
    private let office = OfficeLayer()
    private var occlusionObserver: NSObjectProtocol?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        layer = office
        wantsLayer = true
        office.contentsScale = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: OfficeModel) {
        office.frame = bounds
        office.update(model, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        removeAllToolTips()
        for index in model.desks.indices {
            addToolTip(office.deskRect(at: index), owner: self, userData: nil)
        }
        updatePause()
    }

    public override func layout() {
        super.layout()
        if office.frame != bounds { office.frame = bounds; office.update(office.model) }
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let id = office.deskID(at: point), let desk = office.model.desks.first(where: { $0.id == id }) else { return "" }
        return [desk.name, desk.detail].compactMap { $0 }.joined(separator: " — ")
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = office.deskID(at: point) { onSelect?(id) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePause() }
            }
        }
        updatePause()
    }

    public override func viewDidHide() { super.viewDidHide(); updatePause() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updatePause() }

    private func updatePause() {
        let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        office.isPaused = !visible || office.model.lighting == .off
    }

    isolated deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
}
