#!/bin/bash
# build-pkg.sh — สร้างไฟล์ติดตั้ง KeepAwake.pkg แบบดับเบิลคลิกเดียวจบ
# (ติดตั้งลง /Applications ให้อัตโนมัติ + ล้าง quarantine ให้เอง ไม่ต้องคลิกขวา > Open)
#
# วิธีใช้:
#   1. Build หรือมี KeepAwake.app อยู่แล้ว (เช่นจากการรัน "ติดตั้ง KeepAwake.command")
#   2. รันสคริปต์นี้: ./build-pkg.sh [path/to/KeepAwake.app] [version]
#   3. ได้ไฟล์ KeepAwake-Installer.pkg ในโฟลเดอร์เดียวกัน
set -euo pipefail

APP_PATH="${1:-$HOME/Applications/KeepAwake.app}"
VERSION="${2:-1.0}"
OUT_PKG="$(pwd)/KeepAwake-Installer.pkg"
STAGE_DIR="$(mktemp -d)"
SCRIPTS_DIR="$STAGE_DIR/scripts"

if [ ! -d "$APP_PATH" ]; then
  echo "ไม่พบ KeepAwake.app ที่ $APP_PATH"
  echo "ระบุ path เอง: ./build-pkg.sh /path/to/KeepAwake.app 1.3"
  exit 1
fi

mkdir -p "$STAGE_DIR/root/Applications" "$SCRIPTS_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/root/Applications/"

cat > "$SCRIPTS_DIR/postinstall" << 'EOF'
#!/bin/bash
xattr -dr com.apple.quarantine "/Applications/KeepAwake.app" 2>/dev/null
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

echo "กำลังสร้าง $OUT_PKG ..."
rm -f "$OUT_PKG"
pkgbuild --root "$STAGE_DIR/root" \
  --identifier local.keepawake.installer \
  --version "$VERSION" \
  --install-location / \
  --scripts "$SCRIPTS_DIR" \
  "$OUT_PKG"

rm -rf "$STAGE_DIR"
echo "เสร็จแล้ว: $OUT_PKG"
echo "ผู้ใช้ดับเบิลคลิกไฟล์นี้ แล้วกด Continue/Install ตามขั้นตอนได้เลย ไม่ต้องคลิกขวา > Open"
