import AppKit

/// 支持键盘左右/上下箭头步进调节的滑块
final class SteppingSlider: NSSlider {
    var onFocusChange: ((Bool) -> Void)?
    var stepSize: Int = 1

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            onFocusChange?(false)
        }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)
        let multiplier = isShift ? 2 : 1
        let delta = stepSize * multiplier

        switch event.keyCode {
        case 123, 125: // Left Arrow or Down Arrow: 减少
            step(by: -delta)
        case 124, 126: // Right Arrow or Up Arrow: 增加
            step(by: delta)
        case 53: // Escape: 放弃焦点
            window?.makeFirstResponder(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func step(by delta: Int) {
        let minVal = Int(minValue)
        let maxVal = Int(maxValue)
        let targetVal = max(minVal, min(maxVal, integerValue + delta))
        if targetVal != integerValue {
            integerValue = targetVal
            if let action = action, let target = target {
                NSApp.sendAction(action, to: target, from: self)
            }
        }
    }
}

/// 窗口右下角的「显示大小」滑动条控件（仿 Maple / 访达样式）
/// 支持自适应控制：
/// - 图标模式：调节图标网格尺寸 (32~128px)
/// - 详细列表 / 树状列表：调节列表行高与图标尺寸 (16~32px)
/// - 分栏模式：调节单列宽度 (160~360px)
/// 支持点击获取焦点后使用键盘左右箭头（← / →）直接微调。
final class DisplaySizeSliderControl: NSView {

    var onSizeChanged: ((ViewMode, Int) -> Void)?

    private(set) var currentMode: ViewMode = .list
    private let slider = SteppingSlider()
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
        slider.focusRingType = .default
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.onFocusChange = { [weak self] hasFocus in
            guard let self = self else { return }
            self.label.textColor = hasFocus ? .controlAccentColor : .secondaryLabelColor
            self.label.font = .monospacedDigitSystemFont(ofSize: 11, weight: hasFocus ? .bold : .regular)
        }
        addSubview(slider)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.isSelectable = false
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

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== slider {
            window?.makeFirstResponder(slider)
        }
        super.mouseDown(with: event)
    }

    func configure(for mode: ViewMode) {
        self.currentMode = mode
        switch mode {
        case .icons:
            slider.minValue = 32
            slider.maxValue = 128
            slider.stepSize = 4
            let val = Int(AppSettings.gridIconSize)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节图标大小（32~128，支持点击后键盘 ← / → 调节）"

        case .list:
            slider.minValue = 16
            slider.maxValue = 32
            slider.stepSize = 1
            let val = Int(AppSettings.listIconSize)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节行高与图标尺寸（16~32，支持点击后键盘 ← / → 调节）"

        case .columns:
            slider.minValue = 160
            slider.maxValue = 360
            slider.stepSize = 10
            let val = Int(AppSettings.browserColumnWidth)
            slider.integerValue = val
            label.stringValue = "\(val)"
            slider.toolTip = "调节分栏列宽（160~360，支持点击后键盘 ← / → 调节）"
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = sender.integerValue
        label.stringValue = "\(value)"
        onSizeChanged?(currentMode, value)
    }
}
