// KeepAwake — แผงควบคุมกันไม่ให้ Mac หลับ (Swift / AppKit)
// หน้าจอ: แผงเดียวกันเปิดได้จากเมนูบาร์ (popover) และจาก Dock (หน้าต่าง)
// ต้องมีหน้าต่างไว้เสมอ: จอมีรอยบากที่แถบเมนูเต็ม ระบบจะไม่แสดงไอคอนเมนูบาร์ใหม่
import Cocoa
import CoreGraphics
import IOKit.pwr_mgt
import IOKit.ps

// ---------- อ่านสถานะแบตเตอรี่ ----------
func batteryStatus() -> (onBattery: Bool, percent: Int)? {
    guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        if let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
           let cap = d[kIOPSCurrentCapacityKey as String] as? Int,
           let mx = d[kIOPSMaxCapacityKey as String] as? Int,
           let st = d[kIOPSPowerSourceStateKey as String] as? String {
            let pct = mx > 0 ? cap * 100 / mx : cap
            return (st == kIOPSBatteryPowerValue as String, pct)
        }
    }
    return nil
}

// ---------- กันเครื่องหลับผ่าน IOKit โดยตรง (ไม่ใช้ caffeinate) ----------
// assertion ผูกกับโปรเซสแอปโดยระบบ: แอปตาย (ไม่ว่าทางไหน) ระบบปล่อยให้อัตโนมัติ
// จึงไม่มีทางเกิดการกันหลับ "ค้าง" แบบโปรเซสกำพร้าอีก
final class PowerAssertion {
    private var ids: [IOPMAssertionID] = []
    var isActive: Bool { !ids.isEmpty }

    /// เริ่มกันเครื่องหลับ; สำเร็จก็ต่อเมื่อ assertion "ตัวหลัก" (กัน idle sleep) สร้างได้จริง
    /// ตัวรองล้มเหลวไม่เป็นไร แต่ถ้าตัวหลักล้มเหลว = ถือว่าไม่สำเร็จทั้งหมด (กัน UI โชว์เขียวหลอก)
    @discardableResult
    func start(screenCanSleep: Bool) -> Bool {
        stop()
        let core = "PreventUserIdleSystemSleep"
        var types = [core, "PreventSystemSleep", "PreventDiskIdle"]
        if !screenCanSleep { types.append("PreventUserIdleDisplaySleep") }
        var coreOK = false
        for t in types {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(t as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "KeepAwake — กันเครื่องหลับ" as CFString, &id)
            if rc == kIOReturnSuccess {
                ids.append(id)
                if t == core { coreOK = true }
            }
        }
        if !coreOK { stop() }   // ตัวหลักไม่ได้ = ปล่อยที่เหลือทิ้งให้สถานะสะอาด
        return coreOK
    }

    func stop() {
        for id in ids { IOPMAssertionRelease(id) }
        ids.removeAll()
    }

    deinit { stop() }
}

// ---------- ควบคุมความสว่างจอ (ผ่าน DisplayServices) ----------
enum Brightness {
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static var available: Bool { getFn != nil && setFn != nil }
    static let getFn: GetFn? = {
        guard let h = handle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(p, to: GetFn.self)
    }()
    static let setFn: SetFn? = {
        guard let h = handle, let p = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(p, to: SetFn.self)
    }()

    static func get() -> Float? {
        guard let f = getFn else { return nil }
        var v: Float = 0
        return f(CGMainDisplayID(), &v) == 0 ? v : nil
    }
    @discardableResult
    static func set(_ v: Float) -> Bool {
        guard let f = setFn else { return false }
        return f(CGMainDisplayID(), max(0, min(1, v))) == 0
    }
}

// ---------- สีธีมที่เลือกได้ ----------
enum AccentChoice: String, CaseIterable {
    case green, blue, purple, orange, pink, teal
    var color: NSColor {
        switch self {
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        case .pink: return .systemPink
        case .teal: return .systemTeal
        }
    }
    var label: String {
        switch self {
        case .green: return "เขียว"
        case .blue: return "ฟ้า"
        case .purple: return "ม่วง"
        case .orange: return "ส้ม"
        case .pink: return "ชมพู"
        case .teal: return "ฟ้าอมเขียว"
        }
    }
}

// ---------- ส่วนประกอบหน้าจอ ----------
// ทุกอย่างวาดใน draw(_:) ด้วยสีแบบ dynamic ระบบจึงวาดใหม่เองตอนสลับ light/dark
// (ไม่ใช้ layer + .cgColor ซึ่งเป็น snapshot และเคยทำให้การ์ดค้างสีขาวใน dark mode)

