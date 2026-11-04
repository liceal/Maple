import AppKit

// MARK: - 文件列表/分栏中紧跟文件名的小圆点标签视图

final class TagDotsView: NSView {

    private var colors: [NSColor] = []

    static let dotDiameter: CGFloat = 8.5
    static let dotSpacing: CGFloat = 3.0

    static func preferredWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotSpacing
    }

    func setColors(_ colors: [NSColor]) {
        guard self.colors != colors else { return }
        self.colors = colors
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !colors.isEmpty else { return }

        var x: CGFloat = 0
        let y: CGFloat = (bounds.height - Self.dotDiameter) / 2

        for color in colors {
            let dotRect = NSRect(x: x, y: y, width: Self.dotDiameter, height: Self.dotDiameter)
            if color == .clear {
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.1
                NSColor.secondaryLabelColor.withAlphaComponent(0.75).setStroke()
                ring.stroke()
            } else {
                let path = NSBezierPath(ovalIn: dotRect)
                color.setFill()
                path.fill()

                // 边缘 0.5pt 细微暗边，确保在亮色或暗色选中背景下都边界分明
                let border = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.25, dy: 0.25))
                border.lineWidth = 0.5
                NSColor(white: 0.0, alpha: 0.18).setStroke()
                border.stroke()
            }

            x += Self.dotDiameter + Self.dotSpacing
        }
    }
}

// MARK: - 右键菜单中的横排标签颜色选择器

final class TagColorPickerMenuItem: NSMenuItem {

    var onShowPopover: (([URL], NSRect) -> Void)? {
        get { (view as? TagColorPickerView)?.onShowPopover }
        set { (view as? TagColorPickerView)?.onShowPopover = newValue }
    }

    init(targetURLs: [URL]) {
        let view = TagColorPickerView(targetURLs: targetURLs)
        super.init(title: "标记", action: nil, keyEquivalent: "")
        self.view = view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class TagColorPickerView: NSView {

    let targetURLs: [URL]
    private var buttons: [TagCircleButton] = []
    private var moreButton: TagMoreButton?
    var onShowPopover: (([URL], NSRect) -> Void)?

    init(targetURLs: [URL]) {
        self.targetURLs = targetURLs
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 32))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        let tags = Tags.all
        guard !tags.isEmpty else { return }

        // 收集所有选中文件的标签
        var sharedTags = Set(targetURLs.first.map { Tags.tags(for: $0) } ?? [])
        for url in targetURLs.dropFirst() {
            let fileTags = Set(Tags.tags(for: url))
            sharedTags.formIntersection(fileTags)
        }

        let buttonDiameter: CGFloat = 16
        let spacing: CGFloat = 8
        // 靠左对齐，与右键菜单项左内边距 18pt 一致
        let startX: CGFloat = 18
        let y: CGFloat = (bounds.height - buttonDiameter) / 2

        // 最多展示前 6 个圆点，右侧紧跟一个 "..." 按钮
        let displayTags = Array(tags.prefix(6))
        var currentX = startX

        for tagDef in displayTags {
            let isTagged = sharedTags.contains(tagDef.name)
            let button = TagCircleButton(
                tagDef: tagDef,
                isTagged: isTagged,
                frame: NSRect(x: currentX, y: y, width: buttonDiameter, height: buttonDiameter)
            )
            button.onToggle = { [weak self] in
                self?.handleToggle(tag: tagDef.name)
            }
            addSubview(button)
            buttons.append(button)
            currentX += buttonDiameter + spacing
        }

        // 圆点右侧紧跟一个圆形 "..." 更多按钮
        let moreDiameter: CGFloat = 18
        let moreBtn = TagMoreButton(frame: NSRect(x: currentX + 2, y: (bounds.height - moreDiameter) / 2, width: moreDiameter, height: moreDiameter))
        moreBtn.onClick = { [weak self] in
            guard let self = self else { return }
            let rectInWindow = self.convert(moreBtn.frame, to: nil)
            let screenRect = self.window?.convertToScreen(rectInWindow) ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
            let urls = self.targetURLs
            self.enclosingMenuItem?.menu?.cancelTracking()
            self.onShowPopover?(urls, screenRect)
        }
        addSubview(moreBtn)
        self.moreButton = moreBtn
    }

