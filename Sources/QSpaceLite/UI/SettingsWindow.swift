import AppKit

/// 设置与权限管理窗口控制器（⌘, 或顶部工具栏齿轮按钮打开）。
///
/// 核心能力：
/// 1. **实时检测文件夹与磁盘权限状态**（桌面、文稿、下载、完全磁盘访问权限）。
/// 2. **一键重置 TCC 拒绝记录并重新触发系统授权弹窗**：
///    解决用户误点「不允许 (Don't Allow)」后 macOS 不再弹窗的问题（底层调用 `/usr/bin/tccutil reset` 并主动触发目录访问）。
/// 3. **一键跳转系统隐私设置**与**手动重建全局搜索索引**。
/// 4. **常规与显示设置**（隐藏文件、图标大小、列表行高）。
final class SettingsWindowController: NSObject, NSWindowDelegate {

    var onSettingsChanged: (() -> Void)?
    var onIconSizeChanged: ((CGFloat) -> Void)?
    var onRowHeightChanged: ((CGFloat) -> Void)?

    private let window: NSWindow
    private var permissionRows: [PermissionItemRow] = []
    private let statusBanner = NSTextField(labelWithString: "")
    private let indexStatusLabel = NSTextField(labelWithString: "")
    private let rebuildIndexButton = NSButton()
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "显示以点（.）开头的隐藏文件（⌘⇧.）", target: nil, action: nil)
    private let zebraCheckbox = NSButton(checkboxWithTitle: "在列表视图中显示交替行底色（斑马线）", target: nil, action: nil)
    private let iconSizeSlider = NSSlider()
    private let iconSizeValueLabel = NSTextField(labelWithString: "")
    private let rowHeightSlider = NSSlider()
    private let rowHeightValueLabel = NSTextField(labelWithString: "")

    struct PermissionTarget {
        let id: String
        let title: String
        let subtitle: String
        let url: URL
        let tccService: String
        let isFullDisk: Bool
    }

    private lazy var targets: [PermissionTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            PermissionTarget(
                id: "desktop",
                title: "桌面文件夹 (Desktop)",
                subtitle: "~/Desktop",
                url: home.appendingPathComponent("Desktop"),
                tccService: "SystemPolicyDesktopFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "documents",
                title: "文稿文件夹 (Documents)",
                subtitle: "~/Documents",
                url: home.appendingPathComponent("Documents"),
                tccService: "SystemPolicyDocumentsFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "downloads",
                title: "下载文件夹 (Downloads)",
                subtitle: "~/Downloads",
                url: home.appendingPathComponent("Downloads"),
                tccService: "SystemPolicyDownloadsFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "fulldisk",
                title: "完全磁盘访问权限 (Full Disk Access)",
                subtitle: "允许全局搜索访问受保护目录而无需逐个弹窗",
                url: home.appendingPathComponent("Library/Safari"),
                tccService: "SystemPolicyAllFiles",
                isFullDisk: true
            )
        ]
    }()

    override init() {
        let rect = NSRect(x: 0, y: 0, width: 560, height: 590)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Maple 设置与权限管理"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildUI()
    }

    func show(relativeTo parentWindow: NSWindow?) {
        refreshPermissionStatuses()
        refreshIndexCount()
        syncDisplayControls()

        if let parent = parentWindow {
            let pf = parent.frame
            let wf = window.frame
            let x = pf.midX - wf.width / 2
            let y = pf.midY - wf.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 从「系统设置」切回应用时自动刷新最新权限状态
        refreshPermissionStatuses()
        refreshIndexCount()
    }

    // MARK: - 界面构建

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root

        let mainStack = NSStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = 14
        root.addSubview(mainStack)

        // 1. 权限说明与一键重置卡片
        let permSection = makeCardSection(
            title: "文件夹与搜索权限管理",
            subtitle: "若您在系统权限弹窗中误点了「不允许」，点击下方「重置并重新请求权限」即可清除拒绝记录并立即重新弹出系统授权框。"
        )

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for target in targets {
            let row = PermissionItemRow(target: target)
            row.onAction = { [weak self] t in
                self?.requestSinglePermission(t)
            }
            permissionRows.append(row)
            rowsStack.addArrangedSubview(row)
        }
        permSection.contentStack.addArrangedSubview(rowsStack)

        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8

        let resetAllBtn = NSButton(title: "重置并重新弹出授权框", target: self, action: #selector(resetAndRepromptAllPermissions))
        resetAllBtn.bezelStyle = .rounded
        resetAllBtn.keyEquivalent = "\r"

        let openFilesPrivacyBtn = NSButton(title: "系统设置：文件与文件夹", target: self, action: #selector(openFilesAndFoldersPrivacy))
        openFilesPrivacyBtn.bezelStyle = .rounded

        let openFullDiskBtn = NSButton(title: "系统设置：完全磁盘访问", target: self, action: #selector(openFullDiskAccessPrivacy))
        openFullDiskBtn.bezelStyle = .rounded

        actionBar.addArrangedSubview(resetAllBtn)
        actionBar.addArrangedSubview(openFilesPrivacyBtn)
        actionBar.addArrangedSubview(openFullDiskBtn)
        permSection.contentStack.addArrangedSubview(actionBar)

        statusBanner.font = .systemFont(ofSize: 11.5)
        statusBanner.textColor = .secondaryLabelColor
        statusBanner.stringValue = "提示：重置权限后，系统会依次弹出“桌面”、“文稿”、“下载”访问请求，请点击「允许」。"
        permSection.contentStack.addArrangedSubview(statusBanner)

        mainStack.addArrangedSubview(permSection.container)

        // 2. 全局搜索引擎索引卡片
        let searchSection = makeCardSection(
            title: "全局搜索引擎",
            subtitle: "重新授予文件夹权限后，可点击右侧按钮立即重新扫描并更新常驻内存索引。"
        )

        let searchRow = NSStackView()
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 10

        indexStatusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        indexStatusLabel.textColor = .labelColor
        indexStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rebuildIndexButton.title = "立即重建搜索索引"
        rebuildIndexButton.bezelStyle = .rounded
        rebuildIndexButton.target = self
        rebuildIndexButton.action = #selector(rebuildSearchIndexAction)

        searchRow.addArrangedSubview(indexStatusLabel)
        searchRow.addArrangedSubview(rebuildIndexButton)
        searchSection.contentStack.addArrangedSubview(searchRow)

        mainStack.addArrangedSubview(searchSection.container)

        // 3. 常规与视图显示选项卡片
        let displaySection = makeCardSection(
            title: "常规与显示设置",
            subtitle: nil
        )

        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(hiddenToggled)
        hiddenCheckbox.font = .systemFont(ofSize: 12.5)
        displaySection.contentStack.addArrangedSubview(hiddenCheckbox)

        zebraCheckbox.target = self
        zebraCheckbox.action = #selector(zebraToggled)
        zebraCheckbox.font = .systemFont(ofSize: 12.5)
        displaySection.contentStack.addArrangedSubview(zebraCheckbox)

        // 图标尺寸滑块
        let iconRow = makeSliderRow(
            label: "图标视图尺寸",
            slider: iconSizeSlider,
            valueLabel: iconSizeValueLabel,
            min: 48,
            max: 128,
            action: #selector(iconSliderChanged)
        )
        displaySection.contentStack.addArrangedSubview(iconRow)

        // 列表行高滑块
        let listRow = makeSliderRow(
            label: "列表视图行高",
            slider: rowHeightSlider,
            valueLabel: rowHeightValueLabel,
            min: 20,
            max: 36,
            action: #selector(rowHeightSliderChanged)
        )
        displaySection.contentStack.addArrangedSubview(listRow)

        mainStack.addArrangedSubview(displaySection.container)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])
    }

    private func makeCardSection(title: String, subtitle: String?) -> (container: NSView, contentStack: NSStackView) {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        box.addSubview(stack)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleField.textColor = .labelColor
        stack.addArrangedSubview(titleField)

        if let subtitle, !subtitle.isEmpty {
            let subField = NSTextField(wrappingLabelWithString: subtitle)
            subField.font = .systemFont(ofSize: 11.5)
            subField.textColor = .secondaryLabelColor
            stack.addArrangedSubview(subField)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)
        ])

        return (box, stack)
    }

    private func makeSliderRow(label: String,
                               slider: NSSlider,
                               valueLabel: NSTextField,
                               min: Double,
                               max: Double,
                               action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let nameField = NSTextField(labelWithString: label)
        nameField.font = .systemFont(ofSize: 12.5)
        nameField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        row.addArrangedSubview(nameField)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)
        return row
    }

    // MARK: - 权限检测与一键重新请求

    /// 检查某个目录当前是否可读。
    private func checkAccess(for target: PermissionTarget) -> Bool {
        let path = target.url.path
        if target.isFullDisk {
            // 检测 Safari 或 TimeMachine 等受完全磁盘访问保护的目录是否可读
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let probes = [
                "\(home)/Library/Safari",
                "\(home)/Library/Mail",
                "/Library/Application Support/com.apple.TCC"
            ]
            for probe in probes where FileManager.default.fileExists(atPath: probe) {
                if (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil {
                    return true
                }
            }
            return false
        }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    func refreshPermissionStatuses() {
        for (idx, target) in targets.enumerated() where idx < permissionRows.count {
            let granted = checkAccess(for: target)
            permissionRows[idx].updateStatus(granted: granted)
        }
    }

    /// 针对单个文件夹重置 TCC 记录并立即触发访问弹窗。
    private func requestSinglePermission(_ target: PermissionTarget) {
        if target.isFullDisk {
            openFullDiskAccessPrivacy()
            return
        }

        resetTCC(service: target.tccService)
        resetTCC(service: "All")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 主动列举该目录内容以触发 macOS 系统授权弹窗
            _ = try? FileManager.default.contentsOfDirectory(atPath: target.url.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let self else { return }
                self.refreshPermissionStatuses()
                self.onSettingsChanged?()
                let granted = self.checkAccess(for: target)
                if granted {
                    self.statusBanner.textColor = .systemGreen
                    self.statusBanner.stringValue = "✓「\(target.title)」权限已成功开启！正在更新搜索索引…"
                    self.rebuildSearchIndexAction()
                } else {
                    self.statusBanner.textColor = .systemOrange
                    self.statusBanner.stringValue = "若系统未弹出询问框，请点击「系统设置：文件与文件夹」手动勾选开启。"
                }
            }
        }
    }

    /// 一键重置所有 TCC 权限记录，并依次访问桌面、文稿、下载以立即重新弹出系统授权框。
    @objc private func resetAndRepromptAllPermissions() {
        statusBanner.textColor = .controlAccentColor
        statusBanner.stringValue = "正在重置权限记录并请求系统重新弹窗…"

        resetTCC(service: "All")
        resetTCC(service: "SystemPolicyDesktopFolder")
        resetTCC(service: "SystemPolicyDocumentsFolder")
        resetTCC(service: "SystemPolicyDownloadsFolder")

        let folderTargets = targets.filter { !$0.isFullDisk }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for t in folderTargets {
                _ = try? FileManager.default.contentsOfDirectory(atPath: t.url.path)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self else { return }
                self.refreshPermissionStatuses()
                self.onSettingsChanged?()
                self.rebuildSearchIndexAction()
                self.statusBanner.textColor = .systemGreen
                self.statusBanner.stringValue = "✓ 已重置权限并重新请求授权！如果已在弹窗中点击允许，全局搜索将自动更新。"
            }
        }
    }

    /// 调用 `/usr/bin/tccutil reset` 清除当前应用的权限拒绝记录。
    private func resetTCC(service: String) {
        var bundleIDs: Set<String> = [
            "com.maple.app",
            "com.workbuddy.maple",
            "com.workbuddy.qspacelite",
            "com.qspacelite.app"
        ]
        if let mainID = Bundle.main.bundleIdentifier, !mainID.isEmpty {
            bundleIDs.insert(mainID)
        }
        for bid in bundleIDs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bid]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    @objc private func openFilesAndFoldersPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFullDiskAccessPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 搜索索引与常规设置

    private func refreshIndexCount() {
        let count = FileSearchEngine.shared.indexedCount
        indexStatusLabel.stringValue = "当前内存索引：\(count) 个文件与文件夹"
    }

    @objc private func rebuildSearchIndexAction() {
        rebuildIndexButton.isEnabled = false
        rebuildIndexButton.title = "正在重建索引…"
        indexStatusLabel.stringValue = "正在扫描已授权目录并重建索引…"

        FileSearchEngine.shared.rebuildIndexNow { [weak self] newCount in
            guard let self else { return }
            self.rebuildIndexButton.isEnabled = true
            self.rebuildIndexButton.title = "立即重建搜索索引"
            self.indexStatusLabel.stringValue = "当前内存索引：\(newCount) 个文件与文件夹（已更新）"
        }
    }

    private func syncDisplayControls() {
        hiddenCheckbox.state = AppSettings.showHidden ? .on : .off
        zebraCheckbox.state = AppSettings.showZebraStripes ? .on : .off
        iconSizeSlider.doubleValue = Double(AppSettings.gridIconSize)
        iconSizeValueLabel.stringValue = "\(Int(AppSettings.gridIconSize)) pt"
        rowHeightSlider.doubleValue = Double(AppSettings.listRowHeight)
        rowHeightValueLabel.stringValue = "\(Int(AppSettings.listRowHeight)) pt"
    }

    @objc private func hiddenToggled() {
        AppSettings.showHidden = (hiddenCheckbox.state == .on)
        onSettingsChanged?()
    }

    @objc private func zebraToggled() {
        AppSettings.showZebraStripes = (zebraCheckbox.state == .on)
    }

    @objc private func iconSliderChanged() {
        let val = CGFloat(iconSizeSlider.doubleValue.rounded())
        AppSettings.gridIconSize = val
        iconSizeValueLabel.stringValue = "\(Int(val)) pt"
        onIconSizeChanged?(val)
    }

    @objc private func rowHeightSliderChanged() {
        let val = CGFloat(rowHeightSlider.doubleValue.rounded())
        AppSettings.listRowHeight = val
        rowHeightValueLabel.stringValue = "\(Int(val)) pt"
        onRowHeightChanged?(val)
    }
}

