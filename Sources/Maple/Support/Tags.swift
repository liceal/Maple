import AppKit

/// 标签定义（名称、显示颜色、系统扩展属性存储的颜色索引与标识符）
struct TagDefinition: Hashable {
    let name: String
    let color: NSColor
    let colorKey: String
    let xattrIndex: Int
}

enum Tags {

    private static var _cachedAll: [TagDefinition]?
    private static var activeRenameSearcher: TagSearch?

    /// 标签调色盘：包含 macOS 原生的七种经典标签颜色与 Spotlight 颜色编号
    static let palette: [(key: String, defaultName: String, color: NSColor, xattrIndex: Int)] = [
        ("red", "红色", .systemRed, 6),
        ("green", "绿色", .systemGreen, 2),
        ("blue", "蓝色", .systemBlue, 4),
        ("orange", "橙色", .systemOrange, 7),
        ("yellow", "黄色", .systemYellow, 5),
        ("purple", "紫色", .systemPurple, 3),
        ("gray", "灰色", .systemGray, 1)
    ]

    private static let userDefaultsKey = "MapleTagList"

    /// 获取所有标签。默认给三种：红、绿、蓝。用户可点击侧栏「+」随时添加或改名。
    static var all: [TagDefinition] {
        if let cached = _cachedAll { return cached }

        if let stored = UserDefaults.standard.array(forKey: userDefaultsKey) as? [[String: Any]], !stored.isEmpty {
            var list: [TagDefinition] = []
            for dict in stored {
                guard let name = dict["name"] as? String, !name.isEmpty,
                      let key = dict["colorKey"] as? String,
                      let item = palette.first(where: { $0.key == key }) else { continue }
                list.append(TagDefinition(name: name, color: item.color, colorKey: key, xattrIndex: item.xattrIndex))
            }
            if !list.isEmpty {
                _cachedAll = list
                return list
            }
        }

        // 默认三种：红、绿、蓝
        let defaultList = [
            TagDefinition(name: "红色", color: .systemRed, colorKey: "red", xattrIndex: 6),
            TagDefinition(name: "绿色", color: .systemGreen, colorKey: "green", xattrIndex: 2),
            TagDefinition(name: "蓝色", color: .systemBlue, colorKey: "blue", xattrIndex: 4)
        ]
        _cachedAll = defaultList
        save(list: defaultList)
        return defaultList
    }

    private static func save(list: [TagDefinition]) {
        let array = list.map { ["name": $0.name, "colorKey": $0.colorKey] }
        UserDefaults.standard.set(array, forKey: userDefaultsKey)
        _cachedAll = list
    }

    /// 根据标签名取颜色
    static func color(named name: String) -> NSColor {
        if let found = all.first(where: { $0.name == name }) {
            return found.color
        }
        // 如果文件带有系统其它语言或未在当前列表里的标签名，尝试按调色盘默认名匹配
        if let found = palette.first(where: { $0.defaultName == name || $0.key == name.lowercased() }) {
            return found.color
        }
        return .systemGray
    }

    /// 根据标签名取系统 xattr 编号 (1..7)
    static func colorIndex(for name: String) -> Int {
        if let found = all.first(where: { $0.name == name }) {
            return found.xattrIndex
        }
        if let found = palette.first(where: { $0.defaultName == name || $0.key == name.lowercased() }) {
            return found.xattrIndex
        }
        return 0
    }

    /// 新增标签：自动选择调色盘中下一个未使用的颜色（红绿蓝之后依次为橙、黄、紫、灰，若用完则循环）
    @discardableResult
    static func addTag(name: String? = nil, colorKey: String? = nil) -> TagDefinition {
        var current = all

        // 选择未使用的颜色
        let usedKeys = Set(current.map { $0.colorKey })
        let chosenItem: (key: String, defaultName: String, color: NSColor, xattrIndex: Int)
        if let key = colorKey, let match = palette.first(where: { $0.key == key }) {
            chosenItem = match
        } else if let unused = palette.first(where: { !usedKeys.contains($0.key) }) {
            chosenItem = unused
        } else {
            // 已全用过，循环取
            chosenItem = palette[current.count % palette.count]
        }

        // 确定标签名
        let tagName: String
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            tagName = name.trimmingCharacters(in: .whitespaces)
        } else {
            let base = chosenItem.defaultName
            if !current.contains(where: { $0.name == base }) {
                tagName = base
            } else {
                var idx = 2
                while current.contains(where: { $0.name == "新标签 \(idx)" || $0.name == "\(base) \(idx)" }) {
                    idx += 1
                }
                tagName = "\(base) \(idx)"
            }
        }

