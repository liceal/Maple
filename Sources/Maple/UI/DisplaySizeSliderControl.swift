import AppKit

/// 窗口右下角的「显示大小」滑动条控件（仿 Maple / 访达样式）
/// 支持自适应控制：
/// - 图标模式：调节图标网格尺寸 (32~128px)
/// - 详细列表 / 树状列表：调节列表行高与图标尺寸 (16~32px)
/// - 分栏模式：调节单列宽度 (160~360px)
final class DisplaySizeSliderControl: NSView {

    var onSizeChanged: ((ViewMode, Int) -> Void)?

    private(set) var currentMode: ViewMode = .list
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "16")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.numberOfTickMarks = 2
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        addSubview(slider)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        addSubview(label)

        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 72),

            label.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func configure(for mode: ViewMode) {
        self.currentMode = mode
        switch mode {
        case .icons:
            slider.minValue = 32
            slider.maxValue = 128
            let val = Int(AppSettings.gridIconSize)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节图标大小（32~128）"

        case .list:
            slider.minValue = 16
            slider.maxValue = 32
            let val = Int(AppSettings.listIconSize)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节行高与图标尺寸（16~32）"

        case .columns:
            slider.minValue = 160
            slider.maxValue = 360
            let val = Int(AppSettings.browserColumnWidth)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节分栏列宽（160~360）"
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = sender.integerValue
        label.stringValue = "\(value)"
        onSizeChanged?(currentMode, value)
    }
}