// MARK: - 单项权限状态行视图

private final class PermissionItemRow: NSView {

    let target: SettingsWindowController.PermissionTarget
    var onAction: ((SettingsWindowController.PermissionTarget) -> Void)?

    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    init(target: SettingsWindowController.PermissionTarget) {
        self.target = target
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4.5
        addSubview(dotView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = target.title

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.stringValue = target.subtitle
        subLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        addSubview(textStack)

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.font = .systemFont(ofSize: 11.5, weight: .medium)
        addSubview(statusBadge)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .inline
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.target = self
        actionButton.action = #selector(buttonClicked)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 9),
            dotView.heightAnchor.constraint(equalToConstant: 9),

            textStack.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusBadge.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateStatus(granted: Bool) {
        if granted {
            dotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusBadge.stringValue = "已授权"
            statusBadge.textColor = .systemGreen
            actionButton.title = target.isFullDisk ? "查看设置" : "重新检测"
        } else {
            dotView.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusBadge.stringValue = target.isFullDisk ? "未开启（可选）" : "未授权 / 已拒绝"
            statusBadge.textColor = .systemOrange
            actionButton.title = target.isFullDisk ? "去开启…" : "重新请求授权"
        }
    }

    @objc private func buttonClicked() {
        onAction?(target)
    }
}
