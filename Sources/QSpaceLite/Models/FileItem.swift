import AppKit
import UniformTypeIdentifiers

/// 单个文件/目录的不可变快照。一次性取出全部资源属性，避免在排序/绘制时反复访问磁盘。
struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String

    /// 目录（且不是包）才可进入。包（.app 等）按 Finder 习惯当作文件打开。
    var isNavigable: Bool { isDirectory && !isPackage }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .localizedTypeDescriptionKey
    ]
    static let resourceKeySet: Set<URLResourceKey> = Set(resourceKeys)

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { return nil }
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isPackage = values.isPackage ?? false
        self.isSymbolicLink = values.isSymbolicLink ?? false
        self.isHidden = values.isHidden ?? false
        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate ?? .distantPast
        self.created = values.creationDate ?? .distantPast
        self.kind = values.localizedTypeDescription ?? ""
    }

    /// 零磁盘 I/O 快速构造（供高性能搜索引擎直接从内存索引/stat 快照生成 FileItem）。
    init(fastURL url: URL,
         name: String,
         isDirectory: Bool,
         isPackage: Bool,
         isSymbolicLink: Bool = false,
         size: Int64 = 0,
         modified: Date,
         created: Date? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = name.hasPrefix(".")
        self.size = size
        self.modified = modified
        self.created = created ?? modified
        self.kind = IconCache.shared.kindDescription(forName: name, isDirectory: isDirectory, isPackage: isPackage)
    }

    /// 读取目录内容（不递归）。
    static func contents(of directory: URL, showHidden: Bool) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else { return [] }
        return urls.compactMap(FileItem.init(url:))
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}


// MARK: - 附加信息

/// 「所有者」「群组」这类列的取值。
///
/// 这两个属性用 URLResourceValues 取不到（Swift 侧没有对应的键），
/// 只能走 attributesOfItem。这里加了缓存，列表滚动时不会反复读磁盘。
enum FileDetails {

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4000
        return cache
    }()

    /// 读取文件的所有者与所属组。
    static func ownerAndGroup(of url: URL) -> (owner: String, group: String) {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            let parts = (cached as String).components(separatedBy: "\t")
            return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        var owner = ""
        var group = ""
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            owner = attributes[.ownerAccountName] as? String ?? ""
            group = attributes[.groupOwnerAccountName] as? String ?? ""
        }
        cache.setObject("\(owner)\t\(group)" as NSString, forKey: key)
        return (owner, group)
    }
}

// MARK: - 图标缓存

/// 图标按「类型 / 扩展名」缓存（NSCache），同扩展名只取一次 NSWorkspace 图标；
/// 仅 .app 等包和特殊无扩展名文件按路径缓存。避免在表格滚动或网格渲染时反复阻塞主线程读磁盘。
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let kindCache = NSCache<NSString, NSString>()
    private let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private let fileIcon = NSWorkspace.shared.icon(for: .data)

    init() {
        cache.countLimit = 2000
        kindCache.countLimit = 2000
    }

    /// 内存级快速类型描述（避免搜索结果列表为成百上千个结果逐个发起磁盘 resourceValues 查询）。
    func kindDescription(forName name: String, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory && !isPackage {
            return "文件夹"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if isPackage {
            if ext == "app" { return "应用程序" }
            if ext.isEmpty { return "包" }
        }
        guard !ext.isEmpty else { return "文稿" }
        let key = ext as NSString
        if let cached = kindCache.object(forKey: key) {
            return cached as String
        }
        let desc = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) 文件"
        kindCache.setObject(desc as NSString, forKey: key)
        return desc
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isPackage {
            let key = item.url.path as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            cache.setObject(icon, forKey: key)
            return icon
        }

        if item.isDirectory {
            return folderIcon
        }

        let ext = (item.name as NSString).pathExtension.lowercased()
        let key = (ext.isEmpty ? item.name.lowercased() : ext) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let icon: NSImage
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        cache.setObject(icon, forKey: key)
        return icon
    }
}

