import AppKit

enum ViewMode: String, CaseIterable {
    case list, icons, columns

    var title: String {
        switch self {
        case .list: return "列表"
        case .icons: return "图标"
        case .columns: return "分栏"
        }
    }

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

/// 侧栏可展示的分类枚举。
enum SidebarCategory: String, CaseIterable {
    case favorites = "favorites"
    case icloud    = "icloud"
    case locations = "locations"
    case servers   = "servers"
    case tags      = "tags"

    var title: String {
        switch self {
        case .favorites: return "个人收藏"
        case .icloud:    return "iCloud"
        case .locations: return "位置"
        case .servers:   return "服务器"
        case .tags:      return "标签"
        }
    }
}

/// 用户保存的远程服务器条目（如 SMB / AFP / NFS / FTP / WebDAV / VNC）。
struct ServerEntry: Codable, Equatable {
    var id: String
    var name: String
    var urlString: String

    init(id: String = UUID().uuidString, name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    /// 归一化后的 URL（若未写协议头则默认补全 smb://）。
    var normalizedURLString: String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "smb://\(trimmed)"
    }

    var url: URL? {
        URL(string: normalizedURLString)
    }

    var hostDisplay: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let u = url, let host = u.host, !host.isEmpty {
            if !u.path.isEmpty && u.path != "/" {
                return "\(host)\(u.path)"
            }
            return host
        }
        return urlString
    }
}

/// 轻量偏好存储。全部落在 UserDefaults，启动时恢复上次状态。
enum AppSettings {
    private static let store = UserDefaults.standard

    static var showHidden: Bool {
        get { store.bool(forKey: "showHidden") }
        set {
            store.set(newValue, forKey: "showHidden")
            NotificationCenter.default.post(name: .showHiddenFilesDidChange, object: nil)
        }
    }

    /// 是否在列表视图中显示斑马线交替底色（关闭时整行显示纯白背景）
    private static var _showZebraStripes: Bool = (store.object(forKey: "showZebraStripes") as? Bool) ?? true
    static var showZebraStripes: Bool {
        get { _showZebraStripes }
        set {
            _showZebraStripes = newValue
            store.set(newValue, forKey: "showZebraStripes")
            NotificationCenter.default.post(name: .zebraStripesDidChange, object: nil)
        }
    }

    static var layout: String {
        get { store.string(forKey: "layout") ?? "single" }
        set { store.set(newValue, forKey: "layout") }
    }

    static var viewMode: String {
        get { store.string(forKey: "viewMode") ?? ViewMode.list.rawValue }
        set { store.set(newValue, forKey: "viewMode") }
    }

    static var sortField: String {
        get { store.string(forKey: "sortField") ?? SortField.name.rawValue }
        set { store.set(newValue, forKey: "sortField") }
    }

    static var sortAscending: Bool {
        get { store.object(forKey: "sortAscending") as? Bool ?? true }
        set { store.set(newValue, forKey: "sortAscending") }
    }

    static var groupMode: String {
        get { store.string(forKey: "groupMode") ?? GroupMode.none.rawValue }
        set { store.set(newValue, forKey: "groupMode") }
    }

    /// 各窗格上次所在目录（按窗格序号）。
    static var panePaths: [String] {
        get { store.stringArray(forKey: "panePaths") ?? [] }
        set { store.set(newValue, forKey: "panePaths") }
    }

    /// 各窗格上次的显示方式（list / icons / columns），按窗格序号。
    static var paneViewModes: [String] {
        get { store.stringArray(forKey: "paneViewModes") ?? [] }
        set { store.set(newValue, forKey: "paneViewModes") }
    }

    /// 焦点窗格序号（下次启动时恢复）。
    static var focusedPaneIndex: Int {
        get { store.integer(forKey: "focusedPaneIndex") }
        set { store.set(newValue, forKey: "focusedPaneIndex") }
    }

    /// 窗口位置与大小（NSStringFromRect）。
    static var windowFrame: String? {
        get { store.string(forKey: "windowFrame") }
        set { store.set(newValue, forKey: "windowFrame") }
    }

    // MARK: - 个人收藏

    /// 个人收藏系统预设目录
    static let defaultFavoriteDirectories: [FileManager.SearchPathDirectory] = [
        .desktopDirectory,
        .documentDirectory,
        .downloadsDirectory,
        .moviesDirectory,
        .musicDirectory,
        .picturesDirectory
    ]

