import AppKit
import QuartzCore

/// AppKit host for an `OfficeLayer`: clicks select a desk, tooltips explain it, and the scene
/// pauses whenever the window is hidden or covered.
public final class OfficeView: NSView, NSViewToolTipOwner {
    public var onSelect: ((UUID) -> Void)?
    private let office = OfficeLayer()
    private let host = CALayer()
    private var occlusionObserver: NSObjectProtocol?
    /// 1 for the building, 1/3 for the sidebar strip (exactly one point per art pixel).
    public let zoom: CGFloat

    public init(frame: NSRect = .zero, compact: Bool = false) {
        zoom = compact ? 1 / OfficeLayer.scale : 1
        super.init(frame: frame)
        // The office layer flips its own geometry (y down); the host must not flip again.
        layer = host
        wantsLayer = true
        office.contentsScale = 2
        office.isCompact = compact
        office.anchorPoint = .zero
        office.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        host.isGeometryFlipped = false
        host.addSublayer(office)
    }

    public override convenience init(frame: NSRect) { self.init(frame: frame, compact: false) }

    /// Size the view needs for `desks` people.
    public static func size(desks: Int, compact: Bool) -> CGSize {
        let zoom = compact ? 1 / OfficeLayer.scale : 1
        return CGSize(
            width: OfficeLayer.preferredWidth(desks: desks) * zoom,
            height: (compact ? OfficeLayer.openHeight : OfficeLayer.preferredHeight(desks: desks)) * zoom
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Not flipped: AppKit would then flip the hosting layer too, and together with the office
    // layer's own flip the scene ended up upside down. Only x matters for hit testing.

    private var unzoomedBounds: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    public func update(_ model: OfficeModel) {
        layoutOffice()
        office.update(model, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        removeAllToolTips()
        for index in model.desks.indices {
            let r = office.deskRect(at: index)
            addToolTip(CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom), owner: self, userData: nil)
        }
        updatePause()
    }

    public override func layout() {
        super.layout()
        if office.bounds.size != unzoomedBounds.size { layoutOffice(); office.update(office.model) }
    }

    private func layoutOffice() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Exactly one flip between the window and the art: the office's own.
        office.isGeometryFlipped = !host.isGeometryFlipped
        office.bounds = unzoomedBounds
        office.position = .zero
        CATransaction.commit()
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let id = office.deskID(at: CGPoint(x: point.x / zoom, y: point.y / zoom)), let desk = office.model.desks.first(where: { $0.id == id }) else { return "" }
        return [desk.name, desk.detail].compactMap { $0 }.joined(separator: " — ")
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = office.deskID(at: CGPoint(x: point.x / zoom, y: point.y / zoom)) { onSelect?(id) }
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
