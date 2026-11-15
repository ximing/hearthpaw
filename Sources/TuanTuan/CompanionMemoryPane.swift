import AppKit

/// Local bond, greeting copy, and memory governance. No model calls.
@MainActor
final class CompanionMemoryPane: NSView, NSTextViewDelegate {
    private let session: CompanionSession
    private let memory: MemoryStore
    private let onChanged: () -> Void
    private let scroll = NSScrollView()
    private let document = FlippedCareView()
    private let bondLabel = NSTextField(wrappingLabelWithString: "")
    private let bondDetail = NSTextField(wrappingLabelWithString: "")
    private let replaceBondButton = NSButton()
    private let greetingToggle = NSButton(checkboxWithTitle: "启用本地主动招呼", target: nil, action: nil)
    private let pauseButton = NSButton()
    private let greetingStatus = NSTextField(wrappingLabelWithString: "")
    private let greetingEditor = NSTextView()
    private let greetingScroll = NSScrollView()
    private let saveGreetingsButton = NSButton()
    private let autoToggle = NSButton(checkboxWithTitle: "自动记下明确的非敏感偏好", target: nil, action: nil)
    private let replaceIndexButton = NSButton()
    private let entryPicker = NSPopUpButton()
    private let summaryField = NSTextField()
    private let tagsField = NSTextField()
    private let scopePicker = NSPopUpButton()
    private let bodyEditor = NSTextView()
    private let bodyScroll = NSScrollView()
    private let newButton = NSButton()
    private let saveButton = NSButton()
    private let deleteButton = NSButton()
    private let pendingPicker = NSPopUpButton()
    private let pendingDetail = NSTextField(wrappingLabelWithString: "")
    private let confirmButton = NSButton()
    private let discardButton = NSButton()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var suppressPicker = false
    private var greetingDirty = false
    private var selectedEntryID: UUID?
    private var pendingIDs: [UUID] = []

    init(frame: NSRect, session: CompanionSession, memory: MemoryStore, onChanged: @escaping () -> Void) {
        self.session = session
        self.memory = memory
        self.onChanged = onChanged
        super.init(frame: frame)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:session:memory:onChanged:)") }

    func reload() {
        refreshBond()
        refreshGreetings()
        refreshMemory(keepEditor: true)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === greetingEditor else { return }
        greetingDirty = true
    }

