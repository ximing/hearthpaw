import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var pet: PetWindowController?
    private var statusItem: NSStatusItem?
    private let settingsStore = AppSettingsStore()
    private var settingsController: SettingsWindowController?
    private var agentCoordinator: AgentCoordinator?
    private var chatController: ChatWindowController?
    private var companionSession: CompanionSession?
    private var memoryStore: MemoryStore?
    private var greetingWork: DispatchWorkItem?
    private var lifecycleAsleep = false
    private var chatVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        guard let controller = PetWindowController() else {
            let alert = NSAlert()
            alert.messageText = "团团的角色素材没有加载成功"
            alert.informativeText = "请重新构建原型，确认应用内包含 pet.png 和 pet-alpha.bin。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        pet = controller
        installCompanion()
        if let saved = try? settingsStore.load() { controller.setSize(CGFloat(saved.petSize)) }
        controller.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        controller.didChange = { [weak self] in
            self?.updateSettings()
            self?.rescheduleGreeting()
        }
        controller.onPetLine = { [weak self] zone in
            guard let self, let session = self.companionSession else { return zone.response }
            let line = session.recordPet(zone)
            self.rescheduleGreeting()
            return line
        }
        controller.onInteraction = { [weak self] in
            self?.companionSession?.noteInteraction()
            self?.rescheduleGreeting()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "团团")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "团团 · 聊天、养成与调研"
        item.menu = makeMenu()
        item.menu?.delegate = self
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(willSleep),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(didWake),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        controller.show()
        if let index = CommandLine.arguments.firstIndex(of: "--validate-agent-at"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                do { try await AgentRuntimeValidation.run(at: URL(fileURLWithPath: path, isDirectory: true)) }
                catch { print("Agent validation failed (no production credentials used).") }
                NSApp.terminate(nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--validate-at"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.runValidation(at: path)
            }
        } else if CommandLine.arguments.contains("--settings") {
            showSettings()
        } else if CommandLine.arguments.contains("--chat") {
            showChat()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        greetingWork?.cancel()
        greetingWork = nil
        agentCoordinator?.shutdown()
        pet?.tearDown()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "团团", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "团团")
        add("设置…", action: #selector(showSettings), to: appMenu, key: ",")
        appMenu.addItem(.separator())
        add("退出团团", action: #selector(quit), to: appMenu, key: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Accessory apps still need a main edit menu for AppKit's standard
        // key-equivalent routing. Nil targets resolve to the focused editor,
        // including NSSecureTextField's native secure field editor.
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        let undo = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undo)
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        for (title, action, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(togglePet) {
                item.title = pet?.requestedVisible == true ? "隐藏团团" : "显示团团"
            } else if item.action == #selector(toggleGreetings) {
                item.title = companionSession?.snapshot.greetingsEnabled == false ? "开启主动招呼" : "关闭主动招呼"
            } else if item.identifier?.rawValue == "bond" {
                item.title = bondTitle()
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "团团 · 陪伴 Agent", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        add("和团团聊天 / 调研报告…", action: #selector(showChat), to: menu, key: "t")
        add("抚摸一下", action: #selector(petOnce), to: menu)
        let demonstrations = NSMenuItem(title: "试试分区反馈", action: nil, keyEquivalent: "")
        let touchMenu = NSMenu()
        touchMenu.autoenablesItems = false
        for zone in PetTouchZone.allCases {
            let item = NSMenuItem(title: "摸摸\(zone.title)", action: #selector(demonstrateTouch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = zone.rawValue
            item.isEnabled = true
            touchMenu.addItem(item)
        }
        demonstrations.submenu = touchMenu
        menu.addItem(demonstrations)
        add(pet?.requestedVisible == true ? "隐藏团团" : "显示团团", action: #selector(togglePet), to: menu)
        add("回到主屏右下角", action: #selector(resetPosition), to: menu)
        add(companionSession?.snapshot.greetingsEnabled == false ? "开启主动招呼" : "关闭主动招呼",
            action: #selector(toggleGreetings), to: menu)
        add("暂停招呼两小时", action: #selector(pauseGreetings), to: menu)
        add("设置…", action: #selector(showSettings), to: menu, key: ",")
        menu.addItem(.separator())
        let bond = NSMenuItem(title: bondTitle(), action: nil, keyEquivalent: "")
        bond.identifier = NSUserInterfaceItemIdentifier("bond")
        bond.isEnabled = false
        menu.addItem(bond)
        let future = NSMenuItem(title: "主动发送才联网 · 记忆只在本机", action: nil, keyEquivalent: "")
        future.isEnabled = false
        menu.addItem(future)
        menu.addItem(.separator())
        add("退出团团", action: #selector(quit), to: menu, key: "q")
        return menu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func petOnce() { pet?.pet() }
    @objc private func demonstrateTouch(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let zone = PetTouchZone(rawValue: raw) else { return }
        pet?.pet(zone: zone)
    }
    @objc private func togglePet() { pet?.toggleVisibility() }
    @objc private func resetPosition() { pet?.resetPosition() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func screensChanged() { pet?.recoverPosition(); pet?.refreshMouseAcceptance() }
    @objc private func spaceChanged() { pet?.refreshMouseAcceptance() }
    @objc private func willSleep() {
        lifecycleAsleep = true
        greetingWork?.cancel()
        greetingWork = nil
        pet?.willSleep()
        agentCoordinator?.interruptForSleep()
    }
    @objc private func didWake() {
        // Keep the asleep gate until the missed greeting is skipped. didWake may show the pet
        // and reschedule; that pass must not speak a line that became due while locked.
        pet?.didWake()
        agentCoordinator?.resumeAfterSleep()
        lifecycleAsleep = false
        companionSession?.skipMissedGreeting(gates: currentGates())
        rescheduleGreeting()
    }

    @objc private func showChat() {
        if chatController == nil {
            let coordinator = AgentCoordinator(settingsStore: settingsStore,
                keyProvider: { try KeychainAPIKeyStore().readKey() },
                client: OpenRouterClient(), taskStore: ResearchTaskStore(),
                memoryStore: memoryStore)
            coordinator.onCompanionRound = { [weak self] in
                _ = self?.companionSession?.recordChatRound()
                self?.rescheduleGreeting()
            }
            coordinator.onChange = { [weak self] in self?.rescheduleGreeting() }
            agentCoordinator = coordinator
            let chat = ChatWindowController(coordinator: coordinator,
                onOpenSettings: { [weak self] in self?.showSettings() })
            chat.onVisibility = { [weak self] visible in
                self?.chatVisible = visible
                self?.rescheduleGreeting()
            }
            chatController = chat
        }
        chatController?.present()
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: settingsStore,
                keyStore: KeychainAPIKeyStore(), onSizeChanged: { [weak self] size in
                    self?.pet?.setSize(size)
                }, companion: companionSession, memory: memoryStore, onCareChanged: { [weak self] in
                    self?.rescheduleGreeting()
                })
        }
        updateSettings()
        settingsController?.present()
    }

    private func installCompanion() {
        let sessionStore: CompanionStateStore
        let memories: MemoryStore
        if let root = validationDirectory() {
            sessionStore = CompanionStateStore(fileURL: root.appendingPathComponent("qa-companion/companion.json"))
            memories = MemoryStore(rootURL: root.appendingPathComponent("qa-memory", isDirectory: true))
        } else {
            sessionStore = CompanionStateStore()
            memories = MemoryStore()
        }
        companionSession = CompanionSession(store: sessionStore)
        memoryStore = memories
    }

    /// `--observe-idle-at` only redirects companion and memory files so a resource
    /// soak cannot score or greet into the user's Application Support data.
    /// It does not open chat, settings, or the validation harness.
    private func validationDirectory() -> URL? {
        for flag in ["--validate-at", "--validate-agent-at", "--observe-idle-at"] {
            guard let index = CommandLine.arguments.firstIndex(of: flag),
                  CommandLine.arguments.indices.contains(index + 1) else { continue }
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        return nil
    }

    private func bondTitle() -> String {
        guard let session = companionSession else { return "亲密度 0 · 初识" }
        if session.warning != nil { return "亲密度未读取 · 养成文件损坏" }
        return "亲密度 \(session.snapshot.bond) · \(session.tier.title)"
    }

    private func currentGates() -> GreetingGates {
        GreetingGates(sleeping: lifecycleAsleep,
                      hidden: pet?.requestedVisible != true,
                      visible: pet?.panel.isVisible == true && !lifecycleAsleep,
                      chatting: chatVisible || agentCoordinator?.isChatBusy == true,
                      working: agentCoordinator?.isResearchBusy == true)
    }

    private func rescheduleGreeting() {
        greetingWork?.cancel()
        greetingWork = nil
        guard let session = companionSession else { return }
        let plan = session.plan(gates: currentGates())
        if let line = plan.line {
            session.markSpoken()
            pet?.showBubble(line, seconds: CompanionRhythm.greetingVisibleSeconds)
            if session.plan(gates: currentGates()).line != nil {
                session.forceQuiet(until: Date().addingTimeInterval(CompanionRhythm.hourlyCooldown))
            }
        }
        let next = session.plan(gates: currentGates()).nextCheck
        guard let next else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in self?.rescheduleGreeting() }
        greetingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func toggleGreetings() {
        guard let session = companionSession else { return }
        session.setGreetingsEnabled(!session.snapshot.greetingsEnabled)
        rescheduleGreeting()
    }

    @objc private func pauseGreetings() {
        companionSession?.pauseGreetings()
        rescheduleGreeting()
    }

    private func updateSettings() {
        guard let pet else { return }
        settingsController?.syncPetSize(pet.size)
    }

    private func runValidation(at path: String) {
        guard let pet else { return }
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var checks: [String: Bool] = [:]
            checks["panel_non_opaque"] = !pet.panel.isOpaque
            checks["panel_cannot_become_key"] = !pet.panel.canBecomeKey
            checks["panel_cannot_become_main"] = !pet.panel.canBecomeMain
            checks["panel_has_no_shadow"] = !pet.panel.hasShadow
            checks["joins_normal_spaces"] = pet.panel.collectionBehavior.contains(.canJoinAllSpaces)
            checks["no_fullscreen_auxiliary"] = !pet.panel.collectionBehavior.contains(.fullScreenAuxiliary)
            let emptyLocal = CGPoint(x: 1, y: 1)
            let emptyInWindow = pet.petView.convert(emptyLocal, to: nil)
            let emptyOnScreen = pet.panel.convertPoint(toScreen: emptyInWindow)
            pet.refreshMouseAcceptance(at: emptyOnScreen)
            checks["empty_region_passes_mouse"] = pet.panel.ignoresMouseEvents
            var opaqueLocal: CGPoint?
            for y in stride(from: 10.0, to: Double(pet.size - 10), by: 5) {
                for x in stride(from: 10.0, to: Double(pet.size - 10), by: 5) {
                    let point = CGPoint(x: x, y: y)
                    if pet.petView.containsCharacter(at: point) { opaqueLocal = point; break }
                }
                if opaqueLocal != nil { break }
            }
            if let opaqueLocal {
                let inWindow = pet.petView.convert(opaqueLocal, to: nil)
                let onScreen = pet.panel.convertPoint(toScreen: inWindow)
                pet.refreshMouseAcceptance(at: onScreen)
                checks["character_accepts_mouse"] = !pet.panel.ignoresMouseEvents
            } else { checks["character_accepts_mouse"] = false }
            pet.setSize(250)
            checks["upper_size_clamped"] = pet.size == 220
            pet.setSize(50)
            checks["lower_size_clamped"] = pet.size == 100
            pet.setSize(160)
            pet.hide()
            checks["hide_keeps_app_alive"] = !pet.panel.isVisible && statusItem != nil
            pet.show()
            checks["show_recovers_pet"] = pet.panel.isVisible
            pet.willSleep()
            checks["sleep_hides_pet"] = !pet.panel.isVisible
            pet.didWake()
            checks["wake_restores_visible_pet"] = pet.panel.isVisible
            pet.hide()
            pet.willSleep()
            pet.didWake()
            checks["wake_preserves_user_hidden_state"] = !pet.panel.isVisible
            pet.show()
            pet.petView.layoutSubtreeIfNeeded()
            for zone in PetTouchZone.allCases {
                let point = PetTouchLayout.samplePoint(for: zone, in: pet.petView.imageRect)
                checks["zone_\(zone.rawValue)_hit"] = pet.petView.touchZone(at: point) == zone
                let triggered = pet.petView.triggerTouch(at: point)
                checks["zone_\(zone.rawValue)_animation"] = triggered && pet.petView.lastFeedbackZone == zone && pet.petView.feedbackIsActive
                pet.recoverPosition()
                checks["zone_\(zone.rawValue)_bubble"] = pet.feedbackBubbleIsVisible
                pet.petView.stopFeedback()
                checks["zone_\(zone.rawValue)_cleanup"] = !pet.petView.feedbackIsActive
            }
            checks["transparent_point_has_no_zone"] = pet.petView.touchZone(at: CGPoint(x: 1, y: 1)) == nil
            for part in [PetTouchZone.head, .belly, .tail] {
                pet.petView.showDebugPart(part)
                pet.petView.displayIfNeeded()
                if let bitmap = pet.petView.bitmapImageRepForCachingDisplay(in: pet.petView.bounds) {
                    pet.petView.cacheDisplay(in: pet.petView.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("rig-\(part.rawValue).png"))
                    }
                }
            }
            pet.petView.showDebugPart(nil)
            pet.petView.displayIfNeeded()
            if let bitmap = pet.petView.bitmapImageRepForCachingDisplay(in: pet.petView.bounds) {
                pet.petView.cacheDisplay(in: pet.petView.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("pet-view.png"))
                }
            }
            let scratchSettings = AppSettingsStore(fileURL: directory.appendingPathComponent("settings-qa/settings.json"))
            let validationSettings = SettingsWindowController(store: scratchSettings,
                keyStore: MemoryAPIKeyStore(), onSizeChanged: { _ in })
            for (name, passed) in try validationSettings.captureValidation(at: directory) {
                checks["settings_\(name)"] = passed
            }
            let careSession = CompanionSession(store: CompanionStateStore(
                fileURL: directory.appendingPathComponent("qa-companion/companion.json")))
            let careMemory = MemoryStore(rootURL: directory.appendingPathComponent("qa-memory", isDirectory: true))
            let careSettings = SettingsWindowController(store: scratchSettings, keyStore: MemoryAPIKeyStore(),
                onSizeChanged: { _ in }, companion: careSession, memory: careMemory)
            checks["settings_care_tab_when_injected"] = careSettings.careTabIsPresent()
            careSettings.close()
            checks["application_has_no_regular_dock_presence"] = NSApp.activationPolicy() == .accessory
            let result: [String: Any] = [
                "passed": checks.values.allSatisfy { $0 },
                "checks": checks,
                "architecture": "arm64",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "note": "Internal AppKit checks, not cross-application physical-input or multi-screen end-to-end tests."
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("appkit-checks.json"))
            print(String(decoding: data, as: UTF8.self))
            Task { @MainActor in await self.runMotionValidation(at: directory) }
            return
        } catch { print("Validation error: \(error)") }
        NSApp.terminate(nil)
    }

    private func runMotionValidation(at directory: URL) async {
        guard let pet else { NSApp.terminate(nil); return }
        var checks: [String: Bool] = [:]
        do {
            for zone in PetTouchZone.allCases {
                let point = PetTouchLayout.samplePoint(for: zone, in: pet.petView.imageRect)
                pet.petView.triggerTouch(at: point)
                checks["\(zone.rawValue)_correct_local_layer"] = pet.petView.feedbackTargetsAreValid(for: zone)
                try await Task.sleep(for: .milliseconds(250))
                checks["\(zone.rawValue)_presentation_moves"] = pet.petView.feedbackHasVisibleMotion(for: zone)
                try await Task.sleep(for: .milliseconds(850))
                checks["\(zone.rawValue)_automatically_cleans_up"] = !pet.petView.feedbackIsActive
                checks["\(zone.rawValue)_returns_to_rest_pose"] = !pet.petView.feedbackHasVisibleMotion(for: zone)
            }
            pet.pet(zone: .cheek)
            let singleCount = pet.petView.feedbackAnimationCount
            for _ in 0..<20 { pet.pet(zone: .cheek) }
            checks["rapid_touches_replace_not_stack"] = pet.petView.feedbackAnimationCount == singleCount
            try await Task.sleep(for: .milliseconds(1100))
            checks["rapid_touches_return_to_idle"] = !pet.petView.feedbackIsActive
            pet.pet(zone: .tail)
            try await Task.sleep(for: .milliseconds(750))
            pet.pet(zone: .cheek)
            try await Task.sleep(for: .milliseconds(400))
            checks["old_cleanup_does_not_interrupt_new_touch"] = pet.petView.feedbackTargetsAreValid(for: .cheek)
            try await Task.sleep(for: .milliseconds(700))
            checks["replacement_touch_cleans_up_on_its_own"] = !pet.petView.feedbackIsActive
            pet.hide()
            checks["hide_clears_feedback_bubble"] = !pet.feedbackBubbleIsVisible
            let result: [String: Any] = [
                "passed": checks.values.allSatisfy { $0 },
                "checks": checks,
                "note": "Timed checks of this app's Core Animation presentation layers; no external input injection."
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("motion-checks.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch { print("Motion validation error: \(error)") }
        NSApp.terminate(nil)
    }
}
