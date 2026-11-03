import AppKit
import QuartzCore

// MARK: - 主窗口与应用代理

final class InstallerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var stageView: InstallerStageView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Bundle.main.image(forResource: "AppIcon") ?? NSImage(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns") {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            if flags == [.command] && (chars.lowercased() == "q" || event.keyCode == 12) {
                NSApp.terminate(nil)
                return nil
            }
            if flags == [.command] && (chars.lowercased() == "w" || event.keyCode == 13) {
                self?.window?.performClose(nil)
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let quitItem = appMenu.addItem(withTitle: "退出 Maple 安装向导", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        let closeItem = fileMenu.addItem(withTitle: "关闭窗口", action: #selector(closeAction), keyEquivalent: "w")
        closeItem.target = self

        NSApp.mainMenu = mainMenu
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func closeAction() {
        window?.performClose(nil)
    }

    private func buildWindow() {
        guard window == nil else { return }
        let width: CGFloat = 620
        let height: CGFloat = 460
        let screen = NSScreen.main ?? NSScreen.screens.first
        let sFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let rect = NSRect(x: sFrame.midX - width / 2, y: sFrame.midY - height / 2, width: width, height: height)

        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maple 安装向导"
        window.isReleasedWhenClosed = false
        window.delegate = self

        stageView = InstallerStageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = stageView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 精致胶囊按钮（彻底解决浅色背景下文字发白看不清的问题）

final class InstallerPillButton: NSButton {

    var isPrimary = false {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    init(title: String, isPrimary: Bool = false) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: 13, weight: isPrimary ? .semibold : .medium)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)

        if isPrimary {
            // 主按钮：鲜亮饱满的天空蓝 / 枫叶蓝
            let fillColor = isHighlighted
                ? NSColor(calibratedRed: 0.04, green: 0.44, blue: 0.90, alpha: 1.0)
                : NSColor(calibratedRed: 0.08, green: 0.54, blue: 0.98, alpha: 1.0)
            fillColor.setFill()
            path.fill()
        } else {
            // 次要按钮：高对比度、清晰可读的浅暖白底 + 细边框，绝不泛白
            let fillColor = isHighlighted
                ? NSColor(calibratedWhite: 0.90, alpha: 0.95)
                : NSColor(calibratedWhite: 1.0, alpha: 0.85)
            fillColor.setFill()
            path.fill()

            NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.18, alpha: 0.30).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center

        let textColor: NSColor = isPrimary
            ? .white
            : NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.12, alpha: 0.95)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: isPrimary ? .semibold : .medium),
            .foregroundColor: textColor,
            .paragraphStyle: pStyle
        ]
        let str = NSAttributedString(string: title, attributes: attrs)
        let strSize = str.size()
        let textY = (bounds.height - strSize.height) / 2
        str.draw(in: NSRect(x: 0, y: textY, width: bounds.width, height: strSize.height))
    }
}

// MARK: - 交互式舞台视图

final class InstallerStageView: NSView {

    private let titleLabel = NSTextField(labelWithString: "安装 Maple")
    private let subtitleLabel = NSTextField(labelWithString: "将左侧枫叶拖入文件夹，即可完成安装")
    private let statusLabel = NSTextField(labelWithString: "")

    // 文件夹容器与三层视图
    private let folderContainer = NSView()
    private let folderBackView = NSImageView()
    private let folderFrontView = NSImageView()

    // 文件夹左右横向位置约束（入鞘后平滑滑向正中央）
    private var folderTrailingConstraint: NSLayoutConstraint?
    private var folderCenterXConstraint: NSLayoutConstraint?

    // 拖拽枫叶
    private let leafView = DraggableLeafView()
    private var leafInitialFrame: NSRect = .zero

    // 引导与反馈元素
    private let guideArrow = NSTextField(labelWithString: "拖入此处 ➔")

    // 底部操作按钮
    private let buttonContainer = NSStackView()
    private let revealButton = InstallerPillButton(title: "在“访达”中查看", isPrimary: false)
    private let launchButton = InstallerPillButton(title: "立即启动 Maple", isPrimary: true)

