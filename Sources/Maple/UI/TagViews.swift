import AppKit

// MARK: - 文件列表/分栏中紧跟文件名的小圆点标签视图

final class TagDotsView: NSView {

    private var colors: [NSColor] = []

    static let dotDiameter: CGFloat = 8.5
    static let dotSpacing: CGFloat = 3.0

    static func preferredWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotSpacing
    }

    func setColors(_ colors: [NSColor]) {
        guard self.colors != colors else { return }
        self.colors = colors
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !colors.isEmpty else { return }

        var x: CGFloat = 0
        let y: CGFloat = (bounds.height - Self.dotDiameter) / 2

        for color in colors {
            let dotRect = NSRect(x: x, y: y, width: Self.dotDiameter, height: Self.dotDiameter)
            let path = NSBezierPath(ovalIn: dotRect)
            color.setFill()
            path.fill()

            // 边缘 0.5pt 细微暗边，确保在亮色或暗色选中背景下都边界分明
            let border = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.25, dy: 0.25))
            border.lineWidth = 0.5
            NSColor(white: 0.0, alpha: 0.18).setStroke()
            border.stroke()

            x += Self.dotDiameter + Self.dotSpacing
        }
    }
}

// MARK: - 右键菜单中的横排标签颜色选择器

final class TagColorPickerMenuItem: NSMenuItem {

    init(targetURLs: [URL]) {
        let view = TagColorPickerView(targetURLs: targetURLs)
        super.init(title: "标记", action: nil, keyEquivalent: "")
        self.view = view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class TagColorPickerView: NSView {

    private let targetURLs: [URL]
    private var buttons: [TagCircleButton] = []

    init(targetURLs: [URL]) {
        self.targetURLs = targetURLs
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 34))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        let tags = Tags.all
        guard !tags.isEmpty else { return }

        // 收集所有选中文件的标签
        var sharedTags = Set(targetURLs.first.map { Tags.tags(for: $0) } ?? [])
        for url in targetURLs.dropFirst() {
            let fileTags = Set(Tags.tags(for: url))
            sharedTags.formIntersection(fileTags)
        }

        let buttonDiameter: CGFloat = 18
        let spacing: CGFloat = 10
        let totalWidth = CGFloat(tags.count) * buttonDiameter + CGFloat(tags.count - 1) * spacing
        let startX: CGFloat = max(18, (bounds.width - totalWidth) / 2)
        let y: CGFloat = (bounds.height - buttonDiameter) / 2

        for (index, tagDef) in tags.enumerated() {
            let isTagged = sharedTags.contains(tagDef.name)
            let x = startX + CGFloat(index) * (buttonDiameter + spacing)
            let button = TagCircleButton(
                tagDef: tagDef,
                isTagged: isTagged,
                frame: NSRect(x: x, y: y, width: buttonDiameter, height: buttonDiameter)
            )
            button.onToggle = { [weak self] in
                self?.handleToggle(tag: tagDef.name)
            }
            addSubview(button)
            buttons.append(button)
        }
    }

    private func handleToggle(tag: String) {
        for url in targetURLs {
            Tags.toggleTag(on: url, tag: tag)
        }
        // 发送文件变更与标签变更通知
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)

        // 关闭右键菜单
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: - 颜色圆点按钮（支持悬停放大、选中打勾、未选中空心环）

private final class TagCircleButton: NSView {

    let tagDef: TagDefinition
    var isTagged: Bool
    var onToggle: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }

    init(tagDef: TagDefinition, isTagged: Bool, frame: NSRect) {
        self.tagDef = tagDef
        self.isTagged = isTagged
        super.init(frame: frame)
        toolTip = tagDef.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onToggle?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let diameter = bounds.width
        let image: NSImage
        if isTagged {
            image = Tags.checkedDotImage(color: tagDef.color, diameter: diameter)
        } else {
            image = Tags.ringDotImage(color: tagDef.color, diameter: diameter)
        }

        if isHovered {
            // 悬停时稍微放大 1.1x 绘制
            let inset = -1.0
            let hoverRect = bounds.insetBy(dx: inset, dy: inset)
            image.draw(in: hoverRect)
        } else {
            image.draw(in: bounds)
        }
    }
}