    private func handleToggle(tag: String) {
        for url in targetURLs {
            Tags.toggleTag(on: url, tag: tag)
        }
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: - 精致圆形 "..." 更多按钮

final class TagMoreButton: NSView {

    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            guard oldValue != isPressed else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "更多标签…"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let p = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(p) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let circlePath = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        if isPressed {
            NSColor(white: 0.5, alpha: 0.35).setFill()
            circlePath.fill()
        } else if isHovered {
            NSColor(white: 0.5, alpha: 0.20).setFill()
            circlePath.fill()
        }

        // 绘制三个居中小圆点
        let dotRadius: CGFloat = 1.1
        let dotSpacing: CGFloat = 2.0
        let totalDotsWidth = dotRadius * 2 * 3 + dotSpacing * 2
        var startDotX = bounds.midX - totalDotsWidth / 2 + dotRadius
        let dotY = bounds.midY

        let dotColor: NSColor = isPressed ? .labelColor : .secondaryLabelColor
        dotColor.setFill()

        for _ in 0..<3 {
            let dotRect = NSRect(x: startDotX - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            let path = NSBezierPath(ovalIn: dotRect)
            path.fill()
            startDotX += dotRadius * 2 + dotSpacing
        }
    }
}

// MARK: - 颜色圆点按钮（支持悬停放大、选中打勾、未选中空心环）

private final class TagCircleButton: NSView {

    let tagDef: TagDefinition
    var isTagged: Bool
    var onToggle: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            guard oldValue != isPressed else { return }
            needsDisplay = true
        }
    }

    init(tagDef: TagDefinition, isTagged: Bool, frame: NSRect) {
        self.tagDef = tagDef
        self.isTagged = isTagged
        super.init(frame: frame)
        toolTip = tagDef.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(p) {
            onToggle?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let diameter = bounds.width
        let image: NSImage
        if isTagged {
            image = Tags.checkedDotImage(color: tagDef.color, diameter: diameter)
        } else {
            image = Tags.ringDotImage(color: tagDef.color, diameter: diameter)
        }

        if isHovered || isPressed {
            let inset = isPressed ? 0.5 : -1.0
            let hoverRect = bounds.insetBy(dx: inset, dy: inset)
            image.draw(in: hoverRect)
        } else {
            image.draw(in: bounds)
        }
    }
}

// MARK: - 图2样式的原生标签选择 Popover 视图控制器

final class TagPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let targetURLs: [URL]
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = AllTagsTableView()

    private var allTags: [TagDefinition] = []
    private var filteredTags: [TagDefinition] = []
    private var targetTagsSet: Set<String> = []