    private func build() {
        scroll.frame = bounds
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        document.frame = NSRect(x: 0, y: 0, width: max(500, bounds.width - 20), height: 980)
        scroll.documentView = document
        addSubview(scroll)

        bondLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        bondDetail.font = .systemFont(ofSize: 12)
        bondDetail.textColor = .secondaryLabelColor
        greetingStatus.font = .systemFont(ofSize: 12)
        greetingStatus.textColor = .secondaryLabelColor
        feedback.font = .systemFont(ofSize: 12)
        add(bondLabel, y: 12, height: 36)
        add(bondDetail, y: 50, height: 36)
        configure(replaceBondButton, title: "替换损坏的养成文件…", action: #selector(confirmReplaceBond(_:)), x: 16, y: 92, width: 210)
        placeCheckbox(greetingToggle, action: #selector(toggleGreetings(_:)), x: 16, y: 132, width: 240)
        configure(pauseButton, title: "暂停两小时", action: #selector(pauseTwoHours(_:)), x: 260, y: 128, width: 120)
        add(greetingStatus, y: 164, height: 32)
        place(greetingScroll, x: 16, y: 202, width: 470, height: 78)
        configureText(greetingEditor, in: greetingScroll)
        greetingEditor.delegate = self
        greetingEditor.setAccessibilityLabel("本地主动招呼文案，一行一句。留空则按亲密度使用默认句子。")
        configure(saveGreetingsButton, title: "保存招呼文案", action: #selector(saveGreetings(_:)), x: 16, y: 288, width: 130)
        add(label("招呼不调用模型，也不读取你正在做的事。自定义句子在各关系阶段都使用。", size: 11, color: .secondaryLabelColor),
            y: 324, height: 32)

        add(label("本机记忆", size: 15, weight: .semibold), y: 364, height: 22)
        placeCheckbox(autoToggle, action: #selector(toggleAutomatic(_:)), x: 16, y: 392, width: 280)
        configure(replaceIndexButton, title: "替换损坏的记忆索引…", action: #selector(confirmReplaceIndex(_:)), x: 16, y: 424, width: 200)
        place(entryPicker, x: 16, y: 464, width: 470, height: 26)
        entryPicker.target = self
        entryPicker.action = #selector(selectEntry(_:))
        entryPicker.setAccessibilityLabel("本机记忆条目")
        add(label("简述", size: 12), y: 498, height: 16)
        place(summaryField, x: 16, y: 516, width: 470, height: 24)
        summaryField.font = .systemFont(ofSize: 13)
        add(label("标签，用逗号分开", size: 12), y: 546, height: 16)
        place(tagsField, x: 16, y: 564, width: 220, height: 24)
        tagsField.font = .systemFont(ofSize: 13)
        place(scopePicker, x: 248, y: 562, width: 238, height: 26)
        scopePicker.addItems(withTitles: ["陪伴私有", "调研任务事实"])
        scopePicker.setAccessibilityLabel("记忆适用范围")
        add(label("正文", size: 12), y: 596, height: 16)
        place(bodyScroll, x: 16, y: 614, width: 470, height: 110)
        configureText(bodyEditor, in: bodyScroll)
        bodyEditor.setAccessibilityLabel("记忆正文。保存会写入本机索引和 Markdown 文件。")
        configure(newButton, title: "新建", action: #selector(newEntry(_:)), x: 16, y: 732, width: 72)
        configure(saveButton, title: "保存", action: #selector(saveEntry(_:)), x: 96, y: 732, width: 72)
        configure(deleteButton, title: "删除…", action: #selector(confirmDelete(_:)), x: 176, y: 732, width: 80)
        feedback.font = .systemFont(ofSize: 12)
        add(feedback, y: 768, height: 36)
        add(label("待确认", size: 13, weight: .medium), y: 808, height: 18)
        place(pendingPicker, x: 16, y: 830, width: 470, height: 26)
        pendingPicker.target = self
        pendingPicker.action = #selector(selectPending(_:))
        pendingPicker.setAccessibilityLabel("待确认记忆")
        pendingDetail.font = .systemFont(ofSize: 12)
        pendingDetail.textColor = .secondaryLabelColor
        add(pendingDetail, y: 862, height: 36)
        configure(confirmButton, title: "确认保存", action: #selector(confirmPending(_:)), x: 16, y: 904, width: 100)
        configure(discardButton, title: "丢弃", action: #selector(discardPending(_:)), x: 124, y: 904, width: 72)
        setFeedback("敏感内容不会自动保存。删除会同时移除索引和正文。")
    }

    private func refreshBond() {
        if let warning = session.warning {
            bondLabel.stringValue = "亲密度未读取"
            bondDetail.stringValue = warning
            replaceBondButton.isHidden = false
            greetingToggle.isEnabled = false
            pauseButton.isEnabled = false
            saveGreetingsButton.isEnabled = false
            greetingEditor.isEditable = false
        } else {
            let tier = session.tier
            bondLabel.stringValue = "亲密度 \(session.snapshot.bond) / 100 · \(tier.title)"
            bondDetail.stringValue = "称呼「\(tier.nickname)」。今日抚摸 \(session.snapshot.dailyPetAwards)/10，聊天 \(session.snapshot.dailyChatAwards)/5。不衰减，离开不扣分。"
            replaceBondButton.isHidden = true
            greetingToggle.isEnabled = true
            pauseButton.isEnabled = true
            saveGreetingsButton.isEnabled = true
            greetingEditor.isEditable = true
        }
    }

    private func refreshGreetings() {
        greetingToggle.state = session.snapshot.greetingsEnabled ? .on : .off
        if let until = session.snapshot.pausedUntil, until > Date() {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            greetingStatus.stringValue = "招呼已暂停到 \(formatter.string(from: until))。今日已招呼 \(session.snapshot.greetingsToday)/3。"
        } else if session.snapshot.greetingsEnabled {
            greetingStatus.stringValue = "今日已招呼 \(session.snapshot.greetingsToday)/3。启动后先安静 15 分钟，互动后再隔 30 分钟。"
        } else {
            greetingStatus.stringValue = "主动招呼已关闭。抚摸和聊天仍会计分。"
        }
        guard !greetingDirty else { return }
        greetingEditor.string = session.snapshot.greetingLines.joined(separator: "\n")
    }

    private func refreshMemory(keepEditor: Bool) {
        let view: MemoryOverview
        do { view = try memory.overview() }
        catch {
            setFeedback(message(error), error: true)
            return
        }
        let blocked = view.indexBlocked
        replaceIndexButton.isHidden = !blocked
        autoToggle.isEnabled = !blocked
        autoToggle.state = view.catalog.automaticRecording ? .on : .off
        let editorsEnabled = !blocked
        summaryField.isEnabled = editorsEnabled
        tagsField.isEnabled = editorsEnabled
        scopePicker.isEnabled = editorsEnabled
        bodyEditor.isEditable = editorsEnabled
        newButton.isEnabled = editorsEnabled
        saveButton.isEnabled = editorsEnabled
        deleteButton.isEnabled = editorsEnabled && selectedEntryID != nil
        confirmButton.isEnabled = editorsEnabled && !view.pendingBlocked && !view.pending.isEmpty
        discardButton.isEnabled = confirmButton.isEnabled
        if blocked {
            setFeedback("记忆索引损坏，未覆盖原文件。聊天和宠物仍可用。只有明确替换才会清空索引。", error: true)
        }
        rebuildEntries(view.catalog.entries, keepEditor: keepEditor)
        rebuildPending(view.pending, pendingBlocked: view.pendingBlocked)
    }

    private func rebuildEntries(_ entries: [MemoryEntry], keepEditor: Bool) {
        suppressPicker = true
        entryPicker.removeAllItems()
        let fresh = NSMenuItem(title: "新建一条记忆", action: nil, keyEquivalent: "")
        entryPicker.menu?.addItem(fresh)
        for entry in entries {
            let item = NSMenuItem(title: "\(entry.scope.title) · \(entry.summary)", action: nil, keyEquivalent: "")
            item.representedObject = entry.id.uuidString
            entryPicker.menu?.addItem(item)
        }
        if let selectedEntryID, let index = entries.firstIndex(where: { $0.id == selectedEntryID }) {
            entryPicker.selectItem(at: index + 1)
            deleteButton.isEnabled = summaryField.isEnabled
        } else {
            entryPicker.selectItem(at: 0)
            if !keepEditor { clearEditor() }
        }
        suppressPicker = false
    }

    private func rebuildPending(_ pending: [MemoryCandidate], pendingBlocked: Bool) {
        suppressPicker = true
        pendingIDs = pending.map(\.id)
        pendingPicker.removeAllItems()
        if pendingBlocked {
            pendingPicker.addItem(withTitle: "待确认列表损坏，未改动")
            pendingPicker.isEnabled = false
            pendingDetail.stringValue = "不会覆盖损坏的待确认文件。"
        } else if pending.isEmpty {
            pendingPicker.addItem(withTitle: "没有待确认的记忆")
            pendingPicker.isEnabled = false
            pendingDetail.stringValue = "敏感内容、关闭自动记忆，或不能直接写入的句子，会出现在这里。"
        } else {
            pendingPicker.isEnabled = true
            for candidate in pending {
                pendingPicker.addItem(withTitle: candidate.draft.summary)
            }
            pendingDetail.stringValue = pending[0].reason
        }
        suppressPicker = false
    }

    @objc private func toggleGreetings(_ sender: NSButton) {
        session.setGreetingsEnabled(sender.state == .on)
        refreshGreetings()
        onChanged()
    }

    @objc private func pauseTwoHours(_ sender: NSButton) {
        session.pauseGreetings()
        refreshGreetings()
        onChanged()
        setFeedback("已暂停主动招呼两小时。")
    }

    @objc private func saveGreetings(_ sender: NSButton) {
        do {
            try session.setGreetingLines(greetingEditor.string)
            greetingDirty = false
            refreshGreetings()
            onChanged()
            setFeedback(session.snapshot.greetingLines.isEmpty
                ? "已恢复为按亲密度变化的默认招呼。"
                : "已保存本地招呼文案，不调用模型。")
        } catch {
            setFeedback(message(error), error: true)
        }
    }

    @objc private func confirmReplaceBond(_ sender: NSButton) {
        ask(title: "替换损坏的养成文件？",
            detail: "亲密度和招呼记录会回到初始值。这个操作会覆盖原文件。",
            confirm: "替换") { [weak self] in
            guard let self else { return }
            do {
                try self.session.replaceBlockedFile()
                self.refreshBond()
                self.refreshGreetings()
                self.onChanged()
                self.setFeedback("已换成一份空白养成记录。")
            } catch {
                self.setFeedback(self.message(error), error: true)
            }
        }
    }

    @objc private func toggleAutomatic(_ sender: NSButton) {
        do {
            try memory.setAutomaticRecording(sender.state == .on)
            setFeedback(sender.state == .on ? "已开启自动记录明确的非敏感偏好。" : "已关闭自动记录。新的偏好会留在待确认。")
        } catch {
            setFeedback(message(error), error: true)
            refreshMemory(keepEditor: true)
        }
    }

    @objc private func confirmReplaceIndex(_ sender: NSButton) {
        ask(title: "替换损坏的记忆索引？",
            detail: "原索引会被一份空索引替换。已有正文文件不会自动删除，损坏索引里的条目也不会恢复。",
            confirm: "替换为空索引") { [weak self] in
            guard let self else { return }
            do {
                try self.memory.resetBlockedIndex()
                self.selectedEntryID = nil
                self.clearEditor()
                self.refreshMemory(keepEditor: false)
                self.setFeedback("已换成空的记忆索引。")
            } catch {
                self.setFeedback(self.message(error), error: true)
            }
        }
    }

    @objc private func selectEntry(_ sender: NSPopUpButton) {
        guard !suppressPicker else { return }
        guard let raw = sender.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: raw) else {
            selectedEntryID = nil
            deleteButton.isEnabled = false
            clearEditor()
            return
        }
        do {
            let document = try memory.document(id: id)
            selectedEntryID = id
            summaryField.stringValue = document.entry.summary
            tagsField.stringValue = document.entry.tags.joined(separator: "，")
            scopePicker.selectItem(at: document.entry.scope == .research ? 1 : 0)
            bodyEditor.string = document.body
            deleteButton.isEnabled = true
            setFeedback("已打开这条本机记忆。保存前的修改还在输入框里。")
        } catch {
            setFeedback(message(error), error: true)
        }
    }

    @objc private func newEntry(_ sender: NSButton) {
        selectedEntryID = nil
        suppressPicker = true
        entryPicker.selectItem(at: 0)
        suppressPicker = false
        deleteButton.isEnabled = false
        clearEditor()
        setFeedback("正在写一条新记忆。保存后才会写入索引和正文。")
    }

    @objc private func saveEntry(_ sender: NSButton) {
        let draft = MemoryDraft(id: selectedEntryID,
                                summary: summaryField.stringValue,
                                tags: splitTags(tagsField.stringValue),
                                scope: scopePicker.indexOfSelectedItem == 1 ? .research : .companion,
                                body: bodyEditor.string,
                                isSensitive: MemoryPolicy.sensitive(summaryField.stringValue + "\n" + bodyEditor.string))
        let commit = { [weak self] in
            guard let self else { return }
            do {
                let revision = try self.memory.overview().catalog.revision
                let entry = try self.memory.save(draft, expectedRevision: revision)
                self.selectedEntryID = entry.id
                self.refreshMemory(keepEditor: true)
                self.setFeedback(entry.scope == .companion
                    ? "已保存。这条属于陪伴私有，不会交给调研。"
                    : "已保存为调研任务事实。")
            } catch {
                self.setFeedback(self.message(error), error: true)
            }
        }
        if draft.isSensitive {
            ask(title: "这段内容像是敏感信息",
                detail: "确定后才会写入本机记忆。它不会自动出现在调研任务里，除非你把范围选成调研任务事实。",
                confirm: "仍然保存", then: commit)
        } else {
            commit()
        }
    }

    @objc private func confirmDelete(_ sender: NSButton) {
        guard let id = selectedEntryID else { return }
        ask(title: "删除这条记忆？",
            detail: "索引和正文都会从本机移除，不能撤销。",
            confirm: "删除") { [weak self] in
            guard let self else { return }
            do {
                try self.memory.delete(id: id)
                self.selectedEntryID = nil
                self.clearEditor()
                self.refreshMemory(keepEditor: false)
                self.setFeedback("已删除索引和正文。")
            } catch {
                self.setFeedback(self.message(error), error: true)
            }
        }
    }

    @objc private func selectPending(_ sender: NSPopUpButton) {
        guard !suppressPicker else { return }
        let index = sender.indexOfSelectedItem
        guard pendingIDs.indices.contains(index) else { return }
        if let view = try? memory.overview(), let candidate = view.pending.first(where: { $0.id == pendingIDs[index] }) {
            pendingDetail.stringValue = candidate.reason + "\n" + candidate.draft.body
        }
    }

    @objc private func confirmPending(_ sender: NSButton) {
        let index = pendingPicker.indexOfSelectedItem
        guard pendingIDs.indices.contains(index) else { return }
        let id = pendingIDs[index]
        do {
            _ = try memory.confirmPending(id: id)
            refreshMemory(keepEditor: true)
            setFeedback("已按你的确认写入本机记忆。")
        } catch {
            setFeedback(message(error), error: true)
        }
    }

    @objc private func discardPending(_ sender: NSButton) {
        let index = pendingPicker.indexOfSelectedItem
        guard pendingIDs.indices.contains(index) else { return }
        do {
            try memory.discardPending(id: pendingIDs[index])
            refreshMemory(keepEditor: true)
            setFeedback("已丢弃这条待确认记忆，没有写入正文。")
        } catch {
            setFeedback(message(error), error: true)
        }
    }

    private func clearEditor() {
        summaryField.stringValue = ""
        tagsField.stringValue = ""
        bodyEditor.string = ""
        scopePicker.selectItem(at: 0)
    }

    private func splitTags(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init)
    }

    private func ask(title: String, detail: String, confirm: String, then: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: confirm)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            then()
        }
    }

    private func setFeedback(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func message(_ error: Error) -> String {
        if let safe = error as? SafeAgentError { return safe.message }
        if let care = error as? CompanionStoreError { return care.errorDescription ?? "养成数据没有写入。" }
        return "这次没有写入。原文件未被覆盖。"
    }

    private func add(_ field: NSTextField, y: CGFloat, height: CGFloat) {
        place(field, x: 16, y: y, width: 470, height: height)
    }

    private func placeCheckbox(_ button: NSButton, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
        button.target = self
        button.action = action
        button.font = .systemFont(ofSize: 13)
        place(button, x: x, y: y, width: width, height: 22)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        document.addSubview(view)
    }

    private func configure(_ button: NSButton, title: String, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
        if !title.isEmpty { button.title = title }
        button.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        place(button, x: x, y: y, width: width, height: 28)
    }

    private func configureText(_ textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.documentView = textView
    }
}

private final class FlippedCareView: NSView {
    override var isFlipped: Bool { true }
}
