import AppKit

@MainActor
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetWindowController {
    let panel: PetPanel
    let petView: PetView
    private(set) var requestedVisible = true
    private(set) var size: CGFloat = PetGeometry.defaultSize
    var makeMenu: (() -> NSMenu)?
    var didChange: (() -> Void)?
    var onPetLine: ((PetTouchZone) -> String)?
    var onInteraction: (() -> Void)?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var bubble: PetPanel?
    private var bubbleDismissal: DispatchWorkItem?
    private var sleeping = false

    init?(bundle: Bundle = .main) {
        guard let imageURL = bundle.url(forResource: "pet", withExtension: "png"),
              let maskURL = bundle.url(forResource: "pet-alpha", withExtension: "bin"),
              let image = NSImage(contentsOf: imageURL),
              let maskBytes = try? Data(contentsOf: maskURL),
              let mask = AlphaMask(width: 512, height: 512, pixels: maskBytes) else { return nil }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = PetGeometry.initialFrame(size: size, screen: screen)
        panel = PetPanel(contentRect: frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.title = "团团 · 桌面宠物"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        petView = PetView(frame: CGRect(origin: .zero, size: frame.size), image: image, mask: mask)
        petView.autoresizingMask = [.width, .height]
        panel.contentView = petView
        petView.onPet = { [weak self] zone in self?.pet(zone: zone) }
        petView.onDragEnded = { [weak self] in
            self?.recoverPosition()
            self?.refreshMouseAcceptance()
            self?.dismissBubble()
            self?.onInteraction?()
        }
        petView.makeContextMenu = { [weak self] in self?.makeMenu?() ?? NSMenu() }
    }

    func show() {
        requestedVisible = true
        guard !sleeping else { return }
        recoverPosition()
        panel.orderFrontRegardless()
        installMouseMonitors()
        refreshMouseAcceptance()
        didChange?()
    }

    func hide() {
        requestedVisible = false
        suspendPresentation()
        didChange?()
    }

    func toggleVisibility() { requestedVisible ? hide() : show() }

    func setSize(_ newSize: CGFloat) {
        let edge = PetGeometry.boundedSize(newSize)
        let center = panel.frame.center
        size = edge
        let frame = CGRect(x: center.x - edge / 2, y: center.y - edge / 2, width: edge, height: edge)
        panel.setFrame(PetGeometry.recovered(frame, screens: visibleScreens), display: true)
        petView.needsLayout = true
        petView.layoutSubtreeIfNeeded()
        dismissBubble()
        refreshMouseAcceptance()
        didChange?()
    }

    func resetPosition() {
        let screen = NSScreen.main?.visibleFrame ?? visibleScreens.first ?? panel.frame
        panel.setFrame(PetGeometry.initialFrame(size: size, screen: screen), display: true)
        dismissBubble()
        refreshMouseAcceptance()
    }

    func recoverPosition() {
        let frame = PetGeometry.recovered(panel.frame, screens: visibleScreens)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            dismissBubble()
        }
    }

    func refreshMouseAcceptance(at screenPoint: CGPoint? = nil) {
        guard panel.isVisible, !sleeping, !petView.isDragging else { return }
        let point = panel.convertPoint(fromScreen: screenPoint ?? NSEvent.mouseLocation)
        let local = petView.convert(point, from: nil)
        let ignores = !petView.containsCharacter(at: local)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    var feedbackBubbleIsVisible: Bool { bubble?.isVisible == true }

    func pet(zone: PetTouchZone = .head) {
        guard requestedVisible, !sleeping else { return }
        petView.playPetFeedback(for: zone)
        showBubble(onPetLine?(zone) ?? zone.response)
    }

    func willSleep() {
        sleeping = true
        suspendPresentation()
    }

    func didWake() {
        sleeping = false
        if requestedVisible { show() }
    }

    func tearDown() {
        removeMouseMonitors()
        dismissBubble()
        petView.stopFeedback()
        panel.orderOut(nil)
    }

    private var visibleScreens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        // Mouse movement only. No key events, screen content, click history, or polling timer.
        // Apple documents that these handlers run on the main thread.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMouseAcceptance() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.refreshMouseAcceptance() }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func suspendPresentation() {
        removeMouseMonitors()
        dismissBubble()
        petView.stopFeedback()
        panel.orderOut(nil)
    }

    func showBubble(_ text: String, seconds: TimeInterval = 1.6) {
        dismissBubble()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 13)
        let measured = (trimmed as NSString).boundingRect(
            with: NSSize(width: 240, height: 72),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let width = min(280, max(160, ceil(measured.width) + 24))
        let height = min(78, max(40, ceil(measured.height) + 18))
        let raw = CGRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY + 3,
                         width: width, height: height)
        let frame = PetGeometry.recovered(raw, screens: visibleScreens)
        let bubble = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = false
        bubble.level = .floating
        bubble.collectionBehavior = panel.collectionBehavior
        bubble.hidesOnDeactivate = false
        bubble.ignoresMouseEvents = true
        bubble.isReleasedWhenClosed = false
        let background = NSView(frame: CGRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.93, alpha: 0.98).cgColor
        background.layer?.cornerRadius = 14
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(calibratedWhite: 0.65, alpha: 0.2).cgColor
        let label = NSTextField(wrappingLabelWithString: trimmed)
        label.font = font
        label.textColor = NSColor(calibratedRed: 0.30, green: 0.37, blue: 0.31, alpha: 1)
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.frame = CGRect(x: 10, y: 8, width: width - 20, height: height - 14)
        background.addSubview(label)
        bubble.contentView = background
        self.bubble = bubble
        bubble.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissBubble() }
        bubbleDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: dismissal)
    }

    private func dismissBubble() {
        bubbleDismissal?.cancel()
        bubbleDismissal = nil
        bubble?.orderOut(nil)
        bubble = nil
    }
}