    init(targetURLs: [URL]) {
        self.targetURLs = targetURLs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 290))
        root.wantsLayer = true
        self.view = root
        setupUI()
        loadData()
    }

    private func setupUI() {
        // 1. 顶部标题：文件名称（例如 "Maple 23-29-44-173.app"）
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        if targetURLs.count == 1 {
            titleLabel.stringValue = targetURLs[0].lastPathComponent
        } else {
            titleLabel.stringValue = "\(targetURLs.count) 个项目"
        }
        view.addSubview(titleLabel)

        // 2. 搜索 / 添加标签输入框
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "添加标签..."
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.focusRingType = .none
        view.addSubview(searchField)

        // 3. 标签列表 TableView
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TagColumn"))
        tableView.addTableColumn(col)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    private func loadData() {
        allTags = Tags.allSystemTags
        // 计算目标文件集合中已有的标签集合
        var commonTags = Set(targetURLs.first.map { Tags.tags(for: $0) } ?? [])
        for url in targetURLs.dropFirst() {
            commonTags.formIntersection(Tags.tags(for: url))
        }
        self.targetTagsSet = commonTags
        filterTags()
    }

    private func filterTags() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredTags = allTags
        } else {
            filteredTags = allTags.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        tableView.reloadData()
    }

    // MARK: - NSTextFieldDelegate (输入过滤与回车新建/添加标签)

    func controlTextDidChange(_ obj: Notification) {
        filterTags()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            if let existing = allTags.first(where: { $0.name.lowercased() == text.lowercased() }) {
                toggleTag(name: existing.name)
            } else {
                let newTag = Tags.addTag(name: text)
                toggleTag(name: newTag.name)
            }
            searchField.stringValue = ""
            loadData()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    private func toggleTag(name: String) {
        for url in targetURLs {
            Tags.toggleTag(on: url, tag: name)
        }
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)

        var commonTags = Set(targetURLs.first.map { Tags.tags(for: $0) } ?? [])
        for url in targetURLs.dropFirst() {
            commonTags.formIntersection(Tags.tags(for: url))
        }
        self.targetTagsSet = commonTags
        allTags = Tags.allSystemTags
        filterTags()
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredTags.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredTags.count else { return nil }
        let tagDef = filteredTags[row]
        let isChecked = targetTagsSet.contains(tagDef.name)

        let cellIdentifier = NSUserInterfaceItemIdentifier("TagPopoverRowCell")
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? TagPopoverRowCell) ?? TagPopoverRowCell()
        cell.identifier = cellIdentifier
        cell.configure(tagDef: tagDef, isChecked: isChecked)
        cell.setHovered(self.tableView.hoveredRow == row)
        cell.onClick = { [weak self] in
            self?.toggleTag(name: tagDef.name)
        }
        return cell
    }
}

// MARK: - 标签列表行单元格 (TagPopoverRowCell)

final class TagPopoverRowCell: NSTableCellView {

    var onClick: (() -> Void)?