    private static let cachedDefaultFavoriteURLs: [URL] = {
        var urls: [URL] = []
        for dir in defaultFavoriteDirectories {
            if let u = FileManager.default.urls(for: dir, in: .userDomainMask).first {
                urls.append(u)
            }
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser)
        urls.append(URL(fileURLWithPath: "/Applications"))
        return urls
    }()

    private static let cachedDefaultFavoritePaths: Set<String> = {
        Set(cachedDefaultFavoriteURLs.map { $0.standardizedFileURL.path })
    }()

    static func defaultFavoriteURLs() -> [URL] {
        cachedDefaultFavoriteURLs
    }

    static func defaultFavoritePaths() -> Set<String> {
        cachedDefaultFavoritePaths
    }

    /// 用户显式从预设收藏中取消收藏的路径黑名单（避免取消后又被当做默认收藏）
    private static var removedDefaultFavorites: Set<String> {
        get { Set(store.stringArray(forKey: "removedDefaultFavorites") ?? []) }
        set { store.set(Array(newValue), forKey: "removedDefaultFavorites") }
    }

    /// 用户添加到「个人收藏」的路径。
    static var favorites: [String] {
        get { store.stringArray(forKey: "favorites") ?? [] }
        set {
            store.set(newValue, forKey: "favorites")
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
        }
    }

    /// 检查指定 URL 是否在个人收藏中（包含系统默认预设收藏与用户自定义收藏）
    static func isFavorite(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        if favorites.contains(where: { ($0 as NSString).standardizingPath == target }) {
            return true
        }
        if removedDefaultFavorites.contains(target) {
            return false
        }
        return defaultFavoritePaths().contains(target)
    }

    /// 加入 / 移出个人收藏，返回切换后的状态（true = 已收藏）。
    @discardableResult
    static func toggleFavorite(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let isDefault = defaultFavoritePaths().contains(target)
        let isCurrentlyFav = isFavorite(url)

        if isCurrentlyFav {
            // 移出收藏
            var list = favorites
            list.removeAll { ($0 as NSString).standardizingPath == target }
            favorites = list
            if isDefault {
                var removed = removedDefaultFavorites
                removed.insert(target)
                removedDefaultFavorites = removed
            }
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return false
        } else {
            // 加入收藏
            if isDefault {
                var removed = removedDefaultFavorites
                removed.remove(target)
                removedDefaultFavorites = removed
            }
            var list = favorites
            if !list.contains(where: { ($0 as NSString).standardizingPath == target }) {
                list.append(target)
                favorites = list
            }
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return true
        }
    }

    static func removeFavorite(_ url: URL) {
        let target = url.standardizedFileURL.path
        var list = favorites
        list.removeAll { ($0 as NSString).standardizingPath == target }
        favorites = list
        if defaultFavoritePaths().contains(target) {
            var removed = removedDefaultFavorites
            removed.insert(target)
            removedDefaultFavorites = removed
        }
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    // MARK: - 列表列显示

    /// 当前显示的列（名称列恒显，不在其中）。
    static var visibleColumns: [String] {
        get { store.stringArray(forKey: "visibleColumns") ?? defaultColumns }
        set { store.set(newValue, forKey: "visibleColumns") }
    }

    /// 「恢复到默认」用的一套列。
    static var defaultColumns: [String] {
        get { store.stringArray(forKey: "defaultColumns") ?? ListColumn.builtInDefaults }
        set { store.set(newValue, forKey: "defaultColumns") }
    }

    /// 各列的用户自定义宽度（key 为 ListColumn.rawValue）。缺省时不写，回落到内置默认宽。
    private static var _columnWidths: [String: Double] = store.dictionary(forKey: "columnWidths") as? [String: Double] ?? [:]
    static var columnWidths: [String: Double] {
        get { _columnWidths }
        set {
            _columnWidths = newValue
            store.set(newValue, forKey: "columnWidths")
        }
    }

    /// 名称列的固定宽度（左对齐布局下名称列在左、各列向右排，最后一列自适应填满）。
    private static var _nameColumnWidth: CGFloat = {
        let value = store.double(forKey: "nameColumnWidth")
        return value >= Double(FileListView.minNameWidth) ? CGFloat(value) : 220
    }()
    static var nameColumnWidth: CGFloat {
        get { _nameColumnWidth }
        set {
            _nameColumnWidth = newValue
            store.set(Double(newValue), forKey: "nameColumnWidth")
        }
    }

    /// 分栏视图列宽（可通过拖动列分隔线实时调节并记住）。
    static var browserColumnWidth: CGFloat {
        get {
            let val = store.double(forKey: "browserColumnWidth")
            return val >= 140 ? CGFloat(val) : 214
        }
        set { store.set(Double(newValue), forKey: "browserColumnWidth") }
    }

    /// 恢复默认列时一并清除自定义宽度与名称列宽。
    static func resetColumnWidths() {
        _columnWidths = [:]
        _nameColumnWidth = 220
        store.removeObject(forKey: "columnWidths")
        store.removeObject(forKey: "nameColumnWidth")
    }

    static var sidebarWidth: CGFloat {
        get {
            let value = store.double(forKey: "sidebarWidth")
            return value > 100 ? value : Theme.sidebarWidth
        }
        set { store.set(Double(newValue), forKey: "sidebarWidth") }
    }

    /// 「查看显示选项」：图标视图的图标尺寸。
    static var gridIconSize: CGFloat {
        get {
            guard let val = store.object(forKey: "gridIconSize") as? Double, val >= 32 else {
                return Theme.gridIconSize
            }
            if val == 56.0 || val == 68.0 {
                return Theme.gridIconSize
            }
            return CGFloat(val)
        }
        set {
            store.set(Double(newValue), forKey: "gridIconSize")
            NotificationCenter.default.post(name: .gridIconSizeDidChange, object: nil)
        }
    }

    /// 「查看显示选项」：列表视图的行高。
    static var listRowHeight: CGFloat {
        get {
            let value = store.double(forKey: "listRowHeight")
            return value >= 18 ? value : Theme.rowHeight
        }
        set { store.set(Double(newValue), forKey: "listRowHeight") }
    }

    /// 窗格分隔条位置：按布局分别保存「竖向分界」「横向分界」的比例数组。
    static func splits(for mode: LayoutMode) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let v = (store.array(forKey: "splits.v.\(mode.rawValue)") as? [Double] ?? []).map { CGFloat($0) }
        let h = (store.array(forKey: "splits.h.\(mode.rawValue)") as? [Double] ?? []).map { CGFloat($0) }
        return (v, h)
    }

