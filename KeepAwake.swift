// KeepAwake — หน้าต่างควบคุม กันไม่ให้ Mac หลับ (Swift / AppKit)
// ฟีเจอร์: ปุ่มเลือกเวลา, ต่อเวลา +15/+30, นับถอยหลังสด, สลับจอดับ/จอติด,
//          ไอคอน Dock เอง + แสดงเวลาที่เหลือบน Dock
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var subLabel: NSTextField!
    var headerBox: NSView!
    var stopButton: NSButton!
    var displayCheck: NSButton!
    var customField: NSTextField!

    let power = PowerAssertion()
    var timer: Timer?
    var endDate: Date?
    var infinite = false
    var screenCanSleep = true

    // เฝ้าดูโปรเซส: กันหลับจนกว่าแอปที่เลือกจะปิด
    var watchedApp: NSRunningApplication?

    // หยุดเมื่อแบตต่ำ
    var lowBattCheck: NSButton!
    var lowBattEnabled = false
    let lowBattThreshold = 15
    var battTick = 0

    // หรี่จออัตโนมัติ
    var autoDimCheck: NSButton!
    var autoDimEnabled = false
    var isDimmed = false
    var brightnessBeforeDim: Float?
    let dimAfterSeconds: Double = 300      // ไม่แตะเครื่อง 5 นาที -> หรี่จอ
    let dimLevel: Float = 0.05             // ระดับหรี่ (5%)

    let accent = NSColor.systemGreen

    func applicationDidFinishLaunching(_ note: Notification) {
        buildAppMenu()
        buildWindow()
        updateStatus()   // ตอนว่างใช้ไอคอนบันเดิล (.icns) — ไม่ override
        NSApp.activate(ignoringOtherApps: true)
    }

    // ปิดหน้าต่างแล้ว "ไม่ปิดแอป" — ทำงานต่อเบื้องหลัง
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ note: Notification) { stop() }

    var toldAboutBackground = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)                       // ซ่อนหน้าต่าง ไม่ทำลาย
        if power.isActive && !toldAboutBackground {
            toldAboutBackground = true             // เตือนครั้งแรกครั้งเดียวพอ
            notify("ยังทำงานอยู่เบื้องหลัง — คลิกไอคอนใน Dock เพื่อเปิดหน้าต่างกลับมา")
        }
        return false
    }

    // คลิกไอคอนใน Dock -> เปิดหน้าต่างกลับมา
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func showWindow() {
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
        appMenu.addItem(NSMenuItem(title: "ออกจากโปรแกรม KeepAwake",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // ---------- UI ----------
    func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "KeepAwake"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.center()
        w.delegate = self
        window = w

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 34, left: 22, bottom: 22, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        // ===== การ์ดสถานะด้านบน =====
        statusLabel = makeLabel("พร้อมใช้งาน", size: 34, bold: true)
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        subLabel = makeLabel("กันไม่ให้ Mac หลับ", size: 12, bold: false)
        subLabel.textColor = .secondaryLabelColor
        headerBox = card([statusLabel, subLabel], spacing: 3, padding: 20)
        root.addArrangedSubview(headerBox)

        // ===== การ์ด: ตั้งเวลา =====
        customField = NSTextField(string: UserDefaults.standard.string(forKey: "customTime") ?? "120")
        customField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        customField.alignment = .center
        customField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        customField.target = self
        customField.action = #selector(startCustom)   // กด Enter ในช่อง = เริ่มทันที

        let hint = makeLabel("เลข = นาที · เติม m = นาที · เติม h = ชั่วโมง", size: 10, bold: false)
        hint.textColor = .tertiaryLabelColor

        let timeCard = card([
            sectionLabel("ตั้งเวลา"),
            hstack([btn("30 นาที", #selector(start30)), btn("1 ชั่วโมง", #selector(start60))]),
            hstack([btn("2 ชั่วโมง", #selector(start120)), btn("4 ชั่วโมง", #selector(start240))]),
            hstack([btn("+15 นาที", #selector(add15)), btn("+30 นาที", #selector(add30))]),
            hstack([customField, btn("กำหนดเอง", #selector(startCustom))]),
            hint,
            btn("เปิดค้างไว้ (ไม่จับเวลา)", #selector(startInfinite)),
            btn("จนกว่างานจะเสร็จ… (เลือกแอปที่เฝ้าดู)", #selector(pickWatchApp))
        ], spacing: 8, padding: 14)
        root.addArrangedSubview(timeCard)

        // ===== การ์ด: หน้าจอ & VPN =====
        let vpnBtn = btn("กัน VPN หลุด — จอไม่ดับ", #selector(vpnMode))
        vpnBtn.bezelColor = NSColor.systemBlue
        vpnBtn.contentTintColor = .white

        let ud = UserDefaults.standard
        screenCanSleep = (ud.object(forKey: "screenCanSleep") as? Bool) ?? true
        autoDimEnabled = ud.bool(forKey: "autoDim")

        displayCheck = NSButton(checkboxWithTitle: "ให้จอดับได้ระหว่างทำงาน (ประหยัดไฟ)",
                                target: self, action: #selector(toggleDisplay))
        displayCheck.state = screenCanSleep ? .on : .off
        autoDimCheck = NSButton(checkboxWithTitle: "หรี่จออัตโนมัติเมื่อไม่ได้ใช้ 5 นาที",
                                target: self, action: #selector(toggleAutoDim))
        autoDimCheck.state = autoDimEnabled ? .on : .off
        autoDimCheck.isEnabled = Brightness.available
        if autoDimEnabled { startTimer() }   // ให้เช็ค idle ตั้งแต่เปิดแอป

        lowBattEnabled = ud.bool(forKey: "stopOnLowBatt")
        lowBattCheck = NSButton(checkboxWithTitle: "หยุดอัตโนมัติเมื่อใช้แบตและต่ำกว่า \(lowBattThreshold)%",
                                target: self, action: #selector(toggleLowBatt))
        lowBattCheck.state = lowBattEnabled ? .on : .off

        let screenCard = card([
            sectionLabel("หน้าจอ & VPN"),
            vpnBtn,
            leftRow(displayCheck),
            leftRow(autoDimCheck),
            leftRow(lowBattCheck),
            btn("ดับจอเดี๋ยวนี้ (เครื่องทำงานต่อ)", #selector(blankScreenNow))
        ], spacing: 8, padding: 14)
        root.addArrangedSubview(screenCard)

        // ===== ปุ่มหยุด =====
        stopButton = btn("หยุด", #selector(stopNow))
        stopButton.isEnabled = false
        root.addArrangedSubview(stopButton)

        let content = w.contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        // ให้การ์ดกว้างเท่ากันทั้งหมด
        for c in [headerBox!, timeCard, screenCard] {
            c.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        }
        stopButton.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
        w.makeKeyAndOrderFront(nil)
    }

    /// กล่องการ์ดพื้นหลังโค้งมน
    func card(_ views: [NSView], spacing: CGFloat, padding: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        s.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            s.topAnchor.constraint(equalTo: box.topAnchor),
            s.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        // ให้ของข้างในกว้างเต็มการ์ด
        for v in views where (v is NSStackView || v is NSButton) {
            v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -padding * 2).isActive = true
        }
        return box
    }

    /// จัดคอนโทรลชิดซ้ายภายในการ์ด
    func leftRow(_ v: NSView) -> NSStackView {
        let s = NSStackView(views: [v])
        s.orientation = .horizontal
        s.alignment = .centerY
        s.distribution = .fill
        return s
    }

    func makeLabel(_ s: String, size: CGFloat, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        l.alignment = .center
        return l
    }
    func sectionLabel(_ s: String) -> NSTextField {
        let l = makeLabel(s, size: 10, bold: true)
        l.textColor = .secondaryLabelColor
        return l
    }
    func btn(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }
    func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        return s
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
        let active = power.isActive
        if !active {
            statusLabel.stringValue = "พร้อมใช้งาน"
            statusLabel.font = NSFont.boldSystemFont(ofSize: 26)
            statusLabel.textColor = .secondaryLabelColor
            subLabel.stringValue = "กันไม่ให้ Mac หลับ"
            setDockBadge("")
        } else if infinite {
            if let w = watchedApp {
                statusLabel.stringValue = "เฝ้าดูงาน"
                statusLabel.font = NSFont.boldSystemFont(ofSize: 30)
                statusLabel.textColor = accent
                subLabel.stringValue = "จนกว่า \(w.localizedName ?? "แอป") จะปิด • เครื่องไม่หลับ"
                setDockBadge("👁")
            } else {
                statusLabel.stringValue = "เปิดค้างไว้"
                statusLabel.font = NSFont.boldSystemFont(ofSize: 30)
                statusLabel.textColor = accent
                subLabel.stringValue = screenCanSleep ? "จอดับได้ • เครื่องไม่หลับ" : "จอไม่ดับ • เครื่องไม่หลับ"
                setDockBadge("∞")
            }
        } else if let end = endDate {
            let rem = Int(end.timeIntervalSinceNow.rounded())
            statusLabel.stringValue = fmt(rem)
            statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold)
            statusLabel.textColor = accent
            subLabel.stringValue = screenCanSleep ? "จอดับได้ • เครื่องไม่หลับ" : "จอไม่ดับ • เครื่องไม่หลับ"
            setDockBadge(badgeText(rem))
        }
        // การ์ดสถานะเปลี่ยนสีตามสถานะ
        headerBox?.layer?.backgroundColor = active
            ? accent.withAlphaComponent(0.12).cgColor
            : NSColor.controlBackgroundColor.cgColor
        headerBox?.layer?.borderColor = active
            ? accent.withAlphaComponent(0.45).cgColor
            : NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        stopButton?.isEnabled = active
        stopButton?.bezelColor = active ? NSColor.systemRed : nil
    }

    // ---------- กันเครื่องหลับ ----------

    func launch(seconds: Int, isInfinite: Bool, notifyUser: Bool = true) {
        stop()
        // สร้าง power assertion ผ่าน IOKit ตรงๆ — in-process ไม่มีโปรเซสลูก ไม่มีทางค้าง
        guard power.start(screenCanSleep: screenCanSleep) else {
            // แจ้งชัดๆ อย่าปล่อยให้ผู้ใช้เข้าใจผิดว่าเครื่องถูกกันหลับอยู่
            let a = NSAlert()
            a.messageText = "เริ่มไม่สำเร็จ"
            a.informativeText = "สร้าง power assertion ไม่ได้ — เครื่องยังหลับได้ตามปกติ"
            a.alertStyle = .critical
            a.runModal()
            return
        }
        infinite = isInfinite
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
    @objc func start30() { launch(seconds: 1800, isInfinite: false) }
    @objc func start60() { launch(seconds: 3600, isInfinite: false) }
    @objc func start120() { launch(seconds: 7200, isInfinite: false) }
    @objc func start240() { launch(seconds: 14400, isInfinite: false) }
    @objc func startInfinite() { launch(seconds: 0, isInfinite: true) }
    @objc func vpnMode() {
        screenCanSleep = false          // จอไม่ดับ ไม่ล็อกจอ -> VPN ไม่หลุด
        displayCheck.state = .off
        launch(seconds: 0, isInfinite: true)
    }
    @objc func add15() { extend(900) }
    @objc func add30() { extend(1800) }

    func extend(_ delta: Int) {
        if !power.isActive {
            launch(seconds: delta, isInfinite: false)           // ยังไม่ได้เริ่ม -> เริ่มใหม่
        } else if infinite {
            notify("อยู่ในโหมดเปิดค้างไว้ ไม่ต้องต่อเวลา")        // บอกผู้ใช้ ไม่เงียบเฉย
        } else if let end = endDate {
            let remaining = max(0, Int(end.timeIntervalSinceNow.rounded()))
            launch(seconds: remaining + delta, isInfinite: false, notifyUser: false)  // ต่อเวลา ไม่ต้องแจ้ง "เริ่ม" ซ้ำ
        }
    }

    @objc func startCustom() {
        if let secs = parseTime(customField.stringValue) {
            UserDefaults.standard.set(customField.stringValue, forKey: "customTime")
            launch(seconds: secs, isInfinite: false)
        } else {
            let e = NSAlert()
            e.messageText = "ค่าที่พิมพ์ไม่ถูกต้อง"
            e.informativeText = "ลองใหม่ เช่น 90, 45m, 2h"
            e.runModal()
        }
    }

    @objc func toggleDisplay() {
        screenCanSleep = (displayCheck.state == .on)
        UserDefaults.standard.set(screenCanSleep, forKey: "screenCanSleep")
        guard power.isActive else { updateStatus(); return }
        if infinite {
            let w = watchedApp                       // เก็บ watch ไว้ก่อน (launch->stop จะล้างทิ้ง)
            launch(seconds: 0, isInfinite: true, notifyUser: false)   // แค่สลับโหมด ไม่ต้องแจ้งซ้ำ
            if power.isActive, w != nil {            // คืนการเฝ้าดูหลังสลับโหมดจอ
                watchedApp = w
                updateStatus()
            }
        } else if let end = endDate {
            launch(seconds: max(1, Int(end.timeIntervalSinceNow.rounded())), isInfinite: false, notifyUser: false)
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
    @objc func toggleLowBatt() {
        lowBattEnabled = (lowBattCheck.state == .on)
        UserDefaults.standard.set(lowBattEnabled, forKey: "stopOnLowBatt")
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
    @objc func toggleAutoDim() {
        autoDimEnabled = (autoDimCheck.state == .on)
        UserDefaults.standard.set(autoDimEnabled, forKey: "autoDim")
        if autoDimEnabled {
            if timer == nil { startTimer() }        // ให้ตัวจับเวลาเดินเพื่อคอยเช็ค idle
        } else {
            undim()
            if !power.isActive {                    // ไม่มีงานอะไรให้ timer ทำแล้ว -> หยุด ไม่ปล่อยเดินเปล่า
                timer?.invalidate(); timer = nil
            }
        }
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
