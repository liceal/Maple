import AppKit

/// 侧栏数据节点：分组标题（.group）、文件夹（.folder）、远程服务器（.server）、连接服务器入口（.connectServer）或标签（.tag）。
final class SidebarNode: NSObject {

    enum Kind { case group, folder, server, connectServer, tag }

    let kind: Kind
    let title: String
    let url: URL?
    let tag: String?
    let symbol: String
    /// true 时用磁盘上的真实图标（文件夹、磁盘、应用程序、废纸篓更有辨识度）
    let usesSystemIcon: Bool
    let dotColor: NSColor?
    /// true 表示这是用户自己加入「个人收藏」的条目（可以移除）
    let isUserFavorite: Bool
    /// 关联的已保存服务器配置
    let serverEntry: ServerEntry?
    /// 是否是当前已挂载的网络卷（支持卸载/断开）
    let isMountedNetworkVolume: Bool
    /// 是否是可推出的本地磁盘/外置卷/DMG镜像
    let isEjectableVolume: Bool
    /// 是否是废纸篓
    let isTrash: Bool
    var children: [SidebarNode] = []

    init(kind: Kind,
         title: String,
         url: URL? = nil,
         tag: String? = nil,
         symbol: String = "",
         usesSystemIcon: Bool = false,
         dotColor: NSColor? = nil,
         isUserFavorite: Bool = false,
         serverEntry: ServerEntry? = nil,
         isMountedNetworkVolume: Bool = false,
         isEjectableVolume: Bool = false,
         isTrash: Bool = false) {
        self.kind = kind
        self.title = title
        self.url = url
        self.tag = tag
        self.symbol = symbol
        self.usesSystemIcon = usesSystemIcon
        self.dotColor = dotColor
        self.isUserFavorite = isUserFavorite
        self.serverEntry = serverEntry
        self.isMountedNetworkVolume = isMountedNetworkVolume
        self.isEjectableVolume = isEjectableVolume
        self.isTrash = isTrash
    }

    var isGroup: Bool { kind == .group }
    var isTag: Bool { kind == .tag }
}

/// 仿访达与 QSpace 的 source list 侧栏：个人收藏 / iCloud / 位置 / 服务器 / 标签 + 底部「⋯」操作栏。
final class SidebarView: NSView {

    var onSelect: ((URL) -> Void)?
    /// 在另一个窗格打开
    var onOpenInOtherPane: ((URL) -> Void)?
    /// 点击某个标签。
    var onSelectTag: ((String) -> Void)?
    /// 点击「连接服务器…」或未挂载的已保存服务器条目。
    var onRequestConnectServer: ((ServerEntry?) -> Void)?
    /// 点击底栏设置齿轮按钮。
    var onOpenSettings: (() -> Void)?

    /// 获取当前焦点窗格正在浏览的 URL，供刷新时安全恢复选中项，避免外置卷挂载时误选新卷
    var currentURLProvider: (() -> URL?)?

    /// 列表顶部让出的高度（隐藏标题栏后，交通灯与工具条浮在侧栏上方，
    /// 列表内容要整体下移，避免第一组标题被挡住）。
    var topInset: CGFloat = 38 {
        didSet {
            guard abs(scrollTop.constant - (topInset + 6)) > 0.5 else { return }
            scrollTop.constant = topInset + 6
        }
    }

    private let effect = NSVisualEffectView()
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private let footerBar = NSView()
    private let moreButton = SquareToolbarButton(size: 24)
    private let settingsButton = SquareToolbarButton(size: 24)
    private var scrollTop: NSLayoutConstraint!
    private var nodes: [SidebarNode] = []
    private var isRestoringSelection = false
    /// 最近一次右键命中的节点（菜单动作针对它，而不是选中行）。
    private var contextNode: SidebarNode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        reload()
        observeVolumes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - 构建

