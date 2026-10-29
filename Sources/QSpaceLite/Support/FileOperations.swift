import AppKit

// MARK: - 磁盘文件变动全局通知

extension Notification.Name {
    /// 当有文件在磁盘上被移动、复制或删除后触发，以便各窗格与视图及时刷新
    static let filesDidChangeOnDisk = Notification.Name("MapleFilesDidChangeOnDiskNotification")
    /// 当用户切换是否显示隐藏文件设置时触发
    static let showHiddenFilesDidChange = Notification.Name("MapleShowHiddenFilesDidChangeNotification")
}

// MARK: - 拖拽项生成辅助工具

enum FileDragHelper {

    /// 为给定的文件 URL 列表生成原生拖拽项。
    /// - Parameters:
    ///   - urls: 选中的文件 URL
    ///   - pointInView: 鼠标在当前视图内的坐标
    /// - Returns: 可供 beginDraggingSession 使用的 NSDraggingItem 数组
    static func createDraggingItems(for urls: [URL], at pointInView: NSPoint) -> [NSDraggingItem] {
        guard !urls.isEmpty else { return [] }
        var items: [NSDraggingItem] = []
        let count = urls.count

        for (index, url) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)

            if index == 0 {
                // 主视觉：在鼠标指针下方显示带轻微阴影的文件图标；若为多选则附带数字角标
                let iconSize: CGFloat = 36
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: iconSize, height: iconSize)

                let imageSize: NSSize
                let dragImage: NSImage

                if count > 1 {
                    let badgeText = "\(count)" as NSString
                    let font = NSFont.systemFont(ofSize: 11, weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.white
                    ]
                    let textSize = badgeText.size(withAttributes: attrs)
                    let badgeW = max(textSize.width + 12, 20)
                    let badgeH: CGFloat = 18

                    imageSize = NSSize(width: iconSize + badgeW - 6, height: iconSize + 6)
                    dragImage = NSImage(size: imageSize)
                    dragImage.lockFocus()

                    icon.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))

                    let badgeRect = NSRect(x: iconSize - 8, y: iconSize - 14, width: badgeW, height: badgeH)
                    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2)
                    NSColor.systemRed.setFill()
                    badgePath.fill()

                    let textPoint = NSPoint(
                        x: badgeRect.minX + (badgeW - textSize.width) / 2,
                        y: badgeRect.minY + (badgeH - textSize.height) / 2
                    )
                    badgeText.draw(at: textPoint, withAttributes: attrs)
                    dragImage.unlockFocus()
                } else {
                    imageSize = NSSize(width: iconSize, height: iconSize)
                    dragImage = icon
                }

                let frame = NSRect(
                    x: pointInView.x - iconSize / 2,
                    y: pointInView.y - iconSize / 2,
                    width: imageSize.width,
                    height: imageSize.height
                )
                item.setDraggingFrame(frame, contents: dragImage)
            } else {
                // 其余副选项目分配微小尺寸占位，确保剪贴板持有完整文件集合
                item.setDraggingFrame(NSRect(x: pointInView.x, y: pointInView.y, width: 1, height: 1), contents: NSImage())
            }

            items.append(item)
        }
        return items
    }
}

// MARK: - 跨窗格 / 跨视图文件传输核心

enum FileOperations {

    /// 从拖拽粘贴板中读取有效的本地文件 URL 列表
    static func readURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        if let paths = info.draggingPasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    /// 判断拖拽放置时应当复制还是移动：
    /// 1. 若用户在拖拽时按住了 Option 键，强制执行复制；
    /// 2. 若拖拽源来自外部程序，或者源路径与目标路径跨越不同磁盘卷，执行复制；
    /// 3. 本程序内部在同一卷内拖拽，默认执行移动。
    static func shouldCopy(for info: NSDraggingInfo, destination: URL) -> Bool {
        if NSEvent.modifierFlags.contains(.option) {
            return true
        }
        guard info.draggingSource != nil else {
            // 来自外部应用（如其他程序或访达窗口），安全起见默认复制
            return true
        }
        return false
    }