    private let dotImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkImageView = NSImageView()
    private(set) var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    private func setup() {
        wantsLayer = true

        dotImageView.translatesAutoresizingMaskIntoConstraints = false
        dotImageView.imageScaling = .scaleProportionallyDown
        addSubview(dotImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        checkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkImageView.imageScaling = .scaleProportionallyDown
        checkImageView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkImageView.contentTintColor = .systemBlue
        addSubview(checkImageView)

        NSLayoutConstraint.activate([
            dotImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotImageView.widthAnchor.constraint(equalToConstant: 12),
            dotImageView.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: dotImageView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkImageView.leadingAnchor, constant: -6),

            checkImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkImageView.widthAnchor.constraint(equalToConstant: 13),
            checkImageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    func configure(tagDef: TagDefinition, isChecked: Bool) {
        titleLabel.stringValue = tagDef.name
        checkImageView.isHidden = !isChecked

        // 圆点图标：如果无颜色绘制空心圆；有颜色绘制对应实心圆
        if tagDef.colorKey == "none" {
            dotImageView.image = Tags.paletteIcon(color: nil, diameter: 12)
        } else {
            dotImageView.image = Tags.dotImage(color: tagDef.color, diameter: 12)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // 拦截 mouseDown，防止事件向上传递到 NSTableView 被其内部事件循环吞掉 mouseUp
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(white: 0.5, alpha: 0.12).setFill()
            bgPath.fill()
        }
    }
}

private final class AllTagsTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    private var trackingArea: NSTrackingArea?

    var hoveredRow: Int = -1 {
        didSet {
            guard oldValue != hoveredRow else { return }
            syncHoveredCells()
        }
    }

    private func syncHoveredCells() {
        for r in 0..<numberOfRows {
            if let cell = view(atColumn: 0, row: r, makeIfNecessary: false) as? TagPopoverRowCell {
                cell.setHovered(r == hoveredRow)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = self.row(at: p)
        if r >= 0, r < numberOfRows,
           let cell = view(atColumn: 0, row: r, makeIfNecessary: false) as? TagPopoverRowCell {
            cell.onClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let r = self.row(at: p)
        hoveredRow = (r >= 0 && r < numberOfRows) ? r : -1
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let r = self.row(at: p)
        hoveredRow = (r >= 0 && r < numberOfRows && visibleRect.contains(p)) ? r : -1
        syncHoveredCells()
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
        syncHoveredCells()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        hoveredRow = -1
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }
}

// MARK: - 仿访达原生的删除标签确认弹窗 + 全窗口灰色遮罩 (FinderTagDeleteOverlay)

final class FinderTagDeleteOverlay: NSView {

    private let onConfirm: () -> Void
    private let onCancel: () -> Void
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    static func present(in window: NSWindow,
                        tagName: String,
                        itemCount: Int,
                        onConfirm: @escaping () -> Void,
                        onCancel: @escaping () -> Void = {}) {
        guard let contentView = window.contentView else {
            onConfirm()
            return
        }

        // 移除已有的同类遮罩
        for sub in contentView.subviews where sub is FinderTagDeleteOverlay {
            sub.removeFromSuperview()
        }

        let overlay = FinderTagDeleteOverlay(
            frame: contentView.bounds,
            tagName: tagName,
            itemCount: itemCount,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        window.makeFirstResponder(overlay)
    }

    private init(frame frameRect: NSRect,
                 tagName: String,
                 itemCount: Int,
                 onConfirm: @escaping () -> Void,
                 onCancel: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init(frame: frameRect)
        wantsLayer = true
        setupUI(tagName: tagName, itemCount: itemCount)
        installKeyMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func dismiss(confirmed: Bool) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        removeFromSuperview()
        if confirmed {
            onConfirm()
        } else {
            onCancel()
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            if event.keyCode == 53 { // Escape
                self.dismiss(confirmed: false)
                return nil
            } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                self.dismiss(confirmed: true)
                return nil
            }
            return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 仿访达全窗口灰色遮罩层（覆盖侧栏、工具栏与主内容区）
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let maskColor = isDark
            ? NSColor(white: 0.0, alpha: 0.45)
            : NSColor(white: 0.0, alpha: 0.22)
        maskColor.setFill()
        bounds.fill()
    }

    // 拦截所有鼠标事件，防止穿透到底层窗口
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    private func setupUI(tagName: String, itemCount: Int) {
        // 外层阴影容器（承载圆角投影，不裁切阴影）
        let shadowContainer = NSView()
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.wantsLayer = true
        shadowContainer.layer?.masksToBounds = false

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0.0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowBlurRadius = 24
        shadowContainer.shadow = shadow
        addSubview(shadowContainer)

        // 内层毛玻璃卡片（开启 masksToBounds = true，彻底消除四角直角溢出尖角）
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor(white: 0.0, alpha: 0.14).cgColor
        shadowContainer.addSubview(card)

        // 1. 顶部黄色三角警告图标 + 右下角应用角标（对齐访达 Caution Alert 样式）
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Self.makeCautionAlertIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(iconView)

        // 2. 粗体主提示文案（对齐访达 TG13_V1 / TG13_V2 本地化字符串）
        let titleText: String
        if itemCount > 0 {
            titleText = "你要删除标签“\(tagName)”并将它从\(itemCount)个项目中移除吗？"
        } else {
            titleText = "你要删除标签“\(tagName)”吗？"
        }

        let titleLabel = NSTextField(wrappingLabelWithString: titleText)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.preferredMaxLayoutWidth = 220
        card.addSubview(titleLabel)

        // 3. 副提示文案："此操作无法撤销。"
        let subtitleLabel = NSTextField(labelWithString: "此操作无法撤销。")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .labelColor
        subtitleLabel.alignment = .center
        card.addSubview(subtitleLabel)

        // 4. 底部两个等宽圆角灰色按钮：左「取消」、右「删除标签」
        let cancelBtn = FinderAlertButton(title: "取消") { [weak self] in
            self?.dismiss(confirmed: false)
        }
        let deleteBtn = FinderAlertButton(title: "删除标签") { [weak self] in
            self?.dismiss(confirmed: true)
        }
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cancelBtn)
        card.addSubview(deleteBtn)

        NSLayoutConstraint.activate([
            shadowContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            shadowContainer.widthAnchor.constraint(equalToConstant: 260),

            card.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            card.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            cancelBtn.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            cancelBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cancelBtn.heightAnchor.constraint(equalToConstant: 28),
            cancelBtn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            deleteBtn.topAnchor.constraint(equalTo: cancelBtn.topAnchor),
            deleteBtn.leadingAnchor.constraint(equalTo: cancelBtn.trailingAnchor, constant: 10),
            deleteBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            deleteBtn.widthAnchor.constraint(equalTo: cancelBtn.widthAnchor),
            deleteBtn.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    /// 合成 macOS 经典的「黄色警告三角 + 右下角应用小图标」组合图像
    private static func makeCautionAlertIcon() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size, flipped: false) { rect in
            if let caution = NSImage(named: NSImage.cautionName) {
                caution.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            if let appIcon = NSApp.applicationIconImage {
                let badgeRect = NSRect(x: rect.maxX - 28, y: rect.minY + 1, width: 26, height: 26)
                appIcon.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// 仿访达弹窗底部等宽灰色圆角按钮
private final class FinderAlertButton: NSView {

    private let title: String
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let p = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(p) {
            action()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)

        let alpha: CGFloat
        if isPressed {
            alpha = isDark ? 0.28 : 0.22
        } else if isHovered {
            alpha = isDark ? 0.22 : 0.16
        } else {
            alpha = isDark ? 0.16 : 0.12
        }

        let fillColor = isDark ? NSColor(white: 1.0, alpha: alpha) : NSColor(white: 0.0, alpha: alpha)
        fillColor.setFill()
        path.fill()
    }
}

// MARK: - 访达「所有标签…」分栏视图左列 (AllTagsBrowserColumnView)

final class AllTagsBrowserColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var onSelectTag: ((String) -> Void)?
    var onRequestDeleteTag: ((String) -> Void)?
    var onTagRenamed: ((String, String) -> Void)?
    var onActivate: (() -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = AllTagsBrowserTableView()
    private let rightBorder = Theme.hairlineView()

    private(set) var tags: [TagDefinition] = []
    private(set) var selectedTagName: String?
    private var isReloading = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    private func setupUI() {
        wantsLayer = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TagCol"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menuProvider = { [weak self] row in
            guard let self, row >= 0, row < self.tags.count else { return nil }
            return self.makeTagContextMenu(for: self.tags[row])
        }
        tableView.onTriggerRename = { [weak self] row in
            self?.startInlineRename(atRow: row)
        }
        tableView.onRowClicked = { [weak self] row in
            guard let self, row >= 0, row < self.tags.count else { return }
            self.onActivate?()
            self.selectRow(row, notify: true)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        rightBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rightBorder)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rightBorder.leadingAnchor),

            rightBorder.topAnchor.constraint(equalTo: topAnchor),
            rightBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightBorder.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    override func layout() {
        super.layout()
        if let col = tableView.tableColumns.first {
            col.width = max(80, scrollView.contentSize.width)
        }
    }

    func focus() {
        window?.makeFirstResponder(tableView)
    }

    /// 刷新全部标签列表，默认保持选中当前标签或自动选中第一项（如 "123"）
    func reload(selecting preferredTag: String? = nil, forceSpotlightRefresh: Bool = false, notifySelection: Bool = false) {
        if forceSpotlightRefresh {
            _ = Tags.discoverSpotlightTags(forceRefresh: true)
        }
        isReloading = true
        tags = Tags.allTagsForBrowser
        let targetName = preferredTag ?? selectedTagName ?? tags.first?.name
        if let targetName, tags.contains(where: { $0.name == targetName }) {
            selectedTagName = targetName
        } else {
            selectedTagName = tags.first?.name
        }
        tableView.reloadData()
        if let sel = selectedTagName, let idx = tags.firstIndex(where: { $0.name == sel }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        refreshRowVisuals()
        isReloading = false

        if notifySelection, let selectedTagName {
            onSelectTag?(selectedTagName)
        }
    }

    func select(tagName: String, notify: Bool = false) {
        guard let idx = tags.firstIndex(where: { $0.name == tagName }) else { return }
        selectRow(idx, notify: notify)
    }

    private func selectRow(_ row: Int, notify: Bool) {
        guard row >= 0, row < tags.count else { return }
        let name = tags[row].name
        selectedTagName = name
        isReloading = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isReloading = false
        refreshRowVisuals()
        if notify {
            onSelectTag?(name)
        }
    }

    func refreshRowVisuals() {
        for r in 0..<tableView.numberOfRows {
            let isSel = (r == tableView.selectedRow)
            if let rowView = tableView.rowView(atRow: r, makeIfNecessary: false) as? AllTagsBrowserRowView {
                rowView.isSelected = isSel
                rowView.needsDisplay = true
            }
            if let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? AllTagsBrowserCellView, r < tags.count {
                cell.configure(tagDef: tags[r], isSelected: isSel, isEmphasized: true)
            }
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tags.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("AllTagsBrowserRowView")
        let rv = (tableView.makeView(withIdentifier: id, owner: self) as? AllTagsBrowserRowView) ?? AllTagsBrowserRowView()
        rv.identifier = id
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < tags.count else { return nil }
        let tagDef = tags[row]
        let isSel = (selectedTagName == tagDef.name)

        let id = NSUserInterfaceItemIdentifier("AllTagsBrowserCellView")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AllTagsBrowserCellView) ?? AllTagsBrowserCellView()
        cell.identifier = id
        cell.configure(tagDef: tagDef, isSelected: isSel, isEmphasized: true)
        cell.onCommitRename = { [weak self] newName in
            guard let self else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldName = tagDef.name
            guard !trimmed.isEmpty, trimmed != oldName else {
                self.reload(selecting: oldName)
                return
            }
            self.selectedTagName = trimmed
            Tags.renameTag(oldName: oldName, newName: trimmed)
            self.reload(selecting: trimmed, forceSpotlightRefresh: true)
            self.onTagRenamed?(oldName, trimmed)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < tags.count else { return }
        let name = tags[row].name
        selectedTagName = name
        refreshRowVisuals()
        onSelectTag?(name)
    }

    func startInlineRename(forTag tagName: String) {
        guard let idx = tags.firstIndex(where: { $0.name == tagName }) else { return }
        startInlineRename(atRow: idx)
    }

    private func startInlineRename(atRow row: Int) {
        guard row >= 0, row < tags.count else { return }
        selectRow(row, notify: false)
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? AllTagsBrowserCellView {
            cell.startInlineEditing()
        }
    }

    // MARK: - 右键菜单（与访达「所有标签…」列右键菜单完全一致）

    private func makeTagContextMenu(for tagDef: TagDefinition) -> NSMenu {
        let tagName = tagDef.name
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "在新标签页中打开", action: #selector(ctxOpenTag(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = tagName
        menu.addItem(openItem)

        menu.addItem(.separator())

        if Tags.isTagInSidebar(named: tagName) {
            let hideItem = NSMenuItem(title: "从边栏中移除", action: #selector(ctxHideFromSidebar(_:)), keyEquivalent: "")
            hideItem.target = self
            hideItem.representedObject = tagName
            menu.addItem(hideItem)
        } else {
            let showItem = NSMenuItem(title: "在边栏中显示", action: #selector(ctxShowInSidebar(_:)), keyEquivalent: "")
            showItem.target = self
            showItem.representedObject = tagName
            menu.addItem(showItem)
        }

        let deleteItem = NSMenuItem(title: "删除标签 “\(tagName)”…", action: #selector(ctxDeleteTag(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = tagName
        menu.addItem(deleteItem)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(title: "给“\(tagName)”重新命名", action: #selector(ctxRenameTag(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = tagName
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let currentColorKey = tagDef.colorKey
        let noneItem = NSMenuItem(title: "无颜色", action: #selector(ctxPickColor(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = (tagName: tagName, colorKey: "none")
        noneItem.image = Tags.paletteIcon(color: nil)
        noneItem.state = (currentColorKey == "none" || tagDef.xattrIndex == 0) ? .on : .off
        menu.addItem(noneItem)

        let colorChoices: [(key: String, title: String, color: NSColor)] = [
            ("red", "红色", .systemRed),
            ("orange", "橙色", .systemOrange),
            ("yellow", "黄色", .systemYellow),
            ("green", "绿色", .systemGreen),
            ("blue", "蓝色", .systemBlue),
            ("purple", "紫色", .systemPurple),
            ("gray", "灰色", .systemGray)
        ]

        for choice in colorChoices {
            let item = NSMenuItem(title: choice.title, action: #selector(ctxPickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (tagName: tagName, colorKey: choice.key)
            item.image = Tags.paletteIcon(color: choice.color)
            item.state = (currentColorKey == choice.key) ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    @objc private func ctxOpenTag(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        select(tagName: tagName, notify: true)
    }

    @objc private func ctxHideFromSidebar(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        Tags.hideTagFromSidebar(named: tagName)
        reload(selecting: selectedTagName)
    }

    @objc private func ctxShowInSidebar(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        Tags.showTagInSidebar(named: tagName)
        reload(selecting: selectedTagName)
    }

    @objc private func ctxDeleteTag(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        onRequestDeleteTag?(tagName)
    }

    @objc private func ctxRenameTag(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        startInlineRename(forTag: tagName)
    }

    @objc private func ctxPickColor(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (tagName: String, colorKey: String) else { return }
        Tags.updateTagColor(named: tuple.tagName, colorKey: tuple.colorKey)
        reload(selecting: selectedTagName)
    }
}

private final class AllTagsBrowserTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onTriggerRename: ((Int) -> Void)?
    var onRowClicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let r = self.row(at: p)
        if r >= 0 && r < numberOfRows {
            onRowClicked?(r)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if selectedRow >= 0 {
                onTriggerRename?(selectedRow)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = self.row(at: p)
        guard r >= 0 && r < numberOfRows else { return nil }
        return menuProvider?(r)
    }
}

private final class AllTagsBrowserRowView: NSTableRowView {

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // 始终返回 .normal，避免 AppKit 在 selectionHighlightStyle = .none 下将旧选中行的文字永久锁死为白色反白状态
        .normal
    }

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // selectionHighlightStyle = .none，统一在 drawBackground 中绘制访达蓝色圆角选中条
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }
}

private final class AllTagsBrowserCellView: NSTableCellView, NSTextFieldDelegate {

    var onCommitRename: ((String) -> Void)?

    private let dotView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            nameField.cell?.backgroundStyle = .normal
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.imageScaling = .scaleProportionallyDown
        addSubview(dotView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 13)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self
        addSubview(nameField)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 12),
            dotView.heightAnchor.constraint(equalToConstant: 12),

            nameField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(tagDef: TagDefinition, isSelected: Bool, isEmphasized: Bool) {
        nameField.stringValue = tagDef.name
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.cell?.backgroundStyle = .normal
        nameField.textColor = (isSelected && isEmphasized) ? .white : .labelColor
        nameField.needsDisplay = true

        let size: CGFloat = 10
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circleRect = NSRect(x: (rect.width - size) / 2,
                                    y: (rect.height - size) / 2,
                                    width: size,
                                    height: size)
            if tagDef.colorKey == "none" || tagDef.color == .clear {
                let strokePath = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.75, dy: 0.75))
                strokePath.lineWidth = 1.2
                let strokeColor = (isSelected && isEmphasized)
                    ? NSColor.white.withAlphaComponent(0.9)
                    : NSColor.systemGray.withAlphaComponent(0.85)
                strokeColor.setStroke()
                strokePath.stroke()
            } else {
                if isSelected && isEmphasized {
                    let ringPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: -0.5, dy: -0.5))
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    ringPath.fill()
                }
                let fillPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                tagDef.color.setFill()
                fillPath.fill()
            }
            return true
        }
        img.isTemplate = false
        dotView.image = img
    }

    func startInlineEditing() {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.textColor = .labelColor
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let finalText = nameField.stringValue
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        onCommitRename?(finalText)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(superview)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            nameField.abortEditing()
            nameField.isEditable = false
            nameField.isSelectable = false
            nameField.drawsBackground = false
            onCommitRename?("")
            return true
        }
        return false
    }
}