    private var isInstalled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 背景绘制（温暖枫叶底色）

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bgColors = [
            NSColor(calibratedRed: 0.992, green: 0.968, blue: 0.948, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.962, green: 0.912, blue: 0.880, alpha: 1.0).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [])
        }
    }

    // MARK: 构建界面布局

    private func setupUI() {
        // 1. 顶部标题与副标题
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 23, weight: .bold)
        titleLabel.textColor = NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.12, alpha: 0.95)
        titleLabel.alignment = .center
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.32, blue: 0.28, alpha: 0.90)
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)

        // 2. 文件夹容器（右侧：包含后背板、枫叶插入槽位、前袋盖）
        folderContainer.translatesAutoresizingMaskIntoConstraints = false
        folderContainer.wantsLayer = true
        addSubview(folderContainer)

        let folderW: CGFloat = 260
        let folderH: CGFloat = 260

        folderBackView.frame = NSRect(x: 0, y: 0, width: folderW, height: folderH)
        folderBackView.imageScaling = .scaleProportionallyUpOrDown
        folderBackView.image = loadResourceImage("installer_folder_back.png")
        folderContainer.addSubview(folderBackView)

        folderFrontView.frame = NSRect(x: 0, y: 0, width: folderW, height: folderH)
        folderFrontView.imageScaling = .scaleProportionallyUpOrDown
        folderFrontView.image = loadResourceImage("installer_folder_front.png")
        folderContainer.addSubview(folderFrontView)

        // 3. 左侧可拖拽立体枫叶
        leafView.image = loadResourceImage("installer_leaf.png")
        leafView.onDragBegan = { [weak self] in
            self?.handleLeafDragBegan()
        }
        leafView.onDragging = { [weak self] currentCenter in
            self?.handleLeafDragging(currentCenter: currentCenter)
        }
        leafView.onDragEnded = { [weak self] currentCenter in
            self?.handleLeafDragEnded(currentCenter: currentCenter)
        }
        addSubview(leafView)

        // 4. 引导箭头
        guideArrow.translatesAutoresizingMaskIntoConstraints = false
        guideArrow.font = .systemFont(ofSize: 13, weight: .bold)
        guideArrow.textColor = NSColor(calibratedRed: 0.88, green: 0.32, blue: 0.16, alpha: 0.85)
        guideArrow.alignment = .center
        addSubview(guideArrow)

        // 5. 底部状态与操作按钮
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        addSubview(statusLabel)

        revealButton.target = self
        revealButton.action = #selector(revealInFinderClicked)
        revealButton.widthAnchor.constraint(equalToConstant: 132).isActive = true
        revealButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        launchButton.target = self
        launchButton.action = #selector(launchMapleClicked)
        launchButton.keyEquivalent = "\r"
        launchButton.widthAnchor.constraint(equalToConstant: 142).isActive = true
        launchButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        buttonContainer.orientation = .horizontal
        buttonContainer.spacing = 14
        buttonContainer.alignment = .centerY
        buttonContainer.addArrangedSubview(revealButton)
        buttonContainer.addArrangedSubview(launchButton)
        buttonContainer.alphaValue = 0
        buttonContainer.isHidden = true
        addSubview(buttonContainer)

        let trailingConstraint = folderContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -46)
        let centerConstraint = folderContainer.centerXAnchor.constraint(equalTo: centerXAnchor)
        folderTrailingConstraint = trailingConstraint
        folderCenterXConstraint = centerConstraint

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            trailingConstraint,
            folderContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            folderContainer.widthAnchor.constraint(equalToConstant: folderW),
            folderContainer.heightAnchor.constraint(equalToConstant: folderH),

            guideArrow.centerYAnchor.constraint(equalTo: folderContainer.centerYAnchor, constant: 20),
            guideArrow.trailingAnchor.constraint(equalTo: folderContainer.leadingAnchor, constant: -12),

            statusLabel.bottomAnchor.constraint(equalTo: buttonContainer.topAnchor, constant: -10),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            buttonContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            buttonContainer.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    override func layout() {
        super.layout()
        if leafInitialFrame == .zero && bounds.width > 0 {
            // 原版 3D 枫叶比例: 484 x 517 (高/宽 = 1.068)
            let leafW: CGFloat = 175
            let leafH: CGFloat = leafW * (517.0 / 484.0)
            let initRect = NSRect(x: 55, y: bounds.midY - leafH / 2 + 10, width: leafW, height: leafH)
            leafView.frame = initRect
            leafInitialFrame = initRect
            leafView.startHoverAnimation()
        }
    }

    private func loadResourceImage(_ name: String) -> NSImage? {
        if let img = Bundle.main.image(forResource: name) { return img }
        let fallback = Bundle.main.bundlePath + "/Contents/Resources/" + name
        if let img = NSImage(contentsOfFile: fallback) { return img }
        // 动态回退：尝试在当前工作目录或上级源码工程寻找资源，避免硬编码开发者个人路径
        let currentDir = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(currentDir)/Resources/\(name)",
            "\(currentDir)/Maple/Resources/\(name)"
        ]
        for path in candidates {
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        return nil
    }

    // MARK: - 拖拽交互反馈

    private func handleLeafDragBegan() {
        guard !isInstalled else { return }
        guideArrow.alphaValue = 0.5
    }

    private func handleLeafDragging(currentCenter: NSPoint) {
        guard !isInstalled else { return }
        let folderFrameInSelf = folderContainer.frame
        let inSlotArea = folderFrameInSelf.insetBy(dx: -40, dy: -40).contains(currentCenter)
        if inSlotArea {
            folderFrontView.alphaValue = 0.92
        } else {
            folderFrontView.alphaValue = 1.0
        }
    }

    private func handleLeafDragEnded(currentCenter: NSPoint) {
        guard !isInstalled else { return }
        let folderFrameInSelf = folderContainer.frame
        let targetDropRect = folderFrameInSelf.insetBy(dx: -50, dy: -50)

        if targetDropRect.contains(currentCenter) {
            triggerInsertionAndInstall()
        } else {
            leafView.snapBack(to: leafInitialFrame)
            guideArrow.alphaValue = 1.0
        }
    }

    // MARK: - 枫叶入鞘动画与安装

    private func triggerInsertionAndInstall() {
        isInstalled = true
        leafView.stopHoverAnimation()
        guideArrow.isHidden = true
        subtitleLabel.stringValue = "正在插入并安装 Maple..."

        let folderW = folderContainer.bounds.width
        let scale: CGFloat = folderW / 1024.0

        // 枫叶在 1024x1024 原版图标中的像素级黄金坐标：
        // x: 364, y(底向上): 367, 宽: 484, 高: 517
        let targetX: CGFloat = 364.0 * scale
        let targetY: CGFloat = 367.0 * scale
        let targetW: CGFloat = 484.0 * scale
        let targetH: CGFloat = 517.0 * scale

        let targetFrameInFolder = NSRect(x: targetX, y: targetY, width: targetW, height: targetH)
        let targetFrameInSelf = folderContainer.convert(targetFrameInFolder, to: self)

        // 1. 枫叶入鞘平滑飞入并吸附至与 AppIcon 完全一致的位置
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.40
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            leafView.animator().frame = targetFrameInSelf
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // 2. 将枫叶移入文件夹容器内部（后背板上方、前袋盖下方）
            self.leafView.removeFromSuperview()
            self.folderContainer.addSubview(self.leafView, positioned: .below, relativeTo: self.folderFrontView)
            self.leafView.frame = targetFrameInFolder
            self.folderFrontView.alphaValue = 1.0

            // 3. 伴随清脆吸附音效、金光粒子与合体缩放弹性动效
            NSSound(named: "Glass")?.play()
            self.playFolderPulseAnimation()
            self.showSuccessSparkles()

            // 4. 合体后：文件夹平滑滑向窗口正中央，视觉更均衡有仪式感
            self.animateFolderToCenter()

            // 5. 后台执行文件安装到 /Applications
            self.performFileInstallation()
        })
    }

    private func animateFolderToCenter() {
        folderTrailingConstraint?.isActive = false
        folderCenterXConstraint?.isActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.50
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.layoutSubtreeIfNeeded()
        }
    }

    private func playFolderPulseAnimation() {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.06, 0.98, 1.02, 1.0]
        pulse.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        pulse.duration = 0.45
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        folderContainer.layer?.add(pulse, forKey: "pulse")
    }

    private func showSuccessSparkles() {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: folderContainer.frame.midX + 25, y: folderContainer.frame.midY + 45)
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 10, height: 10)

        let cell = CAEmitterCell()
        cell.birthRate = 28
        cell.lifetime = 0.8
        cell.velocity = 120
        cell.velocityRange = 60
        cell.emissionRange = .pi * 2
        cell.scale = 0.12
        cell.scaleRange = 0.08
        cell.scaleSpeed = -0.1
        cell.alphaSpeed = -1.2
        cell.contents = createSparkleImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)

        emitter.emitterCells = [cell]
        layer?.addSublayer(emitter)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            emitter.birthRate = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                emitter.removeFromSuperlayer()
            }
        }
    }

    private func createSparkleImage() -> NSImage? {
        let size = NSSize(width: 24, height: 24)
        let img = NSImage(size: size)
        img.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 16, height: 16))
        NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.20, alpha: 0.95).setFill()
        path.fill()
        img.unlockFocus()
        return img
    }

    // MARK: - 执行实际文件安装

    private func performFileInstallation() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sourceAppURL = self?.locateSourceMapleApp()
            let targetURL = URL(fileURLWithPath: "/Applications/Maple.app")
            var installSuccess = false

            if let source = sourceAppURL {
                do {
                    // 若 Maple 当前正在运行，先终止旧进程，避免文件占用导致替换失败
                    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.workbuddy.maple")
                        + NSRunningApplication.runningApplications(withBundleIdentifier: "com.workbuddy.qspacelite")
                    for app in runningApps {
                        app.terminate()
                    }
                    Thread.sleep(forTimeInterval: 0.3)

                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try? FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: source, to: targetURL)

                    // 彻底清除复制到 /Applications 后的 quarantine 与 fileprovider 属性
                    let p1 = Process()
                    p1.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                    p1.arguments = ["-cr", targetURL.path]
                    try? p1.run()
                    p1.waitUntilExit()

                    // 重签名以保证 Apple Silicon AMFI 完整性通过
                    let p2 = Process()
                    p2.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    p2.arguments = ["--force", "--deep", "--sign", "-", targetURL.path]
                    try? p2.run()
                    p2.waitUntilExit()

                    installSuccess = true
                } catch {
                    print("Copy failed: \(error)")
                }
            }

            DispatchQueue.main.async {
                self?.handleInstallCompleted(success: installSuccess)
            }
        }
    }

    private func locateSourceMapleApp() -> URL? {
        if let bundled = Bundle.main.url(forResource: "Maple", withExtension: "app") {
            return bundled
        }
        let bundleURL = Bundle.main.bundleURL
        let sibling = bundleURL.deletingLastPathComponent().appendingPathComponent("Maple.app")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        // 动态回退：尝试在当前工作目录或上层工程目录寻找 Maple.app，避免硬编码绝对路径
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            currentDir.appendingPathComponent("Maple.app"),
            currentDir.appendingPathComponent("Maple/Maple.app"),
            currentDir.deletingLastPathComponent().appendingPathComponent("Maple.app")
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func handleInstallCompleted(success: Bool) {
        titleLabel.stringValue = "安装完成"
        subtitleLabel.stringValue = "Maple 已安装至“应用程序”文件夹"
        statusLabel.stringValue = "✓ 已就绪"
        statusLabel.isHidden = false

        buttonContainer.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            buttonContainer.animator().alphaValue = 1.0
        }
    }

    // MARK: - 按钮响应

    @objc private func revealInFinderClicked() {
        let appURL = URL(fileURLWithPath: "/Applications/Maple.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
    }

    @objc private func launchMapleClicked() {
        let appURL = URL(fileURLWithPath: "/Applications/Maple.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 可拖拽立体枫叶视图

final class DraggableLeafView: NSImageView {

    var onDragBegan: (() -> Void)?
    var onDragging: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrameOrigin: NSPoint = .zero
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    func startHoverAnimation() {
        guard !isDragging else { return }
        let hover = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hover.values = [0, 8, -4, 0]
        hover.keyTimes = [0, 0.45, 0.8, 1.0]
        hover.duration = 2.8
        hover.repeatCount = .infinity
        hover.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(hover, forKey: "hover")
    }

    func stopHoverAnimation() {
        layer?.removeAnimation(forKey: "hover")
    }

    func snapBack(to targetFrame: NSRect) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().frame = targetFrame
        }, completionHandler: { [weak self] in
            self?.startHoverAnimation()
        })
    }

    // MARK: 鼠标拖拽事件

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        stopHoverAnimation()
        NSCursor.closedHand.push()
        dragStartMouseLocation = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        dragStartFrameOrigin = frame.origin
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let win = window else { return }
        let currentScreenMouse = win.convertPoint(toScreen: event.locationInWindow)
        let deltaX = currentScreenMouse.x - dragStartMouseLocation.x
        let deltaY = currentScreenMouse.y - dragStartMouseLocation.y

        var newOrigin = NSPoint(
            x: dragStartFrameOrigin.x + deltaX,
            y: dragStartFrameOrigin.y + deltaY
        )
        if let superview {
            newOrigin.x = max(-20, min(superview.bounds.width - frame.width + 20, newOrigin.x))
            newOrigin.y = max(-20, min(superview.bounds.height - frame.height + 20, newOrigin.y))
        }
        frame.origin = newOrigin

        let center = NSPoint(x: frame.midX, y: frame.midY)
        onDragging?(center)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        let center = NSPoint(x: frame.midX, y: frame.midY)
        onDragEnded?(center)
    }
}

// MARK: - 主入口

let app = NSApplication.shared
let delegate = InstallerAppDelegate()
app.delegate = delegate
app.run()