    /// 在目标目录中生成不重名的文件 URL（若已存在则追加 " 2", " 3" 等）
    static func uniqueURL(for fileName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var idx = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(idx)" : "\(base) \(idx).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            idx += 1
        }
    }

    /// 执行文件移动或复制操作
    /// - Parameters:
    ///   - urls: 待移动或复制的文件 URL 列表
    ///   - destinationDirectory: 目标文件夹
    ///   - isCopy: true 为复制，false 为移动
    /// - Returns: 成功落入目标目录的文件 URL 列表
    @discardableResult
    static func transfer(urls: [URL], to destinationDirectory: URL, isCopy: Bool) -> [URL] {
        var createdURLs: [URL] = []
        let fm = FileManager.default
        let destPath = destinationDirectory.standardizedFileURL.path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        for source in urls {
            let srcPath = source.standardizedFileURL.path

            // 禁止将文件夹移动/复制到自身或其子目录中
            if srcPath == destPath || destPath.hasPrefix(srcPath + "/") {
                continue
            }
            // 若为移动且已经在当前目录下，跳过
            if !isCopy && source.deletingLastPathComponent().standardizedFileURL.path == destPath {
                continue
            }

            let targetName = source.lastPathComponent
            let targetURL = uniqueURL(for: targetName, in: destinationDirectory)

            do {
                if isCopy {
                    try fm.copyItem(at: source, to: targetURL)
                } else {
                    try fm.moveItem(at: source, to: targetURL)
                }
                createdURLs.append(targetURL)
            } catch {
                NSLog("[Maple FileOperations] Transfer failed from \(srcPath) to \(targetURL.path): \(error)")
            }
        }
        return createdURLs
    }

    /// 统一校验并执行文件重命名
    /// - Parameters:
    ///   - item: 待重命名的文件模型
    ///   - newName: 用户输入的新名称
    ///   - window: 宿主窗口（展示弹窗警报）
    ///   - onSuccess: 重命名成功后的回调（提供 oldURL 与 newURL）
    /// - Returns: 是否重命名成功
    @discardableResult
    static func performRename(item: FileItem, newName: String, window: NSWindow? = nil, onSuccess: (URL, URL) -> Void) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == item.name {
            return false
        }

        // 1. 非法字符校验（斜杠与冒号）
        if trimmed.contains("/") || trimmed.contains(":") {
            let alert = NSAlert()
            alert.messageText = "名称中不能包含冒号“:”或斜杠“/”"
            alert.informativeText = "请选取其他名称。"
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        // 2. 保留名称校验（单独的点或点点）
        if trimmed == "." || trimmed == ".." {
            let alert = NSAlert()
            alert.messageText = "你不能使用以点“.”开头的保留名称"
            alert.informativeText = "“\(trimmed)”已被系统保留。请选取其他名称。"
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        // 3. 点前缀隐藏文件确认与自动开启显示隐藏文件提示
        let oldName = item.name
        if trimmed.hasPrefix(".") && !oldName.hasPrefix(".") {
            if !AppSettings.showHidden {
                let alert = NSAlert()
                alert.messageText = "确定要使用以“.”开头的名称吗？"
                alert.informativeText = "以“.”开头的名称是系统保留的隐藏文件。由于当前未开启“显示隐藏文件”，重命名后此文件将不再显示。\n\n是否开启“显示隐藏文件”以保持此文件可见？"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "开启显示并重命名")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "仍然重命名")

                let res = alert.runModal()
                if res == .alertFirstButtonReturn {
                    AppSettings.showHidden = true
                } else if res == .alertSecondButtonReturn {
                    return false
                }
                // alertThirdButtonReturn: 保持关闭隐藏文件，直接重命名
            }
        }

        // 4. 重名校验
        let oldURL = item.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if newURL.path == oldURL.path { return false }

        if FileManager.default.fileExists(atPath: newURL.path) {
            let alert = NSAlert()
            alert.messageText = "名称“\(trimmed)”已被使用"
            alert.informativeText = "请选取其他名称。"
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        // 5. 执行文件移动（重命名）
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            onSuccess(oldURL, newURL)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
