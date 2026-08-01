#!/bin/bash
# รัน unit tests ของ KeepAwake — ดับเบิลคลิกหรือรันจาก Terminal
# ผ่านทั้งหมด = ค่อยติดตั้ง (exit 0) | มีพัง = อย่าติดตั้ง (exit 1)
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
echo "=== KeepAwake unit tests ==="
/usr/bin/xcrun swift KeepAwakeCore.swift Tests.swift
RC=$?
echo "============================"
[ $RC -eq 0 ] && echo "ผลลัพธ์: ผ่าน — ติดตั้งได้" || echo "ผลลัพธ์: ไม่ผ่าน — ห้ามติดตั้ง"
exit $RC
