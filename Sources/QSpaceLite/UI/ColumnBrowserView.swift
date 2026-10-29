import AppKit

/// 分栏浏览（Finder / QSpace 的「分栏」模式）。
///
/// 最左一列是当前目录，点开其中一个文件夹，就在它右侧展开该文件夹的内容，
/// 逐级向右延伸；选中文件则收起右侧多余的列。列宽固定，整排可横向滚动。
final class ColumnBrowserView: NSView {

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onActivate: (() -> Void)?
    /// 当前显示位置变化：目录（面包屑末级）+ 选中的文件（若有）。
    var onLocationChange: ((URL, FileItem?) -> Void)?
    /// 其它按键（⌘C、空格、⌫ 等）交给窗格处理。
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onFileRenamed: ((URL, URL) -> Void)?
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    /// 单列宽度常量
    static let minColumnWidth: CGFloat = 140
    static let maxColumnWidth: CGFloat = 700
    static var defaultColumnWidth: CGFloat { AppSettings.browserColumnWidth }

    private let scroll = NSScrollView()
    private let board = ColumnBoard()
    private var columns: [BrowserColumn] = []
    private var dividers: [ColumnDividerView] = []
    /// 选中文件时，列链最右侧追加的一栏文件预览（仿访达分栏视图）。
    private var previewColumn: FilePreviewColumn?

    private var dragStartWidths: [CGFloat] = []
    private var dragStartPreviewWidth: CGFloat = 214

    private(set) var rootURL = URL(fileURLWithPath: NSHomeDirectory())
    private var sortField: SortField = .name
    private var ascending = true

    /// 当前高亮的条目（最深一次选择）。
    private(set) var currentItem: FileItem?
    /// 顶栏面包屑应该显示的目录：选中文件夹时为该文件夹，选中文件时为它所在列，
    /// 什么都没选时为当前活动列。
    private(set) var displayURL = URL(fileURLWithPath: NSHomeDirectory())
    /// 选中文件的名称，追加在面包屑末段；选中文件夹或未选中时为 nil。
    private(set) var displayItem: FileItem?
    private var activeColumn = 0
    /// 程序化选中（新建/重命名后）不触发右侧展开。
    private var suppressExpansion = false

    // MARK: - 生命周期

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.paneBackground
        scroll.scrollerStyle = .overlay
        board.owner = self
        scroll.documentView = board
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    override func layout() {
        super.layout()
        layoutColumns()
    }

    private func layoutColumns() {
        let height = max(0, scroll.contentSize.height)
        var currentX: CGFloat = 0

        for column in columns {
            let width = column.columnWidth
            column.frame = NSRect(x: currentX, y: 0, width: width, height: height)
            currentX += width
        }

        if let preview = previewColumn {
            let width = preview.columnWidth
            preview.frame = NSRect(x: currentX, y: 0, width: width, height: height)
            currentX += width
        }

        board.frame = NSRect(x: 0, y: 0,
                             width: max(currentX, scroll.contentSize.width),
                             height: height)

        updateDividers(height: height)
    }

    private func updateDividers(height: CGFloat) {
        let totalTargets = columns.count + (previewColumn != nil ? 1 : 0)
        while dividers.count < totalTargets {
            let div = ColumnDividerView()
            board.addSubview(div)
            dividers.append(div)
        }
        while dividers.count > totalTargets {
            let div = dividers.removeLast()
            div.removeFromSuperview()
        }

        for (index, col) in columns.enumerated() {
            let div = dividers[index]
            div.columnIndex = index
            div.isPreview = false
            div.frame = NSRect(x: col.frame.maxX - 4, y: 0, width: 8, height: height)
            board.addSubview(div)
            wireDivider(div)
        }

        if let preview = previewColumn {
            let div = dividers[columns.count]
            div.columnIndex = columns.count
            div.isPreview = true
            div.frame = NSRect(x: preview.frame.maxX - 4, y: 0, width: 8, height: height)
            board.addSubview(div)
            wireDivider(div)
        }
    }

