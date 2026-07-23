import Cocoa

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var uiTimer: Timer?
    let poller = ChromeYouTubePoller()
    lazy var previews = PreviewImageProvider(poller: poller)

    // Settings
    var showTimer = true
    var iconSystem = false                       // false = red logo; true = adaptive template
    var previewMode: PreviewMode = .thumbnail

    // Live state mirrored from the poller (main thread only).
    var state: PlayerState = .noChrome
    var info: PlaybackInfo?
    var menuIsOpen = false
    var previewItem: NSMenuItem?
    var lastPreviewVideoId = ""

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if let s = d.string(forKey: "previewMode"), let m = PreviewMode(rawValue: s) { previewMode = m }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        poller.applyConfig(uiConfig())
        poller.onUpdate = { [weak self] st, info in self?.handleUpdate(st, info) }

        renderIdleIcon()

        // Drives the smooth interpolated timer between real syncs and live preview refresh.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.uiTick() }
        RunLoop.main.add(t, forMode: .common)
        uiTimer = t

        poller.start()
    }

    // MARK: - Poller callback

    func handleUpdate(_ st: PlayerState, _ info: PlaybackInfo?) {
        let videoChanged = (info?.videoId ?? "") != (self.info?.videoId ?? "")
        self.state = st
        self.info = info
        applyTitle()
        if menuIsOpen, videoChanged { refreshPreviewRow() }
    }

    // MARK: - Menu bar rendering

    var iconColor: NSColor? { iconSystem ? nil : YouTubeIcon.red }

    func renderIdleIcon() {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        button.image = YouTubeIcon.icon(template: iconSystem)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
    }

    // The 0.25s UI tick: advances the displayed clock via interpolation while playing.
    func uiTick() {
        if state == .playing { applyTitle() }
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        button.image = YouTubeIcon.icon(template: iconSystem)
        guard (state == .playing || state == .paused), let info = info, showTimer else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let cur = info.interpolated(now: Date())
        var text = "\(hms(cur)) / \(hms(info.duration))"
        if state == .paused { text = "⏸ " + text }
        button.imagePosition = .imageLeading
        // Monospaced digits so the advancing clock doesn't nudge neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: state == .paused ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // "1:02:45" when ≥ 1h, else "12:34".
    func hms(_ s: Double) -> String {
        let t = max(0, Int(s)); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        previewItem = nil
        lastPreviewVideoId = ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        poller.applyConfig(uiConfig())
        previewItem = nil
        lastPreviewVideoId = ""

        let playing = (state == .playing || state == .paused)
        if playing, let info = info {
            let width = CGFloat(uiConfig()["boxWidth"] ?? 300)
            let inset = CGFloat(uiConfig()["previewInset"] ?? 14)
            let view = PreviewRowView(width: width, inset: inset)
            view.onClick = { [weak self] in menu.cancelTracking(); self?.poller.focusCurrentTab() }
            view.configure(image: nil, title: info.title.isEmpty ? "YouTube" : info.title, subtitle: "")
            let it = NSMenuItem()
            it.view = view
            menu.addItem(it)
            previewItem = it
            loadPreviewImage(for: info.videoId, into: view)
            menu.addItem(.separator())
        } else {
            menu.addItem(header("YouTube"))
            switch state {
            case .permissionDenied:
                let it = NSMenuItem(title: "Allow Automation for YTBar…", action: #selector(openAutomationPrefs), keyEquivalent: "")
                it.target = self
                menu.addItem(it)
            case .jsDisabled:
                let it = NSMenuItem(title: "Enable: Chrome ▸ View ▸ Developer ▸", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
                let it2 = NSMenuItem(title: "  Allow JavaScript from Apple Events", action: nil, keyEquivalent: "")
                it2.isEnabled = false
                menu.addItem(it2)
            case .noChrome:
                let it = NSMenuItem(title: "Chrome isn't running", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            default:
                let it = NSMenuItem(title: "No YouTube video playing", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))
        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })

        let previewParent = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let previewSub = NSMenu()
        for (mode, name) in [(PreviewMode.thumbnail, "Thumbnail"), (PreviewMode.midVideo, "Mid-video frame")] {
            let it = NSMenuItem(title: name, action: #selector(choosePreview(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = previewMode == mode ? .on : .off
            previewSub.addItem(it)
        }
        previewParent.submenu = previewSub
        menu.addItem(previewParent)

        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (sys, name) in [(false, "Red"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            colorSub.addItem(it)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    // Rebuild only the preview row's image/title when the video changed while the menu is open.
    func refreshPreviewRow() {
        guard let view = previewItem?.view as? PreviewRowView else { return }
        guard state == .playing || state == .paused, let info = info else { return }
        view.configure(image: nil, title: info.title.isEmpty ? "YouTube" : info.title, subtitle: "")
        loadPreviewImage(for: info.videoId, into: view)
    }

    func loadPreviewImage(for videoId: String, into view: PreviewRowView) {
        lastPreviewVideoId = videoId
        let mode = previewMode
        previews.image(videoId: videoId, mode: mode) { [weak self, weak view] img in
            // Ignore a late completion for a video we've since navigated away from.
            guard let self = self, self.lastPreviewVideoId == videoId, let view = view else { return }
            view.configure(image: img, title: self.info?.title.isEmpty == false ? self.info!.title : "YouTube", subtitle: "")
        }
    }

    @objc func choosePreview(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = PreviewMode(rawValue: raw) else { return }
        previewMode = m
        UserDefaults.standard.set(raw, forKey: "previewMode")
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(sys, forKey: "iconSystem")
        applyTitle()
    }

    @objc func openAutomationPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        let labelFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        let item = NSMenuItem()
        item.view = row
        return item
    }

    // Live layout knobs read fresh from ~/.ytbar/uiconfig.json each render, so numeric tweaks
    // (preview size, poll intervals) take effect on the next menu open / poll with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".ytbar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