/// วงแหวนเวลา
final class RingView: NSView {
    var progress: CGFloat = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
    let lineWidth: CGFloat = 9

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()
        guard progress > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * min(progress, 1), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

enum ChipStyle { case neutral, danger, tinted(NSColor) }

/// ปุ่มพื้นเรียบ ใช้ทุกปุ่มในแผง (ปุ่มระบบเล็กเกินสำหรับแผงนี้ และกำหนดสีพื้นตามสถานะไม่ได้เท่าที่ต้องการ)
final class Chip: NSButton {
    private var style: ChipStyle = .neutral
    var fontSize: CGFloat = 12.5 { didSet { needsDisplay = true } }
    private var handler: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ title: String, style: ChipStyle = .neutral, height: CGFloat = 32,
                     handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.style = style
        self.handler = handler
        isBordered = false
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    @objc private func fire() { handler?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let fill: NSColor
        var text: NSColor
        var weight = NSFont.Weight.regular
        switch style {
        case .neutral:
            fill = NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : hovering ? 0.11 : 0.07)
            text = .labelColor
        case .danger:
            fill = NSColor.systemRed.withAlphaComponent(pressed ? 0.75 : hovering ? 0.88 : 1)
            text = .white
            weight = .semibold
        case .tinted(let c):
            fill = c.withAlphaComponent(pressed ? 0.30 : hovering ? 0.24 : 0.16)
            text = .labelColor
        }
        if !isEnabled { text = .tertiaryLabelColor }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let s = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: text
        ])
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// ปุ่มไอคอนเล็ก (มี toolTip และชื่อสำหรับ VoiceOver)
final class IconButton: NSButton {
    private var handler: (() -> Void)?
    convenience init(symbol: String, label: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = label
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    @objc private func fire() { handler?() }
}

/// ปุ่มเลือกสีธีม
final class SwatchButton: NSButton {
    private let color: NSColor
    private let selected: Bool
    private let handler: () -> Void
    init(color: NSColor, name: String, selected: Bool, handler: @escaping () -> Void) {
        self.color = color; self.selected = selected; self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        title = ""
        toolTip = name
        setAccessibilityLabel(name)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("ไม่ได้ใช้") }
    @objc private func fire() { handler() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        if selected {
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

func panelLabel(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                color: NSColor = .labelColor, align: NSTextAlignment = .center) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    return l
}

func chipRow(_ views: [NSView]) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.distribution = .fillEqually
    s.spacing = 6
    return s
}

func flexibleSpace() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentHuggingPriority(.init(1), for: .vertical)
    return v
}

// ---------- แผงควบคุม ----------
// ใช้แบบเดียวกันสองที่: popover จากเมนูบาร์ และหน้าต่างจาก Dock
// สถานะจริงอยู่ที่ AppDelegate ทั้งหมด แผงแค่แสดงผล จึงตรงกันเสมอ
final class PanelController: NSViewController, NSTextFieldDelegate {
    static let width: CGFloat = 300
    static let contentHeight: CGFloat = 334

    private unowned let app: AppDelegate
    private let topInset: CGFloat
    var showingSettings = false
    private var editingCustom = false
    private var customText = UserDefaults.standard.string(forKey: "customTime") ?? "120"

    private var ring: RingView?
    private var bigLabel: NSTextField?
    private var smallLabel: NSTextField?
    private var statusLine: NSTextField?
    private weak var customField: NSTextField?
    private var builtKey: String?
    private var rebuildQueued = false