    static func setSplits(vertical: [CGFloat], horizontal: [CGFloat], for mode: LayoutMode) {
        store.set(vertical.map { Double($0) }, forKey: "splits.v.\(mode.rawValue)")
        store.set(horizontal.map { Double($0) }, forKey: "splits.h.\(mode.rawValue)")
    }

    // MARK: - 侧栏分类显示控制

    /// 当前在侧栏中显示的分类（默认全部显示）。
    static var visibleSidebarCategories: [String] {
        get {
            store.stringArray(forKey: "visibleSidebarCategories")
                ?? SidebarCategory.allCases.map { $0.rawValue }
        }
        set {
            store.set(newValue, forKey: "visibleSidebarCategories")
        }
    }

    static func isSidebarCategoryVisible(_ category: SidebarCategory) -> Bool {
        visibleSidebarCategories.contains(category.rawValue)
    }

    static func toggleSidebarCategory(_ category: SidebarCategory) {
        var current = visibleSidebarCategories
        if let idx = current.firstIndex(of: category.rawValue) {
            current.remove(at: idx)
        } else {
            current.append(category.rawValue)
        }
        visibleSidebarCategories = current
    }

    static func showAllSidebarCategories() {
        visibleSidebarCategories = SidebarCategory.allCases.map { $0.rawValue }
    }

    // MARK: - 已保存的远程服务器

    static var savedServers: [ServerEntry] {
        get {
            guard let data = store.data(forKey: "savedServers"),
                  let entries = try? JSONDecoder().decode([ServerEntry].self, from: data) else {
                return []
            }
            return entries
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: "savedServers")
            }
        }
    }

    @discardableResult
    static func addOrUpdateServer(name: String, urlString: String) -> ServerEntry {
        var list = savedServers
        let entry = ServerEntry(name: name, urlString: urlString)
        let norm = entry.normalizedURLString.lowercased()
        if let idx = list.firstIndex(where: { $0.normalizedURLString.lowercased() == norm }) {
            if !name.isEmpty {
                list[idx].name = name
            }
            list[idx].urlString = entry.normalizedURLString
            savedServers = list
            return list[idx]
        }
        var newEntry = entry
        newEntry.urlString = entry.normalizedURLString
        list.append(newEntry)
        savedServers = list
        return newEntry
    }

    static func removeServer(id: String) {
        savedServers = savedServers.filter { $0.id != id }
    }
}

extension Notification.Name {
    static let zebraStripesDidChange = Notification.Name("AppSettingsZebraStripesDidChange")
    static let favoritesDidChange = Notification.Name("AppSettingsFavoritesDidChange")
    static let gridIconSizeDidChange = Notification.Name("AppSettingsGridIconSizeDidChange")
}
