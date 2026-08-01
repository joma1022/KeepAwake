#!/bin/bash
# ============================================================
#  ตัวติดตั้ง KeepAwake (แอปหน้าต่างควบคุม)
#  ดับเบิลคลิกครั้งเดียว -> สร้างไอคอน + คอมไพล์ Swift เป็นแอป + เปิดใช้งาน
#  ต้องมีไฟล์ KeepAwake.swift อยู่โฟลเดอร์เดียวกัน
#  ใช้ swiftc / iconutil / sips ที่มากับ macOS (ต้องมี Command Line Tools)
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/KeepAwake.swift"
CORE="$DIR/KeepAwakeCore.swift"
APP="$HOME/Applications/KeepAwake.app"
TMP="$(mktemp -d)"

note() { osascript -e "display dialog \"$1\" with title \"KeepAwake\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1; }
fail() { osascript -e "display dialog \"ติดตั้งไม่สำเร็จ:
$1\" with title \"KeepAwake\" buttons {\"OK\"} default button \"OK\" with icon stop" >/dev/null 2>&1; rm -rf "$TMP"; exit 1; }

[ -f "$SRC" ] || fail "ไม่พบไฟล์ KeepAwake.swift ในโฟลเดอร์เดียวกัน"
[ -f "$CORE" ] || fail "ไม่พบไฟล์ KeepAwakeCore.swift ในโฟลเดอร์เดียวกัน"

# รัน unit tests ก่อนติดตั้ง (ถ้ามี) — เทสต์พัง = ไม่ติดตั้ง
if [ -f "$DIR/Tests.swift" ]; then
    echo "กำลังรันเทสต์..."
    /usr/bin/xcrun swift "$CORE" "$DIR/Tests.swift" || fail "unit tests ไม่ผ่าน — ยกเลิกการติดตั้ง"
fi
/usr/bin/xcrun --find swiftc >/dev/null 2>&1 || fail "ไม่พบ Swift compiler — รัน: xcode-select --install แล้วลองใหม่"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || fail "สร้างโฟลเดอร์แอปไม่ได้"

# ---------- 1) สร้างไอคอนถ้วยกาแฟ (.icns) ----------
cat > "$TMP/gen_icon.swift" <<'SWIFT'
import Cocoa
let side: CGFloat = 1024
let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()
let rect = NSRect(x: 96, y: 96, width: 832, height: 832)
let path = NSBezierPath(roundedRect: rect, xRadius: 188, yRadius: 188)
if let g = NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.66, blue: 0.63, alpha: 1),
                      ending:   NSColor(srgbRed: 0.10, green: 0.46, blue: 0.55, alpha: 1)) {
    g.draw(in: path, angle: -90)
} else {
    NSColor.systemTeal.setFill(); path.fill()
}
let conf = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(conf) {
    let s = sym.size
    sym.draw(in: NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2 - 24, width: s.width, height: s.height))
}
img.unlockFocus()
if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
SWIFT

if /usr/bin/xcrun swift "$TMP/gen_icon.swift" "$TMP/icon_1024.png" 2>/dev/null && [ -f "$TMP/icon_1024.png" ]; then
    ISET="$TMP/KeepAwake.iconset"; mkdir -p "$ISET"
    mk() { /usr/bin/sips -z "$1" "$1" "$TMP/icon_1024.png" --out "$ISET/$2" >/dev/null 2>&1; }
    mk 16  icon_16x16.png;     mk 32  icon_16x16@2x.png
    mk 32  icon_32x32.png;     mk 64  icon_32x32@2x.png
    mk 128 icon_128x128.png;   mk 256 icon_128x128@2x.png
    mk 256 icon_256x256.png;   mk 512 icon_256x256@2x.png
    mk 512 icon_512x512.png;   cp "$TMP/icon_1024.png" "$ISET/icon_512x512@2x.png"
    /usr/bin/iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null
fi

# ---------- 2) Info.plist ----------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>KeepAwake</string>
    <key>CFBundleDisplayName</key><string>KeepAwake</string>
    <key>CFBundleIdentifier</key><string>local.keepawake.app</string>
    <key>CFBundleVersion</key><string>1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleExecutable</key><string>KeepAwake</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ---------- 3) คอมไพล์ ----------
echo "กำลังคอมไพล์..."
/usr/bin/xcrun swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/KeepAwake" "$CORE" "$SRC" -framework Cocoa || fail "คอมไพล์ไม่สำเร็จ"

# ---------- 4) ลงทะเบียน + ล้าง quarantine + รีเฟรชไอคอน ----------
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
touch "$APP" 2>/dev/null
rm -rf "$TMP"

open "$APP" || fail "เปิดแอปไม่ได้"
note "ติดตั้งเสร็จแล้ว

หน้าต่าง KeepAwake เปิดขึ้นมาแล้ว และมีไอคอนถ้วยกาแฟ
แอปอยู่ที่ ~/Applications/KeepAwake.app
ครั้งต่อไปเปิดจาก Launchpad หรือ Spotlight (พิมพ์ KeepAwake)"