        let newDef = TagDefinition(name: tagName, color: chosenItem.color, colorKey: chosenItem.key, xattrIndex: chosenItem.xattrIndex)
        current.append(newDef)
        save(list: current)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
        return newDef
    }

    /// 移除标签
    static func removeTag(named name: String) {
        var current = all
        current.removeAll { $0.name == name }
        save(list: current)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 重命名标签：同步更新设置与所有被标记文件的系统 kMDItemUserTags 扩展属性
    static func renameTag(oldName: String, newName: String) {
        guard oldName != newName, !newName.isEmpty else { return }
        var current = all
        if let idx = current.firstIndex(where: { $0.name == oldName }) {
            let old = current[idx]
            current[idx] = TagDefinition(name: newName, color: old.color, colorKey: old.colorKey, xattrIndex: old.xattrIndex)
            save(list: current)
        }

        // 异步更新所有带旧标签的文件扩展属性（强引用保留 searcher 直到 Spotlight 查询回调完成）
        let searcher = TagSearch()
        activeRenameSearcher = searcher
        searcher.search(tag: oldName) { urls in
            DispatchQueue.global(qos: .utility).async {
                for url in urls {
                    replaceTag(on: url, oldTag: oldName, newTag: newName)
                }
            }
        }

        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 获取指定文件的所有标签名
    static func tags(for url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// 在指定文件上替换标签
    static func replaceTag(on url: URL, oldTag: String, newTag: String) {
        var fileTags = tags(for: url)
        if let idx = fileTags.firstIndex(of: oldTag) {
            fileTags[idx] = newTag
            setTags(fileTags, on: url)
        }
    }

    /// 在指定文件上切换标签（有则移除，无则添加）
    static func toggleTag(on url: URL, tag: String) {
        var fileTags = tags(for: url)
        if let idx = fileTags.firstIndex(of: tag) {
            fileTags.remove(at: idx)
        } else {
            fileTags.append(tag)
        }
        setTags(fileTags, on: url)
    }

    /// 将标签写入文件（同时更新 NSURLTagNamesKey 与 com.apple.metadata:_kMDItemUserTags）
    static func setTags(_ fileTags: [String], on url: URL) {
        // 1. Foundation 标准接口
        try? (url as NSURL).setResourceValue(fileTags as NSArray, forKey: .tagNamesKey)

        // 2. 写入包含颜色索引的 Spotlight 属性，让访达与系统全局完美呈现颜色
        let taggedWithColors = fileTags.map { name -> String in
            let idx = colorIndex(for: name)
            return "\(name)\n\(idx)"
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: taggedWithColors, format: .binary, options: 0) {
            url.path.withCString { path in
                _ = data.withUnsafeBytes { raw in
                    setxattr(path, "com.apple.metadata:_kMDItemUserTags", raw.baseAddress, raw.count, 0, 0)
                }
            }
        }
    }

    /// 侧栏小圆点
    static func dotImage(color: NSColor, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(ovalIn: ovalRect)
            color.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 右键菜单：已选中实心圆 + 居中对勾
    static func checkedDotImage(color: NSColor, diameter: CGFloat = 18) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 0.8, dy: 0.8)
            let path = NSBezierPath(ovalIn: ovalRect)
            color.setFill()
            path.fill()

            // 居中白色对勾
            let check = NSBezierPath()
            let w = rect.width
            let h = rect.height
            check.move(to: NSPoint(x: w * 0.28, y: h * 0.48))
            check.line(to: NSPoint(x: w * 0.44, y: h * 0.30))
            check.line(to: NSPoint(x: w * 0.74, y: h * 0.68))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 右键菜单：未选中空心圆环
    static func ringDotImage(color: NSColor, diameter: CGFloat = 18) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 1.2, dy: 1.2)
            let path = NSBezierPath(ovalIn: ovalRect)
            path.lineWidth = 1.5

            // 轻微半透明底色，使点击区域更饱满
            color.withAlphaComponent(0.10).setFill()
            path.fill()

            color.withAlphaComponent(0.85).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// 用 Spotlight 列出某个标签下的所有文件（访达侧栏点标签的行为）。
final class TagSearch {

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    deinit { cancel() }

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query?.stop()
        query = nil
    }

    /// 结果可能分多次回传（Spotlight 边查边报），最后一次是完整集合。
    func search(tag: String, completion: @escaping ([URL]) -> Void) {
        cancel()

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        self.query = query

        let collect: () -> Void = { [weak self, weak query] in
            guard let self, let query, query === self.query else { return }
            query.disableUpdates()
            var urls: [URL] = []
            urls.reserveCapacity(query.resultCount)
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                urls.append(URL(fileURLWithPath: path))
            }
            query.enableUpdates()
            completion(urls)
        }

        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { _ in
                collect()
            }
            observers.append(observer)
        }

        query.start()
    }
}

extension Notification.Name {
    static let tagsDidChange = Notification.Name("TagsDidChangeNotification")
}