    init(app: AppDelegate, topInset: CGFloat) {
        self.app = app
        self.topInset = topInset
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("ไม่ได้ใช้") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.contentHeight + topInset))
        rebuild()
    }

    /// เรียกทุกครั้งที่สถานะเปลี่ยน และทุกวินาทีตอนนับเวลา: ปกติแก้แค่ตัวเลข สร้างปุ่มใหม่เมื่อโครงสร้างเปลี่ยน
    func refresh() {
        guard isViewLoaded else { return }
        if app.power.isActive { editingCustom = false }
        if structureKey() != builtKey { queueRebuild() }
        refreshTexts()
    }

    private func structureKey() -> String {
        [String(showingSettings), String(editingCustom), app.modeKey, String(app.effectiveScreenCanSleep),
         app.currentAccent.rawValue, app.updateTitle, String(app.isUpdating),
         String(app.autoDimEnabled), String(app.lowBattEnabled)].joined(separator: "|")
    }

    // ปุ่มที่กดอยู่อาจถูกแทนที่ระหว่างทำงาน จึงเลื่อนการสร้างใหม่ไปหลัง action จบ
    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rebuildQueued = false
            self.rebuild()
        }
    }

    private func rebuild() {
        if let f = customField { customText = f.stringValue }
        builtKey = structureKey()
        view.subviews.forEach { $0.removeFromSuperview() }
        ring = nil; bigLabel = nil; smallLabel = nil; statusLine = nil
        let root = showingSettings ? buildSettings() : buildMain()
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: topInset),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        refreshTexts()
        if editingCustom { view.window?.makeFirstResponder(customField) }
    }

    private func refreshTexts() {
        guard let ring = ring, let big = bigLabel, let small = smallLabel, let status = statusLine else { return }
        let t = app.ringDisplay(editing: editingCustom)
        ring.progress = t.progress
        ring.color = t.color
        big.stringValue = t.big
        big.font = NSFont.monospacedDigitSystemFont(ofSize: t.big.count > 7 ? 20 : 25, weight: .semibold)
        small.stringValue = t.small
        status.stringValue = t.status
        status.toolTip = t.status
    }

    private func set(editing: Bool) {
        editingCustom = editing
        queueRebuild()
        refreshTexts()
    }

    // ---------- หน้าหลัก ----------
    private func buildMain() -> NSStackView {
        let r = RingView()
        r.color = app.accent
        r.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([r.widthAnchor.constraint(equalToConstant: 148),
                                     r.heightAnchor.constraint(equalToConstant: 148)])
        let big = panelLabel("", size: 25, weight: .semibold)
        let small = panelLabel("", size: 11, color: .secondaryLabelColor)
        let center = NSStackView(views: [big, small])
        center.orientation = .vertical
        center.spacing = 1
        center.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(center)
        NSLayoutConstraint.activate([center.centerXAnchor.constraint(equalTo: r.centerXAnchor),
                                     center.centerYAnchor.constraint(equalTo: r.centerYAnchor)])
        ring = r; bigLabel = big; smallLabel = small

        let status = panelLabel("", size: 11.5, color: .secondaryLabelColor)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLine = status

        let rows = actionRows()
        let actions = NSStackView(views: rows)
        actions.orientation = .vertical
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.heightAnchor.constraint(equalToConstant: 108).isActive = true
        rows.forEach { $0.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true }

        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = app.effectiveScreenCanSleep ? .on : .off
        sw.isEnabled = !app.vpnActive               // โหมด VPN บังคับจอไม่ดับ
        sw.target = self
        sw.action = #selector(toggleScreen(_:))
        sw.setAccessibilityLabel("ให้จอดับได้")
        let swLabel = panelLabel(app.vpnActive ? "จอไม่ดับระหว่างกัน VPN" : "ให้จอดับได้", size: 12.5)
        swLabel.toolTip = "จอดับได้เพื่อประหยัดไฟ แต่เครื่องยังทำงานต่อ"

        let footer = NSStackView(views: [
            sw, swLabel, flexibleSpace(),
            IconButton(symbol: "moon", label: "ดับจอเดี๋ยวนี้") { [weak self] in self?.app.blankScreenNow() },
            IconButton(symbol: "gearshape", label: "ตั้งค่า") { [weak self] in
                self?.showingSettings = true
                self?.queueRebuild()
            }
        ])
        footer.orientation = .horizontal
        footer.spacing = 6

        let root = NSStackView(views: [r, status, actions, footer])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.setCustomSpacing(6, after: r)
        root.setCustomSpacing(12, after: status)
        root.setCustomSpacing(8, after: actions)
        for v in [status, actions, footer] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        return root
    }

    private func actionRows() -> [NSView] {
        let a = app
        func start(_ title: String, _ secs: Int, h: CGFloat = 29) -> Chip {
            Chip(title, height: h) { a.launch(seconds: secs, isInfinite: false) }
        }
        func infinite(h: CGFloat = 29) -> Chip { Chip("ไม่จำกัด", height: h) { a.startInfinite() } }
        func vpn(h: CGFloat = 29) -> Chip {
            Chip("กัน VPN หลุด", style: .tinted(.systemBlue), height: h) { a.vpnMode() }
        }
        func watch(h: CGFloat = 29) -> Chip { Chip("เฝ้าดูแอป…", height: h) { a.pickWatchApp() } }
        let stop = { Chip("หยุด", style: .danger, height: 38) { a.stopNow() } }
        let quick = { chipRow([start("30 น.", 1800), start("1 ชม.", 3600), start("2 ชม.", 7200)]) }

        if editingCustom {
            return [chipRow([start("30 น.", 1800, h: 32), start("1 ชม.", 3600, h: 32), start("2 ชม.", 7200, h: 32)]),
                    chipRow([start("4 ชม.", 14400, h: 32), infinite(h: 32),
                             Chip("ยกเลิก") { [weak self] in self?.set(editing: false) }]),
                    customRow()]
        }
        switch a.modeKey {
        case "timed":
            return [stop(),
                    chipRow([Chip("+15 น.", height: 29) { a.extend(900) },
                             Chip("+30 น.", height: 29) { a.extend(1800) },
                             Chip("+1 ชม.", height: 29) { a.extend(3600) }]),
                    chipRow([infinite(), vpn()])]
        case "infinite":
            return [stop(), quick(), chipRow([vpn(), watch()])]
        case "vpn":
            return [stop(), quick(), chipRow([infinite(), watch()])]
        case "watch":
            return [stop(), quick(), chipRow([infinite(), vpn()])]
        default:
            return [chipRow([start("30 น.", 1800, h: 32), start("1 ชม.", 3600, h: 32), start("2 ชม.", 7200, h: 32)]),
                    chipRow([start("4 ชม.", 14400, h: 32), infinite(h: 32),
                             Chip("กำหนดเอง") { [weak self] in self?.set(editing: true) }]),
                    chipRow([vpn(h: 32), watch(h: 32)])]
        }
    }

    private func customRow() -> NSView {
        let field = NSTextField(string: customText)
        field.placeholderString = "90, 45m, 2h"
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        // ห้ามใช้ target/action: ช่องกรอกจะยิง action ตอนเสียโฟกัสด้วย ทำให้กด "ยกเลิก" แล้วเริ่มจับเวลาเอง
        field.delegate = self
        field.setAccessibilityLabel("เวลาที่กำหนดเอง")
        customField = field
        let go = Chip("เริ่ม", style: .tinted(app.accent)) { [weak self] in self?.startCustom() }
        go.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let s = NSStackView(views: [field, go])
        s.orientation = .horizontal
        s.spacing = 6
        return s
    }

    // Enter = เริ่ม, Esc = ยกเลิก
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            startCustom()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            set(editing: false)
            return true
        default:
            return false
        }
    }

    private func startCustom() {
        guard let f = customField else { return }
        customText = f.stringValue
        if app.startCustom(f.stringValue) { editingCustom = false; refresh() }
    }

    @objc private func toggleScreen(_ s: NSSwitch) { app.setScreenCanSleep(s.state == .on) }

    // ---------- หน้าตั้งค่า ----------
    private func buildSettings() -> NSStackView {
        let a = app
        let back = IconButton(symbol: "chevron.left", label: "กลับ") { [weak self] in
            self?.showingSettings = false
            self?.queueRebuild()
        }
        let head = NSStackView(views: [back, panelLabel("ตั้งค่า", size: 14, weight: .semibold), flexibleSpace()])
        head.orientation = .horizontal
        head.spacing = 4

        let colorRow = NSStackView(views: AccentChoice.allCases.map { c in
            SwatchButton(color: c.color, name: c.label, selected: c == a.currentAccent) { a.pickAccent(c) }
        })
        colorRow.orientation = .horizontal
        colorRow.distribution = .equalSpacing

        let dim = settingRow("หรี่จออัตโนมัติเมื่อไม่ได้ใช้ 5 นาที", on: a.autoDimEnabled,
                             enabled: Brightness.available, #selector(toggleDim(_:)))
        let batt = settingRow("หยุดเองเมื่อใช้แบตต่ำกว่า \(a.lowBattThreshold)%", on: a.lowBattEnabled,
                              enabled: true, #selector(toggleBatt(_:)))

        let upd = Chip(a.updateTitle, height: 26) { a.checkForUpdate() }
        upd.isEnabled = !a.isUpdating
        upd.fontSize = 11.5
        upd.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let verRow = NSStackView(views: [
            panelLabel("KeepAwake v\(a.appVersion())", size: 11, color: .tertiaryLabelColor),
            flexibleSpace(), upd
        ])
        verRow.orientation = .horizontal

        let quit = Chip("ออกจากโปรแกรม", height: 30) { NSApp.terminate(nil) }
        let colorTitle = panelLabel("สีธีม", size: 11.5, weight: .medium, color: .secondaryLabelColor, align: .left)
        let optTitle = panelLabel("พฤติกรรม", size: 11.5, weight: .medium, color: .secondaryLabelColor, align: .left)
        let root = NSStackView(views: [head, colorTitle, colorRow, optTitle, dim, batt, flexibleSpace(), verRow, quit])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.setCustomSpacing(14, after: head)
        root.setCustomSpacing(6, after: colorTitle)
        root.setCustomSpacing(18, after: colorRow)
        root.setCustomSpacing(6, after: optTitle)
        for v in [head, colorRow, dim, batt, verRow, quit] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        return root
    }

    private func settingRow(_ text: String, on: Bool, enabled: Bool, _ sel: Selector) -> NSView {
        let l = panelLabel(text, size: 12.5, align: .left)
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = text
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = on ? .on : .off
        sw.isEnabled = enabled
        sw.target = self
        sw.action = sel
        sw.setAccessibilityLabel(text)
        let s = NSStackView(views: [l, flexibleSpace(), sw])
        s.orientation = .horizontal
        return s
    }
    @objc private func toggleDim(_ s: NSSwitch) { app.setAutoDim(s.state == .on) }
    @objc private func toggleBatt(_ s: NSSwitch) { app.setLowBatt(s.state == .on) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var windowPanel: PanelController?
    var popoverPanel: PanelController?
    var statusItem: NSStatusItem?
    let popover = NSPopover()

    let power = PowerAssertion()
    var timer: Timer?
    var endDate: Date?
    var infinite = false
    var screenCanSleep = true              // ค่าที่ผู้ใช้ตั้งไว้ (บันทึกถาวร)
    var vpnActive = false                  // โหมด VPN บังคับจอไม่ดับเฉพาะรอบนี้
    var ringTotal = 0                      // เวลาทั้งหมดของวงแหวน (ต่อเวลาแล้วเพิ่มตาม ไม่รีเซ็ตเป็นเต็มวง)
    var sessionStart: Date?                // เริ่มรอบนี้เมื่อไหร่ (ใช้แสดง "ผ่านไป")
    var effectiveScreenCanSleep: Bool { screenCanSleep && !vpnActive }

    // เฝ้าดูโปรเซส: กันหลับจนกว่าแอปที่เลือกจะปิด
    var watchedApp: NSRunningApplication?

    // หยุดเมื่อแบตต่ำ
    var lowBattEnabled = false
    let lowBattThreshold = 15
    var battTick = 0

    // หรี่จออัตโนมัติ
    var autoDimEnabled = false
    var isDimmed = false
    var brightnessBeforeDim: Float?
    let dimAfterSeconds: Double = 300      // ไม่แตะเครื่อง 5 นาที -> หรี่จอ
    let dimLevel: Float = 0.05             // ระดับหรี่ (5%)

    var updateTitle = "ตรวจสอบอัปเดต"
    var isUpdating = false
    var currentAccent: AccentChoice = .green
    var accent: NSColor = AccentChoice.green.color

    func applicationDidFinishLaunching(_ note: Notification) {
        loadPreferences()
        buildAppMenu()
        buildWindow()
        buildStatusItem()
        updateStatus()   // ตอนว่างใช้ไอคอนบันเดิล (.icns) — ไม่ override
        showWindow()     // เปิดหน้าต่างเสมอ เผื่อไอคอนเมนูบาร์ไม่มีที่แสดง
    }

    // ---------- โหลดค่าที่บันทึกไว้ ----------
    func loadPreferences() {
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: "accentChoice"), let c = AccentChoice(rawValue: raw) {
            currentAccent = c
        }
        accent = currentAccent.color
        screenCanSleep = (ud.object(forKey: "screenCanSleep") as? Bool) ?? true
        autoDimEnabled = ud.bool(forKey: "autoDim")
        lowBattEnabled = ud.bool(forKey: "stopOnLowBatt")
        if autoDimEnabled { startTimer() }   // ให้เช็ค idle ตั้งแต่เปิดแอป
    }

    // ปิดหน้าต่างแล้ว "ไม่ปิดแอป" — ทำงานต่อเบื้องหลัง
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ note: Notification) { stop() }

    var toldAboutBackground = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)                       // ซ่อนหน้าต่าง ไม่ทำลาย
        if power.isActive && !toldAboutBackground {
            toldAboutBackground = true             // เตือนครั้งแรกครั้งเดียวพอ
            notify("ยังทำงานอยู่เบื้องหลัง — คลิกไอคอนใน Dock หรือเมนูบาร์เพื่อเปิดกลับมา")
        }
        return false
    }

    // คลิกไอคอนใน Dock -> เปิดหน้าต่างกลับมา
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func showWindow() {
        if popover.isShown { popover.performClose(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // เมนูแอป (เพื่อให้ Command+Q ออกจากโปรแกรมได้)
    func buildAppMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let showItem = NSMenuItem(title: "แสดงหน้าต่าง KeepAwake", action: #selector(showWindow), keyEquivalent: "0")
        showItem.target = self
        appMenu.addItem(showItem)
        appMenu.addItem(.separator())
        let updateItem = NSMenuItem(title: "ตรวจสอบเวอร์ชันใหม่...", action: #selector(checkForUpdate), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "ออกจากโปรแกรม KeepAwake",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        // แอปที่สร้างเมนูเองต้องมีเมนู Edit ไม่งั้น Cmd+C/V/X/A ในช่องกรอกจะไม่ทำงาน
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "แก้ไข")
        editMenu.addItem(withTitle: "เลิกทำ", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "ทำซ้ำ", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "ตัด", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "คัดลอก", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "วาง", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "เลือกทั้งหมด", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "หน้าต่าง")
        windowMenu.addItem(withTitle: "ปิดหน้าต่าง", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "ย่อหน้าต่าง", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // ---------- หน้าต่างและเมนูบาร์ ----------
    func buildWindow() {
        let panel = PanelController(app: self, topInset: 30)   // เว้นที่ให้ปุ่มสัญญาณไฟมุมซ้ายบน
        let w = NSWindow(contentViewController: panel)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.title = "KeepAwake"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.center()
        window = w
        windowPanel = panel
    }

    func buildStatusItem() {
        popoverPanel = PanelController(app: self, topInset: 16)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverPanel
        popover.contentSize = NSSize(width: PanelController.width, height: PanelController.contentHeight + 16)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "KeepAwake"
        item.button?.setAccessibilityLabel("KeepAwake")
        statusItem = item
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // ปิดแผงแล้วกลับหน้าหลักเสมอ เปิดครั้งหน้าจะได้เห็นเวลาก่อน
    func popoverDidClose(_ notification: Notification) {
        popoverPanel?.showingSettings = false
        popoverPanel?.refresh()
    }

    /// วงแหวนจิ๋วบนเมนูบาร์: เป็น template image จึงเปลี่ยนสีตามแถบเมนูเอง
    func statusRingImage(progress: CGFloat, active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let r = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(active ? 0.3 : 0.75).setStroke()
            track.stroke()
            if active {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * min(progress, 1), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    var lastStatusItemKey = ""
    func updateStatusItem(progress: CGFloat, title: String) {
        // เปลี่ยนจริงค่อยวาด: แถบเมนูไม่ต้องวาดใหม่ทุกวินาที
        let key = "\(power.isActive)|\(Int(progress * 48))|\(title)"
        guard key != lastStatusItemKey, let button = statusItem?.button else { return }
        lastStatusItemKey = key
        button.image = statusRingImage(progress: progress, active: power.isActive)
        button.title = title.isEmpty ? "" : " \(title)"
    }

    /// โหมดปัจจุบัน ใช้เลือกชุดปุ่มในแผง
    var modeKey: String {
        guard power.isActive else { return "idle" }
        if watchedApp != nil { return "watch" }
        if vpnActive { return "vpn" }
        return infinite ? "infinite" : "timed"
    }

    private var screenStatusText: String {
        (effectiveScreenCanSleep ? "จอดับได้" : "จอไม่ดับ") + " · เครื่องไม่หลับ"
    }

    private func elapsedText() -> String {
        "ผ่านไป \(fmt(Int(Date().timeIntervalSince(sessionStart ?? Date()))))"
    }

    private func endTimeText(_ end: Date, remaining: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = remaining >= 86400 ? "d MMM HH:mm" : "HH:mm"   // เกินหนึ่งวันต้องบอกวันที่ด้วย
        return "ถึง \(f.string(from: end)) น."
    }

    /// ข้อความและวงแหวนของสถานะปัจจุบัน
    func ringDisplay(editing: Bool = false) -> (progress: CGFloat, color: NSColor, big: String, small: String, status: String) {
        switch modeKey {
        case "watch":
            let name = watchedApp?.localizedName ?? "แอป"
            return (1, accent, "เฝ้าดูงาน", elapsedText(), "จนกว่า \(name) จะปิด · เครื่องไม่หลับ")
        case "vpn":
            return (1, .systemBlue, "กัน VPN", elapsedText(), screenStatusText)
        case "infinite":
            return (1, accent, "ไม่จำกัด", elapsedText(), screenStatusText)
        case "timed":
            guard let end = endDate else { fallthrough }
            let rem = Int(end.timeIntervalSinceNow.rounded())
            return (CGFloat(Core.ringProgress(remaining: rem, total: ringTotal)), accent,
                    fmt(rem), endTimeText(end, remaining: rem), screenStatusText)
        default:
            return (0, accent, "พร้อม", "เลือกเวลาด้านล่าง",
                    editing ? "เลข = นาที · m = นาที · h = ชั่วโมง" : "กันไม่ให้ Mac หลับ")
        }
    }

    /// เลือกสีธีมใหม่: บันทึกค่า อัปเดตหน้าจอ/ไอคอน Dock ทันที
    func pickAccent(_ choice: AccentChoice) {
        currentAccent = choice
        accent = choice.color
        UserDefaults.standard.set(choice.rawValue, forKey: "accentChoice")
        updateStatus()
        if power.isActive { updateDockIcon(active: true) }   // ตอนว่างคงไอคอนบันเดิลไว้
    }

    // ---------- อัปเดตอัตโนมัติจาก GitHub Releases ----------
    // ขั้นตอน: เช็คเวอร์ชัน -> ถามผู้ใช้ -> โหลด .dmg -> เมานต์ -> สลับตัวแอป -> เปิดใหม่
    // ทั้งหมดทำด้วยสิทธิ์ผู้ใช้ปกติ (แอปอยู่ ~/Applications) ไม่ต้องใส่รหัสผ่าน

    let updateRepoAPI = "https://api.github.com/repos/joma1022/KeepAwake/releases/latest"

    func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func setUpdateBusy(_ busy: Bool, title: String = "ตรวจสอบอัปเดต") {
        isUpdating = busy
        updateTitle = title
        updateStatus()
    }

    func updateAlert(_ message: String, _ info: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = style
        a.addButton(withTitle: "ตกลง")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func checkForUpdate() {
        guard !isUpdating else { return }
        setUpdateBusy(true, title: "กำลังตรวจสอบ…")

        var req = URLRequest(url: URL(string: updateRepoAPI)!)
        req.setValue("KeepAwake-App", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            DispatchQueue.main.async { self.handleUpdateInfo(data: data, error: err) }
        }.resume()
    }

    func handleUpdateInfo(data: Data?, error: Error?) {
        setUpdateBusy(false)

        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            updateAlert("ตรวจสอบอัปเดตไม่สำเร็จ",
                        "เชื่อมต่อ GitHub ไม่ได้ — ตรวจอินเทอร์เน็ตแล้วลองใหม่อีกครั้ง",
                        style: .warning)
            return
        }

        let current = appVersion()
        guard Core.isNewerVersion(latest: tag, current: current) else {
            updateAlert("ใช้เวอร์ชันล่าสุดอยู่แล้ว", "เวอร์ชันปัจจุบัน v\(current)")
            return
        }

        let htmlURL = json["html_url"] as? String
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let names = assets.compactMap { $0["name"] as? String }

        // ไม่มี .dmg = ติดตั้งอัตโนมัติไม่ได้ -> เปิดหน้าดาวน์โหลดแทน
        guard let pick = Core.pickUpdateAsset(names),
              let assetURLStr = assets.first(where: { ($0["name"] as? String) == pick })?["browser_download_url"] as? String,
              let assetURL = URL(string: assetURLStr) else {
            offerOpenReleasePage(tag: tag, url: htmlURL,
                                 reason: "รุ่นนี้ไม่มีไฟล์ .dmg สำหรับติดตั้งอัตโนมัติ")
            return
        }

        // แอปต้องเขียนทับได้เอง ไม่งั้นต้องให้ผู้ใช้ติดตั้งเอง (กันไปขอรหัสผ่าน)
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: appPath),
              FileManager.default.isWritableFile(atPath: parent) else {
            offerOpenReleasePage(tag: tag, url: htmlURL,
                                 reason: "แอปติดตั้งอยู่ในตำแหน่งที่ต้องใช้สิทธิ์ผู้ดูแล (\(parent))")
            return
        }

        let a = NSAlert()
        a.messageText = "มีเวอร์ชันใหม่: \(tag)"
        a.informativeText = "ตอนนี้ใช้ v\(current)\n\nกด “อัปเดตเลย” เพื่อดาวน์โหลดและติดตั้งให้อัตโนมัติ — แอปจะปิดแล้วเปิดขึ้นมาใหม่เอง"
        a.addButton(withTitle: "อัปเดตเลย")
        a.addButton(withTitle: "เปิดหน้าดาวน์โหลด")
        a.addButton(withTitle: "ไว้ทีหลัง")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(assetURL)
        case .alertSecondButtonReturn:
            if let s = htmlURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        default:
            break
        }
    }

    func offerOpenReleasePage(tag: String, url: String?, reason: String) {
        let a = NSAlert()
        a.messageText = "มีเวอร์ชันใหม่: \(tag)"
        a.informativeText = "\(reason)\nเปิดหน้าดาวน์โหลดเพื่อติดตั้งเองไหม"
        a.addButton(withTitle: "เปิดหน้าดาวน์โหลด")
        a.addButton(withTitle: "ไว้ทีหลัง")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, let s = url, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
    }

    func downloadAndInstall(_ url: URL) {
        setUpdateBusy(true, title: "กำลังดาวน์โหลด…")
        var req = URLRequest(url: url)
        req.setValue("KeepAwake-App", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 300

        URLSession.shared.downloadTask(with: req) { [weak self] tmpURL, resp, err in
            guard let self = self else { return }
            // ต้องย้ายออกจาก tmp ทันที ระบบลบทิ้งเมื่อ closure จบ
            var saved: URL?
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            if let tmpURL = tmpURL, code < 400 {
                let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("KeepAwake-update.dmg")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: tmpURL, to: dest)) != nil { saved = dest }
            }
            DispatchQueue.main.async {
                guard let dmg = saved else {
                    self.setUpdateBusy(false)
                    self.updateAlert("ดาวน์โหลดไม่สำเร็จ",
                                     "โหลดไฟล์อัปเดตไม่ได้ — ลองใหม่ หรือเปิดหน้าดาวน์โหลดเพื่อติดตั้งเอง",
                                     style: .warning)
                    return
                }
                self.installFromDMG(dmg)
            }
        }.resume()
    }

    /// สคริปต์ตัวช่วย: รอแอปปิด -> เมานต์ dmg -> สลับตัวแอป (มี rollback) -> เปิดใหม่
    func installFromDMG(_ dmg: URL) {
        setUpdateBusy(true, title: "กำลังติดตั้ง…")
        let appPath = Bundle.main.bundlePath
        let helper = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keepawake-update.sh")

        let script = """
        #!/bin/bash
        DMG="\(dmg.path)"
        APP="\(appPath)"
        MNT="$(mktemp -d)"
        STAGE="$(mktemp -d)"

        # รอแอปเดิมปิดสนิท (สูงสุด ~10 วินาที)
        for i in $(seq 1 50); do
          pgrep -f "$APP/Contents/MacOS/KeepAwake" >/dev/null 2>&1 || break
          sleep 0.2
        done

        hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MNT" || exit 1
        NEW="$MNT/KeepAwake.app"

        # ก๊อปออกจาก dmg ให้สำเร็จก่อน ค่อยแตะของเดิม — กันแอปหายถ้าไฟล์ที่โหลดมาเสีย
        if [ -d "$NEW" ] && cp -R "$NEW" "$STAGE/KeepAwake.app"; then
          rm -rf "$APP.old"
          if mv "$APP" "$APP.old" 2>/dev/null; then
            if mv "$STAGE/KeepAwake.app" "$APP" 2>/dev/null; then
              rm -rf "$APP.old"
            else
              mv "$APP.old" "$APP"
            fi
          fi
          xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        fi

        hdiutil detach "$MNT" -quiet 2>/dev/null
        rm -rf "$STAGE" "$MNT"
        rm -f "$DMG"
        open "$APP"
        rm -f "$0"
        """

        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [helper.path]
            try p.run()          // ทำงานต่อหลังแอปปิด
        } catch {
            setUpdateBusy(false)
            updateAlert("ติดตั้งไม่สำเร็จ",
                        "เตรียมตัวติดตั้งไม่ได้ — ลองเปิดหน้าดาวน์โหลดเพื่อติดตั้งเอง",
                        style: .warning)
            return
        }
        stop()                    // ปล่อย power assertion ให้เรียบร้อยก่อนปิด
        NSApp.terminate(nil)
    }

    // ---------- ไอคอน Dock + เวลาที่เหลือ ----------
    func updateDockIcon(active: Bool) {
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()
        let bg = active ? accent : NSColor.systemTeal
        let rect = NSRect(x: 28, y: 28, width: 200, height: 200)
        let path = NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46)
        bg.setFill(); path.fill()
        let conf = NSImage.SymbolConfiguration(pointSize: 118, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(conf) {
            let s = sym.size
            let r = NSRect(x: (256 - s.width) / 2, y: (256 - s.height) / 2 - 4, width: s.width, height: s.height)
            sym.draw(in: r)
        }
        img.unlockFocus()
        NSApp.applicationIconImage = img
    }

    var lastBadge = ""
    func setDockBadge(_ text: String) {
        guard text != lastBadge else { return }   // เปลี่ยนจริงค่อยวาด (ข้อความเปลี่ยนนาทีละครั้ง)
        lastBadge = text
        NSApp.dockTile.badgeLabel = text.isEmpty ? nil : text
        NSApp.dockTile.display()
    }

    // logic ล้วนย้ายไป KeepAwakeCore.swift (เพื่อ unit test)
    func fmt(_ total: Int) -> String { Core.fmt(total) }
    func badgeText(_ total: Int) -> String { Core.badgeText(total) }

    func updateStatus() {
        let display = ringDisplay()
        var menuTitle = ""
        switch modeKey {
        case "watch":
            setDockBadge("👁"); menuTitle = "👁"
        case "vpn":
            setDockBadge("∞"); menuTitle = "VPN"
        case "infinite":
            setDockBadge("∞"); menuTitle = "∞"
        case "timed":
            let rem = endDate.map { Int($0.timeIntervalSinceNow.rounded()) } ?? 0
            setDockBadge(badgeText(rem)); menuTitle = Core.menuBarText(rem)
        default:
            setDockBadge("")
        }
        updateStatusItem(progress: display.progress, title: menuTitle)
        windowPanel?.refresh()
        popoverPanel?.refresh()
    }

    // ---------- กันเครื่องหลับ ----------

    func launch(seconds: Int, isInfinite: Bool, notifyUser: Bool = true, vpn: Bool = false,
                continuing: Bool = false) {
        // continuing = รอบเดิมทำต่อ (ต่อเวลา/สลับจอ): วงแหวนและเวลาที่ผ่านไปต้องไม่รีเซ็ต
        let previousTotal = ringTotal
        let previousStart = sessionStart
        stop()
        // สร้าง power assertion ผ่าน IOKit ตรงๆ — in-process ไม่มีโปรเซสลูก ไม่มีทางค้าง
        guard power.start(screenCanSleep: screenCanSleep && !vpn) else {
            // แจ้งชัดๆ อย่าปล่อยให้ผู้ใช้เข้าใจผิดว่าเครื่องถูกกันหลับอยู่
            let a = NSAlert()
            a.messageText = "เริ่มไม่สำเร็จ"
            a.informativeText = "สร้าง power assertion ไม่ได้ — เครื่องยังหลับได้ตามปกติ"
            a.alertStyle = .critical
            a.runModal()
            return
        }
        vpnActive = vpn
        infinite = isInfinite
        ringTotal = continuing ? max(previousTotal, seconds) : seconds
        sessionStart = continuing ? (previousStart ?? Date()) : Date()
        endDate = isInfinite ? nil : Date().addingTimeInterval(TimeInterval(seconds))
        startTimer()
        updateDockIcon(active: true)
        updateStatus()
        if notifyUser { notify(isInfinite ? "เริ่มแล้ว (เปิดค้างไว้)" : "เริ่มกันไม่ให้เครื่องหลับแล้ว") }
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAutoDim()
            self.checkWatchedApp()
            self.checkLowBattery()
            if !self.power.isActive { return }            // ไม่ได้กันเครื่องหลับอยู่ แค่คอยเช็คหรี่จอ
            if !self.infinite, let end = self.endDate, Date() >= end {
                self.stop()
                self.notify("ครบเวลาแล้ว เครื่องกลับมาหลับได้ตามปกติ")
                return
            }
            self.updateStatus()
        }
        t.tolerance = 0.2                 // ลดการปลุก CPU ตรงเวลาเป๊ะ ประหยัดแบต
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        undim()                        // คืนความสว่างก่อนเสมอ
        timer?.invalidate(); timer = nil
        power.stop()
        infinite = false
        endDate = nil
        watchedApp = nil
        vpnActive = false
        ringTotal = 0
        sessionStart = nil
        battTick = 0
        NSApp.applicationIconImage = nil   // คืนเป็นไอคอนบันเดิล (.icns)
        updateStatus()
        // ถ้ายังเปิด "หรี่จออัตโนมัติ" อยู่ ให้ timer เดินต่อเพื่อคอยเช็ค idle
        if autoDimEnabled { startTimer() }
    }

    func notify(_ msg: String) {
        let safe = Core.escapeForAppleScript(msg)
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", "display notification \"\(safe)\" with title \"KeepAwake\""]
        try? t.run()
    }

    // ---------- การกระทำของปุ่ม ----------
    @objc func startInfinite() { launch(seconds: 0, isInfinite: true) }
    @objc func vpnMode() {
        launch(seconds: 0, isInfinite: true, vpn: true)   // จอไม่ดับ ไม่ล็อกจอ -> VPN ไม่หลุด
    }
    func extend(_ delta: Int) {
        guard power.isActive, !infinite, let end = endDate else { return }
        let remaining = max(0, Int(end.timeIntervalSinceNow.rounded()))
        ringTotal += delta
        launch(seconds: remaining + delta, isInfinite: false, notifyUser: false, continuing: true)  // ไม่แจ้ง "เริ่ม" ซ้ำ
    }

    /// คืน true ถ้าเริ่มได้ ค่าไม่ถูกต้องจะแจ้งเตือนและคงช่องกรอกไว้
    func startCustom(_ text: String) -> Bool {
        guard let secs = parseTime(text) else {
            let e = NSAlert()
            e.messageText = "ค่าที่พิมพ์ไม่ถูกต้อง"
            e.informativeText = "ลองใหม่ เช่น 90, 45m, 2h"
            NSApp.activate(ignoringOtherApps: true)
            e.runModal()
            return false
        }
        UserDefaults.standard.set(text, forKey: "customTime")
        launch(seconds: secs, isInfinite: false)
        return power.isActive
    }

    func setScreenCanSleep(_ on: Bool) {
        screenCanSleep = on
        UserDefaults.standard.set(screenCanSleep, forKey: "screenCanSleep")
        guard power.isActive else { updateStatus(); return }
        if infinite {
            let w = watchedApp                       // เก็บ watch ไว้ก่อน (launch->stop จะล้างทิ้ง)
            launch(seconds: 0, isInfinite: true, notifyUser: false, continuing: true)   // แค่สลับโหมด ไม่ต้องแจ้งซ้ำ
            if power.isActive, w != nil {            // คืนการเฝ้าดูหลังสลับโหมดจอ
                watchedApp = w
                updateStatus()
            }
        } else if let end = endDate {
            launch(seconds: max(1, Int(end.timeIntervalSinceNow.rounded())), isInfinite: false,
                   notifyUser: false, continuing: true)
        }
    }

    @objc func stopNow() { stop(); notify("หยุดแล้ว เครื่องกลับมาหลับได้ตามปกติ") }

    // ---------- เฝ้าดูโปรเซส: กันหลับจนกว่าแอปที่เลือกจะปิด ----------
    @objc func pickWatchApp() {
        // รายชื่อแอปที่เปิดอยู่ (เฉพาะแอปมีหน้าต่าง ไม่รวมตัวเอง) เรียงตามชื่อ
        let myPid = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPid }  // เทียบ pid ชัวร์กว่า
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        guard !apps.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "กันหลับจนกว่างานจะเสร็จ"
        alert.informativeText = "เลือกแอปที่กำลังทำงาน — พอแอปนั้นปิด เครื่องจะกลับมาหลับได้เอง"
        alert.addButton(withTitle: "เริ่มเฝ้าดู")
        alert.addButton(withTitle: "ยกเลิก")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for a in apps { pop.addItem(withTitle: a.localizedName ?? "ไม่ทราบชื่อ") }
        alert.accessoryView = pop
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              pop.indexOfSelectedItem >= 0, pop.indexOfSelectedItem < apps.count else { return }

        launch(seconds: 0, isInfinite: true)
        guard power.isActive else { return }        // launch ล้มเหลว อย่าตั้ง watch ค้าง
        watchedApp = apps[pop.indexOfSelectedItem]
        updateStatus()
    }

    func checkWatchedApp() {
        guard power.isActive, let w = watchedApp else { return }
        if w.isTerminated {
            let name = w.localizedName ?? "แอปที่เฝ้าดู"
            stop()
            notify("\(name) ปิดแล้ว — เครื่องกลับมาหลับได้ตามปกติ")
        }
    }

    // ---------- หยุดเมื่อแบตต่ำ ----------
    func setLowBatt(_ on: Bool) {
        lowBattEnabled = on
        UserDefaults.standard.set(lowBattEnabled, forKey: "stopOnLowBatt")
        updateStatus()
    }

    func checkLowBattery() {
        guard lowBattEnabled, power.isActive else { return }
        battTick += 1
        guard battTick >= 30 else { return }        // เช็คทุก ~30 วินาทีพอ
        battTick = 0
        guard let b = batteryStatus(),
              Core.shouldStopForBattery(onBattery: b.onBattery, percent: b.percent, threshold: lowBattThreshold)
        else { return }
        stop()
        notify("แบตเหลือ \(b.percent)% — หยุดกันเครื่องหลับเพื่อถนอมแบต")
    }

    // ---------- หรี่จอ / ดับจอ โดยเครื่องยังทำงาน ----------
    func setAutoDim(_ on: Bool) {
        autoDimEnabled = on
        UserDefaults.standard.set(autoDimEnabled, forKey: "autoDim")
        if autoDimEnabled {
            if timer == nil { startTimer() }        // ให้ตัวจับเวลาเดินเพื่อคอยเช็ค idle
        } else {
            undim()
            if !power.isActive {                    // ไม่มีงานอะไรให้ timer ทำแล้ว -> หยุด ไม่ปล่อยเดินเปล่า
                timer?.invalidate(); timer = nil
            }
        }
        updateStatus()
    }

    @objc func blankScreenNow() {
        // ดับจอทันที แต่ระบบยังตื่นทำงานต่อ
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    func idleSeconds() -> Double {
        // kCGAnyInputEventType = ~0 ; ไม่ force-unwrap กันแครชถ้า init คืน nil
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    func checkAutoDim() {
        guard autoDimEnabled, Brightness.available else { return }
        switch Core.dimAction(isDimmed: isDimmed, idleSeconds: idleSeconds(), dimAfter: dimAfterSeconds) {
        case "dim":
            brightnessBeforeDim = Brightness.get()
            Brightness.set(dimLevel)
            isDimmed = true
        case "undim":
            undim()
        default:
            break
        }
    }

    func undim() {
        guard isDimmed else { return }
        // ถ้าอ่านค่าเดิมไม่ได้ตอนหรี่ ให้คืนที่ 50% แทน — อย่าปล่อยจอมืดค้างที่ 5%
        Brightness.set(brightnessBeforeDim ?? 0.5)
        brightnessBeforeDim = nil
        isDimmed = false
    }

    func parseTime(_ text: String) -> Int? { Core.parseTime(text) }
}

// จุดเริ่มโปรแกรม (@main เพราะคอมไพล์ร่วมกับ KeepAwakeCore.swift แบบหลายไฟล์)
@main
struct KeepAwakeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()   // ไม่คืนค่า — delegate มีชีวิตตลอดอายุแอป
    }
}
