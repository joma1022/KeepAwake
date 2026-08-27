// Tests — unit tests สำหรับ KeepAwakeCore
// รันผ่าน "รันเทสต์.command" หรือ: xcrun swift KeepAwakeCore.swift Tests.swift
// กติกา: ทุกบั๊กที่เคยเจอจริง ต้องมีเทสต์กันไม่ให้กลับมา (ดูคอมเมนต์ [เคยพัง])
import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1 } else { failed += 1; print("  FAIL: \(name)") }
}
func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { passed += 1 } else { failed += 1; print("  FAIL: \(name)  got=\(got) want=\(want)") }
}

// ---------- parseTime ----------
print("parseTime:")
eq("เลขล้วน = นาที", Core.parseTime("90"), 5400)
eq("m = นาที", Core.parseTime("45m"), 2700)
eq("h = ชั่วโมง", Core.parseTime("2h"), 7200)
eq("ทศนิยม h", Core.parseTime("1.5h"), 5400)
eq("ว่าง = ค่าเริ่มต้น 120 นาที", Core.parseTime(""), 7200)
eq("ช่องว่างรอบตัวเลข", Core.parseTime("  30  "), 1800)
eq("ตัวพิมพ์ใหญ่ H", Core.parseTime("2H"), 7200)
check("[เคยพัง] ตัวอักษรล้วน -> nil (เคยกลายเป็น 0=เปิดค้าง)", Core.parseTime("abc") == nil)
check("หน่วยแปลก -> nil", Core.parseTime("2x") == nil)
check("ติดลบ -> nil", Core.parseTime("-5") == nil)
check("ศูนย์ -> nil", Core.parseTime("0") == nil)
check("จุดหลายจุด -> nil", Core.parseTime("1.2.3") == nil)
check("inf -> nil", Core.parseTime("inf") == nil)
check("nan -> nil", Core.parseTime("nan") == nil)
check("ใหญ่เกิน -> nil", Core.parseTime("99999999999h") == nil)

// ---------- fmt ----------
print("fmt:")
eq("ชั่วโมง", Core.fmt(7170), "1:59:30")
eq("ต่ำกว่าชั่วโมง", Core.fmt(150), "02:30")
eq("ศูนย์", Core.fmt(0), "00:00")
eq("[เคยพัง] ติดลบถือเป็นศูนย์", Core.fmt(-5), "00:00")
eq("ขอบชั่วโมงพอดี", Core.fmt(3600), "1:00:00")
eq("ก่อนขอบชั่วโมง", Core.fmt(3599), "59:59")

// ---------- badgeText ----------
print("badgeText:")
eq("ชั่วโมง", Core.badgeText(7170), "1:59")
eq("ปัดขึ้นเป็นนาที", Core.badgeText(90), "2 นาที")
eq("นาทีเป๊ะไม่ปัด", Core.badgeText(120), "2 นาที")
eq("อย่างน้อย 1 นาที", Core.badgeText(10), "1 นาที")
eq("ศูนย์ก็อย่างน้อย 1", Core.badgeText(0), "1 นาที")

// ---------- escapeForAppleScript ----------
print("escapeForAppleScript:")
eq("[เคยพัง] เครื่องหมายคำพูด", Core.escapeForAppleScript("บอก \"สวัสดี\""), "บอก \\\"สวัสดี\\\"")
eq("แบ็กสแลช", Core.escapeForAppleScript("a\\b"), "a\\\\b")
eq("ข้อความปกติไม่เปลี่ยน", Core.escapeForAppleScript("ปกติ"), "ปกติ")

// ---------- shouldStopForBattery ----------
print("shouldStopForBattery:")
check("ใช้แบต+ต่ำกว่าเกณฑ์ -> หยุด", Core.shouldStopForBattery(onBattery: true, percent: 10, threshold: 15))
check("เสียบสาย -> ไม่หยุดแม้แบตต่ำ", !Core.shouldStopForBattery(onBattery: false, percent: 10, threshold: 15))
check("แบตเท่าเกณฑ์พอดี -> ยังไม่หยุด", !Core.shouldStopForBattery(onBattery: true, percent: 15, threshold: 15))
check("แบตสูง -> ไม่หยุด", !Core.shouldStopForBattery(onBattery: true, percent: 80, threshold: 15))

// ---------- dimAction ----------
print("dimAction:")
eq("idle ถึงเกณฑ์ -> หรี่", Core.dimAction(isDimmed: false, idleSeconds: 300, dimAfter: 300), "dim")
eq("idle ไม่ถึง -> เฉย", Core.dimAction(isDimmed: false, idleSeconds: 299, dimAfter: 300), "none")
eq("[เคยพัง] หรี่อยู่+ขยับเมาส์ -> คืนสว่าง", Core.dimAction(isDimmed: true, idleSeconds: 0.5, dimAfter: 300), "undim")
eq("หรี่อยู่+ยัง idle -> คงหรี่", Core.dimAction(isDimmed: true, idleSeconds: 500, dimAfter: 300), "none")

// ---------- isNewerVersion ----------
print("isNewerVersion:")
check("เวอร์ชันหลักใหม่กว่า", Core.isNewerVersion(latest: "2.0", current: "1.9"))
check("เวอร์ชันรองใหม่กว่า", Core.isNewerVersion(latest: "1.3", current: "1.2"))
check("เท่ากัน -> ไม่ใหม่กว่า", !Core.isNewerVersion(latest: "1.2", current: "1.2"))
check("เก่ากว่า -> ไม่ใหม่กว่า", !Core.isNewerVersion(latest: "1.1", current: "1.2"))
check("มี v นำหน้า", Core.isNewerVersion(latest: "v1.3", current: "1.2"))
check("ความยาวไม่เท่ากัน (1.2.1 vs 1.2)", Core.isNewerVersion(latest: "1.2.1", current: "1.2"))
check("ความยาวไม่เท่ากัน เท่ากันจริง (1.2.0 vs 1.2)", !Core.isNewerVersion(latest: "1.2.0", current: "1.2"))

// ---------- สรุป ----------
print("")
print("ผ่าน \(passed) / \(passed + failed)")
if failed > 0 {
    print("มีเทสต์ไม่ผ่าน \(failed) ข้อ — อย่าเพิ่งติดตั้งแอปเวอร์ชันนี้")
    exit(1)
}
print("เทสต์ผ่านทั้งหมด")
exit(0)
