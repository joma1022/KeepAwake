// KeepAwakeCore — logic ล้วน ไม่แตะ UI/ระบบ เพื่อให้เขียน unit test ได้
// กติกา: ทุกฟังก์ชันในไฟล์นี้ต้อง deterministic (อินพุตเดิม = เอาต์พุตเดิมเสมอ)
import CryptoKit
import Foundation

enum Core {

    /// แปลงข้อความเวลาเป็นวินาที: "90"=นาที, "45m"=นาที, "2h"=ชั่วโมง, ว่าง=120 นาที
    /// คืน nil ถ้าค่าไม่ถูกต้อง (ไม่ใช่ตัวเลข, ติดลบ, ศูนย์)
    static func parseTime(_ text: String) -> Int? {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "120" }
        var mult = 60.0
        if s.hasSuffix("h") { mult = 3600; s = String(s.dropLast()) }
        else if s.hasSuffix("m") { mult = 60; s = String(s.dropLast()) }
        guard let v = Double(s), v > 0, v.isFinite else { return nil }
        let secs = (v * mult).rounded()
        guard secs >= 1, secs <= Double(Int32.max) else { return nil }
        return Int(secs)
    }

    /// รูปแบบนับถอยหลังบนหน้าต่าง: ชม>0 -> "H:MM:SS", ไม่งั้น "MM:SS" (ค่าติดลบถือเป็น 0)
    static func fmt(_ total: Int) -> String {
        let s = max(0, total)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    /// ข้อความ badge บน Dock: ชม>0 -> "H:MM", ไม่งั้นปัดขึ้นเป็นนาที "N นาที" (อย่างน้อย 1)
    static func badgeText(_ total: Int) -> String {
        let s = max(0, total)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        return String(format: "%d นาที", max(1, m + (s % 60 > 0 ? 1 : 0)))
    }

    /// สัดส่วนของวงแหวนเวลา (0...1): กันค่าล้นและการหารด้วยศูนย์
    static func ringProgress(remaining: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(remaining) / Double(total)))
    }

    /// ข้อความสั้นบนเมนูบาร์: ชม>0 -> "H:MM", ไม่งั้นปัดขึ้นเป็นนาที "N น." (อย่างน้อย 1)
    /// 59:01 ขึ้นไปปัดเป็น "1:00" เพื่อไม่ให้ขึ้น "60 น."
    static func menuBarText(_ total: Int) -> String {
        let s = max(0, total)
        if s >= 3600 { return String(format: "%d:%02d", s / 3600, (s % 3600) / 60) }
        let minutes = max(1, (s + 59) / 60)
        return minutes >= 60 ? "1:00" : "\(minutes) น."
    }

    /// escape ข้อความก่อนแทรกเข้า AppleScript string literal
    static func escapeForAppleScript(_ msg: String) -> String {
        return msg.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// ตัดสินว่าควรหยุดเพราะแบตต่ำไหม
    static func shouldStopForBattery(onBattery: Bool, percent: Int, threshold: Int) -> Bool {
        return onBattery && percent < threshold
    }

    /// ตัดสินสถานะหรี่จอ: คืนค่าการกระทำ ("dim" | "undim" | "none")
    static func dimAction(isDimmed: Bool, idleSeconds: Double, dimAfter: Double) -> String {
        if !isDimmed && idleSeconds >= dimAfter { return "dim" }
        if isDimmed && idleSeconds < 2 { return "undim" }
        return "none"
    }

    /// เทียบเวอร์ชันแบบ semver อย่างง่าย: latest ใหม่กว่า current ไหม (รองรับ "v" นำหน้า, เติม 0 ให้ความยาวไม่เท่ากัน)
    static func isNewerVersion(latest: String, current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { Int($0) ?? 0 }
        }
        let l = parts(latest), c = parts(current)
        let n = max(l.count, c.count)
        for i in 0..<n {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    /// เลือกไฟล์ติดตั้งจากรายชื่อ asset ของ release: เอา .dmg (อัปเดตอัตโนมัติได้ ไม่ต้องใส่รหัสผ่าน)
    /// คืน nil ถ้าไม่มี .dmg — ให้ผู้เรียกเปิดหน้าดาวน์โหลดแทน
    static func pickUpdateAsset(_ names: [String]) -> String? {
        return names.first { $0.lowercased().hasSuffix(".dmg") }
    }

    /// เลือกไฟล์ checksum ของตัวติดตั้งที่ระบุ คืน nil ถ้าไม่มี (ผู้เรียกต้องไม่ติดตั้งอัตโนมัติ)
    static func pickChecksumAsset(_ names: [String], for fileName: String) -> String? {
        let want = (fileName + ".sha256").lowercased()
        return names.first { $0.lowercased() == want }
    }

    /// อ่านค่า SHA-256 จากไฟล์ checksum: รับรูปแบบของ shasum หรือค่า hash อย่างเดียว
    /// คืน nil ถ้ารูปแบบไม่ถูกต้อง หรือระบุชื่อไฟล์อื่น
    static func parseChecksum(_ text: String, fileName: String) -> String? {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let hash = parts[0].lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        if parts.count == 2 {
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            guard name == fileName else { return nil }
        }
        return hash
    }

    /// ค่า SHA-256 แบบเลขฐานสิบหกตัวพิมพ์เล็ก
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
