import AppKit
import UniformTypeIdentifiers

protocol PaneViewDelegate: AnyObject {
    func paneDidActivate(_ pane: PaneView)
    func pane(_ pane: PaneView, didNavigateTo url: URL)
    func pane(_ pane: PaneView, didChangeViewMode mode: ViewMode)
    func paneDidRequestQuickLook(_ pane: PaneView)
    func paneCanOpenInOtherPane(_ pane: PaneView) -> Bool
    func pane(_ pane: PaneView, openInOtherPane url: URL)
    /// 个人收藏内容发生变化（侧栏需要刷新）。
    func paneDidChangeFavorites(_ pane: PaneView)
}

/// 单个浏览窗格：顶部路径栏 + 中部列表/图标 + 底部状态栏。
final class PaneView: NSView {

    weak var delegate: PaneViewDelegate?

    private(set) var currentURL: URL

    /// 当前操作的目标目录（列表/图标视图为 currentURL，分栏视图为当前选中/右键的列对应目录）。
    var activeDirectoryURL: URL {
        if viewMode == .columns {
            return columnView.activeColumnURL
        }
        return currentURL
    }
    private(set) var items: [FileItem] = []
    private(set) var sections: [FileSection] = []

    var sortField: SortField = .name {
        didSet { applyOrganization() }
    }
    var ascending: Bool = true {
        didSet { applyOrganization() }
    }
    var groupMode: GroupMode = .none {
        didSet { applyOrganization() }
    }
    var viewMode: ViewMode = .list {
        didSet {
            guard oldValue != viewMode else { return }
            // 标签视图强制用列表展示，不覆盖用户原本的显示方式
            if tagName == nil, !isRestoringViewMode { AppSettings.viewMode = viewMode.rawValue }
            applyViewMode()
            delegate?.pane(self, didChangeViewMode: viewMode)
        }
    }
    /// 恢复上次状态时不再改写全局默认显示方式。
    private var isRestoringViewMode = false

    var isFocused: Bool = false {
        didSet {
            guard oldValue != isFocused else { return }
            updateFocusVisuals()
        }
    }

    func updateFocusVisuals() {
        pathBar.isActive = isFocused && AppSettings.highlightPaneAddressBar
        headerTint.fillColor = (isFocused && AppSettings.highlightPaneAddressBar)
            ? NSColor.controlAccentColor.withAlphaComponent(0.17)
            : .clear
        focusRing.color = (isFocused && AppSettings.showPaneBorder)
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : .clear
        iconView.isPaneActive = isFocused
        statusBar.isHidden = AppSettings.hideBottomStatusBar
        needsDisplay = true
    }

    /// 后退 / 前进的历史：**以地址栏显示的地址为唯一依据**。
    /// 这样分栏模式下点开文件夹（地址栏随之变化）也会被记录，
    /// 点左箭头就能回到上一次的位置。
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    /// 地址栏当前显示的地址（历史记录的比较基准）。
    private var displayedLocation: URL = URL(fileURLWithPath: NSHomeDirectory())
    /// 后退 / 前进过程中不写入历史（避免来回跳动时把历史搅乱）。
    private var suppressHistory = false

    /// 标签视图：显示所有带该标签的项目（来自 Spotlight 的平铺列表）。
    private let tagSearch = TagSearch()
    private(set) var tagName: String?
    private var viewModeBeforeTag: ViewMode?
    var isTagView: Bool { tagName != nil }

    // MARK: - 文件操作撤销与重做栈
    struct FileActionRecord {
        enum ActionType {
            case moveToTrash(mapping: [(original: URL, trash: URL)])
            case rename(from: URL, to: URL)
        }
        let type: ActionType
    }
    private var undoStack: [FileActionRecord] = []
    private var redoStack: [FileActionRecord] = []

    // MARK: - 右键上下文目标与剪切标志
    private var contextTargetItems: [FileItem] = []
    private static let cutPasteboardType = NSPasteboard.PasteboardType("com.maple.cut-flag")
    private var effectiveContextItems: [FileItem] {
        if !contextTargetItems.isEmpty {
            return contextTargetItems
        }
        return currentSelection()
    }

    // MARK: - 视图

    private let header = Theme.backgroundView(Theme.paneBackground)
    private let headerTint = Theme.backgroundView(.clear)
    private let focusRing = FocusRingOverlay()
    private let content = NSView()
    private let statusBar = Theme.backgroundView(Theme.paneBackground)
    private let pathBar = PathBar()
    private let paneMenuButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private let sizeSlider = DisplaySizeSliderControl()
    private let previewButton: SquareToolbarButton = {
        let btn = SquareToolbarButton(size: 20)
        btn.showsBackgroundWhenOn = false
        return btn
    }()
    private let emptyLabel = NSTextField(labelWithString: "文件夹为空")
    private let listView = FileListView()
    private let iconView = FileIconView()
    private let columnView = ColumnBrowserView()

    // MARK: - 预览窗格
    private let listAndIconContainer = NSView()
    private let previewPane = FilePreviewPane()
    private let previewSplitter = SplitterView()
    private var previewWidthConstraint: NSLayoutConstraint?
    private var previewWidthAtDragStart: CGFloat = 260
    private var listAndIconTrailingToContent: NSLayoutConstraint?
    private var listAndIconTrailingToSplitter: NSLayoutConstraint?

    // MARK: - 生命周期

