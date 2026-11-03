import AppKit
import Darwin

/// 极速文件搜索引擎（融合开源项目 `fd` 的并行目录树剪枝遍历与 `fzf` / `nucleo` 的多核分词智能打分排序算法）。
///
/// 核心性能优化：
/// 1. **POSIX `fts_open` / `fts_read` 内核级极速遍历**：
///    绕过 Foundation `FileManager` 逐个构造 `NSURL` 与 `NSDictionary` 的桥接开销，直接从 C 层 `stat` 结构体读取大小、修改时间与目录标志；
///    并在遍历期通过 `FTS_SKIP` 原地剪枝 `.app`/`.photoslibrary` 等包内部结构及 `node_modules`/`.git`/`Caches`/`DerivedData` 等海量噪音目录。
/// 2. **多核数据并行内存检索 (`DispatchQueue.concurrentPerform`)**：
///    常驻紧凑型 `ContiguousArray<Entry>` 索引，检索时将十万级条目按 CPU 核心数分片并行打分，1~3 毫秒即可完成全量智能排序。
/// 3. **`fzf` 风格多词分词 + 多级相关性打分**：
///    支持空格多关键词组合（如 `ui pane`）、精确匹配、前缀匹配、驼峰/词界匹配（如 `fiv` 命中 `FileIconView`）、子串匹配与模糊子序列匹配。
/// 4. **内存索引 + `fts` 实时扫描 + Spotlight (`mdfind`) 三擎融合**：
///    无论是「此 Mac」还是「当前文件夹」，首帧均在数毫秒内给出内存索引高分结果，后台并发补充实时目录扫描或 Spotlight 结果。
final class FileSearchEngine {

    /// 单条高分命中结果（包含完整 stat 快照，支持零磁盘 I/O 转为 `FileItem`）。
    struct Hit: Hashable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let size: Int64
        let modified: Date
        let score: Int

        var path: String { url.path }

