import AppKit
import UniformTypeIdentifiers

private final class ChatBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Return inserts a newline; only an explicit Command-Return sends a message.
private final class ChatInputView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76),
           modifiers.contains(.command),
           !modifiers.contains(.option), !modifiers.contains(.control), !hasMarkedText() {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

private enum ChatWindowError: LocalizedError {
    case snapshotFailed

    var errorDescription: String? { "无法导出聊天窗口图片。" }
}

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let coordinator: AgentCoordinator
    private let onOpenSettings: () -> Void
    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let input = ChatInputView()
    private let inputScroll = NSScrollView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let taskDetail = NSTextField(wrappingLabelWithString: "")
    private let selectedDetail = NSTextField(wrappingLabelWithString: "")
    private let historyPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sendButton = NSButton()
    private let researchButton = NSButton()
    private let restoreInputButton = NSButton()
    private let cancelChatButton = NSButton()
    private let cancelResearchButton = NSButton()
    private let openReportButton = NSButton()
    private let revealReportButton = NSButton()
    private let saveReportButton = NSButton()
    private let rememberFactButton = NSButton()
    private let clearButton = NSButton()
    private let settingsButton = NSButton()
    private var refreshTask: Task<Void, Never>?
    private var historyRecords: [ResearchRecord] = []
    private var selectedTaskID: UUID?
    private var lastActiveTaskID: UUID?
    private var renderedBlocks: [String] = []
    private var renderedBlockIDs: [UUID] = []
    private var localNotice: String?
    var onVisibility: ((Bool) -> Void)?

    init(coordinator: AgentCoordinator, onOpenSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "团团 · 聊天与调研"
        window.minSize = NSSize(width: 720, height: 788)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        buildInterface(in: window)
        // Keep an existing application-level observer, if one was installed before this UI.
        let previousChange = coordinator.onChange
        coordinator.onChange = { [weak self] in
            previousChange?()
            self?.scheduleRefresh()
        }
        refreshInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(coordinator:onOpenSettings:)") }

    func present() {
        coordinator.refreshHistory()
        refreshInterface()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
        onVisibility?(true)
    }

    func windowWillClose(_ notification: Notification) {
        // Deliberately do not cancel chat or research. Reopening keeps the input draft.
        onVisibility?(false)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === input else { return }
        refreshInputButtons()
    }

    private func buildInterface(in window: NSWindow) {
        let content = ChatBackgroundView(frame: NSRect(x: 0, y: 0, width: 720, height: 760))
        content.wantsLayer = true
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        let title = label("和团团聊聊", size: 20, weight: .semibold)
        configure(settingsButton, title: "设置…", action: #selector(openSettings(_:)))
        configure(clearButton, title: "清空会话…", action: #selector(clearConversation(_:)))
        addRow([title, spacer(), clearButton, settingsButton], to: stack, height: 28)

        let warning = label("调研可能产生额外工具费用 · 每任务最多 3 次搜索 / 5 篇正文 / 3 次请求 / 5 分钟。\n点击发送即联网；取消连接不保证立即停止计费。", size: 11)
        warning.textColor = .systemOrange
        add(warning, to: stack, height: 32)
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.isSelectable = true
        noticeLabel.setAccessibilityLabel("聊天提示与配置状态")
        add(noticeLabel, to: stack, height: 30)

        add(label("会话 · 纯文本", size: 12, weight: .medium), to: stack, height: 17)
        configureTextView(transcript, in: transcriptScroll, editable: false)
        transcript.setAccessibilityLabel("聊天记录，可选择和复制；不执行网页或 Markdown")
        add(transcriptScroll, to: stack)
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        transcriptScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        transcriptScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        add(label("输入消息或调研主题 · 换行：Return · 发送：⌘Return", size: 11,
                  color: .secondaryLabelColor), to: stack, height: 17)
        configureTextView(input, in: inputScroll, editable: true)
        input.delegate = self
        input.setAccessibilityLabel("消息或调研主题，多行输入，Command Return 发送聊天")
        input.onCommandReturn = { [weak self] in self?.submitInput(researchOnly: false) }
        add(inputScroll, to: stack, height: 74)
        configure(sendButton, title: "发送", action: #selector(sendChat(_:)))
        sendButton.toolTip = "发送当前消息；不会因打开窗口、输入或重开窗口而自动发送。"
        configure(researchButton, title: "调研并生成报告", action: #selector(startResearch(_:)))
        researchButton.toolTip = "明确授权当前主题的独立调研。只附带允许使用的调研记忆，不携带私人偏好、亲密度或角色提示。可能有额外工具费用。"
        configure(restoreInputButton, title: "取回上条输入", action: #selector(restoreLastInput(_:)))
        restoreInputButton.toolTip = "只复制本次会话中上一条用户输入，不联网、不重试，不覆盖当前草稿。"
        configure(cancelChatButton, title: "取消回复", action: #selector(cancelChat(_:)))
        addRow([sendButton, researchButton, restoreInputButton, spacer(), cancelChatButton], to: stack, height: 30)

        let separator = NSBox()
        separator.boxType = .separator
        add(separator, to: stack, height: 1)
        taskLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.setAccessibilityLabel("当前调研状态")
        configure(cancelResearchButton, title: "取消调研", action: #selector(cancelResearch(_:)))
        addRow([taskLabel, spacer(), cancelResearchButton], to: stack, height: 26)
        taskDetail.font = .systemFont(ofSize: 11)
        taskDetail.textColor = .secondaryLabelColor
        add(taskDetail, to: stack, height: 30)

        historyPicker.target = self
        historyPicker.action = #selector(selectHistory(_:))
        historyPicker.setAccessibilityLabel("最近调研任务，最多二十条历史和当前任务")
        historyPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        historyPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (historyPicker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        add(historyPicker, to: stack, height: 26)
        selectedDetail.font = .systemFont(ofSize: 11)
        selectedDetail.textColor = .secondaryLabelColor
        selectedDetail.isSelectable = true
        add(selectedDetail, to: stack, height: 30)

        configure(openReportButton, title: "打开报告", action: #selector(openReport(_:)))
        configure(revealReportButton, title: "在 Finder 中显示", action: #selector(revealReport(_:)))
        configure(saveReportButton, title: "另存为…", action: #selector(saveReport(_:)))
        configure(rememberFactButton, title: "记为任务事实", action: #selector(rememberFact(_:)))
        rememberFactButton.toolTip = "把已完成报告的主题记入本机调研记忆。私人聊天不会写入。"
        addRow([openReportButton, revealReportButton, saveReportButton, rememberFactButton, spacer()], to: stack, height: 30)
        add(label("关闭窗口不会取消任务；睡眠 / 锁屏会中断，不会自动重跑。\n缺少模型或密钥时，请点右上角“设置”。清空会话不删除调研报告。", size: 11,
                  color: .secondaryLabelColor), to: stack, height: 30)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func add(_ view: NSView, to stack: NSStackView, height: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    private func addRow(_ views: [NSView], to stack: NSStackView, height: CGFloat) {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        add(row, to: stack, height: height)
    }

    private func configureTextView(_ textView: NSTextView, in scrollView: NSScrollView, editable: Bool) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView.frame = NSRect(x: 0, y: 0, width: 660, height: 70)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = editable
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scrollView.documentView = textView
    }

    /// One finite task per burst, never a polling or permanent timer.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            self.refreshTask = nil
            self.refreshInterface()
        }
    }

    private func refreshInterface() {
        refreshTranscript()
        refreshInputButtons()
        noticeLabel.stringValue = localNotice ?? (coordinator.notice.isEmpty
            ? "准备好了。可以聊天，或明确点击“调研并生成报告”。" : coordinator.notice)
        noticeLabel.toolTip = noticeLabel.stringValue
        cancelChatButton.isEnabled = coordinator.isChatBusy
        cancelResearchButton.isEnabled = coordinator.isResearchBusy
        clearButton.isEnabled = !coordinator.isChatBusy && !coordinator.entries.isEmpty
        if let active = coordinator.activeResearch {
            taskLabel.stringValue = "调研 · \(active.state.title)"
            taskDetail.stringValue = "\(singleLine(active.topic, limit: 72))\n搜索 \(active.searchesUsed)/3 · 正文 \(active.pagesRead)/5 · 请求 \(active.requestCount)/3 · 最多 5 分钟"
            taskDetail.toolTip = active.detail
        } else {
            taskLabel.stringValue = coordinator.isResearchBusy ? "调研进行中" : "调研 · 当前无进行中的任务"
            taskDetail.stringValue = "调研上下文独立；聊天和调研可并行，最多同时进行一个调研，不排队。"
            taskDetail.toolTip = nil
        }
        refreshHistoryPicker()
        refreshReportButtons()
    }

    private func refreshInputButtons() {
        let hasInput = !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasInput && !coordinator.isChatBusy
        researchButton.isEnabled = hasInput && !coordinator.isResearchBusy
        restoreInputButton.isEnabled = input.string.isEmpty && coordinator.entries.contains(where: { $0.role == .user })
    }

    /// Keep unchanged paragraphs, replace only the changed suffix, and preserve a reader's scroll position.
    private func refreshTranscript() {
        let entries = coordinator.entries
        let blocks = entries.map { entry in
            let status = entry.isError ? " · 未成功" : (entry.isPartial ? " · 正在回复" : "")
            return "\(entry.role.title)\(status)\n\(entry.text)\n\n"
        }
        let ids = entries.map(\.id)
        guard blocks != renderedBlocks || ids != renderedBlockIDs || transcript.string.isEmpty else { return }
        let followEnd = renderedBlocks.isEmpty ||
            transcript.bounds.height - transcriptScroll.contentView.bounds.maxY < 48
        let previousOrigin = transcriptScroll.contentView.bounds.origin
        guard let storage = transcript.textStorage else { return }
        var common = 0
        while common < min(blocks.count, renderedBlocks.count),
              blocks[common] == renderedBlocks[common], ids[common] == renderedBlockIDs[common] {
            common += 1
        }
        let offset = renderedBlocks.prefix(common).reduce(0) { $0 + ($1 as NSString).length }
        let replacement = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        for index in common..<blocks.count {
            let entry = entries[index]
            let block = NSMutableAttributedString(string: blocks[index], attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ])
            let headingLength = (blocks[index].components(separatedBy: "\n").first! as NSString).length
            block.addAttributes([
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: entry.isError ? NSColor.systemRed :
                    (entry.role == .user ? NSColor.controlAccentColor : NSColor.secondaryLabelColor)
            ], range: NSRange(location: 0, length: headingLength))
            replacement.append(block)
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: min(offset, storage.length),
                                              length: max(0, storage.length - offset)), with: replacement)
        if blocks.isEmpty {
            storage.setAttributedString(NSAttributedString(
                string: "团团在这里。输入消息后点“发送”，或明确选择“调研并生成报告”。",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        storage.endEditing()
        renderedBlocks = blocks
        renderedBlockIDs = ids
        transcript.layoutManager?.ensureLayout(for: transcript.textContainer!)
        if followEnd {
            transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        } else {
            transcriptScroll.contentView.scroll(to: previousOrigin)
            transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
        }
    }

    private func refreshHistoryPicker() {
        var records = coordinator.recentResearch
        if let active = coordinator.activeResearch {
            records.removeAll { $0.id == active.id }
            records.insert(active, at: 0)
            if active.id != lastActiveTaskID { selectedTaskID = active.id }
            lastActiveTaskID = active.id
        }
        if !records.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = records.first?.id }
        guard records != historyRecords || historyPicker.numberOfItems == 0 else { return }
        historyRecords = records
        historyPicker.removeAllItems()
        if records.isEmpty {
            historyPicker.addItem(withTitle: "最近任务：暂无调研记录")
            historyPicker.isEnabled = false
            return
        }
        historyPicker.isEnabled = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        for record in records {
            let title = "\(formatter.string(from: record.createdAt)) · \(record.state.title) · \(singleLine(record.topic, limit: 44))"
            // addItem(withTitle:) deduplicates identical titles; use explicit items so UUID identity is preserved.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = record.id.uuidString
            historyPicker.menu?.addItem(item)
        }
        if let index = records.firstIndex(where: { $0.id == selectedTaskID }) {
            historyPicker.selectItem(at: index)
        }
    }

    private var selectedRecord: ResearchRecord? {
        historyRecords.first { $0.id == selectedTaskID }
    }

    private func refreshReportButtons() {
        let record = selectedRecord
        let available = record.map { $0.hasReport || $0.hasDraft } ?? false
        openReportButton.isEnabled = available
        revealReportButton.isEnabled = available
        saveReportButton.isEnabled = available
        rememberFactButton.isEnabled = record?.state == .completed && record?.hasReport == true
        openReportButton.title = record?.hasReport == false && record?.hasDraft == true ? "打开草稿" : "打开报告"
        if let record {
            let artifact = record.hasReport ? "完整报告" : (record.hasDraft ? "仅有草稿，非完整报告" : "无可用报告")
            selectedDetail.stringValue = "\(record.state.title) · \(artifact) · 搜索 \(record.searchesUsed) / 正文 \(record.pagesRead) / 请求 \(record.requestCount)\n\(record.detail.isEmpty ? singleLine(record.topic, limit: 100) : singleLine(record.detail, limit: 100))"
            selectedDetail.toolTip = "\(record.topic)\n\(record.detail)"
        } else {
            selectedDetail.stringValue = "完成的报告会保留在本机；失败或中断的任务不会自动重试。"
            selectedDetail.toolTip = nil
        }
    }

    private func singleLine(_ text: String, limit: Int) -> String {
        let line = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    // These are the only paths to send(): explicit buttons and the editor's Command-Return action.
    private func submitInput(researchOnly: Bool) {
        localNotice = nil
        if coordinator.send(input.string, researchOnly: researchOnly) {
            input.string = ""
            input.didChangeText()
        }
        refreshInterface()
    }

    @objc private func sendChat(_ sender: NSButton) { submitInput(researchOnly: false) }
    @objc private func startResearch(_ sender: NSButton) { submitInput(researchOnly: true) }

    @objc private func restoreLastInput(_ sender: NSButton) {
        guard input.string.isEmpty, let previous = coordinator.entries.last(where: { $0.role == .user }) else { return }
        input.string = previous.text
        input.didChangeText()
        localNotice = "已取回上条输入，尚未联网。请修改后手动选择发送或调研。"
        refreshInterface()
        window?.makeFirstResponder(input)
    }

    @objc private func cancelChat(_ sender: NSButton) {
        coordinator.cancelChat()
        localNotice = "已请求取消回复；关闭连接不保证服务方立即停止计费。"
        refreshInterface()
    }

    @objc private func cancelResearch(_ sender: NSButton) {
        coordinator.cancelResearch()
        localNotice = "已请求取消调研，不会自动重跑；关闭连接不保证服务方立即停止计费。"
        refreshInterface()
    }

    @objc private func openSettings(_ sender: NSButton) { onOpenSettings() }

    @objc private func clearConversation(_ sender: NSButton) {
        guard let window, window.attachedSheet == nil, !coordinator.isChatBusy else { return }
        let alert = NSAlert()
        alert.messageText = "清空当前会话？"
        alert.informativeText = "只清除聊天记录与后续聊天上下文，不删除输入草稿、调研任务或已保存报告。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空会话")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, !self.coordinator.isChatBusy else { return }
            self.coordinator.clearConversation()
            self.localNotice = "会话已清空，调研报告仍保留。"
            self.refreshInterface()
        }
    }

    @objc private func selectHistory(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard historyRecords.indices.contains(index) else { return }
        selectedTaskID = historyRecords[index].id
        refreshReportButtons()
    }

    private func reportURL(for id: UUID) -> URL? {
        guard let url = coordinator.reportURL(for: id), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            localNotice = "找不到该任务的报告文件；可能尚未写入或已被移走。"
            refreshInterface()
            return nil
        }
        return url
    }

    @objc private func openReport(_ sender: NSButton) {
        guard let id = selectedTaskID, let url = reportURL(for: id) else { return }
        localNotice = NSWorkspace.shared.open(url) ? "已交给系统默认应用打开报告。" : "无法打开报告，请在 Finder 中查看或另存为。"
        refreshInterface()
    }

    @objc private func revealReport(_ sender: NSButton) {
        guard let id = selectedTaskID, let url = reportURL(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func rememberFact(_ sender: NSButton) {
        guard let id = selectedTaskID else { return }
        localNotice = nil
        coordinator.rememberResearchFact(id)
        refreshInterface()
    }

    @objc private func saveReport(_ sender: NSButton) {
        guard let window, window.attachedSheet == nil, let id = selectedTaskID,
              let source = reportURL(for: id) else { return }
        let panel = NSSavePanel()
        panel.title = "另存为 Markdown 报告"
        panel.message = "导出 UTF-8 Markdown 文件。为保护现有文件，请使用新文件名；不会覆盖已有文件。"
        panel.nameFieldStringValue = "团团调研-\(id.uuidString.prefix(8))\(selectedRecord?.hasReport == true ? "" : "-草稿").md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            do {
                let text = try String(contentsOf: source, encoding: .utf8)
                // Exclusive creation also protects against a file appearing after the save panel closes.
                try Data(text.utf8).write(to: destination, options: .withoutOverwriting)
                self.localNotice = "已另存为 Markdown 文件，原报告保持不变。"
            } catch {
                self.localNotice = "未保存：目标文件已存在、来源不可读或无法写入。请选择新文件名并检查权限；未覆盖已有文件。"
            }
            self.refreshInterface()
        }
    }

    /// Read-only QA. The caller supplies a mock coordinator with synthetic entries and a scratch task store.
    /// Does not present(), refresh history, send, cancel, clear, open files, or access settings / credentials.
    func captureValidation(at directory: URL) throws -> [String: Bool] {
        let initialEntries = coordinator.entries.map { "\($0.id)|\($0.text)|\($0.isPartial)|\($0.isError)" }
        let initialRecords = coordinator.recentResearch
        let initialActive = coordinator.activeResearch
        let initialChatBusy = coordinator.isChatBusy
        let initialResearchBusy = coordinator.isResearchBusy
        refreshTask?.cancel()
        refreshTask = nil
        refreshInterface()
        guard let view = window?.contentView else { throw ChatWindowError.snapshotFailed }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let controls: [NSView] = [transcriptScroll, inputScroll, sendButton, researchButton, restoreInputButton,
                                  cancelChatButton, cancelResearchButton, historyPicker,
                                  openReportButton, revealReportButton, saveReportButton, rememberFactButton,
                                  settingsButton, clearButton]
        let reportAvailable = selectedRecord.map { $0.hasReport || $0.hasDraft } ?? false
        var checks: [String: Bool] = [
            "chat_fixture_entries_present": !coordinator.entries.isEmpty,
            "chat_fixture_tasks_present": !historyRecords.isEmpty,
            "chat_transcript_matches_injected_entries": coordinator.entries.allSatisfy { transcript.string.contains($0.text) },
            "chat_transcript_is_scrollable_plain_text": transcriptScroll.hasVerticalScroller && !transcript.isRichText && !transcript.isEditable,
            "chat_multiline_input": input.isEditable && input.isVerticallyResizable && !input.isHorizontallyResizable,
            "chat_send_button_state": sendButton.isEnabled == (!input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isChatBusy),
            "chat_research_button_state": researchButton.isEnabled == (!input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isResearchBusy),
            "chat_independent_cancel_states": cancelChatButton.isEnabled == coordinator.isChatBusy && cancelResearchButton.isEnabled == coordinator.isResearchBusy,
            "chat_report_button_states": openReportButton.isEnabled == reportAvailable && revealReportButton.isEnabled == reportAvailable && saveReportButton.isEnabled == reportAvailable,
            "chat_history_selection_displayed": selectedRecord.map { selectedDetail.stringValue.contains($0.state.title) } ?? historyRecords.isEmpty,
            "chat_settings_and_clear_entries": settingsButton.target === self && clearButton.target === self,
            "chat_controls_inside_content": controls.allSatisfy { view.bounds.contains(view.convert($0.bounds, from: $0)) },
            "chat_validation_preserves_entries": initialEntries == coordinator.entries.map { "\($0.id)|\($0.text)|\($0.isPartial)|\($0.isError)" },
            "chat_validation_preserves_tasks": initialRecords == coordinator.recentResearch && initialActive == coordinator.activeResearch,
            "chat_validation_preserves_busy_states": initialChatBusy == coordinator.isChatBusy && initialResearchBusy == coordinator.isResearchBusy
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ChatWindowError.snapshotFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ChatWindowError.snapshotFailed
        }
        try png.write(to: directory.appendingPathComponent("chat-window.png"), options: .atomic)
        checks["chat_window_exported"] = true
        return checks
    }
}