    init(startURL: URL) {
        self.currentURL = startURL
        self.displayedLocation = startURL.standardizedFileURL
        super.init(frame: .zero)
        wantsLayer = true
        buildHeader()
        buildContent()
        buildStatusBar()
        buildFocusRing()
        wireCallbacks()
        loadSettings()
        applyDisplayMetrics()
        // 首屏必须显式应用一次：若恢复的模式与默认值相同，didSet 不会触发，
        // 三个视图会全部叠在一起（最后加入的分栏视图盖住列表）。
        applyViewMode()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func loadSettings() {
        sortField = SortField(rawValue: AppSettings.sortField) ?? .name
        ascending = AppSettings.sortAscending
        groupMode = GroupMode(rawValue: AppSettings.groupMode) ?? .none
        viewMode = ViewMode(rawValue: AppSettings.viewMode) ?? .list
    }

    // MARK: - 构建界面

    private func buildHeader() {
        addSubview(header)

        // 焦点窗格在标题条上叠一层强调色（QSpace 用整块高亮表示当前焦点）
        headerTint.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTint)

        configure(backButton, symbol: "chevron.left", tooltip: "后退", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.right", tooltip: "前进", action: #selector(goForward))

        paneMenuButton.translatesAutoresizingMaskIntoConstraints = false
        paneMenuButton.bezelStyle = .inline
        paneMenuButton.isBordered = false
        paneMenuButton.imagePosition = .imageOnly
        paneMenuButton.image = Self.verticalEllipsisImage()
        paneMenuButton.toolTip = "窗格操作"
        paneMenuButton.target = self
        paneMenuButton.action = #selector(showPaneMenu(_:))
        paneMenuButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        paneMenuButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        pathBar.setURL(currentURL)
        pathBar.onActivate = { [weak self] in self?.activate() }
        pathBar.onNavigate = { [weak self] url, isDouble in
            guard let self else { return }
            // 分栏模式下双击面包屑：把该目录设为最左列并续上原来的展开链；
            // 其余情况（含分栏单击＝退回、其它模式单击＝切换）走原逻辑。
            if isDouble, self.viewMode == .columns {
                self.revealLocationAsRoot(url)
            } else {
                self.revealLocation(url)
            }
        }
        pathBar.onOpenItem = { url in NSWorkspace.shared.open(url) }
        pathBar.onEditingFinished = { [weak self] in self?.restoreFocusAfterPathEditing() }
        pathBar.onToggleFavorite = { [weak self] url in
            guard let self else { return }
            _ = AppSettings.toggleFavorite(url)
            self.pathBar.refreshFavoriteState()
            self.delegate?.paneDidChangeFavorites(self)
        }

        // 顺序：后退 / 前进 / 地址栏 / 省略号（更多功能放在地址栏右侧）
        let stack = NSStackView(views: [backButton, forwardButton, pathBar, paneMenuButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.setCustomSpacing(8, after: forwardButton)
        stack.setCustomSpacing(6, after: pathBar)
        header.addSubview(stack)

        let separator = Theme.hairlineView()
        header.addSubview(separator)

        NSLayoutConstraint.activate([
            headerTint.topAnchor.constraint(equalTo: header.topAnchor),
            headerTint.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerTint.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerTint.trailingAnchor.constraint(equalTo: header.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 24),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])

        header.heightAnchor.constraint(equalToConstant: Theme.headerHeight).isActive = true
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = Theme.symbol(symbol, size: 11, weight: .semibold)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    /// QSpace 地址栏左侧的竖向省略号（模板图，自动适配明暗外观）。
    private static func verticalEllipsisImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            for centerY in [4.0, 8.0, 12.0] {
                NSBezierPath(ovalIn: NSRect(x: 6.9, y: centerY - 1.1, width: 2.2, height: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func buildContent() {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // 1. 列表与图标的容器
        listAndIconContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listAndIconContainer)

        listView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        listAndIconContainer.addSubview(listView)
        listAndIconContainer.addSubview(iconView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        listAndIconContainer.addSubview(emptyLabel)

        for view in [listView, iconView] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: listAndIconContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: listAndIconContainer.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: listAndIconContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: listAndIconContainer.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: listAndIconContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listAndIconContainer.centerYAnchor)
        ])

        // 2. 分栏视图（独占整块窗格，自带内部多列与预览列）
        columnView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(columnView)

        NSLayoutConstraint.activate([
            columnView.topAnchor.constraint(equalTo: content.topAnchor),
            columnView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            columnView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            columnView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        // 3. 列表/图标模式下的右侧预览窗格与可拖动分割线
        previewSplitter.axis = .vertical
        previewSplitter.translatesAutoresizingMaskIntoConstraints = false
        previewSplitter.onDragBegan = { [weak self] in
            guard let self, let constraint = self.previewWidthConstraint else { return }
            self.previewWidthAtDragStart = constraint.constant
        }
        previewSplitter.onDrag = { [weak self] delta in
            guard let self, let constraint = self.previewWidthConstraint else { return }
            let newWidth = min(max(self.previewWidthAtDragStart - delta, 180), 600)
            constraint.constant = newWidth
        }
        previewSplitter.onDragEnd = { [weak self] in
            guard let constraint = self?.previewWidthConstraint else { return }
            AppSettings.previewPaneWidth = constraint.constant
        }
        content.addSubview(previewSplitter)

        previewPane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewPane)

        let widthConstraint = previewPane.widthAnchor.constraint(equalToConstant: AppSettings.previewPaneWidth)
        previewWidthConstraint = widthConstraint

        let toContent = listAndIconContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        let toSplitter = listAndIconContainer.trailingAnchor.constraint(equalTo: previewSplitter.leadingAnchor)
        listAndIconTrailingToContent = toContent
        listAndIconTrailingToSplitter = toSplitter

        NSLayoutConstraint.activate([
            listAndIconContainer.topAnchor.constraint(equalTo: content.topAnchor),
            listAndIconContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            listAndIconContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toContent,

            previewSplitter.topAnchor.constraint(equalTo: content.topAnchor),
            previewSplitter.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewSplitter.trailingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewSplitter.widthAnchor.constraint(equalToConstant: 6),

            previewPane.topAnchor.constraint(equalTo: content.topAnchor),
            previewPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            widthConstraint
        ])

        addSubview(statusBar)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        statusLeft.translatesAutoresizingMaskIntoConstraints = false
        statusLeft.font = .systemFont(ofSize: 10.5)
        statusLeft.textColor = .secondaryLabelColor
        statusBar.addSubview(statusLeft)

        statusRight.translatesAutoresizingMaskIntoConstraints = false
        statusRight.font = .systemFont(ofSize: 10.5)
        statusRight.textColor = .tertiaryLabelColor
        statusRight.alignment = .right
        statusBar.addSubview(statusRight)

        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.onSizeChanged = { [weak self] mode, value in
            guard let self else { return }
            switch mode {
            case .icons:
                AppSettings.gridIconSize = CGFloat(value)
                self.iconView.applyIconSize(CGFloat(value))
            case .list:
                AppSettings.listIconSize = CGFloat(value)
                AppSettings.listRowHeight = max(20, CGFloat(value) + 6)
                self.listView.applyListSize(iconSize: CGFloat(value))
            case .columns:
                AppSettings.browserColumnWidth = CGFloat(value)
                self.columnView.applyColumnWidth(CGFloat(value))
            }
        }
        statusBar.addSubview(sizeSlider)

        // 4. 预览模式切换按钮（右下角，内置图标）
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.image = Theme.previewPaneIcon
        previewButton.toolTip = "显示/隐藏右侧预览窗格"
        previewButton.target = self
        previewButton.action = #selector(previewButtonClicked)
        statusBar.addSubview(previewButton)

        let topLine = Theme.hairlineView()
        statusBar.addSubview(topLine)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),

            topLine.topAnchor.constraint(equalTo: statusBar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 0.5),

            previewButton.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            previewButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            sizeSlider.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -6),
            sizeSlider.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            statusRight.trailingAnchor.constraint(equalTo: sizeSlider.leadingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 0.5),
            statusRight.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 8)
        ])
    }

    private func buildStatusBar() {
        statusBar.heightAnchor.constraint(equalToConstant: Theme.statusHeight).isActive = true
    }

