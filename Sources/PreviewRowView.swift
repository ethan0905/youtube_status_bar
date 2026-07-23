import Cocoa

// A clickable menu row showing the video preview (16:9) with the title beneath it. Clicking anywhere
// on the row focuses the Chrome tab. Custom view so it can host an image and draw its own hover
// highlight (menu items with custom views don't get the system highlight).
final class PreviewRowView: NSView {
    var onClick: (() -> Void)?

    private let highlightView = NSVisualEffectView()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var hovered = false

    private let pad: CGFloat
    private let imageH: CGFloat

    init(width: CGFloat, inset: CGFloat) {
        self.pad = inset
        let imgW = width - inset * 2
        self.imageH = (imgW * 9 / 16).rounded()
        let titleH: CGFloat = 18, gap: CGFloat = 4
        let rowH = imageH + gap + titleH + pad
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]

        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 6
        highlightView.isHidden = true
        addSubview(highlightView)

        imageView.frame = NSRect(x: inset, y: gap + titleH, width: imgW, height: imageH)
        imageView.autoresizingMask = [.width, .maxYMargin]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.15).cgColor
        addSubview(imageView)

        titleField.font = .menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: inset, y: gap, width: imgW, height: titleH)
        titleField.autoresizingMask = [.width]
        addSubview(titleField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: NSImage?, title: String, subtitle: String) {
        imageView.image = image
        titleField.stringValue = title
        toolTip = subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; highlightView.isHidden = false }
    override func mouseExited(with event: NSEvent) { hovered = false; highlightView.isHidden = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 2)
    }
}
