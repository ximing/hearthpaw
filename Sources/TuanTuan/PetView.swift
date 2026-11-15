import AppKit
import QuartzCore

@MainActor
final class PetView: NSView {
    var onPet: ((PetTouchZone) -> Void)?
    var onDragEnded: (() -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    private(set) var isDragging = false
    private(set) var lastFeedbackZone: PetTouchZone?
    private var gesture: PetDragGesture?
    private var pressedPoint: CGPoint?
    private var feedbackCleanup: DispatchWorkItem?
    private let mask: AlphaMask
    private let spriteGroup = CALayer()
    private let headLayer = CALayer()
    private let bodyLayer = CALayer()
    private let tailLayer = CALayer()
    private let hintLayer = CALayer()
    private let leftBlush = CAShapeLayer()
    private let rightBlush = CAShapeLayer()
    private let hitInset: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    var imageRect: CGRect { bounds.insetBy(dx: hitInset, dy: hitInset) }
    var feedbackIsActive: Bool {
        animationLayers.contains { !($0.animationKeys() ?? []).isEmpty }
    }
    private var animationLayers: [CALayer] {
        [headLayer, bodyLayer, tailLayer, hintLayer, leftBlush, rightBlush]
    }

    init(frame: NSRect, image: NSImage, mask: AlphaMask) {
        self.mask = mask
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(spriteGroup)
        var proposed = NSRect(origin: .zero, size: image.size)
        let bitmap = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        // Three clipped layers share the original bitmap; no new pose images or frame loop.
        for part in [tailLayer, bodyLayer, headLayer] {
            part.contents = bitmap
            part.contentsGravity = .resizeAspect
            part.magnificationFilter = .linear
            part.minificationFilter = .trilinear
            spriteGroup.addSublayer(part)
        }
        headLayer.anchorPoint = CGPoint(x: 0.43, y: 0.61)
        bodyLayer.anchorPoint = CGPoint(x: 0.43, y: 0.94)
        tailLayer.anchorPoint = CGPoint(x: 0.75, y: 0.86)
        for blush in [leftBlush, rightBlush] {
            blush.fillColor = NSColor(calibratedRed: 0.94, green: 0.48, blue: 0.54, alpha: 1).cgColor
            blush.opacity = 0
            headLayer.addSublayer(blush)
        }
        if let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil) {
            var rect = NSRect(origin: .zero, size: heart.size)
            hintLayer.contents = heart.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            hintLayer.contentsGravity = .resizeAspect
        }
        hintLayer.opacity = 0
        layer?.addSublayer(hintLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("团团，桌面宠物")
        setAccessibilityHelp("点按头顶、脸颊、肚子或尾巴会有不同反馈；拖动移动，右键打开菜单。")
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteGroup.frame = imageRect
        let size = imageRect.size
        for part in [headLayer, bodyLayer, tailLayer] {
            part.bounds = CGRect(origin: .zero, size: size)
            part.position = CGPoint(x: part.anchorPoint.x * size.width, y: part.anchorPoint.y * size.height)
        }
        headLayer.mask = shapeMask(path: headPath(size: size), size: size)
        tailLayer.mask = shapeMask(path: tailPath(size: size), size: size)
        // Small overlap only at the joints fills seams during bounded movement.
        let bodyMask = CGMutablePath()
        bodyMask.addRect(CGRect(origin: .zero, size: size))
        bodyMask.addPath(headPath(size: size, shift: -0.045))
        bodyMask.addPath(tailPath(size: size, seamInset: 0.018))
        bodyLayer.mask = shapeMask(path: bodyMask, size: size, evenOdd: true)
        configureBlush(leftBlush, center: CGPoint(x: 0.20, y: 0.45), size: size)
        configureBlush(rightBlush, center: CGPoint(x: 0.57, y: 0.53), size: size)
        hintLayer.frame = CGRect(x: bounds.midX - 11, y: 4, width: 22, height: 22)
        CATransaction.commit()
    }

    func containsCharacter(at point: CGPoint) -> Bool { mask.contains(point, in: imageRect) }

    func touchZone(at point: CGPoint) -> PetTouchZone? {
        guard containsCharacter(at: point) else { return nil }
        return PetTouchLayout.zone(at: point, in: imageRect)
    }

    /// Shared by physical mouse clicks and the app's internal validation (no input injection).
    @discardableResult
    func triggerTouch(at point: CGPoint) -> Bool {
        guard let zone = touchZone(at: point) else { return false }
        onPet?(zone)
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        containsCharacter(at: convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard touchZone(at: local) != nil else { return }
        stopFeedback()
        pressedPoint = local
        gesture = PetDragGesture(pointer: NSEvent.mouseLocation, origin: window.frame.origin)
        isDragging = true
        window.ignoresMouseEvents = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard var gesture, let window else { return }
        let origin = gesture.moved(to: NSEvent.mouseLocation)
        self.gesture = gesture
        if gesture.hasDragged { window.setFrameOrigin(origin) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        let point = pressedPoint
        self.gesture = nil
        pressedPoint = nil
        isDragging = false
        if !gesture.hasDragged, let point,
           containsCharacter(at: convert(event.locationInWindow, from: nil)) {
            triggerTouch(at: point)
        }
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard containsCharacter(at: convert(event.locationInWindow, from: nil)),
              let menu = makeContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        onDragEnded?()
    }

    override func accessibilityPerformPress() -> Bool { onPet?(.head); return true }

    func playPetFeedback(for zone: PetTouchZone = .head) {
        stopFeedback()
        lastFeedbackZone = zone
        switch zone {
        case .head:
            keyframes(headLayer, keyPath: "transform.rotation.z", values: [0, -0.045, 0.035, 0],
                      duration: 0.68, key: zone.animationKey)
            keyframes(headLayer, keyPath: "transform.translation.y", values: [0, 2.0, -1.0, 0],
                      duration: 0.68, key: "head-nod")
            keyframes(headLayer, keyPath: "transform.scale", values: [1, 0.98, 1.015, 1],
                      duration: 0.68, key: "head-softness")
        case .cheek:
            keyframes(headLayer, keyPath: "transform.translation.x", values: [0, -2.5, 2, 0],
                      duration: 0.78, key: zone.animationKey)
            keyframes(headLayer, keyPath: "transform.rotation.z", values: [0, 0.035, -0.035, 0],
                      duration: 0.78, key: "cheek-nuzzle")
            for blush in [leftBlush, rightBlush] {
                keyframes(blush, keyPath: "opacity", values: [0, 0.32, 0.24, 0],
                          duration: 0.90, key: "blush")
            }
        case .belly:
            keyframes(bodyLayer, keyPath: "transform.scale.y", values: [1, 0.91, 1.04, 1],
                      duration: 0.70, key: zone.animationKey)
            keyframes(bodyLayer, keyPath: "transform.scale.x", values: [1, 1.035, 0.985, 1],
                      duration: 0.70, key: "belly-softness")
            keyframes(headLayer, keyPath: "transform.translation.y", values: [0, 1.2, -0.8, 0],
                      duration: 0.70, key: "belly-head-follow")
        case .tail:
            keyframes(tailLayer, keyPath: "transform.rotation.z", values: [0, 0.10, -0.09, 0.065, -0.035, 0],
                      duration: 0.90, key: zone.animationKey)
        }
        let normalizedHint: CGPoint = switch zone {
        case .head: CGPoint(x: 0.48, y: 0.08)
        case .cheek: CGPoint(x: 0.67, y: 0.30)
        case .belly: CGPoint(x: 0.44, y: 0.72)
        case .tail: CGPoint(x: 0.88, y: 0.51)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintLayer.position = CGPoint(x: imageRect.minX + normalizedHint.x * imageRect.width,
                                     y: imageRect.minY + normalizedHint.y * imageRect.height)
        CATransaction.commit()
        keyframes(hintLayer, keyPath: "opacity", values: [0, 0.75, 0.55, 0], duration: 0.85, key: "hint-fade")
        keyframes(hintLayer, keyPath: "transform.translation.y", values: [6, 0, -7, -12],
                  duration: 0.85, key: "hint-rise")
        // AppKit can retain completed animation entries even after presentation is at rest.
        // One cancellable event cleanup, never an idle timer or frame loop.
        let cleanup = DispatchWorkItem { [weak self] in self?.stopFeedback() }
        feedbackCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: cleanup)
    }

    func stopFeedback() {
        feedbackCleanup?.cancel()
        feedbackCleanup = nil
        for layer in animationLayers { layer.removeAllAnimations() }
    }

    var feedbackAnimationCount: Int {
        animationLayers.reduce(0) { $0 + ($1.animationKeys() ?? []).count }
    }

    func feedbackTargetsAreValid(for zone: PetTouchZone) -> Bool {
        let target = zone == .tail ? tailLayer : (zone == .belly ? bodyLayer : headLayer)
        guard target.animation(forKey: zone.animationKey) != nil else { return false }
        switch zone {
        case .head, .cheek:
            return (bodyLayer.animationKeys() ?? []).isEmpty && (tailLayer.animationKeys() ?? []).isEmpty
        case .belly:
            return (tailLayer.animationKeys() ?? []).isEmpty
        case .tail:
            return (headLayer.animationKeys() ?? []).isEmpty && (bodyLayer.animationKeys() ?? []).isEmpty
        }
    }

    func feedbackHasVisibleMotion(for zone: PetTouchZone) -> Bool {
        let target = zone == .tail ? tailLayer : (zone == .belly ? bodyLayer : headLayer)
        guard let presentation = target.presentation() else { return false }
        return !CATransform3DEqualToTransform(presentation.transform, CATransform3DIdentity)
    }

    /// Diagnostic isolation of existing pixels, not a generated pose or a user-facing mode.
    func showDebugPart(_ part: PetTouchZone?) {
        headLayer.isHidden = part != nil && part != .head && part != .cheek
        bodyLayer.isHidden = part != nil && part != .belly
        tailLayer.isHidden = part != nil && part != .tail
        hintLayer.isHidden = part != nil
    }

    private func keyframes(_ layer: CALayer, keyPath: String, values: [Double], duration: Double, key: String) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .cubic
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }

    private func shapeMask(path: CGPath, size: CGSize, evenOdd: Bool = false) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.path = path
        mask.fillColor = NSColor.white.cgColor
        mask.fillRule = evenOdd ? .evenOdd : .nonZero
        return mask
    }

    private func configureBlush(_ blush: CAShapeLayer, center: CGPoint, size: CGSize) {
        let rect = CGRect(x: (center.x - 0.06) * size.width, y: (center.y - 0.027) * size.height,
                          width: 0.12 * size.width, height: 0.054 * size.height)
        blush.path = CGPath(ellipseIn: rect, transform: nil)
    }

    private func headPath(size: CGSize, shift: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: (y + shift) * size.height) }
        path.move(to: p(-0.02, -0.02))
        path.addLine(to: p(1.02, -0.02))
        path.addLine(to: p(1.02, 0.57))
        path.addLine(to: p(0.82, 0.57))
        path.addCurve(to: p(0.07, 0.585), control1: p(0.72, 0.65), control2: p(0.40, 0.685))
        path.addLine(to: p(-0.02, 0.585))
        path.closeSubpath()
        return path
    }

    private func tailPath(size: CGSize, seamInset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
        path.move(to: p(0.81 + seamInset, 0.57))
        path.addCurve(to: p(1.02, 0.80), control1: p(0.99, 0.53), control2: p(1.02, 0.67))
        path.addLine(to: p(1.02, 1.02))
        path.addLine(to: p(0.675 + seamInset, 1.02))
        path.addCurve(to: p(0.756 + seamInset, 0.70), control1: p(0.69 + seamInset, 0.91), control2: p(0.765 + seamInset, 0.85))
        path.addCurve(to: p(0.81 + seamInset, 0.57), control1: p(0.82 + seamInset, 0.66), control2: p(0.79 + seamInset, 0.63))
        path.closeSubpath()
        return path
    }
}
