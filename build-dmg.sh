#!/bin/bash
# build-dmg.sh — สร้างไฟล์ติดตั้ง KeepAwake.dmg แบบลากวาง (drag-to-Applications)
#
# วิธีใช้:
#   1. Build หรือมี KeepAwake.app อยู่แล้ว (เช่นจากการรัน "ติดตั้ง KeepAwake.command")
#   2. รันสคริปต์นี้: ./build-dmg.sh [path/to/KeepAwake.app]
#   3. ได้ไฟล์ KeepAwake-Installer.dmg และ KeepAwake-Installer.dmg.sha256 ในโฟลเดอร์ปัจจุบัน
#   4. ตอนออก release ต้องอัปโหลดทั้งสองไฟล์ ไม่งั้นตัวอัปเดตในแอปจะไม่ติดตั้งอัตโนมัติ
set -euo pipefail

APP_PATH="${1:-$HOME/Applications/KeepAwake.app}"
OUT_DMG="$(pwd)/KeepAwake-Installer.dmg"
OUT_SHA="$OUT_DMG.sha256"
VOL_NAME="KeepAwake"
STAGE_DIR="$(mktemp -d)"

if [ ! -d "$APP_PATH" ]; then
  echo "ไม่พบ KeepAwake.app ที่ $APP_PATH"
  echo "ระบุ path เอง: ./build-dmg.sh /path/to/KeepAwake.app"
  exit 1
fi

echo "กำลังเตรียมไฟล์สำหรับ DMG..."
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "กำลังสร้าง $OUT_DMG ..."
rm -f "$OUT_DMG" "$OUT_SHA"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$OUT_DMG"

(cd "$(dirname "$OUT_DMG")" && shasum -a 256 "$(basename "$OUT_DMG")" > "$OUT_SHA")

rm -rf "$STAGE_DIR"
echo "เสร็จแล้ว: $OUT_DMG"
echo "checksum: $OUT_SHA"
echo "ผู้ใช้เปิดไฟล์นี้ แล้วลาก KeepAwake ไปวางที่ Applications เป็นอันเสร็จ"
