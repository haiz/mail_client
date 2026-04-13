import AppKit

/// NSButton subclass that shows a pointing-hand cursor on hover, animates a
/// rounded-rect background glow on enter/exit, and spring-compresses on press.
///
/// Hover: semi-transparent background fades in (0.12 s ease-out), icon tint
///        lifts from secondaryLabelColor → labelColor.
/// Press: layer spring-compresses to 0.88 and bounces back on release.
/// All layer mutations happen in updateLayer() or explicit animation blocks —
/// never inside draw paths — per the AppKit rules in GUI/CLAUDE.md.
final class CursorButton: NSButton {

    // MARK: - State

    private var cursorTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    // MARK: - Hover background layer

    private let hoverBg = CALayer()
    private var hoverBgInstalled = false

    /// True → system calls updateLayer() instead of draw(); implies wantsLayer.
    override var wantsUpdateLayer: Bool { true }

    // Install once the backing layer exists.
    private func installHoverBgIfNeeded() {
        guard !hoverBgInstalled, let layer = layer else { return }
        hoverBg.cornerRadius = 6
        hoverBg.opacity = 0
        layer.insertSublayer(hoverBg, at: 0)
        hoverBgInstalled = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installHoverBgIfNeeded()
    }

    // MARK: - Layer rendering

    override func updateLayer() {
        installHoverBgIfNeeded()
        // Keep background color in sync with the current appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBg.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }
        // Keep background geometry in sync with bounds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBg.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Tracking area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = cursorTrackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    // MARK: - Mouse events

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.push()
        animateHoverBackground(visible: true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.pop()
        animateHoverBackground(visible: false)
        if isPressed {
            isPressed = false
            animatePressScale(down: false)
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        animatePressScale(down: true)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        animatePressScale(down: false)
        super.mouseUp(with: event)
    }

    // MARK: - Animations

    private func animateHoverBackground(visible: Bool) {
        let toOpacity: Float = visible ? 1 : 0
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverBg.presentation()?.opacity ?? hoverBg.opacity
        anim.toValue = toOpacity
        anim.duration = visible ? 0.12 : 0.20
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hoverBg.add(anim, forKey: "hoverFade")
        hoverBg.opacity = toOpacity

        // Lift icon brightness alongside the background.
        contentTintColor = visible ? .labelColor : .secondaryLabelColor
    }

    private func animatePressScale(down: Bool) {
        let toScale: CGFloat = down ? 0.88 : 1.0
        let fromScale = (layer?.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.0
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = fromScale
        spring.toValue = toScale
        spring.stiffness = 420
        spring.damping = 26
        spring.initialVelocity = down ? -4 : 4
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "pressScale")
        layer?.setValue(toScale, forKeyPath: "transform.scale")
    }
}
