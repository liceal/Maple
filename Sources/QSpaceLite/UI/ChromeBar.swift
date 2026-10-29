import AppKit

/// 顶部工具条：自绘的一条 38pt 区域，替代系统标题栏 + 系统工具栏。
///
/// 之所以不用 NSToolbar：系统工具条会自带标题栏底纹，而且左侧条目总是紧贴交通灯，
/// 无法与侧栏右沿对齐。这里自己画，背景与窗格同色、不画分隔线，
/// 左右分别与侧栏 / 窗格对齐，视觉上和内容连成一整块（QSpace 那种一体感）。
final class ChromeBar: NSView {

    static let height = Theme.chromeHeight

    /// 内容（按钮）的垂直中心：比条带正中略高一点，和交通灯大致在同一高度
    private static let contentCenterY: CGFloat = 17

    let navView = ToolbarNavView()
    let viewModeView = ToolbarViewModeView()
    let newFolderButton = SquareToolbarButton()
    let searchButton = SquareToolbarButton()
    let moreButton = SquareToolbarButton()
    let layoutButton = SquareToolbarButton()

    /// 在空白处按下时的回调（拖动窗口 / 双击缩放由外部处理）。
    var onDragArea: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        newFolderButton.image = Theme.symbol("folder.badge.plus", size: 15)
        newFolderButton.toolTip = "新建文件夹"

        searchButton.image = Theme.symbol("magnifyingglass", size: 15)
        searchButton.toolTip = "搜索文件（⌘F）"

        moreButton.image = Theme.moreMenuImage()
        moreButton.toolTip = "更多：新建、排序、分组与显示选项"

        layoutButton.image = LayoutMode.single.icon
        layoutButton.toolTip = "窗口排列方式"

        navView.translatesAutoresizingMaskIntoConstraints = false
        layoutButton.translatesAutoresizingMaskIntoConstraints = false

        let group = NSStackView(views: [newFolderButton, viewModeView, searchButton, moreButton])
        group.translatesAutoresizingMaskIntoConstraints = false
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 2

        addSubview(navView)
        addSubview(group)
        addSubview(layoutButton)

        // 中间这组功能靠右排，紧贴布局按钮左侧（不再居中）
        NSLayoutConstraint.activate([
            navView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            navView.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.contentCenterY),
            navView.heightAnchor.constraint(equalToConstant: 28),

            group.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.contentCenterY),
            group.leadingAnchor.constraint(greaterThanOrEqualTo: navView.trailingAnchor, constant: 16),
            group.trailingAnchor.constraint(equalTo: layoutButton.leadingAnchor, constant: -14),

            layoutButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.contentCenterY)
        ])
    }

    /// 与窗格同一个底色，不画分隔线，看起来就是窗格内容的延伸。
    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onDragArea?(event)
    }
}

/// 侧栏顶部那一条（交通灯所在的空白区）：透明，只负责拖动窗口。
final class ChromeDragStrip: NSView {

    var onDragArea: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDragArea?(event)
    }
}