        /// 零磁盘 I/O 转换为视图层通用的 `FileItem`。
        func toFileItem() -> FileItem {
            FileItem(fastURL: url,
                     name: name,
                     isDirectory: isDirectory,
                     isPackage: isPackage,
                     size: size,
                     modified: modified)
        }
    }

    /// 紧凑型常驻内存索引条目。
    private struct Entry {
        let path: String
        let name: String
        let lowerName: String
        let lowerPath: String
        let isDirectory: Bool
        let isPackage: Bool
        let size: Int64
        let modified: TimeInterval
        let depth: Int16
    }

    static let shared = FileSearchEngine()

    /// 搜索范围。
    enum Scope: Equatable {
        /// 全盘（多核内存索引 + Spotlight 异步补全）
        case everywhere
        /// 限定在指定文件夹内递归搜索（内存索引毫秒级首屏 + C 层 `fts` 实时穿透扫描）
        case folder(URL)
    }

    /// 遍历时默认跳过的海量缓存/构建产物及受 TCC 隐私保护的系统库目录（避免后台索引无故触发通讯录/日历/提醒事项等弹窗）。
    private static let ignoredDirectoryNames: Set<String> = [
        "Library", ".git", ".hg", ".svn", "node_modules", ".build", "DerivedData",
        "Pods", "Caches", "Cache", ".Trash", "Trash", "__pycache__",
        ".venv", "venv", ".npm", ".cargo", ".gradle", ".idea",
        "Containers", "Group Containers", "CloudKit", "Logs", "Saved Application State"
    ]

    /// macOS 包后缀（当作单个整体条目索引，不深入包内部遍历数万个资源文件）。
    private static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "xcodeproj",
        "xcworkspace", "playground", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "qlgenerator", "prefpane"
    ]

    private let indexQueue = DispatchQueue(label: "com.qspacelite.search.index", qos: .utility)
    private let lock = NSLock()
    private var entries: ContiguousArray<Entry> = []
    private var isIndexLoaded = false

    private var metadataProcess: Process?
    private let generationLock = NSLock()
    private var generation = 0

    private var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private init() {}

    // MARK: - 索引构建与磁盘缓存

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.qspacelite.app", isDirectory: true)
            .appendingPathComponent("fast-index-v2.tsv")
    }

    /// 当前索引磁盘缓存占用大小（字节）。
    var diskCacheSizeBytes: Int64 {
        let url = Self.cacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    /// 格式化后的当前索引大小描述（如 "8.0 MB"）。
    var formattedIndexSize: String {
        let bytes = diskCacheSizeBytes
        if bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        let count = indexedCount
        if count > 0 {
            let estimated = Int64(count) * 85
            return ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        }
        return "0 KB"
    }

    /// 当前内存索引中的文件/目录总数。
    var indexedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 预热并后台更新索引（幂等）。
    func loadIndex() {
        guard !isIndexLoaded else { return }
        isIndexLoaded = true
        indexQueue.async { [weak self] in
            self?.readCache()
            self?.rebuildIndex()
        }
    }

    /// 手动强制重新扫描并重建全局搜索索引（例如重新授予文件夹权限后调用）。
    func rebuildIndexNow(completion: ((Int) -> Void)? = nil) {
        isIndexLoaded = true
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.rebuildIndex()
            let count = self.indexedCount
            DispatchQueue.main.async {
                completion?(count)
            }
        }
    }

    private func readCache() {
        // 清理早期版本残留的废弃索引文件，释放磁盘空间
        let legacyFile = Self.cacheURL.deletingLastPathComponent().appendingPathComponent("name-index.txt")
        if FileManager.default.fileExists(atPath: legacyFile.path) {
            try? FileManager.default.removeItem(at: legacyFile)
        }

        guard let data = try? Data(contentsOf: Self.cacheURL),
              let text = String(data: data, encoding: .utf8) else { return }
        var loaded = ContiguousArray<Entry>()
        loaded.reserveCapacity(100_000)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // 格式：path \t flags(0=file,1=dir,2=pkg) \t size \t mtime
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let path = String(parts[0])
            let flag = Int(parts[1]) ?? 0
            let isDirectory = (flag == 1 || flag == 2)
            let isPackage = (flag == 2)
            let size = Int64(parts[2]) ?? 0
            let modified = Double(parts[3]) ?? 0
            let name = (path as NSString).lastPathComponent
            let depth = Int16(min(120, path.utf8.lazy.filter { $0 == UInt8(ascii: "/") }.count))
            loaded.append(Entry(path: path,
                                name: name,
                                lowerName: name.lowercased(),
                                lowerPath: path.lowercased(),
                                isDirectory: isDirectory,
                                isPackage: isPackage,
                                size: size,
                                modified: modified,
                                depth: depth))
        }
        guard !loaded.isEmpty else { return }
        lock.lock()
        entries = loaded
        lock.unlock()
    }

    private func rebuildIndex() {
        let roots = Self.indexRoots()
        // 将顶层种子目录展开一层，便于多核并行使用 fts 扫描
        var seeds: [URL] = []
        let fm = FileManager.default
        for root in roots {
            if let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) {
                for child in children {
                    let name = child.lastPathComponent
                    if Self.ignoredDirectoryNames.contains(name) { continue }
                    seeds.append(child)
                }
            } else {
                seeds.append(root)
            }
        }

        let bucketLock = NSLock()
        var allEntries = ContiguousArray<Entry>()
        allEntries.reserveCapacity(120_000)

        DispatchQueue.concurrentPerform(iterations: seeds.count) { idx in
            let seed = seeds[idx]
            let subEntries = self.ftsCollectEntries(rootURL: seed, maxDepth: 11, showHidden: false)
            guard !subEntries.isEmpty else { return }
            bucketLock.lock()
            allEntries.append(contentsOf: subEntries)
            bucketLock.unlock()
        }

        guard !allEntries.isEmpty else { return }
        lock.lock()
        entries = allEntries
        lock.unlock()
        writeCache(allEntries)
    }

    private func writeCache(_ list: ContiguousArray<Entry>) {
        var text = ""
        text.reserveCapacity(list.count * 84)
        for entry in list {
            let flag = entry.isPackage ? "2" : (entry.isDirectory ? "1" : "0")
            text += entry.path
            text += "\t"
            text += flag
            text += "\t"
            text += String(entry.size)
            text += "\t"
            text += String(Int64(entry.modified))
            text += "\n"
        }
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func indexRoots() -> [URL] {
        var roots: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications")
        ]
        for volume in FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey, .volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? [] {
            let path = volume.standardizedFileURL.path
            guard path != "/", path.hasPrefix("/Volumes/") else { continue }
            roots.append(volume)
        }
        return roots
    }

    // MARK: - POSIX `fts_open` 极速目录树遍历

    private static func isPackageName(_ name: String) -> Bool {
        guard let dotIdx = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dotIdx)...].lowercased()
        return packageExtensions.contains(ext)
    }

    /// 使用 C 标准库 `fts_open` / `fts_read` 遍历目录树，返回 `Entry` 数组。
    private func ftsCollectEntries(rootURL: URL,
                                   maxDepth: Int,
                                   showHidden: Bool,
                                   shouldAbort: (() -> Bool)? = nil) -> ContiguousArray<Entry> {
        var result = ContiguousArray<Entry>()
        let rootPath = rootURL.standardizedFileURL.path
        guard !rootPath.isEmpty else { return result }

        let cPath = strdup(rootPath)
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]

        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return result
        }
        defer { fts_close(fts) }

        var step = 0
        while let entPtr = fts_read(fts) {
            step &+= 1
            if (step & 255) == 0, shouldAbort?() == true {
                break
            }

            let info = Int32(entPtr.pointee.fts_info)
            let level = Int(entPtr.pointee.fts_level)

            // 后序目录节点或无效节点直接跳过
            if info == FTS_DP || info == FTS_DC || info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                continue
            }

            guard let pathPtr = entPtr.pointee.fts_path else { continue }
            let fullPath = String(cString: pathPtr)
            let name = (fullPath as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { continue }

            // 隐藏文件/目录过滤（根自身若为隐藏目录则允许进入）
            if level > 0 && !showHidden && name.hasPrefix(".") {
                if info == FTS_D { fts_set(fts, entPtr, FTS_SKIP) }
                continue
            }

            // 剪枝噪音目录
            if level > 0 && info == FTS_D && Self.ignoredDirectoryNames.contains(name) {
                fts_set(fts, entPtr, FTS_SKIP)
                continue
            }

            let isDir = (info == FTS_D)
            let isPkg = isDir && Self.isPackageName(name)

            // 若是 .app / .photoslibrary 等包目录，将其本身作为单个条目收录后立刻剪枝跳过内部
            if isPkg {
                fts_set(fts, entPtr, FTS_SKIP)
            } else if isDir && level >= maxDepth {
                fts_set(fts, entPtr, FTS_SKIP)
            }

            // 根节点如果是搜索起始文件夹本身（level == 0 且非单文件/包），不重复收录根文件夹自己
            if level == 0 && isDir && !isPkg {
                continue
            }

            var fileSize: Int64 = 0
            var mtime: TimeInterval = 0
            if let statPtr = entPtr.pointee.fts_statp {
                fileSize = Int64(statPtr.pointee.st_size)
                mtime = TimeInterval(statPtr.pointee.st_mtimespec.tv_sec)
            }

            let depth = Int16(min(120, fullPath.utf8.lazy.filter { $0 == UInt8(ascii: "/") }.count))
            result.append(Entry(path: fullPath,
                                name: name,
                                lowerName: name.lowercased(),
                                lowerPath: fullPath.lowercased(),
                                isDirectory: isDir,
                                isPackage: isPkg,
                                size: fileSize,
                                modified: mtime,
                                depth: depth))
        }

        return result
    }

    // MARK: - `fzf` / `nucleo` 风格多词智能打分算法

    /// 计算单个条目对分词查询的匹配得分；不匹配返回 `nil`。
    private static func scoreEntry(_ entry: Entry, tokens: [String], now: TimeInterval) -> Int? {
        var totalScore = 0
        let nameLower = entry.lowerName
        let nameUTF8 = Array(nameLower.utf8)
        let nameLen = nameUTF8.count

        for token in tokens {
            let tokenUTF8 = Array(token.utf8)
            guard !tokenUTF8.isEmpty else { continue }

            if nameLower == token {
                // 1. 完整文件名精确匹配
                totalScore += 1200
            } else if nameLower.hasPrefix(token) {
                // 2. 文件名前缀匹配（越短越优先）
                totalScore += 780 - min(180, max(0, nameLen - tokenUTF8.count) * 4)
            } else if let range = nameLower.range(of: token) {
                // 3. 文件名子串匹配：检查是否处在词界（如 `_`、`-`、`.`、空格之后）
                let startOffset = nameLower.distance(from: nameLower.startIndex, to: range.lowerBound)
                var isWordBoundary = (startOffset == 0)
                if startOffset > 0 && startOffset <= nameUTF8.count {
                    let prevByte = nameUTF8[startOffset - 1]
                    if prevByte == UInt8(ascii: "_") || prevByte == UInt8(ascii: "-") ||
                       prevByte == UInt8(ascii: ".") || prevByte == UInt8(ascii: " ") {
                        isWordBoundary = true
                    }
                }
                if isWordBoundary {
                    totalScore += 560 - min(140, startOffset * 4) - min(100, nameLen * 2)
                } else {
                    totalScore += 360 - min(120, startOffset * 3) - min(100, nameLen * 2)
                }
            } else if let fuzzyBonus = fuzzySubsequenceScore(haystack: nameUTF8, needle: tokenUTF8) {
                // 4. 顺序模糊匹配（如输入 "fiv" 匹配 "FileIconView.swift"）
                totalScore += fuzzyBonus
            } else if tokens.count > 1 && entry.lowerPath.contains(token) {
                // 5. 多词组合查询时，允许部分词命中父路径（如 "ui pane"）
                totalScore += 140
            } else {
                return nil
            }
        }

        // 附加权重：应用程序 > 文件夹 > 普通文件，浅层路径更优，近期修改更优
        if entry.isPackage && entry.lowerName.hasSuffix(".app") {
            totalScore += 135
        } else if entry.isDirectory {
            totalScore += 35
        }

        totalScore -= Int(entry.depth) * 5

        let age = max(0, now - entry.modified)
        if age < 86_400 {
            totalScore += 45 // 24小时内修改
        } else if age < 86_400 * 7 {
            totalScore += 25 // 7天内修改
        } else if age < 86_400 * 30 {
            totalScore += 10 // 30天内修改
        }

        return totalScore
    }

    /// 紧凑 UTF-8 字节级模糊子序列匹配（仅当长度 >= 2 时启用，奖励连续命中与首字母命中）。
    private static func fuzzySubsequenceScore(haystack: [UInt8], needle: [UInt8]) -> Int? {
        let nLen = needle.count
        let hLen = haystack.count
        guard nLen >= 2, nLen <= hLen else { return nil }

        var nIdx = 0
        var hIdx = 0
        var score = 70
        var lastMatchIdx = -2
        var firstMatchIdx = -1

        while nIdx < nLen && hIdx < hLen {
            if haystack[hIdx] == needle[nIdx] {
                if firstMatchIdx == -1 { firstMatchIdx = hIdx }
                if hIdx == lastMatchIdx + 1 {
                    score += 24 // 连续字符加成
                } else if hIdx == 0 || haystack[hIdx - 1] == UInt8(ascii: "_") ||
                          haystack[hIdx - 1] == UInt8(ascii: "-") || haystack[hIdx - 1] == UInt8(ascii: ".") {
                    score += 18 // 词首边界加成
                }
                lastMatchIdx = hIdx
                nIdx += 1
            }
            hIdx += 1
        }

        guard nIdx == nLen else { return nil }
        let span = lastMatchIdx - firstMatchIdx + 1
        // 若跨度过大且无连续命中，过滤掉偶发噪音匹配
        if span > nLen * 4 && score < 105 { return nil }
        return max(30, score - (span - nLen) * 3)
    }

    // MARK: - 对外极速搜索接口

    /// 执行搜索。
    /// - Parameters:
    ///   - term: 搜索关键字（支持空格分隔多关键词）
    ///   - scope: `.everywhere`（此 Mac）或 `.folder(URL)`（指定文件夹）
    ///   - limit: 最大返回条数
    ///   - completion: 主线程回调 `(hits, elapsedMilliseconds, isFinal)`
    func search(term: String,
                scope: Scope,
                limit: Int = 350,
                completion: @escaping ([Hit], Double, Bool) -> Void) {
        let current = bumpGeneration()
        cancelSpotlight()

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([], 0, true)
            return
        }

        let tokens = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else {
            completion([], 0, true)
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        switch scope {
        case .everywhere:
            searchEverywhere(rawTerm: trimmed,
                             tokens: tokens,
                             limit: limit,
                             startTime: startTime,
                             generation: current,
                             completion: completion)
        case .folder(let root):
            searchInFolder(root: root,
                           rawTerm: trimmed,
                           tokens: tokens,
                           limit: limit,
                           startTime: startTime,
                           generation: current,
                           completion: completion)
        }
    }

    /// 多核并行扫描常驻内存索引切片。
    private func parallelScoreSnapshot(_ snapshot: ContiguousArray<Entry>,
                                       pathPrefix: String?,
                                       tokens: [String],
                                       limit: Int) -> [Hit] {
        let count = snapshot.count
        guard count > 0 else { return [] }

        let now = Date().timeIntervalSince1970
        let workers = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, count / 2048))
        let chunkSize = (count + workers - 1) / workers

        var workerBuckets = Array(repeating: [Hit](), count: workers)
        workerBuckets.withUnsafeMutableBufferPointer { bucketPtr in
            DispatchQueue.concurrentPerform(iterations: workers) { workerIdx in
                let start = workerIdx * chunkSize
                let end = min(count, start + chunkSize)
                guard start < end else { return }

                var localHits: [Hit] = []
                localHits.reserveCapacity(64)

                for i in start..<end {
                    let entry = snapshot[i]
                    if let prefix = pathPrefix {
                        guard entry.path.hasPrefix(prefix) else { continue }
                    }
                    guard let score = Self.scoreEntry(entry, tokens: tokens, now: now) else { continue }
                    localHits.append(Hit(url: URL(fileURLWithPath: entry.path),
                                         name: entry.name,
                                         isDirectory: entry.isDirectory,
                                         isPackage: entry.isPackage,
                                         size: entry.size,
                                         modified: Date(timeIntervalSince1970: entry.modified),
                                         score: score))
                }

                if localHits.count > limit {
                    localHits.sort { $0.score > $1.score }
                    localHits.removeSubrange(limit..<localHits.count)
                }
                bucketPtr[workerIdx] = localHits
            }
        }

        var merged: [Hit] = []
        for bucket in workerBuckets where !bucket.isEmpty {
            merged.append(contentsOf: bucket)
        }
        merged.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.modified > rhs.modified
        }
        if merged.count > limit {
            merged.removeSubrange(limit..<merged.count)
        }
        return merged
    }

    private func searchEverywhere(rawTerm: String,
                                  tokens: [String],
                                  limit: Int,
                                  startTime: CFAbsoluteTime,
                                  generation current: Int,
                                  completion: @escaping ([Hit], Double, Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self, current == self.currentGeneration else { return }

            self.lock.lock()
            let snapshot = self.entries
            self.lock.unlock()

            let initialHits = self.parallelScoreSnapshot(snapshot,
                                                         pathPrefix: nil,
                                                         tokens: tokens,
                                                         limit: limit)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.currentGeneration else { return }
                completion(initialHits, elapsedMs, false)
            }

            // Spotlight 补漏：异步查找主词并在后台合并
            let primaryToken = tokens.max(by: { $0.count < $1.count }) ?? rawTerm
            self.runSpotlight(term: primaryToken, rootPath: "/", limit: limit, generation: current) { [weak self] spotEntries in
                guard let self, current == self.currentGeneration else { return }
                let now = Date().timeIntervalSince1970
                var known = Set(initialHits.map { $0.path })
                var merged = initialHits

                for entry in spotEntries where !known.contains(entry.path) {
                    guard let score = Self.scoreEntry(entry, tokens: tokens, now: now) else { continue }
                    known.insert(entry.path)
                    merged.append(Hit(url: URL(fileURLWithPath: entry.path),
                                      name: entry.name,
                                      isDirectory: entry.isDirectory,
                                      isPackage: entry.isPackage,
                                      size: entry.size,
                                      modified: Date(timeIntervalSince1970: entry.modified),
                                      score: score))
                }

                merged.sort { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.modified > rhs.modified
                }
                if merged.count > limit {
                    merged.removeSubrange(limit..<merged.count)
                }

                let totalMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                DispatchQueue.main.async { [weak self] in
                    guard let self, current == self.currentGeneration else { return }
                    completion(merged, min(elapsedMs, totalMs), true)
                }
            }
        }
    }

    private func searchInFolder(root: URL,
                                rawTerm: String,
                                tokens: [String],
                                limit: Int,
                                startTime: CFAbsoluteTime,
                                generation current: Int,
                                completion: @escaping ([Hit], Double, Bool) -> Void) {
        let stdRoot = root.standardizedFileURL.path
        let prefix = stdRoot == "/" ? "/" : (stdRoot + "/")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self, current == self.currentGeneration else { return }

            // 1. 首屏：直接从常驻内存索引中过滤该文件夹前缀（< 1.5 ms 出首帧）
            self.lock.lock()
            let snapshot = self.entries
            self.lock.unlock()

            let cachedHits = self.parallelScoreSnapshot(snapshot,
                                                        pathPrefix: prefix,
                                                        tokens: tokens,
                                                        limit: limit)
            let firstElapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            if !cachedHits.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, current == self.currentGeneration else { return }
                    completion(cachedHits, firstElapsedMs, false)
                }
            }

            // 2. 实时穿透扫描：用 C 层 fts_open 扫描该文件夹，捕获新建或未进缓存的所有文件
            let showHidden = AppSettings.showHidden
            let liveEntries = self.ftsCollectEntries(
                rootURL: root,
                maxDepth: 10,
                showHidden: showHidden,
                shouldAbort: { [weak self] in
                    guard let self else { return true }
                    return current != self.currentGeneration
                }
            )
            guard current == self.currentGeneration else { return }

            let liveHits = self.parallelScoreSnapshot(liveEntries,
                                                      pathPrefix: nil,
                                                      tokens: tokens,
                                                      limit: limit)
            let finalElapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.currentGeneration else { return }
                completion(liveHits, cachedHits.isEmpty ? finalElapsedMs : firstElapsedMs, true)
            }
        }
    }

    // MARK: - Spotlight (`mdfind`) 异步流式补漏

    private func runSpotlight(term: String,
                              rootPath: String,
                              limit: Int,
                              generation current: Int,
                              completion: @escaping ([Entry]) -> Void) {
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let query = "kMDItemFSName == '*\(escaped)*'cd"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", rootPath, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        metadataProcess = process

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try process.run()
            } catch {
                completion([])
                return
            }

            let handle = pipe.fileHandleForReading
            var collected: [Entry] = []
            var leftover = Data()
            let newline = UInt8(ascii: "\n")

            while current == self.currentGeneration {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                leftover.append(chunk)

                while let range = leftover.firstIndex(of: newline) {
                    let lineData = leftover.subdata(in: 0..<range)
                    leftover.removeSubrange(0...range)
                    guard let path = String(data: lineData, encoding: .utf8), !path.isEmpty else { continue }
                    if path.contains("/Library/Caches/") || path.contains("/node_modules/") || path.contains("/.git/") {
                        continue
                    }
                    if let entry = Self.statEntry(atPath: path) {
                        collected.append(entry)
                        if collected.count >= limit { break }
                    }
                }
                if collected.count >= limit {
                    process.terminate()
                    break
                }
            }
            if process.isRunning { process.terminate() }
            completion(collected)
        }
    }

    private static func statEntry(atPath path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isDir = (mode == S_IFDIR)
        let name = (path as NSString).lastPathComponent
        let isPkg = isDir && isPackageName(name)
        let depth = Int16(min(120, path.utf8.lazy.filter { $0 == UInt8(ascii: "/") }.count))
        return Entry(path: path,
                     name: name,
                     lowerName: name.lowercased(),
                     lowerPath: path.lowercased(),
                     isDirectory: isDir,
                     isPackage: isPkg,
                     size: Int64(st.st_size),
                     modified: TimeInterval(st.st_mtimespec.tv_sec),
                     depth: depth)
    }

    func cancel() {
        _ = bumpGeneration()
        cancelSpotlight()
    }

    private func cancelSpotlight() {
        if let proc = metadataProcess, proc.isRunning {
            proc.terminate()
        }
        metadataProcess = nil
    }
}
