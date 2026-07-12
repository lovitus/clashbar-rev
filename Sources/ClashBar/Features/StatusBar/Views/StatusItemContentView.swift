import AppKit

final class StatusItemContentView: NSView {
    // No horizontal padding; icon and text sit flush against each other.
    private let statusItemHorizontalPadding: CGFloat = 0
    private let iconSize: CGFloat = 24
    private let brandIconRenderSize: CGFloat = 24
    private let symbolPointSize: CGFloat = 20
    private let iconTextSpacing: CGFloat = 0
    private let textContainerWidth: CGFloat = 34
    private let textLineHeight: CGFloat = 11

    private let iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = true
        return imageView
    }()

    private var currentDisplay: MenuBarDisplay?
    private var cachedUpLine: String = ""
    private var cachedDownLine: String = ""
    private lazy var runBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.runImage, size: brandIconRenderSize)
    private lazy var sleepBrandStatusIconImage: NSImage? = Self.makeBrandStatusIconImage(
        source: BrandIcon.sleepImage, size: brandIconRenderSize)
    private static let brandIconRenderScales: [CGFloat] = [1, 2, 3]

    var usesBrandIcon: Bool {
        self.runBrandStatusIconImage != nil || self.sleepBrandStatusIconImage != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        self.addSubview(self.iconView)
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
            speedLines: nil,
            isRunning: false)
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
        let previousUpLine = self.cachedUpLine
        let previousDownLine = self.cachedDownLine

        self.currentDisplay = display
        self.cachedUpLine = display.speedLines?.up ?? ""
        self.cachedDownLine = display.speedLines?.down ?? ""

        let shouldShowIcon = display.mode != .speedOnly
        if shouldShowIcon, let brandIcon = self.brandStatusIconImage(isRunning: display.isRunning) {
            if self.iconView.image !== brandIcon {
                self.iconView.image = brandIcon
            }
        } else if let symbolName = display.symbolName {
            if self.iconView.image == nil ||
                previousSymbolName != symbolName ||
                self.currentDisplay?.mode != previousMode
            {
                let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClashBar")
                let config = NSImage.SymbolConfiguration(pointSize: self.symbolPointSize, weight: .semibold)
                self.iconView.image = image?.withSymbolConfiguration(config)
            }
        } else {
            self.iconView.image = nil
        }

        switch display.mode {
        case .iconOnly:
            self.iconView.isHidden = false
        case .iconAndSpeed:
            self.iconView.isHidden = false
        case .speedOnly:
            self.iconView.isHidden = true
        }

        let modeChanged = previousMode != display.mode
        let iconVisibilityChanged = previousIconHidden != self.iconView.isHidden
        let speedTextChanged = previousUpLine != self.cachedUpLine || previousDownLine != self.cachedDownLine

        if speedTextChanged || modeChanged {
            self.needsDisplay = true
        }

        if modeChanged || iconVisibilityChanged {
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
        let iconOriginX = floor(self.statusItemHorizontalPadding)

        if self.iconView.isHidden == false {
            self.iconView.frame = CGRect(
                x: iconOriginX,
                y: floor(centerY - self.iconSize / 2),
                width: self.iconSize,
                height: self.iconSize)
        } else {
            self.iconView.frame = .zero
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let display = self.currentDisplay, display.mode != .iconOnly else { return }

        let originX = floor(
            self.statusItemHorizontalPadding +
                ((display.mode == .iconAndSpeed) ? (self.iconSize + self.iconTextSpacing) : 0))
        let stackHeight = self.textLineHeight * 2
        let stackOriginY = floor(bounds.midY - stackHeight / 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        (self.cachedUpLine as NSString).draw(
            in: CGRect(
                x: originX,
                y: stackOriginY + self.textLineHeight,
                width: self.textContainerWidth,
                height: self.textLineHeight),
            withAttributes: attributes)
        (self.cachedDownLine as NSString).draw(
            in: CGRect(
                x: originX,
                y: stackOriginY,
                width: self.textContainerWidth,
                height: self.textLineHeight),
            withAttributes: attributes)
    }

    private func brandStatusIconImage(isRunning: Bool) -> NSImage? {
        isRunning ? self.runBrandStatusIconImage : self.sleepBrandStatusIconImage
    }

    private static func makeBrandStatusIconImage(source: NSImage?, size: CGFloat) -> NSImage? {
        guard let source else { return nil }
        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize)

        for scale in Self.brandIconRenderScales {
            guard let representation = self.makeBrandStatusIconRepresentation(
                source: source,
                pointSize: targetSize,
                scale: scale)
            else {
                continue
            }
            rendered.addRepresentation(representation)
        }

        guard rendered.representations.isEmpty == false else { return nil }
        rendered.isTemplate = true
        return rendered
    }

    private static func makeBrandStatusIconRepresentation(
        source: NSImage,
        pointSize: NSSize,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return nil
        }

        representation.size = pointSize

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: pointSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }
}