    private func wireDivider(_ div: ColumnDividerView) {
        div.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartWidths = self.columns.map { $0.columnWidth }
            self.dragStartPreviewWidth = self.previewColumn?.columnWidth ?? AppSettings.browserColumnWidth
        }
        div.onDrag = { [weak self, weak div] dx, isOption in
            guard let self, let div else { return }
            let index = div.columnIndex
            if div.isPreview {
                let startW = self.dragStartPreviewWidth
                let newW = max(Self.minColumnWidth, min(Self.maxColumnWidth, startW + dx))
                if isOption {
                    for col in self.columns { col.columnWidth = newW }
                    self.previewColumn?.columnWidth = newW
                    AppSettings.browserColumnWidth = newW
                } else {
                    self.previewColumn?.columnWidth = newW
                }
            } else if index < self.columns.count {
                let startW = index < self.dragStartWidths.count ? self.dragStartWidths[index] : self.columns[index].columnWidth
                let newW = max(Self.minColumnWidth, min(Self.maxColumnWidth, startW + dx))
                if isOption {
                    for col in self.columns { col.columnWidth = newW }
                    self.previewColumn?.columnWidth = newW
                    AppSettings.browserColumnWidth = newW
                } else {
                    self.columns[index].columnWidth = newW
                }
            }
            self.layoutColumns()
        }
        div.onDragEnded = { [weak self] in
            guard let self else { return }
            if let first = self.columns.first {
                AppSettings.browserColumnWidth = first.columnWidth
            }
        }
        div.onDoubleClick = { [weak self, weak div] in
            guard let self, let div else { return }
            if div.isPreview {
                self.previewColumn?.columnWidth = AppSettings.browserColumnWidth
                self.layoutColumns()
            } else {
                self.autoSizeColumn(at: div.columnIndex)
            }
        }
    }

    private func autoSizeColumn(at index: Int) {
        guard index < columns.count else { return }
        let col = columns[index]
        let font = NSFont.systemFont(ofSize: 12.5)
        var maxWidth: CGFloat = 0
        for item in col.items {
            let width = (item.name as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth { maxWidth = width }
        }
        let ideal = max(Self.minColumnWidth, min(Self.maxColumnWidth, maxWidth + 65))
        if abs(col.columnWidth - ideal) < 2 {
            col.columnWidth = AppSettings.browserColumnWidth
        } else {
            col.columnWidth = ideal
        }
        layoutColumns()
    }

    // MARK: - 数据

    /// 由窗格调用：根目录或排序发生变化时刷新。
    func refresh(root: URL, sort: SortField, ascending: Bool) {
        let rootChanged = root.standardizedFileURL != rootURL.standardizedFileURL
        rootURL = root
        sortField = sort
        self.ascending = ascending

        if rootChanged || columns.isEmpty {
            rebuild()
        } else {
            reloadKeepingChain()
        }
    }

    /// 重置为「只有一列」的状态，并选中 url（若在根目录内）。
    func setRoot(_ url: URL, selecting target: URL? = nil) {
        rootURL = url
        rebuild()
        if let target { select(urls: [target]) }
    }

    private func rebuild() {
        removeColumns(from: 0)
        clearPreview()
        let first = makeColumn(url: rootURL, index: 0)
        first.reload(showHidden: AppSettings.showHidden, sort: sortField, ascending: ascending)
        columns = [first]
        board.addSubview(first)
        activeColumn = 0
        currentItem = nil
        layoutColumns()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLocation()
    }

    /// 排序/显示隐藏变化时，保留已展开的列链，只重新读取内容。
    private func reloadKeepingChain() {
        guard !columns.isEmpty else { return rebuild() }
        for column in columns {
            column.reload(showHidden: AppSettings.showHidden,
                          sort: sortField,
                          ascending: ascending,
                          restoring: column.selectedItem?.url)
        }
        // 链上某一列选中的目录已经不存在（被删除/改名）时，收掉后面的列
        for index in 0..<max(0, columns.count - 1) {
            guard let item = columns[index].selectedItem, item.isNavigable else {
                removeColumns(from: index + 1)
                break
            }
        }
        layoutColumns()
        syncPreview()
        updateLocation()
    }

    private func makeColumn(url: URL, index: Int) -> BrowserColumn {
        let column = BrowserColumn(url: url)
        column.columnWidth = AppSettings.browserColumnWidth
        column.horizontalScrollTarget = scroll
        column.onDropFiles = { [weak self] urls, dest, isCopy in
            self?.onDropFiles?(urls, dest, isCopy)
        }
        column.onSelect = { [weak self, weak column] item in
            guard let self, let column,
                  let index = self.columns.firstIndex(where: { $0 === column }) else { return }
            self.activeColumn = index
            let items = column.selectedItems
            if self.suppressExpansion {
                self.currentItem = items.last ?? item
                let urls = Set(items.map { $0.url })
                self.onSelectionChange?(urls.isEmpty ? Set([item?.url].compactMap { $0 }) : urls)
                self.updateLocation()
                return
            }
            self.expand(after: index, item: item, selectedItems: items)
        }
        column.onOpen = { [weak self] item in self?.onOpen?(item) }
        column.onActivate = { [weak self] in self?.onActivate?() }
        column.keyHandler = { [weak self, weak column] event in
            guard let self, let column,
                  let index = self.columns.firstIndex(where: { $0 === column }) else { return false }
            return self.handleKey(event, columnIndex: index)
        }
        column.menuProvider = { [weak self, weak column] _ in
            self?.menuProvider?(column?.selectedItem)
        }
        column.onFileRenamed = { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
        return column
    }

    func startRenameOnActiveColumn() {
        if activeColumn >= 0, activeColumn < columns.count, columns[activeColumn].hasSingleSelection {
            columns[activeColumn].startRenameSelected()
            return
        }
        for col in columns.reversed() {
            if col.hasSingleSelection {
                col.startRenameSelected()
                return
            }
        }
        if let last = columns.last {
            last.startRenameSelected()
        }
    }

    // MARK: - 展开与收起

    private func expand(after index: Int, item: FileItem?, selectedItems: [FileItem] = []) {
        removeColumns(from: index + 1)
        currentItem = selectedItems.last ?? item

        if selectedItems.count > 1 {
            // 多选状态：在最右侧展示多选汇总预览（仿访达分栏视图）
            syncPreview(items: selectedItems, scrollToVisible: true)
            activeColumn = index
            let urls = Set(selectedItems.map { $0.url })
            onSelectionChange?(urls)
            updateLocation()
            onActivate?()
            return
        }

        if let item, item.isNavigable {
            let next = makeColumn(url: item.url, index: index + 1)
            next.reload(showHidden: AppSettings.showHidden, sort: sortField, ascending: ascending)
            columns.append(next)
            board.addSubview(next)
            activeColumn = index + 1
            layoutColumns()
            next.scrollToVisible(next.bounds)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if let item, !item.isNavigable {
            // 选中单文件：在列链最右侧追加一栏文件预览（仿访达分栏视图）。
            syncPreview(items: [item], scrollToVisible: true)
            activeColumn = index
        } else {
            currentItem = nil
            clearPreview()
            layoutColumns()
        }

        let urls = Set(selectedItems.isEmpty ? [item?.url].compactMap { $0 } : selectedItems.map { $0.url })
        onSelectionChange?(urls)
        updateLocation()
        onActivate?()
    }

    /// 定位到指定地址：逐级展开父目录，最后选中目标并展开它。
    ///
    /// 后退 / 前进以及点地址栏上的某一级都走这里 —— 分栏模式下地址栏显示的
    /// 就是「当前选中的文件夹」，所以回到某个历史地址 = 把整条展开链恢复回去。
    func locate(at url: URL) {
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        let isDirectory = exists && isDir.boolValue
        let targetFolder = isDirectory ? target : target.deletingLastPathComponent().standardizedFileURL

        let root = rootURL.standardizedFileURL
        if !targetFolder.path.hasPrefix(root.path + "/") && targetFolder.path != root.path {
            // target 不在当前 root 内：寻找合适的祖先根目录（优先使用用户主目录或常用目录）
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let desktop = home.appendingPathComponent("Desktop").standardizedFileURL
            let documents = home.appendingPathComponent("Documents").standardizedFileURL
            let downloads = home.appendingPathComponent("Downloads").standardizedFileURL

            let chosenRoot: URL
            if targetFolder.path == desktop.path || targetFolder.path.hasPrefix(desktop.path + "/") {
                chosenRoot = desktop
            } else if targetFolder.path == documents.path || targetFolder.path.hasPrefix(documents.path + "/") {
                chosenRoot = documents
            } else if targetFolder.path == downloads.path || targetFolder.path.hasPrefix(downloads.path + "/") {
                chosenRoot = downloads
            } else if targetFolder.path == home.path || targetFolder.path.hasPrefix(home.path + "/") {
                chosenRoot = home
            } else {
                chosenRoot = (targetFolder.pathComponents.count > 2)
                    ? URL(fileURLWithPath: (targetFolder.path as NSString).deletingLastPathComponent).standardizedFileURL
                    : targetFolder
            }
            rootURL = chosenRoot
        }

        let effectiveRoot = rootURL.standardizedFileURL
        if target.path == effectiveRoot.path {
            rebuild()
            return
        }

        // 从根到目标的每一级目录/文件
        var chain: [URL] = []
        var current = effectiveRoot
        for component in target.pathComponents.dropFirst(effectiveRoot.pathComponents.count) {
            current = current.appendingPathComponent(component)
            chain.append(current.standardizedFileURL)
        }

        rebuild()
        for level in chain {
            guard let column = columns.last else { break }
            guard let item = column.item(withURL: level) else { break }
            expand(after: columns.count - 1, item: item)
        }
    }

    /// 当前展开链的最深一列（可能就是根）。
    var deepestURL: URL { columns.last?.url ?? rootURL }

    /// 地址栏点某一级：只在链内「退到」这一级 —— 收掉它右侧的列、把焦点移回来，
    /// 不改根、不重新读盘。目标不在链上时返回 false，交给调用方决定怎么导航。
    @discardableResult
    func rewind(to url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard let index = columns.firstIndex(where: { $0.url.standardizedFileURL.path == target.path }) else {
            return false
        }

        removeColumns(from: index + 1)
        activeColumn = index
        if index > 0 {
            suppressExpansion = true
            columns[index - 1].select(url: target)
            suppressExpansion = false
            currentItem = columns[index - 1].selectedItem
        } else {
            // 回退到根列（index == 0）：收掉右侧所有列，取消根列内的子项展开
            currentItem = nil
            columns[0].deselect()
        }
        syncPreview()
        columns[index].scrollToVisible(columns[index].bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLocation()
        onSelectionChange?(Set([currentItem?.url].compactMap { $0 }))
        onActivate?()
        return true
    }

    /// 重新计算顶栏应显示的目录并通知窗格。
    private func updateLocation() {
        let columnURL: URL = columns.indices.contains(activeColumn) ? columns[activeColumn].url : rootURL
        let newURL: URL
        let newItem: FileItem?

        let selected = columns.indices.contains(activeColumn) ? columns[activeColumn].selectedItems : []
        if selected.count > 1 {
            newURL = columnURL
            newItem = nil
        } else if let item = currentItem, item.isNavigable {
            // 选中文件夹：它自己就是当前地址（右侧同时展开它的内容）
            newURL = item.url
            newItem = nil
        } else if let item = currentItem {
            // 选中文件：地址停在它所在的一列，文件名追加为末段
            newURL = columnURL
            newItem = item
        } else {
            newURL = columnURL
            newItem = nil
        }

        guard newURL.standardizedFileURL.path != displayURL.standardizedFileURL.path
                || newItem?.url != displayItem?.url else { return }
        displayURL = newURL
        displayItem = newItem
        onLocationChange?(newURL, newItem)
    }

    private func removeColumns(from index: Int) {
        guard index < columns.count else { return }
        for column in columns[index...] {
            column.removeFromSuperview()
        }
        columns.removeSubrange(index...)
        activeColumn = min(activeColumn, max(0, columns.count - 1))
    }

    private func clearPreview() {
        guard let preview = previewColumn else { return }
        preview.removeFromSuperview()
        previewColumn = nil
    }

    /// 当前选中单项或多项时，在最右侧追加一栏文件预览；为空选或未展开文件夹时移除预览。
    private func syncPreview(items: [FileItem] = [], scrollToVisible: Bool = false) {
        clearPreview()
        if items.count > 1 {
            let preview = FilePreviewColumn()
            preview.configure(with: items)
            previewColumn = preview
            board.addSubview(preview)
        } else if let item = items.first, !item.isNavigable {
            let preview = FilePreviewColumn()
            preview.configure(with: item)
            previewColumn = preview
            board.addSubview(preview)
        }
        layoutColumns()
        if scrollToVisible, previewColumn != nil {
            let maxX = board.frame.width
            let visible = scroll.contentSize.width
            scroll.contentView.scroll(to: NSPoint(x: max(0, maxX - visible), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: - 键盘

    private func handleKey(_ event: NSEvent, columnIndex: Int) -> Bool {
        switch event.keyCode {
        case 124:  // →
            if let item = columns[columnIndex].selectedItem, item.isNavigable,
               columnIndex + 1 < columns.count {
                activeColumn = columnIndex + 1
                columns[columnIndex + 1].focus()
                columns[columnIndex + 1].selectFirstRow()
                return true
            }
            return true
        case 123:  // ←
            if columnIndex > 0 {
                activeColumn = columnIndex - 1
                columns[columnIndex - 1].focus()
                currentItem = columns[columnIndex - 1].selectedItem
                updateLocation()
                return true
            }
            return true
        default:
            return keyHandler?(event) ?? false
        }
    }

    // MARK: - 对外接口（与列表/图标视图保持一致）

    var selectedItems: [FileItem] {
        guard columns.indices.contains(activeColumn) else {
            return [currentItem].compactMap { $0 }
        }
        let items = columns[activeColumn].selectedItems
        return items.isEmpty ? [currentItem].compactMap { $0 } : items
    }

    /// 当前活动列的项目数（状态栏用，避免一直显示根目录的项目数）。
    var activeColumnItemCount: Int {
        columns.indices.contains(activeColumn) ? columns[activeColumn].items.count : 0
    }

    func focus() {
        guard !columns.isEmpty else { return }
        activeColumn = min(activeColumn, columns.count - 1)
        columns[activeColumn].focus()
    }

    func selectAll() {
        guard !columns.isEmpty else { return }
        let index = min(activeColumn, columns.count - 1)
        columns[index].selectAll()
    }

    /// 程序化选中（新建文件夹、重命名之后）。只高亮，不自动展开——
    /// 展开是用户点选文件夹时的行为，否则新建完就会直接钻进去。
    func select(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        suppressExpansion = true
        defer { suppressExpansion = false }
        for index in stride(from: columns.count - 1, through: 0, by: -1) {
            let col = columns[index]
            let matching = col.items.filter { urls.contains($0.url) }
            if !matching.isEmpty {
                removeColumns(from: index + 1)
                activeColumn = index
                col.select(urls: urls)
                currentItem = col.selectedItems.last ?? col.selectedItem
                if col.selectedItems.count > 1 {
                    syncPreview(items: col.selectedItems)
                } else {
                    syncPreview()
                }
                updateLocation()
                onSelectionChange?(urls)
                return
            }
        }
        // 各列都没有：从根目录重新读一遍再试
        rebuild()
        if let first = columns.first {
            first.select(urls: urls)
            currentItem = first.selectedItems.last ?? first.selectedItem
            if first.selectedItems.count > 1 {
                syncPreview(items: first.selectedItems)
            } else {
                syncPreview()
            }
            updateLocation()
            onSelectionChange?(urls)
        }
    }

    func scrollToTop() {
        columns.first?.selectFirstRow()
    }

    /// 点击分栏右侧空白画布或列底部空白：清空选中并收起右侧预览（访达同款）
    func handleBlankAreaClick() {
        if activeColumn >= 0 && activeColumn < columns.count {
            columns[activeColumn].deselectAll()
        }
        currentItem = nil
        clearPreview()
        layoutColumns()
        onSelectionChange?(Set())
        updateLocation()
    }
}

// MARK: - 画布

/// 承载多列的翻转容器（作为横向滚动视图的 documentView）。
private final class ColumnBoard: NSView {
    override var isFlipped: Bool { true }
    weak var owner: ColumnBrowserView?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        owner?.handleBlankAreaClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.handleBlankAreaClick()
        return owner?.menuProvider?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 单列

/// 一列文件列表：自带滚动视图与数据源。
final class BrowserColumn: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let url: URL
    private(set) var items: [FileItem] = []
    var columnWidth: CGFloat = AppSettings.browserColumnWidth

    private let table = KeyTableView()
    private let scroll = ColumnScrollView()

    /// 外层横向滚动视图：列内的横向手势要交给它，否则点到某一列后整排就滚不动了。
    weak var horizontalScrollTarget: NSScrollView? {
        didSet { scroll.horizontalTarget = horizontalScrollTarget }
    }

    var onSelect: ((FileItem?) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onActivate: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onFileRenamed: ((URL, URL) -> Void)?
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)
        table.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        table.menuProvider = { [weak self] event in
            self?.menuProvider?(event == nil ? nil : self?.selectedItem)
        }
        table.onTriggerRename = { [weak self] row in self?.startRename(at: row) }
        table.isPointInName = { [weak self] row, point in
            guard let self, row >= 0, row < self.items.count else { return false }
            if let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnRowCell {
                return cell.isPointInName(point, in: self.table)
            }
            return true
        }
        table.registerForDraggedTypes([.fileURL])
        table.urlsForRows = { [weak self] rows in
            guard let self else { return [] }
            return rows.compactMap { r in
                guard r >= 0, r < self.items.count else { return nil }
                return self.items[r].url
            }
        }

        NotificationCenter.default.addObserver(forName: .zebraStripesDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
            self.table.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let column = table.tableColumns.first {
            column.width = max(40, scroll.contentSize.width)
        }
    }

    func deselectAll() {
        table.deselectAll(nil)
    }

    override func mouseDown(with event: NSEvent) {
        deselectAll()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        deselectAll()
        return menuProvider?(nil)
    }

    // MARK: - 数据

    func reload(showHidden: Bool, sort: SortField, ascending: Bool, restoring keep: URL? = nil) {
        let raw = FileItem.contents(of: url, showHidden: showHidden)
        items = FileOrganizer.sections(items: raw, sort: sort, ascending: ascending, group: .none)
            .flatMap { $0.items }
        table.reloadData()
        if let keep, let index = items.firstIndex(where: { $0.url == keep }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    var selectedItem: FileItem? {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    var selectedItems: [FileItem] {
        let rows = table.selectedRowIndexes
        return rows.compactMap { index in
            guard index >= 0, index < items.count else { return nil }
            return items[index]
        }
    }

    /// 批量选中指定 URLs
    func select(urls: Set<URL>) {
        let indices = items.enumerated().compactMap { index, item in
            urls.contains(item.url) ? index : nil
        }
        if !indices.isEmpty {
            let set = IndexSet(indices)
            table.selectRowIndexes(set, byExtendingSelection: false)
            if let first = indices.first {
                table.scrollRowToVisible(first)
            }
        } else {
            table.deselectAll(nil)
        }
    }

    /// 找到指定 URL 对应的条目（供程序化定位使用）。
    func item(withURL url: URL) -> FileItem? {
        let target = url.standardizedFileURL.path
        return items.first { $0.url.standardizedFileURL.path == target }
    }

    func focus() { window?.makeFirstResponder(table) }

    func selectFirstRow() {
        guard !items.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    /// 选中指定 URL，成功返回 true。
    @discardableResult
    func select(url: URL) -> Bool {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return false }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        return true
    }

    func selectAll() { table.selectAll(nil) }

    func deselect() {
        table.deselectAll(nil)
    }

    var hasSingleSelection: Bool {
        table.selectedRow >= 0 && table.selectedRowIndexes.count == 1
    }

    // MARK: - 就地重命名（访达同款）

    func startRenameSelected() {
        let row = table.selectedRow
        guard row >= 0, table.selectedRowIndexes.count == 1 else { return }
        startRename(at: row)
    }

    func startRename(at row: Int) {
        guard row >= 0, row < items.count else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnRowCell else { return }
        cell.startInlineEditing()
    }

    func performRename(item: FileItem, newName: String) {
        FileOperations.performRename(item: item, newName: newName, window: window) { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
    }

    @objc private func handleDoubleClick() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onOpen?(items[row])
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 26 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ColumnTableRowView")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? ColumnTableRowView)
            ?? ColumnTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ColumnRowCell)
            ?? ColumnRowCell(identifier: identifier)
        cell.configure(with: items[row])
        cell.onCommitRename = { [weak self] newName in
            guard let self, row < self.items.count else { return }
            self.performRename(item: self.items[row], newName: newName)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        onActivate?()
        onSelect?(selectedItem)
    }

    // MARK: - 拖拽数据源与接收

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return [] }
        let destURL: URL
        if row >= 0, row < items.count, items[row].isDirectory {
            destURL = items[row].url
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            destURL = url
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return FileOperations.shouldCopy(for: info, destination: destURL) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return false }
        let destURL: URL
        if row >= 0, row < items.count, items[row].isDirectory {
            destURL = items[row].url
        } else {
            destURL = url
        }
        let isCopy = FileOperations.shouldCopy(for: info, destination: destURL)
        onDropFiles?(urls, destURL, isCopy)
        return true
    }
}

// MARK: - 访达风格圆角行视图

/// 分栏列表行视图：仿访达四边圆角高亮。
/// - 左右内缩 (5pt)，避免紧贴分栏边界
/// - 单项选中：四角全圆角 (radius 5.5)
/// - 连续多选：首行顶角圆角、末行底角圆角、中间行无缝平滑拼接
class ColumnTableRowView: NSTableRowView {

    override func drawBackground(in dirtyRect: NSRect) {
        let baseColor = NSColor.controlBackgroundColor
        guard AppSettings.showZebraStripes else {
            baseColor.setFill()
            bounds.fill()
            return
        }

        var candidateView: NSView? = superview
        var table: NSTableView?
        while let v = candidateView {
            if let t = v as? NSTableView {
                table = t
                break
            }
            candidateView = v.superview
        }
        guard let table else {
            baseColor.setFill()
            bounds.fill()
            return
        }

        let row = table.row(for: self)
        guard row >= 0 else {
            baseColor.setFill()
            bounds.fill()
            return
        }

        let stripeColor = NSColor.alternatingContentBackgroundColors.count > 1
            ? NSColor.alternatingContentBackgroundColors[1]
            : (baseColor.blended(withFraction: 0.04, of: .labelColor) ?? baseColor)
        let color = (row % 2 == 1) ? stripeColor : baseColor
        color.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        let horizontalInset: CGFloat = 5.0
        let cornerRadius: CGFloat = 5.5

        guard let table = superview as? NSTableView else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: horizontalInset, dy: 0),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
            color.setFill()
            path.fill()
            return
        }

        let row = table.row(for: self)
        guard row >= 0 else { return }

        let prevSelected = row > 0 && table.isRowSelected(row - 1)
        let nextSelected = row < table.numberOfRows - 1 && table.isRowSelected(row + 1)

        let topY: CGFloat = prevSelected ? -0.5 : 0
        let bottomY: CGFloat = nextSelected ? bounds.height + 0.5 : bounds.height

        // 关键：在 fullWidth 样式或不同滚动容器下，table.bounds.width 往往会比可视区宽 12pt（导致右侧圆角被 Clip 裁切成直角）
        // 故必须取可视宽度与 bounds.width 的较小值，确保右侧同样留出 5pt 内边距并完整画出所有圆角！
        let visibleWidth: CGFloat
        if let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 {
            visibleWidth = clip.bounds.width
        } else if table.visibleRect.width > 0 {
            visibleWidth = table.visibleRect.width
        } else {
            visibleWidth = bounds.width
        }
        let effectiveWidth = min(bounds.width, visibleWidth)

        let rect = NSRect(x: horizontalInset,
                          y: topY,
                          width: max(0, effectiveWidth - horizontalInset * 2),
                          height: max(0, bottomY - topY))

        let path = ColumnTableRowView.selectionPath(rect: rect,
                                                    roundTop: !prevSelected,
                                                    roundBottom: !nextSelected,
                                                    radius: cornerRadius)

        let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        path.fill()
    }

    static func selectionPath(rect: NSRect, roundTop: Bool, roundBottom: Bool, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let r = min(radius, rect.width / 2, rect.height / 2)

        path.move(to: NSPoint(x: minX + (roundTop ? r : 0), y: minY))

        if roundTop {
            path.line(to: NSPoint(x: maxX - r, y: minY))
            path.appendArc(from: NSPoint(x: maxX, y: minY), to: NSPoint(x: maxX, y: minY + r), radius: r)
        } else {
            path.line(to: NSPoint(x: maxX, y: minY))
        }

        if roundBottom {
            path.line(to: NSPoint(x: maxX, y: maxY - r))
            path.appendArc(from: NSPoint(x: maxX, y: maxY), to: NSPoint(x: maxX - r, y: maxY), radius: r)
        } else {
            path.line(to: NSPoint(x: maxX, y: maxY))
        }

        if roundBottom {
            path.line(to: NSPoint(x: minX + r, y: maxY))
            path.appendArc(from: NSPoint(x: minX, y: maxY), to: NSPoint(x: minX, y: maxY - r), radius: r)
        } else {
            path.line(to: NSPoint(x: minX, y: maxY))
        }

        if roundTop {
            path.line(to: NSPoint(x: minX, y: minY + r))
            path.appendArc(from: NSPoint(x: minX, y: minY), to: NSPoint(x: minX + r, y: minY), radius: r)
        } else {
            path.line(to: NSPoint(x: minX, y: minY))
        }

        path.close()
        return path
    }
}

// MARK: - 单元格

private final class ColumnRowCell: NSTableCellView, NSTextFieldDelegate {

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHiddenItem: Bool = false
    private var currentItem: FileItem?

    private(set) var isInlineEditing: Bool = false
    private var isStartingEditing = false
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        for field in [icon, title, chevron] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = true
            field.autoresizingMask = []
        }
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingMiddle
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = .tertiaryLabelColor

        for field in [icon, title, chevron] as [NSView] { addSubview(field) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isInlineEditing {
            isInlineEditing = false
            isStartingEditing = false
            title.isEditable = false
            title.isSelectable = false
            title.drawsBackground = false
            title.isBordered = false
            title.layer?.borderWidth = 0
            title.delegate = nil
        }
    }

    // MARK: - 就地重命名

    func isPointInName(_ pointInTable: NSPoint, in table: NSTableView) -> Bool {
        let local = convert(pointInTable, from: table)
        guard local.y >= 0 && local.y <= bounds.height else { return false }
        if local.x < 25 { return false }
        if !chevron.isHidden && local.x > chevron.frame.minX - 4 { return false }
        return true
    }

    func startInlineEditing() {
        guard !isInlineEditing else { return }
        isInlineEditing = true
        isStartingEditing = true

        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.textColor = .labelColor
        title.isBordered = true
        title.lineBreakMode = .byClipping
        title.cell?.isScrollable = true

        title.wantsLayer = true
        title.layer?.cornerRadius = 3
        title.layer?.masksToBounds = true
        title.layer?.borderWidth = 1
        title.layer?.borderColor = NSColor.separatorColor.cgColor

        needsLayout = true
        window?.makeFirstResponder(title)
        title.delegate = self

        if let editor = title.currentEditor() as? NSTextView {
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.drawsBackground = false
            var attrs = editor.typingAttributes
            attrs[.foregroundColor] = NSColor.labelColor
            editor.typingAttributes = attrs
            let fullText = title.stringValue
            let isDir = currentItem?.isNavigable ?? false
            let ext = (fullText as NSString).pathExtension
            let length: Int
            if isDir || ext.isEmpty || fullText.hasPrefix(".") {
                length = fullText.count
            } else {
                length = (fullText as NSString).deletingPathExtension.count
            }
            editor.selectedRange = NSRange(location: 0, length: length)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStartingEditing = false
            self.title.textColor = .labelColor
            if let editor = self.title.currentEditor() as? NSTextView {
                editor.textColor = .labelColor
                editor.insertionPointColor = .labelColor
                var attrs = editor.typingAttributes
                attrs[.foregroundColor] = NSColor.labelColor
                editor.typingAttributes = attrs
            }
        }
    }

    func endInlineEditing(commit: Bool) {
        guard isInlineEditing else { return }
        isInlineEditing = false
        isStartingEditing = false
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        title.isBordered = false
        title.layer?.borderWidth = 0
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.isScrollable = false
        title.delegate = nil
        updateColors()
        needsLayout = true

        let original = currentItem?.name ?? ""
        if commit {
            let newName = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName.isEmpty || newName == original {
                title.stringValue = original
            } else {
                onCommitRename?(newName)
            }
        } else {
            title.stringValue = original
            onCancelRename?()
        }
        if let table = superview as? NSTableView ?? (superview?.superview as? NSTableView) {
            window?.makeFirstResponder(table)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endInlineEditing(commit: true)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endInlineEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if isInlineEditing {
            needsLayout = true
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isStartingEditing, isInlineEditing else { return }
        endInlineEditing(commit: true)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        if isInlineEditing {
            title.textColor = .labelColor
            if let editor = title.currentEditor() as? NSTextView {
                editor.textColor = .labelColor
                editor.insertionPointColor = .labelColor
                var attrs = editor.typingAttributes
                attrs[.foregroundColor] = NSColor.labelColor
                editor.typingAttributes = attrs
            }
            return
        }
        if backgroundStyle == .emphasized {
            title.textColor = .white
            chevron.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        } else {
            title.textColor = isHiddenItem ? .secondaryLabelColor : .labelColor
            chevron.contentTintColor = .tertiaryLabelColor
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSize = Theme.listIconSize
        icon.frame = NSRect(x: 9, y: (height - iconSize) / 2, width: iconSize, height: iconSize)

        let visibleW: CGFloat
        if let clip = (superview as? NSTableRowView)?.superview?.enclosingScrollView?.contentView, clip.bounds.width > 0 {
            visibleW = clip.bounds.width
        } else {
            visibleW = bounds.width
        }
        let cellW = min(bounds.width, visibleW)

        let chevronWidth: CGFloat = chevron.isHidden ? 0 : 13
        chevron.frame = NSRect(x: cellW - 14 - chevronWidth, y: (height - 12) / 2,
                               width: chevronWidth, height: 12)

        let textHeight: CGFloat = isInlineEditing ? 21 : 17
        let nameX = icon.frame.maxX + 7 - (isInlineEditing ? 3 : 0)
        let nameRight = chevron.isHidden ? cellW - 12 : chevron.frame.minX - 4
        let maxAvailableW = max(50, nameRight - nameX)

        let titleWidth: CGFloat
        if isInlineEditing {
            let font = title.font ?? .systemFont(ofSize: 12.5)
            let textW = (title.stringValue as NSString).size(withAttributes: [.font: font]).width
            titleWidth = min(maxAvailableW, max(50, ceil(textW) + 18))
        } else {
            titleWidth = max(0, nameRight - nameX)
        }

        title.frame = NSRect(x: nameX, y: (height - textHeight) / 2, width: titleWidth, height: textHeight)
    }

    func configure(with item: FileItem) {
        self.currentItem = item
        self.isHiddenItem = item.isHidden
        icon.image = IconCache.shared.icon(for: item)
        title.stringValue = item.name
        chevron.isHidden = !item.isNavigable
        chevron.image = Theme.symbol("chevron.right", size: 9, weight: .semibold)
        updateColors()
        needsLayout = true
    }
}

// MARK: - 单列滚动视图

/// 分栏里每一列表格自己的滚动视图。
/// 竖向滚动留给自己，横向手势交给外层「整排」滚动视图，
/// 否则点开某一列后，横向滚动会被这一列吃掉，整排就滚不动了。
private final class ColumnScrollView: NSScrollView {

    weak var horizontalTarget: NSScrollView?

    override func mouseDown(with event: NSEvent) {
        if let browserColumn = superview as? BrowserColumn {
            browserColumn.deselectAll()
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let browserColumn = superview as? BrowserColumn {
            browserColumn.deselectAll()
            return browserColumn.menuProvider?(nil)
        }
        return super.menu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let horizontalTarget else {
            super.scrollWheel(with: event)
            return
        }
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        if dx > dy, dx > 0.01 {
            horizontalTarget.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - 文件预览列

/// 选中文件时追加在列链最右侧的一栏：大图标 / 缩略图 + 文件元信息
/// （种类、大小、创建与修改时间、上次打开时间、版本、尺寸、位置等），1:1 还原访达分栏预览列。
final class FilePreviewColumn: NSView {

    var columnWidth: CGFloat = AppSettings.browserColumnWidth

    static let bundleSizeCache = NSCache<NSURL, NSNumber>()
    private var currentURL: URL?
    private weak var sizeValueField: NSTextField?

    static func calculateDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true {
                if let s = vals?.totalFileAllocatedSize ?? vals?.fileSize {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private let scroll = NSScrollView()
    private let documentView = FlippedDocumentView()
    private let iconView = NSImageView()
    private let textContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let infoHeaderLabel = NSTextField(labelWithString: "信息")
    private let infoStack = NSStackView()

    private var iconLeadingConstraint: NSLayoutConstraint!
    private var iconTrailingConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.paneBackground
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        // documentView 与 clipView 等宽且原点为 (0,0)，防止 NSClipView 重置坐标导致内部文字贴边
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(iconView)

        // 下方文字区统一留出充足的左右内边距（18pt），彻底告别贴边拥挤感
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(textContainer)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 3
        nameLabel.alignment = .left
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.alignment = .left
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        infoHeaderLabel.font = .systemFont(ofSize: 11.5, weight: .bold)
        infoHeaderLabel.textColor = .labelColor
        infoHeaderLabel.alignment = .left
        infoHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        infoStack.orientation = .vertical
        infoStack.alignment = .width
        infoStack.spacing = 0
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        textContainer.addSubview(nameLabel)
        textContainer.addSubview(subtitleLabel)
        textContainer.addSubview(infoHeaderLabel)
        textContainer.addSubview(infoStack)

        iconLeadingConstraint = iconView.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 18)
        iconTrailingConstraint = iconView.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -18)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 128)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),

            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            iconView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            iconLeadingConstraint,
            iconTrailingConstraint,
            iconHeightConstraint,

            // 文字容器：左右各留 18pt 安全边距（仿访达原生预览栏排版）
            textContainer.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 18),
            textContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            textContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
            textContainer.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),

            nameLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoHeaderLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            infoHeaderLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoHeaderLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoStack.topAnchor.constraint(equalTo: infoHeaderLabel.bottomAnchor, constant: 4),
            infoStack.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])
    }

    func configure(with item: FileItem) {
        currentURL = item.url
        sizeValueField = nil

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
            .localizedTypeDescriptionKey, .isSymbolicLinkKey
        ]
        let values = try? item.url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false

        // 1. 顶部图片/图标：图片文件可铺满左右边距展示大图，文件夹/包/普通文件展示 128pt 高清大图标
        var imageDimensions: (Int, Int)?
        if !isDirectory && !isPackage, let image = NSImage(contentsOfFile: item.url.path), image.size.width > 1 {
            iconView.image = image
            iconLeadingConstraint.constant = 0
            iconTrailingConstraint.constant = 0
            iconHeightConstraint.constant = 176
            let px = Int(image.size.width), py = Int(image.size.height)
            if px > 0, py > 0 { imageDimensions = (px, py) }
        } else {
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 128, height: 128)
            iconView.image = icon
            iconLeadingConstraint.constant = 18
            iconTrailingConstraint.constant = -18
            iconHeightConstraint.constant = 128
        }

        // 2. 标题与副标题（种类 - 大小，与访达一致）
        nameLabel.alignment = .left
        subtitleLabel.alignment = .left
        infoHeaderLabel.isHidden = false
        nameLabel.stringValue = item.name

        var initialSize: Int64?
        if !isDirectory {
            if let size = values?.fileSize ?? values?.totalFileAllocatedSize {
                initialSize = Int64(size)
            }
        } else if let cached = FilePreviewColumn.bundleSizeCache.object(forKey: item.url as NSURL) {
            initialSize = cached.int64Value
        }

        let kindText = values?.localizedTypeDescription ?? (isDirectory ? (isPackage ? "应用程序" : "文件夹") : "文件")
        if let initialSize {
            subtitleLabel.stringValue = "\(kindText) - \(Format.bytes(initialSize))"
        } else {
            subtitleLabel.stringValue = kindText
        }

        // 3. 「信息」键值表（左侧项目名浅灰、右侧数值右对齐 + 行间细分割线，复刻访达标准预览）
        var rows: [(String, String)] = []
        if let initialSize {
            rows.append(("大小", Format.bytes(initialSize)))
        } else if isPackage || isDirectory {
            rows.append(("大小", "正在计算…"))
        }
        if let created = values?.creationDate {
            rows.append(("创建时间", Format.date(created)))
        }
        if let modified = values?.contentModificationDate {
            rows.append(("修改时间", Format.date(modified)))
        }
        if let accessed = values?.contentAccessDate {
            rows.append(("上次打开时间", Format.date(accessed)))
        } else {
            rows.append(("上次打开时间", "--"))
        }
        if let (px, py) = imageDimensions {
            rows.append(("尺寸", "\(px) × \(py)"))
        }
        if isPackage,
           let bundle = Bundle(url: item.url),
           let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
                      ?? (bundle.infoDictionary?["CFBundleVersion"] as? String),
           !version.isEmpty {
            rows.append(("版本", version))
        }
        if values?.isSymbolicLink == true {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)) ?? "?"
            rows.append(("链接目标", target))
        }

        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, pair) in rows.enumerated() {
            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false

            let k = NSTextField(labelWithString: pair.0)
            k.font = .systemFont(ofSize: 11.5)
            k.textColor = .secondaryLabelColor
            k.alignment = .left
            k.setContentHuggingPriority(.required, for: .horizontal)
            k.setContentCompressionResistancePriority(.required, for: .horizontal)
            k.translatesAutoresizingMaskIntoConstraints = false

            let v = NSTextField(labelWithString: pair.1)
            v.font = .systemFont(ofSize: 11.5, weight: .medium)
            v.textColor = .labelColor
            v.alignment = .right
            v.lineBreakMode = .byTruncatingMiddle
            v.maximumNumberOfLines = 1
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.translatesAutoresizingMaskIntoConstraints = false

            if pair.0 == "大小" {
                self.sizeValueField = v
            }

            rowContainer.addSubview(k)
            rowContainer.addSubview(v)

            NSLayoutConstraint.activate([
                rowContainer.heightAnchor.constraint(equalToConstant: 26),
                k.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                k.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                v.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                v.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                v.leadingAnchor.constraint(greaterThanOrEqualTo: k.trailingAnchor, constant: 10)
            ])

            if index < rows.count - 1 {
                let divider = Theme.hairlineView()
                rowContainer.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                    divider.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
                    divider.heightAnchor.constraint(equalToConstant: 1)
                ])
            }

            infoStack.addArrangedSubview(rowContainer)
        }

        // 异步计算包（.app）或文件夹真实大小，计算完毕后自动更新界面并写入缓存
        if (isPackage || isDirectory) && initialSize == nil {
            let targetURL = item.url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let total = FilePreviewColumn.calculateDirectorySize(at: targetURL)
                FilePreviewColumn.bundleSizeCache.setObject(NSNumber(value: total), forKey: targetURL as NSURL)
                DispatchQueue.main.async {
                    guard let self, self.currentURL == targetURL else { return }
                    let formatted = Format.bytes(total)
                    self.sizeValueField?.stringValue = formatted
                    self.subtitleLabel.stringValue = "\(kindText) - \(formatted)"
                }
            }
        }
    }

    /// 多选状态下的概览预览（1:1 还原访达分栏多选预览效果）
    func configure(with items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            configure(with: items[0])
            return
        }

        // 1. 顶部叠放复合预览图（双层文档/文件夹层叠外观）
        let stackWidth: CGFloat = 128
        let stackHeight: CGFloat = 128
        let stackedImage = NSImage(size: NSSize(width: stackWidth, height: stackHeight), flipped: false) { rect in
            let icon1 = NSWorkspace.shared.icon(forFile: items[0].url.path)
            let icon2 = NSWorkspace.shared.icon(forFile: items[min(1, items.count - 1)].url.path)

            let backRect = NSRect(x: 18, y: 16, width: 92, height: 92)
            icon2.draw(in: backRect, from: .zero, operation: .sourceOver, fraction: 0.85)

            let frontRect = NSRect(x: 6, y: 4, width: 98, height: 98)
            icon1.draw(in: frontRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        iconView.image = stackedImage
        iconLeadingConstraint.constant = 18
        iconTrailingConstraint.constant = -18
        iconHeightConstraint.constant = 128

        // 2. 标题（如 "2份文稿"、"3个文件夹"、"4个项目"）与副标题（"2 项 - 6 KB"）
        let allNavigable = items.allSatisfy { $0.isNavigable }
        let allFiles = items.allSatisfy { !$0.isNavigable }
        let title: String
        if allNavigable {
            title = "\(items.count)个文件夹"
        } else if allFiles {
            title = "\(items.count)份文稿"
        } else {
            title = "\(items.count)个项目"
        }

        nameLabel.alignment = .center
        nameLabel.stringValue = title

        var totalBytes: Int64 = 0
        var hasValidSize = false
        for it in items {
            if let vals = try? it.url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]),
               let s = vals.fileSize ?? vals.totalFileAllocatedSize {
                totalBytes += Int64(s)
                hasValidSize = true
            }
        }
        if hasValidSize {
            subtitleLabel.stringValue = "\(items.count) 项 - \(Format.bytes(totalBytes))"
        } else {
            subtitleLabel.stringValue = "\(items.count) 项"
        }
        subtitleLabel.alignment = .center

        // 3. 元数据：创建时间区间与修改时间区间
        var creationDates: [Date] = []
        var modificationDates: [Date] = []
        for it in items {
            if let vals = try? it.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                if let c = vals.creationDate { creationDates.append(c) }
                if let m = vals.contentModificationDate { modificationDates.append(m) }
            }
        }

        func dateRangeString(_ dates: [Date]) -> String? {
            guard !dates.isEmpty else { return nil }
            let sorted = dates.sorted()
            guard let first = sorted.first, let last = sorted.last else { return nil }
            let fYear = Calendar.current.component(.year, from: first)
            let lYear = Calendar.current.component(.year, from: last)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy年M月d日"
            if Calendar.current.isDate(first, inSameDayAs: last) {
                return fmt.string(from: first)
            } else if fYear == lYear {
                let endFmt = DateFormatter()
                endFmt.dateFormat = "M月d日"
                return "\(fmt.string(from: first))～\(endFmt.string(from: last))"
            } else {
                return "\(fmt.string(from: first))～\(fmt.string(from: last))"
            }
        }

        var rows: [(String, String)] = []
        if let cr = dateRangeString(creationDates) {
            rows.append(("创建时间", cr))
        }
        if let md = dateRangeString(modificationDates) {
            rows.append(("修改时间", md))
        }

        infoHeaderLabel.isHidden = true
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, pair) in rows.enumerated() {
            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false

            let k = NSTextField(labelWithString: pair.0)
            k.font = .systemFont(ofSize: 11.5)
            k.textColor = .secondaryLabelColor
            k.alignment = .left
            k.setContentHuggingPriority(.required, for: .horizontal)
            k.setContentCompressionResistancePriority(.required, for: .horizontal)
            k.translatesAutoresizingMaskIntoConstraints = false

            let v = NSTextField(labelWithString: pair.1)
            v.font = .systemFont(ofSize: 11.5)
            v.textColor = .labelColor
            v.alignment = .right
            v.lineBreakMode = .byTruncatingMiddle
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.translatesAutoresizingMaskIntoConstraints = false

            rowContainer.addSubview(k)
            rowContainer.addSubview(v)

            NSLayoutConstraint.activate([
                rowContainer.heightAnchor.constraint(equalToConstant: 26),
                k.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                k.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                v.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                v.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                v.leadingAnchor.constraint(greaterThanOrEqualTo: k.trailingAnchor, constant: 10)
            ])

            if index < rows.count - 1 {
                let divider = Theme.hairlineView()
                rowContainer.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                    divider.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
                    divider.heightAnchor.constraint(equalToConstant: 1)
                ])
            }

            infoStack.addArrangedSubview(rowContainer)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 可拖拽列分隔线

/// 分栏之间的竖向分割线：支持鼠标悬浮左右光标、拖拽改变列宽（按住 ⌥ 键等比例改变所有列宽）、
/// 双击自动根据最长文件名智能适应宽度（同 macOS 访达原生行为）。
final class ColumnDividerView: NSView {
    var columnIndex: Int = 0
    var isPreview: Bool = false

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var dragStartOrigin: NSPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStartOrigin = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        let dx = event.locationInWindow.x - dragStartOrigin.x
        let isOption = event.modifierFlags.contains(.option)
        onDrag?(dx, isOption)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

