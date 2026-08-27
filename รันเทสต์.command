#!/bin/bash
# รัน unit tests ของ KeepAwake — ดับเบิลคลิกหรือรันจาก Terminal
# ผ่านทั้งหมด = ค่อยติดตั้ง (exit 0) | มีพัง = อย่าติดตั้ง (exit 1)
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
echo "=== KeepAwake unit tests ==="
# หมายเหตุ: xcrun swift แบบหลายไฟล์ (swift a.swift b.swift) บน toolchain บางเวอร์ชัน
# ไม่รัน top-level code ของไฟล์ที่สอง (เงียบ ไม่มี error, exit 0 เสมอ) — ต่อไฟล์เป็นไฟล์เดียวก่อนรันเพื่อความชัวร์
TMP_TEST="$(mktemp -t keepawaketest).swift"
cat "$DIR/KeepAwakeCore.swift" "$DIR/Tests.swift" > "$TMP_TEST"
/usr/bin/xcrun swift "$TMP_TEST"
RC=$?
rm -f "$TMP_TEST"
echo "============================"
[ $RC -eq 0 ] && echo "ผลลัพธ์: ผ่าน — ติดตั้งได้" || echo "ผลลัพธ์: ไม่ผ่าน — ห้ามติดตั้ง"
exit $RC
