import AppKit

final class StatusItemContentView: NSView {
    // Keep a 1pt optical inset to stabilize status-item width across icon/text mode switches.
    private let statusItemHorizontalPadding: CGFloat = MenuBarLayoutTokens.opticalNudge
    private let iconSize: CGFloat = 24
    private let brandIconRenderSize: CGFloat = 24
    private let symbolPointSize: CGFloat = 20
    private let iconTextSpacing: CGFloat = 1
    private let textContainerWidth: CGFloat = 42
    private let textLineHeight: CGFloat = 11

    private let iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = NSColor.labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = true
        return imageView
    }()

    private let upLabel = StatusItemContentView.makeLineLabel()
    private let downLabel = StatusItemContentView.makeLineLabel()

    private var currentDisplay: MenuBarDisplay?
    private lazy var brandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(size: brandIconRenderSize)

    var usesBrandIcon: Bool {
        self.brandStatusIconImage != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        addSubview(self.iconView)
        addSubview(self.upLabel)
        addSubview(self.downLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        CGSize(width: self.requiredWidth, height: NSStatusBar.system.thickness)
    }

    var requiredWidth: CGFloat {
        let display = self.currentDisplay ?? MenuBarDisplay(
            mode: .iconOnly,
            symbolName: "bolt.slash.circle",
            speedLines: nil)
        switch display.mode {
        case .iconOnly:
            return self.statusItemHorizontalPadding * 2 + self.iconSize
        case .iconAndSpeed:
            return self.statusItemHorizontalPadding * 2 + self.iconSize + self.iconTextSpacing + self.textContainerWidth
        case .speedOnly:
            return self.statusItemHorizontalPadding * 2 + self.textContainerWidth
        }
    }

    func apply(display: MenuBarDisplay) {
        let previousMode = self.currentDisplay?.mode
        let previousSymbolName = self.currentDisplay?.symbolName
        let previousIconHidden = self.iconView.isHidden
        let previousUpHidden = self.upLabel.isHidden
        let previousDownHidden = self.downLabel.isHidden

        self.currentDisplay = display
        let upLine = display.speedLines?.up ?? ""
        if self.upLabel.stringValue != upLine {
            self.upLabel.stringValue = upLine
        }
        let downLine = display.speedLines?.down ?? ""
        if self.downLabel.stringValue != downLine {
            self.downLabel.stringValue = downLine
        }

        let shouldShowIcon = display.mode != .speedOnly
        if shouldShowIcon, let brandIcon = brandStatusIconImage {
            if self.iconView.image !== brandIcon {
                self.iconView.image = brandIcon
            }
            // Avoid per-frame tint recomposition for custom PNG icon snapshots.
            self.iconView.contentTintColor = nil
        } else if let symbolName = display.symbolName {
            if self.iconView.image == nil || previousSymbolName != symbolName || self.currentDisplay?.mode != previousMode {
                let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClashBar")
                let config = NSImage.SymbolConfiguration(pointSize: self.symbolPointSize, weight: .semibold)
                self.iconView.image = image?.withSymbolConfiguration(config)
            }
            self.iconView.contentTintColor = NSColor.labelColor
        } else {
            self.iconView.image = nil
            self.iconView.contentTintColor = nil
        }

        switch display.mode {
        case .iconOnly:
            self.iconView.isHidden = false
            self.upLabel.isHidden = true
            self.downLabel.isHidden = true
        case .iconAndSpeed:
            self.iconView.isHidden = false
            self.upLabel.isHidden = false
            self.downLabel.isHidden = false
        case .speedOnly:
            self.iconView.isHidden = true
            self.upLabel.isHidden = false
            self.downLabel.isHidden = false
        }

        let modeChanged = previousMode != display.mode
        let visibilityChanged = previousIconHidden != self.iconView.isHidden ||
            previousUpHidden != self.upLabel.isHidden ||
            previousDownHidden != self.downLabel.isHidden

        if modeChanged || visibilityChanged {
            self.needsLayout = true
        }
        if modeChanged {
            self.invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()

        let totalHeight = bounds.height
        let centerY = floor(totalHeight / 2)
        var cursorX = floor(self.statusItemHorizontalPadding)

        if self.iconView.isHidden == false {
            self.iconView.frame = CGRect(
                x: floor(cursorX),
                y: floor(centerY - self.iconSize / 2),
                width: self.iconSize,
                height: self.iconSize)
            cursorX += self.iconSize + self.iconTextSpacing
        } else {
            self.iconView.frame = .zero
        }

        if self.upLabel.isHidden || self.downLabel.isHidden {
            self.upLabel.frame = .zero
            self.downLabel.frame = .zero
            return
        }

        let stackHeight = self.textLineHeight * 2
        let stackOriginY = floor(centerY - stackHeight / 2)
        let textOriginX = floor(cursorX)

        self.upLabel.frame = CGRect(
            x: textOriginX,
            y: floor(stackOriginY + self.textLineHeight),
            width: self.textContainerWidth,
            height: self.textLineHeight)
        self.downLabel.frame = CGRect(
            x: textOriginX,
            y: stackOriginY,
            width: self.textContainerWidth,
            height: self.textLineHeight)
    }

    private static func makeLineLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 2
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }

    private static func makeBrandStatusIconImage(size: CGFloat) -> NSImage? {
        guard let source = BrandIcon.image else { return nil }
        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high])
        rendered.unlockFocus()
        rendered.isTemplate = false
        return rendered
    }
}
