import AppKit

/// QA only: tracks presence and successful operations, never retains a key's contents.
final class MemoryAPIKeyStore: APIKeyStore {
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var queryCount = 0
    private(set) var isPresent = false

    func containsKey() throws -> Bool {
        queryCount += 1
        return isPresent
    }

    func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw SettingsUIError.invalidQAKey
        }
        saveCount += 1
        isPresent = true
    }

    func delete() throws {
        deleteCount += 1
        isPresent = false
    }
}

private enum SettingsUIError: LocalizedError {
    case invalidQAKey
    case unsafeValidationStore
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .invalidQAKey: return "验证密钥不能为空或包含内部空白。"
        case .unsafeValidationStore: return "设置验证仅允许独立临时配置和 MemoryAPIKeyStore。"
        case .snapshotFailed: return "无法导出设置标签页图片。"
        }
    }
}

private final class SettingsPageView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let store: AppSettingsStore
    private let keyStore: any APIKeyStore
    private let onSizeChanged: (CGFloat) -> Void
    private let companionSession: CompanionSession?
    private let memoryStore: MemoryStore?
    private let onCareChanged: () -> Void
    private let showsCare: Bool
    private var carePane: CompanionMemoryPane? = nil
    private var persisted = AppSettings()
    private var readBlocked = false
    private var displayedPetSize: CGFloat = 160

    private let tabs = NSTabView()
    private let pagePicker = NSSegmentedControl(labels: ["外观", "模型", "角色"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let appearancePage = SettingsPageView()
    private let modelsPage = SettingsPageView()
    private let personaPage = SettingsPageView()
    private let personaEditor = NSTextView()
    private let personaFeedback = NSTextField(wrappingLabelWithString: "")
    private let savePersonaButton = NSButton()
    private let previewPersonaButton = NSButton()
    private let restorePersonaButton = NSButton()
    private var personaPreviewWindow: NSWindow?
    private var personaPreviewTextView: NSTextView?
    private let sizeLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 160, minValue: 100, maxValue: 220,
                                      target: nil, action: nil)
    private let sizeFeedback = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSSecureTextField()
    private let keyStatus = NSTextField(labelWithString: "")
    private let keyFeedback = NSTextField(wrappingLabelWithString: "")
    private let companionField = NSTextField()
    private let researchField = NSTextField()
    private let modelFeedback = NSTextField(wrappingLabelWithString: "")
    private let saveKeyButton = NSButton()
    private let deleteKeyButton = NSButton()
    private let copyButton = NSButton()
    private let saveModelsButton = NSButton()
    private let reloadButton = NSButton()
    private let restoreButton = NSButton()

    init(store: AppSettingsStore, keyStore: any APIKeyStore,
         onSizeChanged: @escaping (CGFloat) -> Void,
         companion: CompanionSession? = nil, memory: MemoryStore? = nil,
         onCareChanged: @escaping () -> Void = {}) {
        self.store = store
        self.keyStore = keyStore
        self.onSizeChanged = onSizeChanged
        self.companionSession = companion
        self.memoryStore = memory
        self.onCareChanged = onCareChanged
        self.showsCare = companion != nil && memory != nil
        let height: CGFloat = showsCare ? 740 : 600
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "团团 · 设置"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        buildInterface(in: window)
        reloadModelsFromDisk(notifySize: false, reloadPersona: true)
        refreshKeyStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:keyStore:onSizeChanged:)") }

    func present() {
        // Do not reload model fields here: the same window owns any unsaved draft.
        refreshKeyStatus()
        carePane?.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Pet movement/visibility callbacks may call this often. No disk write or model reload.
    func syncPetSize(_ size: CGFloat) {
        guard size.isFinite else { return }
        displayedPetSize = min(220, max(100, size))
        sizeSlider.doubleValue = Double(displayedPetSize)
        sizeLabel.stringValue = "角色尺寸  \(Int(displayedPetSize.rounded())) pt"
    }

    func windowWillClose(_ notification: Notification) {
        // Model and persona drafts survive closing; unsaved secrets deliberately do not.
        clearKeyInput()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === companionField || field === researchField else { return }
        if readBlocked {
            setFeedback(modelFeedback, "设置读取失败，原文件未覆盖。请重新读取，或明确恢复默认后再保存。", error: true)
        } else {
            setFeedback(modelFeedback, hasModelDraft ? "模型 ID 有未保存的更改。" : "模型 ID 与已保存设置一致。")
        }
    }

    private var hasModelDraft: Bool {
        companionField.stringValue != persisted.companionModelID ||
        researchField.stringValue != persisted.researchModelID
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === personaEditor else { return }
        updatePersonaFeedback()
    }

    private func updatePersonaFeedback() {
        let count = personaEditor.string.trimmingCharacters(in: .whitespacesAndNewlines).count
        if readBlocked {
            setFeedback(personaFeedback, "设置读取失败，未覆盖原文件。请到“模型”页重新读取或明确恢复配置。", error: true)
        } else if count > 6000 {
            setFeedback(personaFeedback, "\(count) / 6000 字符，超出上限；请缩短后保存。输入不会被截断。", error: true)
        } else {
            let status = personaEditor.string == persisted.personaPrompt ? "与已保存角色一致。" : "有未保存的角色更改。"
            setFeedback(personaFeedback, "\(count) / 6000 字符。\(status)空白保存时采用默认角色。")
        }
    }

    private func buildInterface(in window: NSWindow) {
        let contentHeight: CGFloat = showsCare ? 740 : 600
        let content = SettingsPageView(frame: NSRect(x: 0, y: 0, width: 600, height: contentHeight))
        content.wantsLayer = true
        window.contentView = content
        pagePicker.frame = NSRect(x: showsCare ? 110 : 150, y: 16, width: showsCare ? 380 : 300, height: 30)
        pagePicker.target = self
        pagePicker.action = #selector(selectPage(_:))
        pagePicker.selectedSegment = 0
        pagePicker.setAccessibilityLabel(showsCare ? "设置分类：外观、模型、角色或养成" : "设置分类：外观、模型或角色")
        content.addSubview(pagePicker)
        let tabHeight = contentHeight - 78
        tabs.frame = NSRect(x: 18, y: 60, width: 564, height: tabHeight)
        tabs.autoresizingMask = [.width, .height]
        tabs.font = .systemFont(ofSize: 13)
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        let pageHeight: CGFloat = showsCare ? tabHeight : 524
        for (identifier, title, page) in [("appearance", "外观", appearancePage),
                                           ("models", "模型", modelsPage),
                                           ("persona", "角色", personaPage)] {
            page.frame = NSRect(x: 0, y: 0, width: 536, height: pageHeight)
            page.wantsLayer = true
            page.autoresizingMask = [.width, .height]
            let item = NSTabViewItem(identifier: identifier)
            item.label = title
            item.view = page
            tabs.addTabViewItem(item)
        }
        if showsCare, let companionSession, let memoryStore {
            pagePicker.segmentCount = 4
            pagePicker.setLabel("养成", forSegment: 3)
            for index in 0..<4 { pagePicker.setWidth(86, forSegment: index) }
            let care = SettingsPageView(frame: NSRect(x: 0, y: 0, width: 536, height: pageHeight))
            care.wantsLayer = true
            care.autoresizingMask = [.width, .height]
            let pane = CompanionMemoryPane(frame: care.bounds, session: companionSession, memory: memoryStore,
                                           onChanged: { [weak self] in self?.onCareChanged() })
            pane.autoresizingMask = [.width, .height]
            care.addSubview(pane)
            carePane = pane
            let item = NSTabViewItem(identifier: "care")
            item.label = "养成"
            item.view = care
            tabs.addTabViewItem(item)
        }
        content.addSubview(tabs)
        buildAppearancePage()
        buildModelsPage()
        buildPersonaPage()
        tabs.selectTabViewItem(at: 0)
    }

    @objc private func selectPage(_ sender: NSSegmentedControl) {
        guard (0..<tabs.numberOfTabViewItems).contains(sender.selectedSegment) else { return }
        tabs.selectTabViewItem(at: sender.selectedSegment)
        if sender.selectedSegment == 3 { carePane?.reload() }
    }

    private func buildAppearancePage() {
        addLabel("一只安静待在桌面上的小伙伴", to: appearancePage,
                 x: 18, y: 20, width: 496, height: 28, size: 20, weight: .semibold)
        addLabel("原生 macOS · 无声 · 静置时没有动画循环", to: appearancePage,
                 x: 18, y: 55, width: 496, height: 22, size: 12, color: .secondaryLabelColor)
        sizeLabel.frame = NSRect(x: 18, y: 106, width: 496, height: 24)
        sizeLabel.font = .systemFont(ofSize: 14, weight: .medium)
        appearancePage.addSubview(sizeLabel)
        sizeSlider.frame = NSRect(x: 16, y: 141, width: 500, height: 24)
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        // One action at mouse-up, rather than one atomic file write per dragged pixel.
        sizeSlider.isContinuous = false
        sizeSlider.setAccessibilityLabel("团团尺寸，100 到 220 点；结束拖动后保存")
        appearancePage.addSubview(sizeSlider)
        addLabel("100 pt", to: appearancePage, x: 18, y: 169, width: 100, height: 18,
                 size: 11, color: .secondaryLabelColor)
        let maximum = addLabel("220 pt", to: appearancePage, x: 416, y: 169, width: 98,
                               height: 18, size: 11, color: .secondaryLabelColor)
        maximum.alignment = .right
        prepareFeedback(sizeFeedback, in: appearancePage, x: 18, y: 198, width: 496, height: 42)
        addSeparator(to: appearancePage, y: 253)
        addLabel("和团团相处", to: appearancePage, x: 18, y: 278, width: 496,
                 height: 24, size: 15, weight: .semibold)
        addLabel("点头顶：点头；点脸颊：轻蹭和脸红\n点肚子：软弹；点尾巴：局部摆尾\n拖动换位置；右键 / 菜单栏爪印管理\n关闭设置窗口不会退出团团。", to: appearancePage,
                 x: 18, y: 316, width: 496, height: 98, size: 13, color: .secondaryLabelColor)
        addSeparator(to: appearancePage, y: 434)
        addLabel("鼠标指针仅用于本机透明区域命中判断，不记录。\n只有显式发送聊天 / 调研才联网；保存设置本身不联网。", to: appearancePage,
                 x: 18, y: 455, width: 496, height: 48, size: 12, color: .secondaryLabelColor)
    }

    private func buildModelsPage() {
        addLabel("OpenRouter 模型设置", to: modelsPage, x: 18, y: 14, width: 496,
                 height: 26, size: 18, weight: .semibold)
        let endpoint = addLabel("服务地址：https://openrouter.ai/api/v1", to: modelsPage,
                                x: 18, y: 45, width: 496, height: 20, size: 12,
                                color: .secondaryLabelColor)
        endpoint.isSelectable = true
        addLabel("仅显式发送聊天 / 调研时联网；保存设置不联网，仅检查格式。\n保存不核验模型或费用；工具兼容性由实际请求验证。", to: modelsPage,
                 x: 18, y: 72, width: 496, height: 36, size: 12, color: .secondaryLabelColor)

        addLabel("API 密钥", to: modelsPage, x: 18, y: 118, width: 120, height: 22,
                 size: 13, weight: .semibold)
        keyStatus.frame = NSRect(x: 156, y: 119, width: 358, height: 20)
        keyStatus.font = .systemFont(ofSize: 11)
        keyStatus.alignment = .right
        keyStatus.textColor = .secondaryLabelColor
        modelsPage.addSubview(keyStatus)
        keyField.frame = NSRect(x: 18, y: 148, width: 294, height: 24)
        keyField.placeholderString = "输入新密钥（不回填已保存内容）"
        keyField.font = .systemFont(ofSize: 12)
        keyField.setAccessibilityLabel("新的 OpenRouter API 密钥；不显示已保存密钥")
        modelsPage.addSubview(keyField)
        configure(saveKeyButton, title: "保存密钥", action: #selector(saveKey(_:)),
                  in: modelsPage, x: 316, y: 144, width: 94)
        configure(deleteKeyButton, title: "删除密钥", action: #selector(deleteKey(_:)),
                  in: modelsPage, x: 410, y: 144, width: 108)
        addLabel("仅存入本机钥匙串；留空不删除。关闭窗口会清空未保存密钥。", to: modelsPage,
                 x: 18, y: 180, width: 496, height: 30, size: 11, color: .secondaryLabelColor)
        prepareFeedback(keyFeedback, in: modelsPage, x: 18, y: 212, width: 496, height: 32)
        addSeparator(to: modelsPage, y: 253)

        addLabel("模型 ID（手动填写；留空表示未配置）", to: modelsPage,
                 x: 18, y: 267, width: 496, height: 22, size: 13, weight: .semibold)
        addLabel("陪伴", to: modelsPage, x: 18, y: 305, width: 60, height: 22, size: 13)
        addLabel("调研", to: modelsPage, x: 18, y: 344, width: 60, height: 22, size: 13)
        for (field, role, y) in [(companionField, "陪伴", 302.0), (researchField, "调研", 341.0)] {
            field.frame = NSRect(x: 82, y: y, width: 432, height: 24)
            field.font = .systemFont(ofSize: 12)
            field.placeholderString = "例如 provider/model-id（不是网址）"
            field.delegate = self
            field.setAccessibilityLabel("\(role)模型 ID")
            modelsPage.addSubview(field)
        }
        configure(copyButton, title: "复制陪伴到调研", action: #selector(copyCompanion(_:)),
                  in: modelsPage, x: 12, y: 377, width: 160)
        configure(saveModelsButton, title: "保存模型", action: #selector(saveModels(_:)),
                  in: modelsPage, x: 396, y: 377, width: 122)
        prepareFeedback(modelFeedback, in: modelsPage, x: 18, y: 417, width: 496, height: 43)
        configure(reloadButton, title: "重新读取", action: #selector(reloadModels(_:)),
                  in: modelsPage, x: 12, y: 475, width: 110)
        configure(restoreButton, title: "恢复模型默认…", action: #selector(confirmRestore(_:)),
                  in: modelsPage, x: 126, y: 475, width: 150)
        addLabel("模型操作不会删除密钥", to: modelsPage, x: 302, y: 483, width: 212,
                 height: 20, size: 11, color: .secondaryLabelColor)
    }

    private func buildPersonaPage() {
        addLabel("团团的身份、角色与语气", to: personaPage, x: 18, y: 14,
                 width: 496, height: 26, size: 18, weight: .semibold)
        addLabel("陪伴聊天的 system prompt · 最多 6000 字符 · 留空恢复默认", to: personaPage,
                 x: 18, y: 48, width: 496, height: 24, size: 12, color: .secondaryLabelColor)
        addLabel("只影响保存后的下一次聊天，不改变应用的固定权限。\n调研始终使用独立工作提示词；正在进行的聊天 / 调研不变。\n编辑、保存和预览均在本机完成，不会联网或调用模型。", to: personaPage,
                 x: 18, y: 79, width: 496, height: 58, size: 12, color: .secondaryLabelColor)
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 149, width: 496, height: 254))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        configurePersonaTextView(personaEditor, in: scroll, editable: true)
        personaEditor.delegate = self
        personaEditor.setAccessibilityLabel("角色 system prompt：身份、角色与语气，最多 6000 字符")
        personaPage.addSubview(scroll)
        prepareFeedback(personaFeedback, in: personaPage, x: 18, y: 417, width: 496, height: 43)
        configure(savePersonaButton, title: "保存角色", action: #selector(savePersona(_:)),
                  in: personaPage, x: 12, y: 475, width: 118)
        configure(previewPersonaButton, title: "本地预览", action: #selector(previewPersona(_:)),
                  in: personaPage, x: 134, y: 475, width: 118)
        configure(restorePersonaButton, title: "恢复角色默认…", action: #selector(confirmRestorePersona(_:)),
                  in: personaPage, x: 354, y: 475, width: 164)
    }

    private func configurePersonaTextView(_ textView: NSTextView, in scroll: NSScrollView, editable: Bool) {
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                      height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        scroll.documentView = textView
    }

    @discardableResult
    private func addLabel(_ text: String, to view: NSView, x: CGFloat, y: CGFloat,
                          width: CGFloat, height: CGFloat, size: CGFloat,
                          weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        view.addSubview(label)
        return label
    }

    private func addSeparator(to view: NSView, y: CGFloat) {
        let separator = NSBox(frame: NSRect(x: 18, y: y, width: 496, height: 1))
        separator.boxType = .separator
        view.addSubview(separator)
    }

    private func configure(_ button: NSButton, title: String, action: Selector,
                           in view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = action
        button.frame = NSRect(x: x, y: y, width: width, height: 32)
        view.addSubview(button)
    }

    private func prepareFeedback(_ field: NSTextField, in view: NSView,
                                 x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        view.addSubview(field)
    }

    private func setFeedback(_ field: NSTextField, _ text: String, error: Bool = false) {
        field.stringValue = text
        field.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func clearKeyInput() {
        if let editor = keyField.currentEditor() { editor.string = "" }
        window?.endEditing(for: keyField)
        keyField.stringValue = ""
    }

    private func refreshKeyStatus() {
        do {
            let present = try keyStore.containsKey()
            keyStatus.stringValue = present ? "密钥已保存（不显示内容）" : "尚未保存密钥"
            deleteKeyButton.isEnabled = present
        } catch {
            keyStatus.stringValue = "无法查询密钥状态"
            deleteKeyButton.isEnabled = true
            setFeedback(keyFeedback, "无法查询钥匙串元信息。未读取或显示密钥内容。", error: true)
        }
    }

    @objc private func saveKey(_ sender: NSButton) {
        let candidate = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            setFeedback(keyFeedback, "未保存：请输入密钥。留空不会删除已有密钥。", error: true)
            return
        }
        guard !candidate.contains(where: { $0.isWhitespace }) else {
            setFeedback(keyFeedback, "密钥不能包含内部空白；未保存，也未更改模型。", error: true)
            return
        }
        do {
            try keyStore.save(candidate)
            clearKeyInput()
            refreshKeyStatus()
            setFeedback(keyFeedback, "密钥已单独保存；输入已清空。模型设置未更改。")
        } catch {
            // Never interpolate a key or an arbitrary backend error into UI/logs.
            setFeedback(keyFeedback, "密钥保存失败。请检查钥匙串权限后重试；模型设置未更改。", error: true)
        }
    }

    @objc private func deleteKey(_ sender: NSButton) {
        do {
            try keyStore.delete()
            clearKeyInput()
            refreshKeyStatus()
            setFeedback(keyFeedback, "密钥已删除。两个模型 ID 与未保存输入均未更改。")
        } catch {
            setFeedback(keyFeedback, "密钥删除失败。请检查钥匙串权限后重试；模型设置未更改。", error: true)
        }
    }

    private func setReadBlocked() {
        readBlocked = true
        saveModelsButton.isEnabled = false
        savePersonaButton.isEnabled = false
        restorePersonaButton.isEnabled = false
        sizeSlider.isEnabled = false
        let message = "设置读取失败，原文件未覆盖。请重新读取，或明确恢复模型默认以重建配置。"
        setFeedback(modelFeedback, message, error: true)
        setFeedback(sizeFeedback, message, error: true)
        updatePersonaFeedback()
    }

    private func allowSettingsEdits() {
        readBlocked = false
        saveModelsButton.isEnabled = true
        savePersonaButton.isEnabled = true
        restorePersonaButton.isEnabled = true
        sizeSlider.isEnabled = true
    }

    /// Every write re-reads the file first, so stale UI cannot silently replace a damaged file.
    private func settingsForWrite() throws -> AppSettings {
        do { return try store.load() }
        catch {
            setReadBlocked()
            throw error
        }
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        guard !readBlocked else {
            syncPetSize(displayedPetSize)
            return
        }
        let previousSize = displayedPetSize
        do {
            var next = try settingsForWrite()
            next.petSize = sender.doubleValue
            try store.save(next)
            persisted = next
            syncPetSize(CGFloat(next.petSize))
            onSizeChanged(CGFloat(next.petSize))
            setFeedback(sizeFeedback, "尺寸已保存。结束拖动时提交，不影响未保存的模型输入。")
        } catch {
            syncPetSize(previousSize)
            if !readBlocked {
                setFeedback(sizeFeedback, "尺寸保存失败，已保留原尺寸；模型输入未更改。", error: true)
            }
        }
    }

    @objc private func copyCompanion(_ sender: NSButton) {
        researchField.stringValue = companionField.stringValue
        setFeedback(modelFeedback, "已复制到调研输入框；点击“保存模型”后才会写入配置。")
    }

    @objc private func saveModels(_ sender: NSButton) {
        guard !readBlocked else { return }
        do {
            var next = try settingsForWrite()
            next.companionModelID = companionField.stringValue
            next.researchModelID = researchField.stringValue
            do { next = try next.validated() }
            catch {
                setFeedback(modelFeedback, "模型未保存：请填写合理的模型 ID，勿填网址或内部空白。输入已保留。", error: true)
                return
            }
            try store.save(next)
            persisted = next
            companionField.stringValue = next.companionModelID
            researchField.stringValue = next.researchModelID
            setFeedback(modelFeedback, "两个模型 ID 已保存。未联网验证；密钥未更改。")
        } catch {
            if !readBlocked {
                setFeedback(modelFeedback, "模型保存失败；输入已保留，密钥未更改。请检查配置文件权限。", error: true)
            }
        }
    }

    @objc private func reloadModels(_ sender: NSButton) {
        if hasModelDraft {
            askToDiscard(title: "重新读取并放弃未保存的模型输入？", detail: "将从本机配置重新读取设置；不会更改已保存密钥。",
                         confirm: "重新读取") { [weak self] in self?.reloadModelsFromDisk() }
        } else {
            reloadModelsFromDisk()
        }
    }

    private func reloadModelsFromDisk(notifySize: Bool = true, reloadPersona: Bool = false) {
        do {
            let loaded = try store.load()
            persisted = loaded
            companionField.stringValue = loaded.companionModelID
            researchField.stringValue = loaded.researchModelID
            if reloadPersona { personaEditor.string = loaded.personaPrompt }
            allowSettingsEdits()
            updatePersonaFeedback()
            syncPetSize(CGFloat(loaded.petSize))
            if notifySize { onSizeChanged(CGFloat(loaded.petSize)) }
            setFeedback(sizeFeedback, "尺寸在结束拖动时自动保存。")
            setFeedback(modelFeedback, "已读取本机设置。模型与密钥分别保存；不会自动联网。")
        } catch {
            // Leave existing draft text and damaged bytes intact.
            setReadBlocked()
        }
    }

    @objc private func confirmRestore(_ sender: NSButton) {
        let detail = readBlocked
            ? "将以默认配置重建无法读取的设置文件：尺寸 160 pt，两个模型 ID 留空，角色恢复默认。此操作会覆盖原配置，但不会删除密钥。"
            : "将清空两个模型 ID 并立即保存，未保存的模型输入会被替换。保留已保存尺寸和角色，不会删除密钥。"
        askToDiscard(title: "恢复模型默认设置？", detail: detail, confirm: "恢复默认") { [weak self] in
            self?.restoreModelDefaults()
        }
    }

    private func askToDiscard(title: String, detail: String, confirm: String,
                              action: @escaping @MainActor () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: confirm)
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { action() }
        }
    }

    /// Called only after explicit confirmation, or by the isolated QA entry point below.
    private func restoreModelDefaults() {
        do {
            // A damaged file can be replaced only through this explicit recovery path.
            var next: AppSettings
            let recovering = readBlocked
            if recovering {
                next = AppSettings()
            } else {
                next = try settingsForWrite()
                next.companionModelID = ""
                next.researchModelID = ""
            }
            try store.save(next)
            persisted = next
            companionField.stringValue = ""
            researchField.stringValue = ""
            if recovering { personaEditor.string = next.personaPrompt }
            allowSettingsEdits()
            updatePersonaFeedback()
            syncPetSize(CGFloat(next.petSize))
            onSizeChanged(CGFloat(next.petSize))
            setFeedback(sizeFeedback, "尺寸已保存。")
            setFeedback(modelFeedback, recovering
                ? "已明确重建默认配置：尺寸 160 pt，模型留空，角色默认。密钥未删除。"
                : "已恢复模型默认（两个 ID 留空）。密钥未删除，角色未更改。")
        } catch {
            setFeedback(modelFeedback, "恢复默认失败，未宣告保存成功。请检查配置文件权限。", error: true)
        }
    }

    @objc private func savePersona(_ sender: NSButton) {
        guard !readBlocked else { return }
        do {
            var next = try settingsForWrite()
            next.personaPrompt = personaEditor.string
            do { next = try next.validated() }
            catch {
                setFeedback(personaFeedback, "角色未保存：去除首尾空白后不能超过 6000 字符。输入已保留。", error: true)
                return
            }
            try store.save(next)
            persisted = next
            personaEditor.string = next.personaPrompt
            setFeedback(personaFeedback, "角色已保存，下一次聊天采用；进行中的任务、模型与密钥不变。")
        } catch {
            if !readBlocked {
                setFeedback(personaFeedback, "角色保存失败，输入已保留；模型与密钥未更改。", error: true)
            }
        }
    }

    @objc private func previewPersona(_ sender: NSButton) {
        let persona: String
        do { persona = try AppSettings(personaPrompt: personaEditor.string).validated().personaPrompt }
        catch {
            setFeedback(personaFeedback, "无法预览：角色去除首尾空白后不能超过 6000 字符。", error: true)
            return
        }
        // Deliberately no client, coordinator, key access, or store write in this path.
        if personaPreviewWindow == nil {
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            preview.title = "团团 · 角色本地预览（非模型回复）"
            preview.isReleasedWhenClosed = false
            preview.isRestorable = false
            let content = SettingsPageView(frame: NSRect(x: 0, y: 0, width: 540, height: 430))
            preview.contentView = content
            addLabel("最终角色文本 · 未发送给模型，也未保存\n应用的固定权限不会因角色文字改变。", to: content,
                     x: 18, y: 14, width: 504, height: 42, size: 12, color: .secondaryLabelColor)
            let scroll = NSScrollView(frame: NSRect(x: 18, y: 68, width: 504, height: 344))
            scroll.autoresizingMask = [.width, .height]
            scroll.borderType = .bezelBorder
            scroll.hasVerticalScroller = true
            let textView = NSTextView()
            configurePersonaTextView(textView, in: scroll, editable: false)
            textView.setAccessibilityLabel("本地最终角色文本；未请求模型")
            content.addSubview(scroll)
            personaPreviewTextView = textView
            personaPreviewWindow = preview
            preview.center()
        }
        personaPreviewTextView?.string = persona
        personaPreviewWindow?.makeKeyAndOrderFront(nil)
        setFeedback(personaFeedback, "仅在本机预览最终角色文本；没有联网、读取密钥或保存。")
    }

    @objc private func confirmRestorePersona(_ sender: NSButton) {
        guard !readBlocked else { return }
        askToDiscard(title: "恢复团团的默认角色？",
                     detail: "将替换角色草稿并立即保存默认角色；模型、尺寸和密钥不变，不影响进行中的任务。",
                     confirm: "恢复角色默认") { [weak self] in self?.restorePersonaDefaults() }
    }

    private func restorePersonaDefaults() {
        guard !readBlocked else { return }
        do {
            var next = try settingsForWrite()
            next.personaPrompt = AppSettings.defaultPersonaPrompt
            try store.save(next)
            persisted = next
            personaEditor.string = next.personaPrompt
            setFeedback(personaFeedback, "已恢复默认角色，下一次聊天采用；模型、尺寸和密钥不变。")
        } catch {
            if !readBlocked {
                setFeedback(personaFeedback, "恢复角色失败，未保存；模型与密钥未更改。", error: true)
            }
        }
    }

    /// True only when this window was given both a companion session and a memory store.
    func careTabIsPresent() -> Bool {
        guard showsCare, tabs.numberOfTabViewItems == 4 else { return false }
        return tabs.tabViewItem(at: 0).label == "外观" && tabs.tabViewItem(at: 1).label == "模型" &&
            tabs.tabViewItem(at: 2).label == "角色" && tabs.tabViewItem(at: 3).label == "养成" &&
            carePane != nil
    }

    /// Uses this same controller and its injected scratch file; never creates a production store.
    /// Confirmation sheets are deliberately bypassed only for explicit QA recovery calls.
    func captureValidation(at directory: URL) throws -> [String: Bool] {
        let scratch = store.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let production = AppSettingsStore.defaultFileURL.standardizedFileURL.resolvingSymlinksInPath()
        let productionDirectory = production.deletingLastPathComponent().path + "/"
        guard let memory = keyStore as? MemoryAPIKeyStore,
              scratch != production, !scratch.path.hasPrefix(productionDirectory) else {
            throw SettingsUIError.unsafeValidationStore
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [
            "settings_qa_uses_scratch_store": true,
            "settings_qa_uses_memory_keys": true,
            // Preserve the legacy appearance/model coverage while adding a third page.
            "settings_two_native_tabs": tabs.numberOfTabViewItems >= 2 &&
                tabs.tabViewItem(at: 0).label == "外观" && tabs.tabViewItem(at: 1).label == "模型",
            "settings_three_native_tabs": tabs.numberOfTabViewItems == 3,
            "settings_slider_commits_once_per_drag": !sizeSlider.isContinuous,
            "settings_secure_initially_empty": keyField.stringValue.isEmpty
        ]
        defer { clearKeyInput(); personaPreviewWindow?.close() }

        pagePicker.selectedSegment = 2
        selectPage(pagePicker)
        checks["settings_persona_picker_selects_page"] = tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 2
        pagePicker.selectedSegment = 1
        selectPage(pagePicker)
        checks["settings_models_picker_selects_page"] = tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 1
        pagePicker.selectedSegment = 0
        selectPage(pagePicker)
        checks["settings_appearance_picker_selects_page"] = tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 0

        // Deterministic baseline, equivalent to explicitly confirming recovery in this QA window.
        restoreModelDefaults()
        checks.merge(validateEditingShortcuts()) { _, new in new }
        personaEditor.string = "  你是团团，一只温柔的奶白猫。回答简短，不责备用户。\n "
        savePersonaButton.performClick(nil)
        let savedPersona = try store.load().personaPrompt
        checks["settings_persona_saved_and_trimmed"] = savedPersona == "你是团团，一只温柔的奶白猫。回答简短，不责备用户。"
        personaEditor.string = "临时草稿"
        reloadModelsFromDisk(reloadPersona: true)
        checks["settings_persona_reload"] = personaEditor.string == savedPersona
        let beforePreview = try Data(contentsOf: store.fileURL)
        let keyQueriesBeforePreview = memory.queryCount
        personaEditor.string = "  这是只在本机预览的人格草稿。  "
        previewPersonaButton.performClick(nil)
        let bytesAfterPreview = try Data(contentsOf: store.fileURL)
        checks["settings_persona_preview_is_local_and_unsaved"] = personaPreviewTextView?.string == "这是只在本机预览的人格草稿。" &&
            bytesAfterPreview == beforePreview && memory.queryCount == keyQueriesBeforePreview
        personaPreviewWindow?.close()
        personaEditor.string = savedPersona
        companionField.stringValue = "  example/companion-model  "
        researchField.stringValue = "example/research-model"
        saveModelsButton.performClick(nil)
        var disk = try AppSettingsStore(fileURL: store.fileURL).load()
        checks["settings_models_saved_and_trimmed"] = disk.companionModelID == "example/companion-model" &&
            disk.researchModelID == "example/research-model"
        checks["settings_models_save_preserves_persona"] = disk.personaPrompt == savedPersona
        checks["settings_roles_independent"] = disk.companionModelID != disk.researchModelID
        companionField.stringValue = ""
        researchField.stringValue = ""
        // This is the same reload implementation used after the user's discard confirmation.
        reloadModelsFromDisk()
        checks["settings_models_reload"] = companionField.stringValue == disk.companionModelID &&
            researchField.stringValue == disk.researchModelID

        companionField.stringValue = "example/unsaved-companion"
        researchField.stringValue = "example/unsaved-research"
        personaEditor.string = "未保存的角色草稿"
        syncPetSize(184)
        checks["settings_size_sync_preserves_drafts"] = companionField.stringValue == "example/unsaved-companion" &&
            researchField.stringValue == "example/unsaved-research"
        tabs.selectTabViewItem(at: 0)
        tabs.selectTabViewItem(at: 1)
        checks["settings_tab_switch_preserves_drafts"] = companionField.stringValue == "example/unsaved-companion" &&
            researchField.stringValue == "example/unsaved-research"
        sizeSlider.doubleValue = 180
        sizeChanged(sizeSlider)
        let sizedDisk = try store.load()
        checks["settings_size_save_preserves_saved_models"] = sizedDisk.petSize == 180 &&
            sizedDisk.companionModelID == disk.companionModelID && sizedDisk.researchModelID == disk.researchModelID
        checks["settings_size_save_preserves_drafts"] = companionField.stringValue == "example/unsaved-companion" &&
            researchField.stringValue == "example/unsaved-research"
        checks["settings_size_save_preserves_persona_and_draft"] = sizedDisk.personaPrompt == savedPersona &&
            personaEditor.string == "未保存的角色草稿"

        let initialSaveCount = memory.saveCount
        // Obviously synthetic QA input; MemoryAPIKeyStore never retains even this text.
        keyField.stringValue = "  qa-placeholder-not-a-real-key  "
        saveKeyButton.performClick(nil)
        let diskAfterKeySave = try store.load()
        checks["settings_key_saved_separately"] = memory.isPresent && memory.saveCount == initialSaveCount + 1 &&
            diskAfterKeySave == sizedDisk
        checks["settings_secure_cleared_after_save"] = keyField.stringValue.isEmpty
        checks["settings_key_save_preserves_drafts"] = companionField.stringValue == "example/unsaved-companion" &&
            researchField.stringValue == "example/unsaved-research"
        let savesBeforeBlank = memory.saveCount
        let deletesBeforeBlank = memory.deleteCount
        keyField.stringValue = ""
        saveKeyButton.performClick(nil)
        checks["settings_empty_key_does_not_delete"] = memory.isPresent && memory.saveCount == savesBeforeBlank &&
            memory.deleteCount == deletesBeforeBlank

        copyButton.performClick(nil)
        let diskAfterCopy = try store.load()
        checks["settings_copy_companion_to_research"] = researchField.stringValue == "example/unsaved-companion" &&
            diskAfterCopy == sizedDisk
        saveModelsButton.performClick(nil)
        disk = try store.load()
        checks["settings_copied_models_persist"] = disk.companionModelID == "example/unsaved-companion" &&
            disk.researchModelID == disk.companionModelID
        checks["settings_model_operations_preserve_persona_draft"] = disk.personaPrompt == savedPersona &&
            personaEditor.string == "未保存的角色草稿"
        checks["settings_model_save_does_not_touch_key"] = memory.isPresent && memory.saveCount == savesBeforeBlank &&
            memory.deleteCount == deletesBeforeBlank
        let beforeInvalid = disk
        companionField.stringValue = "https://openrouter.ai/not-a-model-id"
        saveModelsButton.performClick(nil)
        checks["settings_invalid_model_rejected_without_overwrite"] = (try store.load()) == beforeInvalid &&
            companionField.stringValue == "https://openrouter.ai/not-a-model-id"
        reloadModelsFromDisk()

        restoreModelDefaults()
        disk = try store.load()
        checks["settings_restore_models_keeps_key"] = disk.companionModelID.isEmpty && disk.researchModelID.isEmpty &&
            memory.isPresent && memory.deleteCount == deletesBeforeBlank
        checks["settings_restore_models_keeps_size"] = disk.petSize == 180
        checks["settings_restore_models_keeps_persona"] = disk.personaPrompt == savedPersona &&
            personaEditor.string == "未保存的角色草稿"

        // Verify corrupted-file protection using only the injected scratch URL.
        let damagedBytes = Data("{qa-invalid-settings".utf8)
        try damagedBytes.write(to: store.fileURL, options: .atomic)
        reloadModelsFromDisk()
        saveModelsButton.performClick(nil)
        sizeSlider.doubleValue = 190
        sizeChanged(sizeSlider)
        savePersonaButton.performClick(nil)
        checks["settings_corrupt_file_not_overwritten"] = (try Data(contentsOf: store.fileURL)) == damagedBytes &&
            readBlocked && !saveModelsButton.isEnabled && !sizeSlider.isEnabled
        let bytesAfterBlockedPersona = try Data(contentsOf: store.fileURL)
        checks["settings_persona_corrupt_file_not_overwritten"] = !savePersonaButton.isEnabled &&
            !restorePersonaButton.isEnabled && bytesAfterBlockedPersona == damagedBytes
        restoreModelDefaults()
        disk = try store.load()
        checks["settings_explicit_corrupt_recovery"] = !readBlocked && disk == AppSettings() && memory.isPresent

        companionField.stringValue = "example/companion-model"
        researchField.stringValue = "example/research-model"
        saveModelsButton.performClick(nil)
        let beforeDelete = try store.load()
        companionField.stringValue = "example/draft-kept-after-delete"
        deleteKeyButton.performClick(nil)
        let diskAfterDelete = try store.load()
        checks["settings_delete_key_independent"] = !memory.isPresent && diskAfterDelete == beforeDelete &&
            companionField.stringValue == "example/draft-kept-after-delete"
        reloadModelsFromDisk()
        keyField.stringValue = "qa-placeholder-not-a-real-key"
        saveKeyButton.performClick(nil)
        // Exercise migration with a genuine old three-field document in this scratch store only.
        let legacy = Data(#"{"petSize":172,"companionModelID":"example/legacy-companion","researchModelID":"example/legacy-research"}"#.utf8)
        try legacy.write(to: store.fileURL, options: .atomic)
        reloadModelsFromDisk(reloadPersona: true)
        let migrated = try store.load()
        let bytesAfterMigration = try Data(contentsOf: store.fileURL)
        checks["settings_persona_legacy_migration"] = personaEditor.string == AppSettings.defaultPersonaPrompt &&
            migrated.petSize == 172 && bytesAfterMigration == legacy
        companionField.stringValue = "example/unsaved-model-draft"
        personaEditor.string = "  自定义角色，温柔而简短。  "
        let keySavesBeforePersona = memory.saveCount
        let keyDeletesBeforePersona = memory.deleteCount
        savePersonaButton.performClick(nil)
        let beforePersonaRestore = try store.load()
        checks["settings_persona_save_independent"] = beforePersonaRestore.personaPrompt == "自定义角色，温柔而简短。" &&
            beforePersonaRestore.petSize == 172 && beforePersonaRestore.companionModelID == "example/legacy-companion" &&
            beforePersonaRestore.researchModelID == "example/legacy-research" && memory.isPresent &&
            memory.saveCount == keySavesBeforePersona && memory.deleteCount == keyDeletesBeforePersona &&
            companionField.stringValue == "example/unsaved-model-draft"
        personaEditor.string = String(repeating: "猫", count: 6001)
        savePersonaButton.performClick(nil)
        checks["settings_persona_over_limit_rejected"] = (try store.load()) == beforePersonaRestore &&
            personaEditor.string.count == 6001
        restorePersonaDefaults()
        var expectedAfterPersonaRestore = beforePersonaRestore
        expectedAfterPersonaRestore.personaPrompt = AppSettings.defaultPersonaPrompt
        checks["settings_restore_persona_keeps_models_size_and_key"] = (try store.load()) == expectedAfterPersonaRestore &&
            memory.isPresent && memory.saveCount == keySavesBeforePersona && memory.deleteCount == keyDeletesBeforePersona &&
            companionField.stringValue == "example/unsaved-model-draft"
        personaEditor.string = " \n\t "
        previewPersonaButton.performClick(nil)
        checks["settings_persona_blank_preview_defaults"] = personaPreviewTextView?.string == AppSettings.defaultPersonaPrompt
        personaPreviewWindow?.close()
        savePersonaButton.performClick(nil)
        checks["settings_persona_blank_save_defaults"] = (try store.load()).personaPrompt == AppSettings.defaultPersonaPrompt
        reloadModelsFromDisk()
        clearKeyInput()
        checks["settings_secure_empty_for_snapshots"] = keyField.stringValue.isEmpty
        checks["settings_key_status_without_secret"] = memory.isPresent && keyStatus.stringValue == "密钥已保存（不显示内容）"
        checks["settings_model_inputs_visible"] = !companionField.isHidden && !researchField.isHidden &&
            companionField.isEditable && researchField.isEditable
        checks["settings_persona_editor_plain_and_editable"] = personaEditor.isEditable && !personaEditor.isRichText &&
            !personaEditor.importsGraphics
        checks["settings_no_api_key_in_json"] = !(try String(contentsOf: store.fileURL, encoding: .utf8))
            .contains("qa-placeholder-not-a-real-key")
        try captureTab(at: 0, to: directory.appendingPathComponent("settings-appearance.png"))
        try captureTab(at: 1, to: directory.appendingPathComponent("settings-models.png"))
        try captureTab(at: 2, to: directory.appendingPathComponent("settings-persona.png"))
        checks["settings_appearance_tab_exported"] = true
        checks["settings_models_tab_exported"] = true
        checks["settings_persona_tab_exported"] = true
        checks["settings_secure_empty_after_validation"] = keyField.stringValue.isEmpty
        return checks
    }

    /// Exercises the real AppKit menu → first responder → field editor path.
    /// Synthetic input only; restores clipboard bytes without logging their contents.
    private func validateEditingShortcuts() -> [String: Bool] {
        let pasteboard = NSPasteboard.general
        let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let drafts = (companionField.stringValue, researchField.stringValue, personaEditor.string)
        defer {
            window?.makeFirstResponder(nil)
            clearKeyInput()
            companionField.stringValue = drafts.0
            researchField.stringValue = drafts.1
            personaEditor.string = drafts.2
            pasteboard.clearContents()
            let restored = originalItems.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
            tabs.selectTabViewItem(at: 0)
        }
        var checks: [String: Bool] = [:]
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Activation is asynchronous when this QA app is launched from a terminal.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        window?.makeKeyAndOrderFront(nil)
        checks["settings_editing_window_has_keyboard_focus"] = NSApp.keyWindow === window
        tabs.selectTabViewItem(at: 1)
        for (name, field) in [("key", keyField as NSTextField),
                              ("companion", companionField), ("research", researchField)] {
            field.stringValue = ""
            window?.makeFirstResponder(field)
            let editor = field.currentEditor() as? NSTextView
            editor?.selectAll(nil)
            pasteboard.clearContents()
            pasteboard.setString("qa/pasted-value", forType: .string)
            let handled = performEditingShortcut("v", keyCode: 9)
            checks["settings_\(name)_command_v_pastes"] = handled && editor?.string == "qa/pasted-value"
            window?.makeFirstResponder(nil)
            checks["settings_\(name)_paste_commits_to_field"] = field.stringValue == "qa/pasted-value"
        }
        tabs.selectTabViewItem(at: 2)
        personaEditor.string = "原有文字"
        window?.makeFirstResponder(personaEditor)
        let selected = performEditingShortcut("a", keyCode: 0)
        checks["settings_persona_command_a_selects_all"] = selected &&
            personaEditor.selectedRange() == NSRange(location: 0, length: (personaEditor.string as NSString).length)
        pasteboard.clearContents()
        pasteboard.setString("粘贴的角色设定\n第二行", forType: .string)
        let handled = performEditingShortcut("v", keyCode: 9)
        checks["settings_persona_command_v_replaces_selection"] = handled &&
            personaEditor.string == "粘贴的角色设定\n第二行"
        checks["settings_paste_does_not_save_key"] = (keyStore as? MemoryAPIKeyStore)?.saveCount == 0
        return checks
    }

    private func performEditingShortcut(_ character: String, keyCode: UInt16) -> Bool {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode) else { return false }
        print("[DEBUG-paste] menu=\(NSApp.mainMenu != nil) key=\(NSApp.keyWindow === window) editor=\(window.firstResponder is NSTextView) target=\(NSApp.target(forAction: #selector(NSText.paste(_:))) != nil)")
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func captureTab(at index: Int, to url: URL) throws {
        clearKeyInput()
        tabs.selectTabViewItem(at: index)
        pagePicker.selectedSegment = index
        guard let view = window?.contentView else { throw SettingsUIError.snapshotFailed }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsUIError.snapshotFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SettingsUIError.snapshotFailed
        }
        try png.write(to: url, options: .atomic)
    }
}