    private func setup() {
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        addSubview(effect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.registerForDraggedTypes([.fileURL])
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleClick)
        outline.menuProvider = { [weak self] node in self?.makeContextMenu(for: node) }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        // 底部操作栏（带「⋯」按钮）
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footerBar.clipsToBounds = true
        let footerLine = Theme.hairlineView()
        footerBar.addSubview(footerLine)

        moreButton.image = Theme.symbol("ellipsis.circle", size: 14.5, weight: .medium)
        moreButton.toolTip = "侧栏选项与操作"
        moreButton.target = self
        moreButton.action = #selector(moreButtonClicked(_:))
        footerBar.addSubview(moreButton)

        settingsButton.image = Theme.symbol("gearshape", size: 13.5, weight: .regular)
        settingsButton.toolTip = "偏好设置与权限管理 (⌘,)"
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        footerBar.addSubview(settingsButton)

        effect.addSubview(scroll)
        effect.addSubview(footerBar)

        let top = scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: topInset + 6)
        scrollTop = top
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            top,
            scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            footerBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 32),

            footerLine.topAnchor.constraint(equalTo: footerBar.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),

            moreButton.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 8),
            moreButton.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor, constant: 1),

            settingsButton.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor, constant: 1)
        ])
    }

    // MARK: - 菜单（底部「⋯」按钮 & 右键空白处 / 条目）

    override func menu(for event: NSEvent) -> NSMenu? {
        return makeSidebarAreaMenu()
    }

    @objc private func moreButtonClicked(_ sender: NSButton) {
        let menu = makeSidebarAreaMenu()
        let point = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    /// 构造「展示分类」子菜单。
    private func makeCategorySubmenu() -> NSMenu {
        let sub = NSMenu(title: "展示分类")
        sub.autoenablesItems = false
        for category in SidebarCategory.allCases {
            let item = NSMenuItem(title: category.title,
                                  action: #selector(toggleCategoryClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = category.rawValue
            item.state = AppSettings.isSidebarCategoryVisible(category) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let showAll = NSMenuItem(title: "显示全部分类",
                                 action: #selector(showAllCategoriesClicked),
                                 keyEquivalent: "")
        showAll.target = self
        let allVisible = SidebarCategory.allCases.allSatisfy { AppSettings.isSidebarCategoryVisible($0) }
        showAll.isEnabled = !allVisible
        sub.addItem(showAll)
        return sub
    }

    /// 侧栏空白处右键或点击底部「⋯」按钮弹出的菜单。
    private func makeSidebarAreaMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
        categoryItem.submenu = makeCategorySubmenu()
        menu.addItem(categoryItem)

        menu.addItem(.separator())

        let connectItem = NSMenuItem(title: "连接服务器…", action: #selector(connectServerMenuClicked), keyEquivalent: "k")
        connectItem.keyEquivalentModifierMask = [.command]
        connectItem.target = self
        menu.addItem(connectItem)

        let browseNet = NSMenuItem(title: "浏览网络邻居 (/Network)", action: #selector(browseNetworkMenuClicked), keyEquivalent: "")
        browseNet.target = self
        menu.addItem(browseNet)

        menu.addItem(.separator())

        let expandAll = NSMenuItem(title: "展开全部分组", action: #selector(expandAllGroupsClicked), keyEquivalent: "")
        expandAll.target = self
        menu.addItem(expandAll)

        let collapseAll = NSMenuItem(title: "收起全部分组", action: #selector(collapseAllGroupsClicked), keyEquivalent: "")
        collapseAll.target = self
        menu.addItem(collapseAll)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新侧栏", action: #selector(refreshClicked), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        return menu
    }

    /// 右键菜单：空白处或分组标题唤起侧栏通用操作菜单；具体节点提供针对性操作 + 展示分类选项。
    private func makeContextMenu(for node: SidebarNode?) -> NSMenu? {
        guard let node, !node.isGroup else {
            return makeSidebarAreaMenu()
        }
        contextNode = node
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. 连接服务器入口
        if node.kind == .connectServer {
            let connect = NSMenuItem(title: "连接服务器…", action: #selector(connectServerMenuClicked), keyEquivalent: "k")
            connect.keyEquivalentModifierMask = [.command]
            connect.target = self
            menu.addItem(connect)
            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 2. 标签
        if node.kind == .tag {
            let tagName = node.tag ?? node.title
            let openItem = NSMenuItem(title: "在新窗格中打开", action: #selector(openTagInOtherPaneClicked), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = tagName
            menu.addItem(openItem)

            let renameItem = NSMenuItem(title: "重命名“\(tagName)”…", action: #selector(renameTagClicked), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = tagName
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(title: "从列表中移除“\(tagName)”", action: #selector(deleteTagClicked), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = tagName
            menu.addItem(deleteItem)

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新", action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 3. 服务器
        if node.kind == .server {
            let openOrConnect = NSMenuItem(
                title: node.url != nil ? "在新窗格中打开" : "连接服务器…",
                action: #selector(openOrConnectContextServerClicked),
                keyEquivalent: ""
            )
            openOrConnect.target = self
            menu.addItem(openOrConnect)

            // 如果是已挂载的网络卷：显示「推出」
            if node.isMountedNetworkVolume, let url = node.url {
                let unmount = NSMenuItem(title: "推出“\(node.title)”", action: #selector(ejectVolumeClicked(_:)), keyEquivalent: "E")
                unmount.keyEquivalentModifierMask = [.command]
                unmount.target = self
                unmount.representedObject = url
                menu.addItem(unmount)
            }

            menu.addItem(.separator())

            if let url = node.url {
                let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealClicked), keyEquivalent: "")
                reveal.target = self
                menu.addItem(reveal)

                let terminal = NSMenuItem(title: "在“终端”中打开", action: #selector(openInTerminalClicked), keyEquivalent: "")
                terminal.target = self
                terminal.representedObject = url
                menu.addItem(terminal)

                let copyPath = NSMenuItem(title: "拷贝路径", action: #selector(copyPathClicked), keyEquivalent: "C")
                copyPath.keyEquivalentModifierMask = [.command, .option]
                copyPath.target = self
                copyPath.representedObject = url
                menu.addItem(copyPath)
            }

            if let entry = node.serverEntry {
                if let serverURL = entry.url {
                    let copyServerURL = NSMenuItem(title: "拷贝服务器地址", action: #selector(copyServerURLClicked), keyEquivalent: "")
                    copyServerURL.target = self
                    copyServerURL.representedObject = serverURL
                    menu.addItem(copyServerURL)
                }

                menu.addItem(.separator())

                let editItem = NSMenuItem(title: "编辑服务器连接…", action: #selector(editContextServerClicked), keyEquivalent: "")
                editItem.target = self
                editItem.representedObject = entry
                menu.addItem(editItem)

                let remove = NSMenuItem(title: "从列表中移除", action: #selector(removeSavedServerClicked(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = entry.id
                menu.addItem(remove)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新", action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 4. 废纸篓
        if node.isTrash {
            if let url = node.url {
                let openInOther = NSMenuItem(title: "在新窗格中打开", action: #selector(openInOtherPaneClicked), keyEquivalent: "")
                openInOther.target = self
                openInOther.representedObject = url
                menu.addItem(openInOther)
            }

            let emptyTrash = NSMenuItem(title: "清倒废纸篓…", action: #selector(emptyTrashClicked), keyEquivalent: "")
            emptyTrash.target = self
            menu.addItem(emptyTrash)

            menu.addItem(.separator())

            if let url = node.url {
                let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealClicked), keyEquivalent: "")
                reveal.target = self
                menu.addItem(reveal)

                let copyPath = NSMenuItem(title: "拷贝路径", action: #selector(copyPathClicked), keyEquivalent: "")
                copyPath.target = self
                copyPath.representedObject = url
                menu.addItem(copyPath)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新", action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 5. 挂载的本地磁盘、DMG 镜像、外置磁盘或文件夹条目
        if let url = node.url {
            let openInOther = NSMenuItem(title: "在新窗格中打开", action: #selector(openInOtherPaneClicked), keyEquivalent: "")
            openInOther.target = self
            openInOther.representedObject = url
            menu.addItem(openInOther)

            // 【核心推出功能】：若是可推出的挂载卷/外置磁盘/DMG，提供「推出“名称”」
            if node.isEjectableVolume || Self.isVolumeEjectable(url: url) {
                let eject = NSMenuItem(title: "推出“\(node.title)”", action: #selector(ejectVolumeClicked(_:)), keyEquivalent: "E")
                eject.keyEquivalentModifierMask = [.command]
                eject.target = self
                eject.representedObject = url
                menu.addItem(eject)
            }

            menu.addItem(.separator())

            // 针对个人收藏文件夹：新建文件夹
            if node.isUserFavorite || !node.isEjectableVolume {
                let newFolder = NSMenuItem(title: "新建文件夹…", action: #selector(newFolderInContextClicked), keyEquivalent: "N")
                newFolder.keyEquivalentModifierMask = [.command, .shift]
                newFolder.target = self
                newFolder.representedObject = url
                menu.addItem(newFolder)
            }

            let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealClicked), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)

            let terminal = NSMenuItem(title: "在“终端”中打开", action: #selector(openInTerminalClicked), keyEquivalent: "")
            terminal.target = self
            terminal.representedObject = url
            menu.addItem(terminal)

            let copyPath = NSMenuItem(title: "拷贝路径", action: #selector(copyPathClicked), keyEquivalent: "C")
            copyPath.keyEquivalentModifierMask = [.command, .option]
            copyPath.target = self
            copyPath.representedObject = url
            menu.addItem(copyPath)

            let getInfo = NSMenuItem(title: "显示简介", action: #selector(getInfoClicked), keyEquivalent: "i")
            getInfo.keyEquivalentModifierMask = [.command]
            getInfo.target = self
            getInfo.representedObject = url
            menu.addItem(getInfo)

            if node.isUserFavorite {
                menu.addItem(.separator())
                let remove = NSMenuItem(title: "从个人收藏中移除", action: #selector(removeFavoriteClicked), keyEquivalent: "")
                remove.target = self
                remove.representedObject = url
                menu.addItem(remove)
            }

            // 移到废纸篓与直接删除
            if !node.isTrash {
                menu.addItem(.separator())
                let trashItem = NSMenuItem(title: "移到废纸篓", action: #selector(trashContextNodeClicked), keyEquivalent: "")
                trashItem.target = self
                trashItem.representedObject = url
                menu.addItem(trashItem)

                let deleteItem = NSMenuItem(title: "直接删除…", action: #selector(deleteContextNodeImmediatelyClicked), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = url
                menu.addItem(deleteItem)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新", action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类", action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        return makeSidebarAreaMenu()
    }

    // MARK: - 数据

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .tagsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .favoritesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .sidebarIconSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .sidebarIconStyleDidChange, object: nil)
    }

    @objc private func volumesChanged() { reload() }

    func reload(preservingCurrentURL currentURL: URL? = nil) {
        let previousURL = currentURL ?? currentURLProvider?() ?? selectedNode()?.url
        let previousTag = selectedNode()?.tag

        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [SidebarNode] = []

        // 1. 个人收藏
        if AppSettings.isSidebarCategoryVisible(.favorites) {
            let favorites = SidebarNode(kind: .group, title: SidebarCategory.favorites.title)
            for (directory, title) in Self.favoriteEntries {
                guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { continue }
                if AppSettings.isFavorite(url) {
                    favorites.children.append(SidebarNode(kind: .folder, title: title, url: url, usesSystemIcon: true))
                }
            }
            if AppSettings.isFavorite(home) {
                favorites.children.append(SidebarNode(kind: .folder, title: "主目录", url: home, symbol: "house.fill"))
            }
            let appURL = URL(fileURLWithPath: "/Applications")
            if AppSettings.isFavorite(appURL) {
                favorites.children.append(SidebarNode(kind: .folder,
                                                      title: "应用程序",
                                                      url: appURL,
                                                      usesSystemIcon: true))
            }
            let defaultPaths = AppSettings.defaultFavoritePaths()
            for path in AppSettings.favorites {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if defaultPaths.contains(url.standardizedFileURL.path) { continue }
                let name = FileManager.default.displayName(atPath: url.path)
                let title = name.isEmpty ? url.lastPathComponent : name
                favorites.children.append(SidebarNode(kind: .folder,
                                                      title: title,
                                                      url: url,
                                                      usesSystemIcon: true,
                                                      isUserFavorite: true))
            }
            list.append(favorites)
        }

        // 2. iCloud
        if AppSettings.isSidebarCategoryVisible(.icloud) {
            let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            if FileManager.default.fileExists(atPath: cloud.path) {
                let group = SidebarNode(kind: .group, title: SidebarCategory.icloud.title)
                group.children.append(SidebarNode(kind: .folder, title: "iCloud 云盘", url: cloud, symbol: "icloud"))
                list.append(group)
            }
        }

        // 3. 位置：本地根卷 + 已挂载的本地外置磁盘，最后是废纸篓
        if AppSettings.isSidebarCategoryVisible(.locations) {
            let locations = SidebarNode(kind: .group, title: SidebarCategory.locations.title)
            for volume in Self.localVolumeEntries() {
                locations.children.append(SidebarNode(kind: .folder,
                                                      title: volume.name,
                                                      url: volume.url,
                                                      usesSystemIcon: true,
                                                      isEjectableVolume: volume.isEjectable))
            }
            if let trash = Self.trashURL() {
                locations.children.append(SidebarNode(kind: .folder,
                                                      title: "废纸篓",
                                                      url: trash,
                                                      usesSystemIcon: true,
                                                      isTrash: true))
            }
            list.append(locations)
        }

        // 4. 服务器：已挂载的网络卷 + 已保存的常用服务器 + 「连接服务器…」快捷入口
        if AppSettings.isSidebarCategoryVisible(.servers) {
            let serversGroup = SidebarNode(kind: .group, title: SidebarCategory.servers.title)
            let mountedNets = ServerConnectWindowController.mountedNetworkVolumes()
            var handledMountPaths = Set<String>()

            // 先展示用户已保存的服务器（如果已挂载则关联其挂载路径）
            for entry in AppSettings.savedServers {
                let matchedMount = entry.url.flatMap { ServerConnectWindowController.findMountedVolume(matching: $0) }
                if let m = matchedMount {
                    handledMountPaths.insert(m.standardizedFileURL.path)
                }
                serversGroup.children.append(
                    SidebarNode(
                        kind: .server,
                        title: entry.hostDisplay,
                        url: matchedMount,
                        serverEntry: entry,
                        isMountedNetworkVolume: matchedMount != nil
                    )
                )
            }

            // 再展示其它当前已挂载但未在收藏中的网络卷
            for net in mountedNets where !handledMountPaths.contains(net.url.standardizedFileURL.path) {
                let tempEntry = net.remountURL.map { ServerEntry(name: net.name, urlString: $0.absoluteString) }
                serversGroup.children.append(
                    SidebarNode(
                        kind: .server,
                        title: net.name,
                        url: net.url,
                        serverEntry: tempEntry,
                        isMountedNetworkVolume: true
                    )
                )
            }

            // 始终提供「连接服务器…」入口
            serversGroup.children.append(
                SidebarNode(
                    kind: .connectServer,
                    title: "连接服务器…",
                    symbol: "plus.circle"
                )
            )
            list.append(serversGroup)
        }

        // 5. 标签
        if AppSettings.isSidebarCategoryVisible(.tags) {
            let tags = SidebarNode(kind: .group, title: SidebarCategory.tags.title)
            for tag in Tags.all {
                tags.children.append(SidebarNode(kind: .tag,
                                                 title: tag.name,
                                                 tag: tag.name,
                                                 dotColor: tag.color))
            }
            list.append(tags)
        }

        nodes = list
        outline.deselectAll(nil)
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }

        if let tag = previousTag {
            select(tag: tag)
        } else if let url = previousURL {
            select(url: url)
        } else {
            outline.deselectAll(nil)
        }
    }

    private static var favoriteEntries: [(FileManager.SearchPathDirectory, String)] {
        [
            (.desktopDirectory, "桌面"),
            (.documentDirectory, "文稿"),
            (.downloadsDirectory, "下载"),
            (.moviesDirectory, "影片"),
            (.musicDirectory, "音乐"),
            (.picturesDirectory, "图片")
        ]
    }

    /// 本地卷：根卷排在最前（名字取真实的卷名，如 Macintosh HD），随后是其它已挂载的本地可浏览卷（不含网络卷）。
    private static func localVolumeEntries() -> [(name: String, url: URL, isEjectable: Bool)] {
        var result: [(String, URL, Bool)] = []
        let root = URL(fileURLWithPath: "/")
        let rootName = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        result.append((rootName?.isEmpty == false ? rootName! : "Macintosh HD", root, false))

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in urls {
            guard url.standardizedFileURL.path != "/" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]),
                  values.volumeIsBrowsable != false,
                  values.volumeIsLocal != false,
                  let name = values.volumeName, !name.isEmpty else { continue }
            let isEjectable = isVolumeEjectable(url: url)
            result.append((name, url, isEjectable))
        }
        return result
    }

    /// 判断某个路径是否是可推出的磁盘或挂载卷（外置驱动器、DMG镜像、USB驱动器等）
    static func isVolumeEjectable(url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" { return false }
        if let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]) {
            if values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false {
                return true
            }
        }
        if path.hasPrefix("/Volumes/") && !path.hasSuffix("/Macintosh HD") {
            return true
        }
        return false
    }

    private static func trashURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 选中同步

    func select(url: URL) {
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        let target = url.standardizedFileURL.path

        for node in nodes {
            for child in node.children {
                guard let childURL = child.url else { continue }
                if childURL.standardizedFileURL.path == target {
                    let row = outline.row(forItem: child)
                    if row >= 0 {
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        outline.scrollRowToVisible(row)
                    }
                    return
                }
            }
        }
        outline.deselectAll(nil)
    }

    /// 让某个标签行成为选中项（切换窗格焦点时用）。
    func select(tag: String) {
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        for node in nodes {
            for child in node.children where child.tag == tag {
                let row = outline.row(forItem: child)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
                return
            }
        }
        outline.deselectAll(nil)
    }

    // MARK: - 动作

    @objc private func handleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else {
            outline.deselectAll(nil)
            return
        }
        open(node)
    }

    private func open(_ node: SidebarNode) {
        switch node.kind {
        case .connectServer:
            outline.deselectAll(nil)
            onRequestConnectServer?(nil)
        case .server:
            if let mountedURL = node.url {
                onSelect?(mountedURL)
            } else if let entry = node.serverEntry {
                ServerConnectWindowController.shared.connect(entry: entry)
            } else {
                onRequestConnectServer?(nil)
            }
        case .tag:
            if let tag = node.tag { onSelectTag?(tag) }
        case .folder:
            if let url = node.url { onSelect?(url) }
        case .group:
            break
        }
    }

    @objc private func toggleCategoryClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let category = SidebarCategory(rawValue: raw) else { return }
        AppSettings.toggleSidebarCategory(category)
        reload()
    }

    @objc private func showAllCategoriesClicked() {
        AppSettings.showAllSidebarCategories()
        reload()
    }

    @objc private func connectServerMenuClicked() {
        onRequestConnectServer?(nil)
    }

    @objc private func browseNetworkMenuClicked() {
        onSelect?(URL(fileURLWithPath: "/Network"))
    }

    @objc private func expandAllGroupsClicked() {
        for node in nodes { outline.expandItem(node) }
    }

    @objc private func collapseAllGroupsClicked() {
        for node in nodes { outline.collapseItem(node) }
    }

    @objc private func openOrConnectContextServerClicked() {
        guard let node = contextNode ?? selectedNode() else { return }
        open(node)
    }

    @objc private func editContextServerClicked(_ sender: NSMenuItem) {
        let entry = sender.representedObject as? ServerEntry
        onRequestConnectServer?(entry)
    }

    @objc private func unmountServerClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        reload()
    }

    @objc private func removeSavedServerClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppSettings.removeServer(id: id)
        reload()
    }

    @objc private func revealClicked() {
        let node = contextNode ?? selectedNode()
        guard let url = node?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func refreshClicked() { reload() }

    /// 从个人收藏里移除某个条目。
    @objc private func removeFavoriteClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AppSettings.removeFavorite(url)
        reload()
    }

    /// 边栏右键将文件夹移到废纸篓
    @objc private func trashContextNodeClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/" || path == home || path == "/Applications" || path == "/System" {
            let alert = NSAlert()
            alert.messageText = "系统核心目录不能移到废纸篓"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        FileOperations.playTrashSound()
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            if AppSettings.isFavorite(url) {
                AppSettings.removeFavorite(url)
            }
            reload()
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// 边栏右键直接永久删除文件夹
    @objc private func deleteContextNodeImmediatelyClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/" || path == home || path == "/Applications" || path == "/System" {
            let alert = NSAlert()
            alert.messageText = "系统核心目录不能直接删除"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        FileOperations.deleteImmediately(urls: [url], window: window) { [weak self] success in
            if success {
                if AppSettings.isFavorite(url) {
                    AppSettings.removeFavorite(url)
                }
                self?.reload()
            }
        }
    }

    @objc private func settingsButtonClicked() {
        onOpenSettings?()
    }

    @objc private func openTagInOtherPaneClicked(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String ?? contextNode?.tag ?? contextNode?.title else { return }
        onSelectTag?(tagName)
    }

    @objc private func renameTagClicked(_ sender: NSMenuItem) {
        guard let oldName = sender.representedObject as? String ?? contextNode?.tag ?? contextNode?.title else { return }
        let alert = NSAlert()
        alert.messageText = "重命名标签"
        alert.informativeText = "为标签“\(oldName)”输入新的名称："
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = oldName
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != oldName else { return }
            Tags.renameTag(oldName: oldName, newName: newName)
            reload()
        }
    }

    @objc private func openInOtherPaneClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        onOpenInOtherPane?(url)
    }

    @objc private func ejectVolumeClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let title = contextNode?.title ?? url.lastPathComponent
        eject(url: url, title: title)
    }

    func eject(url: URL, title: String) {
        let volName = title.isEmpty ? url.lastPathComponent : title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var success = false
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                success = true
            } catch {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = ["unmount", url.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                } else {
                    let p2 = Process()
                    p2.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    p2.arguments = ["unmount", "force", url.path]
                    try? p2.run()
                    p2.waitUntilExit()
                    if p2.terminationStatus == 0 {
                        success = true
                    } else {
                        let h = Process()
                        h.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        h.arguments = ["detach", url.path, "-force"]
                        try? h.run()
                        h.waitUntilExit()
                        success = (h.terminationStatus == 0)
                    }
                }
            }

            DispatchQueue.main.async {
                if !success {
                    let alert = NSAlert()
                    alert.messageText = "无法推出“\(volName)”"
                    alert.informativeText = "该磁盘可能正被其它应用程序使用。请先关闭使用该磁盘的程序后再试。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                self?.reload()
            }
        }
    }

    @objc private func openInTerminalClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        if let termURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: termURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    @objc private func copyPathClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(url.path, forType: .string)
    }

    @objc private func copyServerURLClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func getInfoClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(url.path)\" as alias)"
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    @objc private func newFolderInContextClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let folderName = contextNode?.title ?? url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "在“\(folderName)”中新建子文件夹："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "未命名文件夹"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let folderToCreate = name.isEmpty ? "未命名文件夹" : name
            let newURL = url.appendingPathComponent(folderToCreate)
            try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            reload()
        }
    }

    @objc private func emptyTrashClicked(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "确定要清倒废纸篓吗？"
        alert.informativeText = "此操作将永久抹掉废纸篓中的所有项目，且无法撤销。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "清倒废纸篓")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let script = "tell application \"Finder\" to empty trash"
            if let appleScript = NSAppleScript(source: script) {
                var err: NSDictionary?
                appleScript.executeAndReturnError(&err)
            }
            reload()
        }
    }

    @objc private func deleteTagClicked(_ sender: NSMenuItem) {
        guard let tagName = (sender.representedObject as? String) ?? contextNode?.tag ?? contextNode?.title else { return }
        let alert = NSAlert()
        alert.messageText = "移除标签"
        alert.informativeText = "确定要从列表中移除标签“\(tagName)”吗？"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Tags.renameTag(oldName: tagName, newName: "")
            reload()
        }
    }

    private func selectedNode() -> SidebarNode? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? SidebarNode
    }
}

// MARK: - 侧栏列表

/// 侧栏列表：右键时按被点中的节点动态生成菜单（点空白区域同样弹出侧栏操作菜单）。
final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((SidebarNode?) -> NSMenu?)?
    private var trackingArea: NSTrackingArea?

    var hoveredRow: Int = -1 {
        didSet {
            if oldValue != hoveredRow {
                if oldValue >= 0 && oldValue < numberOfRows {
                    rowView(atRow: oldValue, makeIfNecessary: false)?.needsDisplay = true
                }
                if hoveredRow >= 0 && hoveredRow < numberOfRows {
                    rowView(atRow: hoveredRow, makeIfNecessary: false)?.needsDisplay = true
                }
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

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, let node = item(atRow: row) as? SidebarNode, !node.isGroup {
            hoveredRow = row
        } else {
            hoveredRow = -1
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let node = row >= 0 ? (item(atRow: row) as? SidebarNode) : nil
        return menuProvider?(node) ?? super.menu(for: event)
    }
}

// MARK: - 数据源 / 代理

extension SidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? SidebarNode { return node.children.count }
        return nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SidebarNode { return node.children[index] }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup == false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.isGroup == true ? 26 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? SidebarNode, !node.isGroup else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarRowView")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView)
            ?? SidebarRowView()
        row.identifier = identifier
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("group")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarGroupCell)
                ?? SidebarGroupCell(identifier: identifier)
            view.textField?.stringValue = node.title
            return view
        }
        let identifier = NSUserInterfaceItemIdentifier("item")
        let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarItemCell)
            ?? SidebarItemCell(identifier: identifier)
        view.configure(with: node)
        view.onEject = { [weak self] in
            if let url = node.url {
                self?.eject(url: url, title: node.title)
            }
        }
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        guard let node = selectedNode() else { return }
        open(node)
    }

    // MARK: 拖拽接收

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? SidebarNode, let dest = node.url, node.kind == .folder || node.isTrash else {
            return []
        }
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return [] }
        return FileOperations.shouldCopy(for: info, destination: dest) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? SidebarNode, let dest = node.url, node.kind == .folder || node.isTrash else {
            return false
        }
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return false }
        if node.isTrash {
            FileOperations.playTrashSound()
            NSWorkspace.shared.recycle(urls) { _, _ in
                NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            }
            return true
        }
        let isCopy = FileOperations.shouldCopy(for: info, destination: dest)
        FileOperations.transfer(urls: urls, to: dest, isCopy: isCopy)
        FileOperations.playFileAddedSound()
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        return true
    }
}

// MARK: - 单元格

private final class SidebarGroupCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 侧栏专用推出按钮（支持悬停深灰/高亮底色反馈、小手光标、默认浅灰）

private final class SidebarEjectButton: NSButton {

    private var trackingArea: NSTrackingArea?

    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance()
        }
    }

    var isRowSelected = false {
        didSet {
            guard oldValue != isRowSelected else { return }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        title = ""
        image = Theme.symbol("eject.fill", size: 8.5, weight: .medium) ?? NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "推出")
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 3.5
        updateAppearance()
    }

    private func updateAppearance() {
        if isHighlighted {
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        } else if isHovered {
            // 鼠标移上去：颜色变深，带精致的微灰背景反馈（完全包含在浅灰色行背景内）
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        } else {
            // 默认状态：颜色更浅更干净
            contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func resetCursorRects() {
        // 鼠标放上去显示「小手」光标
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }
}

private final class SidebarItemCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let ejectButton = SidebarEjectButton()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    var onEject: (() -> Void)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            ejectButton.isRowSelected = (backgroundStyle == .emphasized)
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .controlAccentColor
        addSubview(icon)

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.isHidden = true
        addSubview(statusDot)

        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.target = self
        ejectButton.action = #selector(ejectButtonClicked)
        ejectButton.isHidden = true
        addSubview(ejectButton)

        let dim = AppSettings.sidebarIconSize.dimension
        let w = icon.widthAnchor.constraint(equalToConstant: dim)
        let h = icon.heightAnchor.constraint(equalToConstant: dim)
        iconWidthConstraint = w
        iconHeightConstraint = h

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            w,
            h,

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
            ejectButton.heightAnchor.constraint(equalToConstant: 15),

            title.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func ejectButtonClicked() {
        onEject?()
    }

    func configure(with node: SidebarNode) {
        let dim = AppSettings.sidebarIconSize.dimension
        iconWidthConstraint?.constant = dim
        iconHeightConstraint?.constant = dim
        title.stringValue = node.title

        let canEject = node.isEjectableVolume || node.isMountedNetworkVolume
        ejectButton.isHidden = !canEject
        ejectButton.toolTip = canEject ? "推出“\(node.title)”" : nil

        statusDot.isHidden = canEject || !node.isMountedNetworkVolume

        if node.kind == .connectServer {
            icon.image = Theme.symbol("plus.circle", size: 13, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            title.textColor = .secondaryLabelColor
            return
        }

        title.textColor = .labelColor
        if let dotColor = node.dotColor {
            icon.image = Tags.dotImage(color: dotColor)
            icon.contentTintColor = nil
            return
        }

        if AppSettings.sidebarIconStyle == .minimalist {
            icon.image = Theme.minimalistSidebarIcon(for: node, size: dim)
            icon.contentTintColor = .secondaryLabelColor
            return
        }

        if node.kind == .server {
            icon.image = Theme.serverIcon(urlString: node.serverEntry?.urlString ?? "", size: dim)
            icon.contentTintColor = nil
            return
        }
        if let url = node.url, let special = Theme.specialFolderIcon(for: url, size: dim) {
            icon.image = special
            icon.contentTintColor = nil
            return
        }
        if node.usesSystemIcon, let url = node.url {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
            icon.contentTintColor = nil
            return
        }
        if node.symbol == "house.fill" {
            icon.image = Theme.colorfulHomeIcon(size: dim)
            icon.contentTintColor = nil
            return
        }
        icon.image = Theme.symbol(node.symbol, size: 13)
        icon.contentTintColor = .controlAccentColor
    }
}

// MARK: - 侧栏高保真极简浅灰圆角选中行与悬浮反馈

private final class SidebarRowView: NSTableRowView {

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // 返回 .normal，防止系统将选中行的文字强制反白，保持极简深色文字与浅灰底
        .normal
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        needsDisplay = true
    }

    private var isHovered: Bool {
        guard let outline = (superview as? SidebarOutlineView)
            ?? (enclosingScrollView?.documentView as? SidebarOutlineView) else {
            return false
        }
        let myRow = outline.row(for: self)
        return myRow >= 0 && outline.hoveredRow == myRow
    }

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // selectionHighlightStyle 为 .none 时不调用；留空防止系统原生蓝色绘制
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let selectionRect = bounds.insetBy(dx: 5, dy: 1)
        if isSelected {
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            let fillColor = NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return NSColor(white: 1.0, alpha: 0.18)
                } else {
                    return NSColor(white: 0.0, alpha: 0.12)
                }
            }
            fillColor.setFill()
            path.fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            let fillColor = NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return NSColor(white: 1.0, alpha: 0.09)
                } else {
                    return NSColor(white: 0.0, alpha: 0.05)
                }
            }
            fillColor.setFill()
            path.fill()
        }
    }
}
