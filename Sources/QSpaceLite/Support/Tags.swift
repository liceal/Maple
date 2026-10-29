import AppKit

/// 访达的七个默认标签。名称必须与系统里存储的标签字符串一致，
/// Spotlight 的 `kMDItemUserTags` 里存的就是这些名字。
struct TagDefinition {
    let name: String
    let color: NSColor
}

enum Tags {

    private static var _cachedAll: [TagDefinition]?
    private static var activeRenameSearcher: TagSearch?

    /// 名称优先取系统里访达的标签设置（用户改过名字也能对上），顺序与颜色固定。
    static var all: [TagDefinition] {
        if let cached = _cachedAll { return cached }
        let fallback = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色"]
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .systemGray]

        var names = fallback
        if let stored = UserDefaults.standard.array(forKey: "FavoriteTagNames") as? [String]
            ?? UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String] {
            let cleaned = stored.map { $0.trimmingCharacters(in: .whitespaces) }
            if cleaned.count == colors.count, cleaned.allSatisfy({ !$0.isEmpty }) {
                names = cleaned
            }
        }
        let list = zip(names, colors).map { TagDefinition(name: $0, color: $1) }
        _cachedAll = list
        return list
    }

    static func color(named name: String) -> NSColor {
        all.first { $0.name == name }?.color ?? .systemGray
    }

    /// 重命名标签：同步更新设置与所有被标记文件的系统 kMDItemUserTags 扩展属性
    static func renameTag(oldName: String, newName: String) {
        var currentNames = all.map { $0.name }
        if let idx = currentNames.firstIndex(of: oldName) {
            currentNames[idx] = newName
            UserDefaults.standard.set(currentNames, forKey: "FavoriteTagNames")
            UserDefaults(suiteName: "com.apple.finder")?.set(currentNames, forKey: "FavoriteTagNames")
            _cachedAll = nil
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

    /// 在指定文件上替换标签
    static func replaceTag(on url: URL, oldTag: String, newTag: String) {
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey])
            var tags = values.tagNames ?? []
            if let index = tags.firstIndex(of: oldTag) {
                tags[index] = newTag
                try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
            }
        } catch {}
    }

    /// 在指定文件上切换标签（有则移除，无则添加）
    static func toggleTag(on url: URL, tag: String) {
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey])
            var tags = values.tagNames ?? []
            if let index = tags.firstIndex(of: tag) {
                tags.remove(at: index)
            } else {
                tags.append(tag)
            }
            try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
        } catch {}
    }

    /// 侧栏标签行前面的小圆点。
    static func dotImage(color: NSColor, diameter: CGFloat = 11) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4))
            color.setFill()
            path.fill()
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