    /// 焦点描边罩在整块之上（点击穿透），保证 2pt 边框不被内容视图盖住。
    private func buildFocusRing() {
        focusRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusRing)
        NSLayoutConstraint.activate([
            focusRing.topAnchor.constraint(equalTo: topAnchor),
            focusRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRing.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func wireCallbacks() {
        listView.onOpen = { [weak self] item in self?.open(item) }
        listView.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
        listView.onActivate = { [weak self] in self?.activate() }
        listView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        listView.menuProvider = { [weak self] item in self?.makeContextMenu(clickedItem: item) }
        listView.onSortChange = { [weak self] field in self?.toggleSort(field) }
        listView.canSwipeBack = { [weak self] in self?.canSwipeBackInIconView ?? false }
        listView.canSwipeForward = { [weak self] in self?.canGoForward ?? false }
        listView.onSwipeBack = { [weak self] in self?.swipeBackInIconView() }
        listView.onSwipeForward = { [weak self] in self?.goForward() }
        listView.onFileRenamed = { [weak self] oldURL, newURL in self?.handleFileRenamed(from: oldURL, to: newURL) }

        iconView.onOpen = { [weak self] item in self?.open(item) }
        iconView.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
        iconView.onActivate = { [weak self] in self?.activate() }
        iconView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        iconView.menuProvider = { [weak self] item in self?.makeContextMenu(clickedItem: item) }
        iconView.canSwipeBack = { [weak self] in self?.canSwipeBackInIconView ?? false }
        iconView.canSwipeForward = { [weak self] in self?.canGoForward ?? false }
        iconView.onSwipeBack = { [weak self] in self?.swipeBackInIconView() }
        iconView.onSwipeForward = { [weak self] in self?.goForward() }
        iconView.onFileRenamed = { [weak self] oldURL, newURL in self?.handleFileRenamed(from: oldURL, to: newURL) }

        columnView.onOpen = { [weak self] item in self?.open(item) }
        columnView.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
        columnView.onActivate = { [weak self] in self?.activate() }
        columnView.onLocationChange = { [weak self] _, _ in
            guard let self, self.viewMode == .columns else { return }
            self.refreshPathBar()
            self.updateNavigationButtons()
            // 分栏里换列也算「位置变了」，顶部标题要跟着更新
            self.delegate?.pane(self, didNavigateTo: self.currentURL)
        }
        columnView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        columnView.menuProvider = { [weak self] item in self?.makeContextMenu(clickedItem: item) }
        columnView.onFileRenamed = { [weak self] oldURL, newURL in self?.handleFileRenamed(from: oldURL, to: newURL) }

        listView.onDropFiles = { [weak self] urls, dest, isCopy in
            self?.handleDroppedFiles(urls, destinationDirectory: dest, isCopy: isCopy)
        }
        iconView.onDropFiles = { [weak self] urls, dest, isCopy in
            self?.handleDroppedFiles(urls, destinationDirectory: dest, isCopy: isCopy)
        }
        columnView.onDropFiles = { [weak self] urls, dest, isCopy in
            self?.handleDroppedFiles(urls, destinationDirectory: dest, isCopy: isCopy)
        }

        NotificationCenter.default.addObserver(forName: .filesDidChangeOnDisk, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }

        NotificationCenter.default.addObserver(forName: .showHiddenFilesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }

        NotificationCenter.default.addObserver(forName: .paneAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateFocusVisuals()
        }

        NotificationCenter.default.addObserver(forName: .bottomStatusBarDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateFocusVisuals()
        }
    }

    // MARK: - 焦点

    func activate() {
        delegate?.paneDidActivate(self)
    }

    override func mouseDown(with event: NSEvent) {
        activate()
        super.mouseDown(with: event)
    }

    /// 窗口未激活时的第一次点击也照常交给本视图处理（选中、切焦点一步到位）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        header.needsDisplay = true
        statusBar.needsDisplay = true
        pathBar.needsDisplay = true
        needsDisplay = true
    }

    // MARK: - 数据加载

    func navigate(to url: URL, recordHistory: Bool = true) {
        leaveTagMode()
        let target = url.standardizedFileURL
        guard target.path != currentURL.standardizedFileURL.path || items.isEmpty else { return }
        // 历史由 refreshPathBar → applyPathBarLocation 统一记录，这里只负责切换目录
        if !recordHistory { suppressHistory = true }
        currentURL = target
        reload()
        delegate?.pane(_:self, didNavigateTo: target)
        if !recordHistory { suppressHistory = false }
    }

    func reload() {
        if let tagName {
            emptyLabel.isHidden = false
            runTagSearch(tagName)
            return
        }
        items = FileItem.contents(of: currentURL, showHidden: AppSettings.showHidden)
        applyOrganization()
        // 目录内容可能变了（例如刚新建文件夹），重新判断地址栏箭头是否置灰
        pathBar.invalidateFolderCache()
        refreshPathBar()
        if items.isEmpty {
            if FileItem.isTrash(url: currentURL) && !FileItem.checkTrashPermission() {
                emptyLabel.stringValue = "未能读取废纸篓内容\n请在「系统设置」>「隐私与安全性」授予 Maple 权限".localized
                promptTrashPermissionIfNeeded()
            } else {
                emptyLabel.stringValue = "文件夹为空".localized
            }
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        updateNavigationButtons()
        updateStatus()
        updatePreviewContent()
    }

    private static var hasPromptedTrashAlert = false

    private func promptTrashPermissionIfNeeded() {
        guard !Self.hasPromptedTrashAlert else { return }
        Self.hasPromptedTrashAlert = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, FileItem.isTrash(url: self.currentURL), self.items.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "需要废纸篓访问权限".localized
            alert.informativeText = "由于 macOS 隐私安全保护机制，浏览“废纸篓”需要授予 Maple「完全磁盘访问权限」或允许控制「访达」。\n\n点击「打开系统设置」前往开启权限后即可正常浏览。".localized
            alert.alertStyle = .informational
            alert.addButton(withTitle: "打开系统设置".localized)
            alert.addButton(withTitle: "好".localized)

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// 顶栏面包屑跟随当前视图的「显示位置」：分栏模式下是选中的文件夹/文件，
    /// 列表与图标模式下就是窗格所在目录。
    private func refreshPathBar() {
        if let tagName {
            pathBar.setBadge(title: tagName, color: Tags.color(named: tagName))
            return
        }
        guard viewMode == .columns else {
            applyPathBarLocation(currentURL, trailing: nil)
            return
        }
        if let item = columnView.displayItem {
            applyPathBarLocation(columnView.displayURL,
                                 trailing: PathBar.Trailing(name: item.name, url: item.url))
        } else {
            applyPathBarLocation(columnView.displayURL, trailing: nil)
        }
    }

    /// 设置地址栏显示的地址，并据此维护后退 / 前进历史。
    ///
    /// 历史只认「地址栏显示的地址变了」这一件事，所以无论是列表模式换目录、
    /// 分栏模式点开下一列、还是点地址栏上的某一级，都会留下一条可回退的记录。
    private func applyPathBarLocation(_ url: URL, trailing item: PathBar.Trailing?) {
        let target = url.standardizedFileURL
        if !suppressHistory, target.path != displayedLocation.path {
            backStack.append(displayedLocation)
            forwardStack.removeAll()
        }
        displayedLocation = target
        pathBar.setURL(url, trailing: item)
    }

    // MARK: - 标签视图

    /// 侧栏点击标签：平铺列出所有带该标签的项目（与访达一致）。
    func showTag(_ name: String) {
        // 先落状态再 activate：焦点回调要靠 tagName 把侧栏切到对应的标签行
        if tagName == nil { viewModeBeforeTag = viewMode }
        tagName = name
        if viewMode == .columns { viewMode = .list }
        activate()
        items = []
        emptyLabel.stringValue = "正在查找带有「\(name)」标签的项目…"
        emptyLabel.isHidden = false
        applyOrganization()
        refreshPathBar()
        updateNavigationButtons()
        updateStatus()
        runTagSearch(name)
    }

    private func runTagSearch(_ name: String) {
        tagSearch.search(tag: name) { [weak self] urls in
            guard let self, self.tagName == name else { return }
            self.items = urls.compactMap { FileItem(url: $0) }
            self.emptyLabel.stringValue = "没有带「\(name)」标签的项目"
            self.emptyLabel.isHidden = !self.items.isEmpty
            self.applyOrganization()
            self.updateStatus()
        }
    }

    /// 离开标签视图：恢复进入前的显示方式，地址栏回到真实目录。
    private func leaveTagMode() {
        guard tagName != nil else { return }
        tagSearch.cancel()
        tagName = nil
        emptyLabel.stringValue = "文件夹为空"
        emptyLabel.isHidden = true
        if let previous = viewModeBeforeTag {
            viewModeBeforeTag = nil
            viewMode = previous
        }
        refreshPathBar()
        updateStatus()
    }

    /// 点击表头排序：同一列再次点击切换升降序
    private func toggleSort(_ field: SortField) {
        if sortField == field {
            ascending.toggle()
            AppSettings.sortAscending = ascending
        } else {
            applySort(field)
        }
    }

    private func applyOrganization() {
        listView.sortField = sortField
        listView.ascending = ascending
        listView.currentFolderURL = currentURL
        iconView.currentFolderURL = currentURL
        sections = FileOrganizer.sections(items: items,
                                          sort: sortField,
                                          ascending: ascending,
                                          group: groupMode)
        listView.update(sections: sections)
        iconView.update(sections: sections)
        columnView.refresh(root: currentURL, sort: sortField, ascending: ascending)
        updateStatus()
    }

    private func handleDroppedFiles(_ urls: [URL], destinationDirectory: URL, isCopy: Bool) {
        let created = FileOperations.transfer(urls: urls, to: destinationDirectory, isCopy: isCopy)
        if !created.isEmpty {
            FileOperations.playFileAddedSound()
        }
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        reload()
        if !created.isEmpty {
            select(urls: Set(created))
        }
    }

    private func applyViewMode() {
        listView.isHidden = viewMode != .list
        iconView.isHidden = viewMode != .icons
        columnView.isHidden = viewMode != .columns
        listAndIconContainer.isHidden = viewMode == .columns
        pathBar.isColumnMode = viewMode == .columns
        sizeSlider.configure(for: viewMode)
        switch viewMode {
        case .list: listView.focus()
        case .icons: iconView.focus()
        case .columns:
            columnView.refresh(root: currentURL, sort: sortField, ascending: ascending)
            columnView.focus()
        }
        refreshPathBar()
        updateNavigationButtons()
        updateStatus()
        syncPreviewPaneState()
    }

    /// 导航按钮的依据：分栏模式下取「当前显示位置」。
    private var navigationBaseURL: URL {
        viewMode == .columns ? columnView.displayURL : currentURL
    }

    private func updateNavigationButtons() {
        // 不用 NSButton.isEnabled 表达历史状态：inline 无边框按钮在禁用时会
        // 把模板图标画得近乎透明，看起来像箭头消失。始终保持图标可见，
        // 仅降低透明度；动作本身仍会检查是否有可导航的位置。
        updateNavigationButton(backButton, available: !backStack.isEmpty)
        updateNavigationButton(forwardButton, available: !forwardStack.isEmpty)
    }

    private func updateNavigationButton(_ button: NSButton, available: Bool) {
        button.isEnabled = true
        button.alphaValue = available ? 1 : 0.35
    }

    private func updateStatus() {
        // 分栏模式下统计当前活动列，和顶栏地址保持一致
        let count = viewMode == .columns ? columnView.activeColumnItemCount : items.count
        let selected = currentSelection().count
        if selected > 0 {
            statusLeft.stringValue = "\(count) 个项目，已选 \(selected) 个"
        } else {
            statusLeft.stringValue = "\(count) 个项目"
        }

        if let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            statusRight.stringValue = "可用 \(Format.bytes(capacity))"
        } else {
            statusRight.stringValue = ""
        }
    }

    // MARK: - 选中

    func currentSelection() -> [FileItem] {
        switch viewMode {
        case .list: return listView.selectedItems
        case .icons: return iconView.selectedItems
        case .columns: return columnView.selectedItems
        }
    }

    private var selectedURLs: Set<URL> {
        Set(currentSelection().map { $0.url })
    }

    private func selectionChanged() {
        refreshPathBar()
        updateStatus()
        activate()
        updatePreviewContent()
    }

    // MARK: - 预览模式控制

    @objc private func previewButtonClicked() {
        let current = AppSettings.isPreviewPaneVisible(for: viewMode)
        let newVisible = !current
        AppSettings.setPreviewPaneVisible(newVisible, for: viewMode)
        syncPreviewPaneState()
    }

    private func syncPreviewPaneState() {
        let isVisible = AppSettings.isPreviewPaneVisible(for: viewMode)
        previewButton.isOn = isVisible
        previewButton.contentTintColor = isVisible ? .controlAccentColor : .secondaryLabelColor

        if viewMode == .columns {
            previewPane.isHidden = true
            previewSplitter.isHidden = true
            listAndIconTrailingToSplitter?.isActive = false
            listAndIconTrailingToContent?.isActive = true
            previewWidthConstraint?.isActive = false
            columnView.isPreviewEnabled = isVisible
        } else {
            if isVisible {
                previewPane.isHidden = false
                previewSplitter.isHidden = false
                listAndIconTrailingToContent?.isActive = false
                listAndIconTrailingToSplitter?.isActive = true
                previewWidthConstraint?.isActive = true
                updatePreviewContent()
            } else {
                previewPane.isHidden = true
                previewSplitter.isHidden = true
                listAndIconTrailingToSplitter?.isActive = false
                listAndIconTrailingToContent?.isActive = true
                previewWidthConstraint?.isActive = false
            }
        }
    }

    private func updatePreviewContent() {
        guard !previewPane.isHidden, viewMode != .columns else { return }
        let selection = currentSelection()
        if selection.count == 1 {
            previewPane.configure(with: selection[0])
        } else if selection.count > 1 {
            previewPane.configure(with: selection)
        } else {
            previewPane.configureEmpty(folder: currentURL, itemsCount: items.count)
        }
    }

    // MARK: - 打开

    func open(_ item: FileItem) {
        if item.isNavigable {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        for item in currentSelection() {
            open(item)
            break
        }
    }

    // MARK: - 导航动作

    /// 顶部工具栏标题用的文件夹名（分栏模式下取当前显示位置）。
    var displayedFolderName: String {
        let base = viewMode == .columns ? columnView.displayURL : currentURL
        if let tagName { return tagName }
        let name = FileManager.default.displayName(atPath: base.path)
        return name.isEmpty ? base.lastPathComponent : name
    }

    /// 是否还有可后退的位置（工具栏箭头用）。
    var canGoBack: Bool { !backStack.isEmpty }
    /// 是否还有可前进的位置（工具栏箭头用）。
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 恢复上次的显示方式（不改写全局默认）。
    func restoreViewMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        isRestoringViewMode = true
        viewMode = mode
        isRestoringViewMode = false
    }

    /// 定位到某个文件：进入它所在的目录并选中它（搜索结果用）。
    func reveal(_ url: URL) {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
        activate()
        leaveTagMode()
        if viewMode == .columns {
            columnView.locate(at: target)
            currentURL = columnView.rootURL
            refreshPathBar()
            updateNavigationButtons()
            updateStatus()
        } else {
            if isDirectory.boolValue {
                navigate(to: target)
            } else {
                navigate(to: target.deletingLastPathComponent())
                select(urls: [target])
            }
        }
    }

    @objc func goBack() {
        guard let previous = backStack.popLast() else { return }
        activate()
        leaveTagMode()
        let departing = displayedLocation
        forwardStack.append(departing)
        goToLocation(previous, record: false)
        // 若退回的是上一级父目录，自动高亮刚刚退出的子文件夹，方便定位
        if departing.deletingLastPathComponent().standardizedFileURL.path == previous.standardizedFileURL.path {
            select(urls: [departing])
        }
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { return }
        activate()
        leaveTagMode()
        backStack.append(displayedLocation)
        goToLocation(next, record: false)
    }

    /// 图标视图下是否允许右滑回退：优先走后退历史；若无历史但非根目录，则可右滑回到上一级父目录。
    private var canSwipeBackInIconView: Bool {
        if canGoBack { return true }
        let base = currentURL.standardizedFileURL
        let parentPath = (base.path as NSString).deletingLastPathComponent
        return !parentPath.isEmpty && parentPath != base.path
    }

    /// 图标视图触摸板右滑回退：有后退历史时执行浏览器式后退；无后退历史时直接退回上一级父文件夹（并将原目录压入前进栈，支持左滑前进回来）。
    private func swipeBackInIconView() {
        if canGoBack {
            goBack()
            return
        }
        let departing = currentURL.standardizedFileURL
        let parentPath = (departing.path as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, parentPath != departing.path else { return }
        let parent = URL(fileURLWithPath: parentPath).standardizedFileURL

        activate()
        leaveTagMode()
        forwardStack.append(departing)
        goToLocation(parent, record: false)
        select(urls: [departing])
    }

    /// 点地址栏上的某一级 / 选下拉里的文件夹 / 点击末段文件。
    ///
    /// 分栏模式下「点某一级」退到那一级（收掉它右侧的列），不保留右侧旧展开目录；
    /// 点击末段文件时，在分栏中高亮选中并定位该文件。
    private func revealLocation(_ url: URL) {
        activate()
        leaveTagMode()
        let target = url.standardizedFileURL

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        let isDirectory = exists && isDir.boolValue

        if !isDirectory {
            // 点击的是文件：高亮选中并定位到该文件
            let parent = target.deletingLastPathComponent().standardizedFileURL
            if viewMode == .columns {
                if columnView.displayURL.standardizedFileURL.path == parent.path {
                    columnView.select(urls: [target])
                } else {
                    columnView.locate(at: target)
                }
                refreshPathBar()
                updateNavigationButtons()
                updateStatus()
            } else {
                if currentURL.standardizedFileURL.path != parent.path {
                    navigate(to: parent)
                }
                select(urls: [target])
            }
            return
        }

        guard viewMode == .columns else {
            goToLocation(target)
            return
        }

        // 分栏模式：如果在当前列链内，回退到该级并收掉它右侧的所有列
        if columnView.rewind(to: target) {
            refreshPathBar()
            updateNavigationButtons()
            updateStatus()
            return
        }

        // 不在展开链里（如点击了根之上的祖先目录）：以该目录为新的起点，
        // 绝不重新展开右侧旧目录链（与访达一致）
        currentURL = target
        columnView.setRoot(target)
        refreshPathBar()
        updateNavigationButtons()
        updateStatus()
    }

    /// 分栏模式下双击面包屑：把该目录设为最左列（新的根），再把原来的展开链续回去。
    ///
    /// 与单击「退回」不同，双击不改变列的前后顺序、只是把整条链平移到以它为起点。
    private func revealLocationAsRoot(_ url: URL) {
        activate()
        leaveTagMode()
        guard viewMode == .columns else {
            // 非分栏模式没有「最左列」概念，双击等同于普通切换
            goToLocation(url.standardizedFileURL)
            return
        }
        let target = url.standardizedFileURL
        // 先记下当前最深处（双击之前整条链还在），把它作为续接目标
        let keep = columnView.deepestURL.standardizedFileURL
        columnView.setRoot(target)
        columnView.locate(at: keep)
        refreshPathBar()
        updateNavigationButtons()
        updateStatus()
    }

    /// 定位到某个地址。分栏模式下把整条展开链恢复到该地址，
    /// 其它模式直接切换窗格目录。record 为 false 时不写入历史。
    private func goToLocation(_ url: URL, record: Bool = true) {
        let target = url.standardizedFileURL
        guard viewMode == .columns else {
            navigate(to: target, recordHistory: record)
            return
        }
        if !record { suppressHistory = true }
        columnView.locate(at: target)
        refreshPathBar()
        updateNavigationButtons()
        if !record { suppressHistory = false }
    }

    @objc func goUp() {
        activate()
        leaveTagMode()
        // 分栏模式下「上一层」从当前显示位置算起（选中的文件夹 / 文件所在列）
        let base = navigationBaseURL
        let parentPath = (base.path as NSString).deletingLastPathComponent
        guard parentPath != base.path else { return }
        let parent = URL(fileURLWithPath: parentPath)

        if parent.standardizedFileURL.path == currentURL.standardizedFileURL.path {
            // 上一层就是窗格根目录：只把分栏展开链收回，不重新导航
            if viewMode == .columns {
                columnView.setRoot(currentURL)
                refreshPathBar()
                updateNavigationButtons()
            }
            return
        }
        navigate(to: parent)
    }

    /// 进入路径编辑（菜单「前往 → 编辑路径」与 ⌘L）。
    @objc func beginEditingPath() {
        activate()
        pathBar.beginEditingPath()
    }

    /// 恢复文件列表的键盘焦点，避免快捷键失效。
    func focus() {
        switch viewMode {
        case .list: listView.focus()
        case .icons: iconView.focus()
        case .columns: columnView.focus()
        }
    }

    private func restoreFocusAfterPathEditing() {
        focus()
    }

    // MARK: - 排序 / 分组 / 显示选项（由顶部「更多」菜单调用）

    /// 菜单里选排序字段：只切字段，不改升降序（升降序由单独的命令控制）。
    func applySort(_ field: SortField) {
        if sortField != field {
            sortField = field
            ascending = (field == .name)
        }
        AppSettings.sortField = sortField.rawValue
        AppSettings.sortAscending = ascending
    }

    func applyAscending(_ value: Bool) {
        ascending = value
        AppSettings.sortAscending = value
    }

    func applyGroup(_ mode: GroupMode) {
        groupMode = mode
        AppSettings.groupMode = mode.rawValue
    }

    @objc func refresh() { reload() }

    func toggleHiddenFiles() {
        AppSettings.showHidden.toggle()
        reload()
    }

    /// 「查看显示选项」实时生效。
    func applyDisplayMetrics() {
        iconView.applyIconSize(AppSettings.gridIconSize)
        listView.rowHeight = AppSettings.listRowHeight
    }

    func updateIconSize(_ size: CGFloat) {
        iconView.applyIconSize(size)
    }

    func updateRowHeight(_ height: CGFloat) {
        listView.rowHeight = height
    }

    /// 菜单里「显示简介 / 快速查看」的对象名：有选中取选中项，否则取当前目录。
    var menuTargetName: String {
        if let item = currentSelection().first { return item.name }
        if let tagName { return tagName }
        let name = FileManager.default.displayName(atPath: navigationBaseURL.path)
        return name.isEmpty ? navigationBaseURL.lastPathComponent : name
    }

    func requestQuickLook() {
        delegate?.paneDidRequestQuickLook(self)
    }

    // MARK: - 键盘

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if (flags.contains(.command) || flags.contains(.control)) && chars == "z" {
            if flags.contains(.shift) {
                redoAction()
            } else {
                undoAction()
            }
            return true
        }

        if (flags == .command || flags == [.command, .shift]) && chars == "f" {
            return false
        }

        if flags == .command {
            switch chars {
            case "q":
                NSApp.terminate(nil)
                return true
            case "a":
                selectAll()
                return true
            case "c":
                copySelection()
                return true
            case "v":
                paste()
                return true
            case "f":
                return false
            case "w":
                window?.performClose(nil)
                return true
            case "[":
                goBack()
                return true
            case "]":
                goForward()
                return true
            default:
                break
            }
            if event.keyCode == 51 || event.keyCode == 117 {  // ⌫ / ⌦
                trashSelected()
                return true
            }
            if event.keyCode == 126 {  // ↑
                goUp()
                return true
            }
            if event.keyCode == 125 {  // ↓
                openSelection()
                return true
            }
        }

        switch event.keyCode {
        case 36, 76:  // Return / Enter
            renameSelected()
            return true
        case 49:  // Space
            delegate?.paneDidRequestQuickLook(self)
            return true
        case 51, 117:  // Delete
            trashSelected()
            return true
        default:
            return false
        }
    }

    func selectAll() {
        switch viewMode {
        case .list: listView.selectAll()
        case .icons: iconView.selectAll()
        case .columns: columnView.selectAll()
        }
        updateStatus()
    }

    func clearSelection() {
        switch viewMode {
        case .list: listView.deselectAll()
        case .icons: iconView.deselectAll()
        case .columns: columnView.clearSelection()
        }
        updateStatus()
    }

    // MARK: - 地址栏「窗格操作」菜单

    @objc private func showPaneMenu(_ sender: NSButton) {
        activate()
        let menu = makePaneMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    /// 当前窗格目录的常用操作，以及该窗格自己的显示方式、分组和排序。
    private func makePaneMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        add(menu, "在终端打开", #selector(openInTerminal))
        add(menu, "显示简介", #selector(showPaneInfo))
        let otherPane = add(menu, "在其他窗格中显示", #selector(openPaneInOtherPane))
        otherPane.isEnabled = delegate?.paneCanOpenInOtherPane(self) ?? false
        add(menu, "在访达中显示", #selector(revealPaneInFinder))

        menu.addItem(.separator())
        add(menu, "拷贝路径", #selector(copyPanePath))
        let pasteItem = add(menu, "粘贴", #selector(paste))
        let pasteOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let pastedURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: pasteOptions) as? [URL]
        pasteItem.isEnabled = !isTagView && !(pastedURLs?.isEmpty ?? true)

        menu.addItem(.separator())
        let newFolder = add(menu, "新建文件夹", #selector(createFolder))
        newFolder.isEnabled = !isTagView
        let newFile = add(menu, "新建文件", #selector(createFile))
        newFile.isEnabled = !isTagView

        menu.addItem(.separator())

        let viewItem = NSMenuItem(title: "显示方式", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        viewMenu.autoenablesItems = false
        for mode in ViewMode.allCases {
            let item = add(viewMenu, mode.title, #selector(paneViewModePicked(_:)))
            item.representedObject = mode.rawValue
            item.state = mode == viewMode ? .on : .off
            item.isEnabled = !isTagView
        }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let groupItem = NSMenuItem(title: "分组", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        groupMenu.autoenablesItems = false
        for mode in GroupMode.allCases {
            let item = add(groupMenu, mode.title, #selector(paneGroupPicked(_:)))
            item.representedObject = mode.rawValue
            item.state = mode == groupMode ? .on : .off
        }
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        let sortItem = NSMenuItem(title: "排序", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortMenu.autoenablesItems = false
        for field in SortField.allCases {
            let item = add(sortMenu, field.title, #selector(paneSortPicked(_:)))
            item.representedObject = field.rawValue
            item.state = field == sortField ? .on : .off
        }
        sortMenu.addItem(.separator())
        let asc = add(sortMenu, "升序", #selector(paneOrderPicked(_:)))
        asc.representedObject = "asc"
        asc.state = ascending ? .on : .off
        let desc = add(sortMenu, "降序", #selector(paneOrderPicked(_:)))
        desc.representedObject = "desc"
        desc.state = ascending ? .off : .on
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(.separator())
        add(menu, AppSettings.showHidden ? "隐藏隐藏文件" : "显示隐藏文件", #selector(togglePaneHiddenFiles))
        add(menu, "刷新", #selector(refresh))
        return menu
    }

    @objc private func paneViewModePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ViewMode(rawValue: raw) else { return }
        viewMode = mode
    }

    @objc private func paneGroupPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = GroupMode(rawValue: raw) else { return }
        applyGroup(mode)
    }

    @objc private func paneSortPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let field = SortField(rawValue: raw) else { return }
        applySort(field)
    }

    @objc private func paneOrderPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyAscending(raw == "asc")
    }

    @objc private func openPaneInOtherPane() {
        delegate?.pane(self, openInOtherPane: currentURL)
    }

    @objc private func togglePaneHiddenFiles() {
        toggleHiddenFiles()
    }

    // MARK: - 文件操作

    @objc func createFolder() {
        guard tagName == nil else { NSSound.beep(); return }
        let dir = activeDirectoryURL
        let base = "未命名文件夹"
        var candidate = base
        var index = 2
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(index)"
            index += 1
        }
        let target = dir.appendingPathComponent(candidate)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            FileOperations.playFileAddedSound()
            reload()
            select(urls: [target])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.renameSelected()
            }
        } catch {
            presentError(error, title: "无法新建文件夹")
        }
    }

    @objc func createFile() {
        guard tagName == nil else { NSSound.beep(); return }
        let target = uniqueDestination(for: "未命名文件.txt")
        do {
            try Data().write(to: target)
            FileOperations.playFileAddedSound()
            reload()
            select(urls: [target])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.renameSelected()
            }
        } catch {
            presentError(error, title: "无法新建文件")
        }
    }

    private func handleFileRenamed(from oldURL: URL, to newURL: URL) {
        undoStack.append(FileActionRecord(type: .rename(from: oldURL, to: newURL)))
        redoStack.removeAll()
        reload()
        select(urls: [newURL])
        selectionChanged()
    }

    @objc func renameSelected() {
        switch viewMode {
        case .list:
            listView.startRenameSelected()
        case .icons:
            iconView.startRenameSelected()
        case .columns:
            columnView.startRenameOnActiveColumn()
        }
    }

    @objc func trashSelected() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        FileOperations.playTrashSound()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var trashedMapping: [(original: URL, trash: URL)] = []
            var firstError: Error?

            for url in urls {
                var resultingURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    if let inTrash = resultingURL as URL? {
                        trashedMapping.append((original: url, trash: inTrash))
                    }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }

            DispatchQueue.main.async {
                if !trashedMapping.isEmpty {
                    self.undoStack.append(FileActionRecord(type: .moveToTrash(mapping: trashedMapping)))
                    self.redoStack.removeAll()
                }
                if let firstError, trashedMapping.isEmpty {
                    self.presentError(firstError, title: "无法移到废纸篓")
                } else {
                    self.contextTargetItems.removeAll()
                    if self.viewMode != .columns {
                        self.clearSelection()
                    }
                    self.reload()
                    self.refreshPathBar()
                    self.selectionChanged()
                    self.focus()
                    NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                }
            }
        }
    }

    // MARK: - 撤销与重做

    @objc func undo(_ sender: Any?) {
        undoAction()
    }

    @objc func redo(_ sender: Any?) {
        redoAction()
    }

    @objc func undoAction() {
        guard let record = undoStack.popLast() else {
            NSSound.beep()
            return
        }

        switch record.type {
        case .moveToTrash(let mapping):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var restoredURLs: [URL] = []
                var redoMapping: [(original: URL, trash: URL)] = []

                for (original, inTrash) in mapping {
                    guard FileManager.default.fileExists(atPath: inTrash.path) else { continue }
                    let parent = original.deletingLastPathComponent()
                    guard FileManager.default.fileExists(atPath: parent.path) else { continue }

                    var dest = original
                    if FileManager.default.fileExists(atPath: dest.path) {
                        dest = self.uniqueDestination(for: original.lastPathComponent)
                    }

                    do {
                        try FileManager.default.moveItem(at: inTrash, to: dest)
                        restoredURLs.append(dest)
                        redoMapping.append((original: dest, trash: inTrash))
                    } catch {
                        print("Failed to restore \(inTrash) to \(dest): \(error)")
                    }
                }

                DispatchQueue.main.async {
                    if !restoredURLs.isEmpty {
                        FileOperations.playFileAddedSound()
                        self.redoStack.append(FileActionRecord(type: .moveToTrash(mapping: redoMapping)))
                        self.reload()
                        self.select(urls: Set(restoredURLs))
                        self.refreshPathBar()
                        self.selectionChanged()
                        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                    } else {
                        NSSound.beep()
                    }
                }
            }

        case .rename(let fromURL, let toURL):
            if FileManager.default.fileExists(atPath: toURL.path) && !FileManager.default.fileExists(atPath: fromURL.path) {
                do {
                    try FileManager.default.moveItem(at: toURL, to: fromURL)
                    redoStack.append(FileActionRecord(type: .rename(from: toURL, to: fromURL)))
                    reload()
                    select(urls: Set([fromURL]))
                    refreshPathBar()
                    selectionChanged()
                    NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    @objc func redoAction() {
        guard let record = redoStack.popLast() else {
            NSSound.beep()
            return
        }

        switch record.type {
        case .moveToTrash(let mapping):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var trashedMapping: [(original: URL, trash: URL)] = []

                for (urlToTrash, _) in mapping {
                    guard FileManager.default.fileExists(atPath: urlToTrash.path) else { continue }
                    var resultingURL: NSURL?
                    do {
                        try FileManager.default.trashItem(at: urlToTrash, resultingItemURL: &resultingURL)
                        if let inTrash = resultingURL as URL? {
                            trashedMapping.append((original: urlToTrash, trash: inTrash))
                        }
                    } catch { }
                }

                DispatchQueue.main.async {
                    if !trashedMapping.isEmpty {
                        FileOperations.playTrashSound()
                        self.undoStack.append(FileActionRecord(type: .moveToTrash(mapping: trashedMapping)))
                        self.clearSelection()
                        self.reload()
                        self.refreshPathBar()
                        self.selectionChanged()
                        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                    }
                }
            }

        case .rename(let fromURL, let toURL):
            if FileManager.default.fileExists(atPath: fromURL.path) && !FileManager.default.fileExists(atPath: toURL.path) {
                do {
                    try FileManager.default.moveItem(at: fromURL, to: toURL)
                    undoStack.append(FileActionRecord(type: .rename(from: fromURL, to: toURL)))
                    reload()
                    select(urls: Set([toURL]))
                    refreshPathBar()
                    selectionChanged()
                    NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    @objc func cutSelection() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString("cut", forType: Self.cutPasteboardType)
    }

    @objc func copySelection() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString("copy", forType: Self.cutPasteboardType)
    }

    @objc func paste() {
        guard tagName == nil else { NSSound.beep(); return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return }

        let isCut = NSPasteboard.general.string(forType: Self.cutPasteboardType) == "cut"

        var firstCreated: URL?
        let targetDir = activeDirectoryURL
        for source in urls {
            let destination = uniqueDestination(for: source.lastPathComponent, in: targetDir)
            do {
                if isCut {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                if firstCreated == nil { firstCreated = destination }
            } catch {
                presentError(error, title: "粘贴失败")
                return
            }
        }
        if isCut {
            NSPasteboard.general.setString("", forType: Self.cutPasteboardType)
        }
        reload()
        if let firstCreated {
            FileOperations.playFileAddedSound()
            select(urls: [firstCreated])
        }
    }

    private func uniqueDestination(for name: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? activeDirectoryURL
        var candidate = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 2
        while true {
            let fileName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    @objc func copyPath() {
        let targets = effectiveContextItems
        let urls = targets.isEmpty ? [activeDirectoryURL] : targets.map { $0.url }
        copyPathsToPasteboard(urls)
    }

    /// 地址栏菜单始终拷贝当前活动目录，不受文件列表选中项影响。
    @objc private func copyPanePath() {
        copyPathsToPasteboard([activeDirectoryURL])
    }

    private func copyPathsToPasteboard(_ urls: [URL]) {
        let text = urls.map { $0.path }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 复制副本（Duplicate）
    @objc func contextDuplicate() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        let created = FileOperations.duplicate(urls: urls)
        if !created.isEmpty {
            reload()
            select(urls: Set(created))
        }
    }

    /// 压缩选中的文件/文件夹
    @objc func contextCompress() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        FileOperations.compress(urls: urls) { [weak self] created in
            self?.reload()
            if let first = created.first {
                self?.select(urls: Set([first]))
            }
        }
    }

    /// 解压缩归档文件
    @objc func contextDecompress() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        FileOperations.decompress(urls: urls) { [weak self] in
            self?.reload()
        }
    }

    /// 直接永久删除（不进废纸篓）
    @objc func deleteImmediately() {
        let targets = effectiveContextItems
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        FileOperations.deleteImmediately(urls: urls, window: window) { [weak self] success in
            if success {
                guard let self else { return }
                self.contextTargetItems.removeAll()
                if self.viewMode != .columns {
                    self.clearSelection()
                }
                self.reload()
                self.refreshPathBar()
                self.selectionChanged()
                self.focus()
                NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            }
        }
    }

    @objc func revealInFinder() {
        let targets = effectiveContextItems
        let urls = targets.isEmpty ? [activeDirectoryURL] : targets.map { $0.url }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func revealPaneInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([activeDirectoryURL])
    }

    @objc func openInTerminal() {
        let targetURL: URL
        if let target = effectiveContextItems.first {
            targetURL = target.isDirectory ? target.url : target.url.deletingLastPathComponent()
        } else {
            targetURL = activeDirectoryURL
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([targetURL], withApplicationAt: terminal, configuration: configuration)
    }

    @objc func showInfo() {
        let targets = effectiveContextItems
        let urls = targets.isEmpty ? [navigationBaseURL] : targets.map { $0.url }
        presentInfo(for: urls)
    }

    /// 地址栏菜单显示当前目录简介，而不是列表里恰好选中的项目。
    @objc private func showPaneInfo() {
        presentInfo(for: [navigationBaseURL])
    }

    private func presentInfo(for urls: [URL]) {
        guard let window else { return }
        guard let url = urls.first else { return }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey, .creationDateKey,
                                         .localizedTypeDescriptionKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false

        var lines: [String] = []
        let displayName = FileManager.default.displayName(atPath: url.path)
        lines.append("名称：\(displayName.isEmpty ? url.lastPathComponent : displayName)")
        lines.append("种类：\(values?.localizedTypeDescription ?? (isDirectory ? "文件夹" : "文件"))")
        let isPackage = values?.isPackage ?? false
        var sizeVal: Int64?
        if !isDirectory {
            if let size = values?.fileSize { sizeVal = Int64(size) }
        } else if let cached = BundleSizeCache.shared.size(for: url) {
            sizeVal = cached
        } else if isPackage || isDirectory {
            sizeVal = BundleSizeCache.calculateDirectorySize(at: url)
            BundleSizeCache.shared.set(size: sizeVal ?? 0, for: url)
        }
        if let sizeVal {
            lines.append("大小：\(Format.bytes(sizeVal))")
        }
        if urls.count > 1 {
            lines.append("已选 \(urls.count) 个项目，以上为第一个项目的信息")
        }
        lines.append("位置：\(url.deletingLastPathComponent().path)")
        if let created = values?.creationDate { lines.append("创建：\(Format.date(created))") }
        if let modified = values?.contentModificationDate { lines.append("修改：\(Format.date(modified))") }
        if values?.isSymbolicLink == true {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
            lines.append("链接目标：\(target)")
        }
        if !isDirectory, let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let appName = FileManager.default.displayName(atPath: appURL.path)
            lines.append("打开方式：\(appName)")
        }

        let alert = NSAlert()
        alert.messageText = "简介"
        alert.informativeText = lines.joined(separator: "\n")

        // 设置为目标文件/目录/应用的真实图标（避免默认显示为 Maple 自身图标）
        let targetIcon = NSWorkspace.shared.icon(forFile: url.path)
        targetIcon.size = NSSize(width: 64, height: 64)
        alert.icon = targetIcon

        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func presentError(_ error: Error, title: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    // MARK: - 选中同步

    func select(urls: Set<URL>) {
        switch viewMode {
        case .list: listView.select(urls: urls)
        case .icons: iconView.select(urls: urls)
        case .columns: columnView.select(urls: urls)
        }
        updateStatus()
    }

    // MARK: - 右键菜单

    private func makeContextMenu(clickedItem: FileItem?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let selection = currentSelection()
        let targetItems: [FileItem]
        if let clickedItem {
            if selection.contains(where: { $0.url == clickedItem.url }) {
                targetItems = selection
            } else {
                targetItems = [clickedItem]
            }
        } else {
            targetItems = []
        }
        self.contextTargetItems = targetItems
        let hasSelection = !targetItems.isEmpty

        if hasSelection {
            // 1. 打开 / 在新窗格中打开
            add(menu, "打开", #selector(contextOpen))
            add(menu, "在新窗格中打开", #selector(contextOpenInOtherPane))

            // 打开方式（仅对单选有效）
            if targetItems.count == 1, let openWithSub = makeOpenWithSubmenu(for: targetItems[0]) {
                let openWithItem = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
                openWithItem.submenu = openWithSub
                menu.addItem(openWithItem)
            }

            menu.addItem(.separator())

            // 2. 快速查看 & 显示简介
            let qlTitle = targetItems.count == 1 ? "快速查看“\(targetItems[0].name)”" : "快速查看 \(targetItems.count) 项"
            let qlItem = add(menu, qlTitle, #selector(contextQuickLook))
            qlItem.keyEquivalent = " "

            let infoItem = add(menu, "显示简介", #selector(showInfo))
            infoItem.keyEquivalent = "i"
            infoItem.keyEquivalentModifierMask = [.command]

            menu.addItem(.separator())

            // 3. 剪切、拷贝、拷贝路径、复制
            let cutItem = add(menu, targetItems.count == 1 ? "剪切“\(targetItems[0].name)”" : "剪切 \(targetItems.count) 项", #selector(cutSelection))
            cutItem.keyEquivalent = "x"
            cutItem.keyEquivalentModifierMask = [.command]

            let copyItem = add(menu, targetItems.count == 1 ? "拷贝“\(targetItems[0].name)”" : "拷贝 \(targetItems.count) 项", #selector(copySelection))
            copyItem.keyEquivalent = "c"
            copyItem.keyEquivalentModifierMask = [.command]

            let copyPathItem = add(menu, "拷贝路径", #selector(copyPath))
            copyPathItem.keyEquivalent = "c"
            copyPathItem.keyEquivalentModifierMask = [.command, .option]

            let dupItem = add(menu, "复制", #selector(contextDuplicate))
            dupItem.keyEquivalent = "d"
            dupItem.keyEquivalentModifierMask = [.command]

            menu.addItem(.separator())

            // 4. 重命名
            if targetItems.count == 1 {
                let renameItem = add(menu, "重命名", #selector(renameSelected))
                renameItem.keyEquivalent = "\r"
            }

            // 5. 压缩 / 解压缩
            let allArchives = targetItems.allSatisfy { FileOperations.isArchive(url: $0.url) }
            if allArchives {
                let title = targetItems.count == 1 ? "解压缩“\(targetItems[0].name)”" : "解压缩 \(targetItems.count) 个归档"
                add(menu, title, #selector(contextDecompress))
            } else {
                let title = targetItems.count == 1 ? "压缩“\(targetItems[0].name)”" : "压缩 \(targetItems.count) 个项目"
                add(menu, title, #selector(contextCompress))
            }

            menu.addItem(.separator())

            // 6. 标记
            let tagItem = NSMenuItem(title: "标记", action: nil, keyEquivalent: "")
            let tagSubmenu = NSMenu(title: "标记")
            tagSubmenu.autoenablesItems = false
            for def in Tags.all {
                let m = NSMenuItem(title: def.name, action: #selector(toggleTagFromMenu(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = def.name
                m.image = Tags.dotImage(color: def.color, diameter: 12)
                tagSubmenu.addItem(m)
            }
            tagItem.submenu = tagSubmenu
            menu.addItem(tagItem)

            menu.addItem(.separator())

            // 7. 移到废纸篓 & 直接删除…
            let trashItem = add(menu, targetItems.count == 1 ? "移到废纸篓" : "将 \(targetItems.count) 项移到废纸篓", #selector(trashSelected))
            trashItem.keyEquivalent = "\u{08}"
            trashItem.keyEquivalentModifierMask = [.command]

            let deleteItem = add(menu, "直接删除…", #selector(deleteImmediately))
            deleteItem.keyEquivalent = "\u{08}"
            deleteItem.keyEquivalentModifierMask = [.command, .option]

            menu.addItem(.separator())

            // 8. 终端 & 访达
            add(menu, "在终端中打开", #selector(openInTerminal))
            add(menu, "在 Finder 中显示", #selector(revealInFinder))
        } else {
            // 空白处右键
            if tagName == nil {
                add(menu, "新建文件夹", #selector(createFolder))
                add(menu, "新建文件", #selector(createFile))
                menu.addItem(.separator())
                add(menu, "粘贴", #selector(paste))
                menu.addItem(.separator())
            }
            add(menu, "在终端中打开", #selector(openInTerminal))
            add(menu, "在 Finder 中显示", #selector(revealInFinder))
            menu.addItem(.separator())
            add(menu, "刷新", #selector(refresh))
        }

        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func makeOpenWithSubmenu(for item: FileItem) -> NSMenu? {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        guard !appURLs.isEmpty else { return nil }
        let submenu = NSMenu(title: "打开方式")
        submenu.autoenablesItems = false

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: item.url)

        for appURL in appURLs.prefix(10) {
            let appName = FileManager.default.displayName(atPath: appURL.path)
            let isDefault = (appURL.standardizedFileURL.path == defaultApp?.standardizedFileURL.path)
            let title = isDefault ? "\(appName) (默认)" : appName
            let m = NSMenuItem(title: title, action: #selector(openWithAppMenuItemClicked(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = (appURL: appURL, fileURL: item.url)
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            m.image = icon
            submenu.addItem(m)
        }

        submenu.addItem(.separator())
        let otherItem = NSMenuItem(title: "其他…", action: #selector(openWithOtherAppClicked(_:)), keyEquivalent: "")
        otherItem.target = self
        otherItem.representedObject = item.url
        submenu.addItem(otherItem)

        return submenu
    }

    @objc private func openWithAppMenuItemClicked(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (appURL: URL, fileURL: URL) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([pair.fileURL], withApplicationAt: pair.appURL, configuration: config, completionHandler: nil)
    }

    @objc private func openWithOtherAppClicked(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.message = "选取用于打开“\(fileURL.lastPathComponent)”的应用程序"
        panel.prompt = "打开"
        if let window {
            panel.beginSheetModal(for: window) { resp in
                if resp == .OK, let appURL = panel.url {
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
                }
            }
        } else if panel.runModal() == .OK, let appURL = panel.url {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        }
    }

    @objc private func contextQuickLook() {
        delegate?.paneDidRequestQuickLook(self)
    }

    @objc private func contextOpen() {
        let targets = effectiveContextItems
        for item in targets {
            open(item)
            break
        }
    }

    @objc private func contextOpenInOtherPane() {
        guard let item = effectiveContextItems.first else { return }
        NotificationCenter.default.post(name: .openInOtherPane, object: item.url)
    }

    @objc private func toggleTagFromMenu(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        let selected = effectiveContextItems
        for item in selected {
            Tags.toggleTag(on: item.url, tag: tagName)
        }
        refresh()
    }
}

extension Notification.Name {
    static let openInOtherPane = Notification.Name("QSpaceLiteOpenInOtherPane")
}
