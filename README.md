# KeepAwake

แอปเล็กๆ กันไม่ให้ Mac หลับ พร้อมตัวจับเวลา — เหมาะกับตอนปล่อยงานทำทิ้งไว้ หรือกัน VPN หลุดตอนพักจอ
ใช้ IOKit power assertion ของ macOS โดยตรง (in-process) — ปิดแอปเมื่อไหร่ระบบปล่อยให้อัตโนมัติ ไม่มีทางค้าง

A tiny macOS menu app to keep your Mac awake with a timer — great for long-running tasks or keeping a VPN alive while the screen would otherwise sleep.

## ฟีเจอร์ / Features

- เลือกเวลา 30 นาที / 1 / 2 / 4 ชั่วโมง หรือกำหนดเอง (เช่น 90, 45m, 2h)
- ปุ่มต่อเวลา +15 / +30 นาที
- นับถอยหลังแบบสด + แสดงเวลาที่เหลือบนไอคอน Dock
- โหมด "จอดับได้" (ประหยัดไฟ) หรือ "จอไม่ดับ" (กัน VPN หลุด/ไม่ล็อกจอ)
- หรี่จออัตโนมัติเมื่อไม่ได้ใช้ 5 นาที (คืนความสว่างเองเมื่อขยับเมาส์) — ประหยัดไฟโดย VPN ไม่หลุด
- ปุ่มดับจอทันทีโดยเครื่องยังทำงานต่อ
- ปิดหน้าต่างแล้วทำงานต่อเบื้องหลัง คลิกไอคอน Dock เพื่อเปิดกลับมา
- ไอคอนถ้วยกาแฟ เปลี่ยนเป็นสีเขียวเมื่อกำลังทำงาน

## ติดตั้ง / Install

ต้องมี Command Line Tools (Swift compiler) — ถ้ายังไม่มีให้รัน `xcode-select --install` ก่อน

1. วางไฟล์ `KeepAwake.swift` และ `ติดตั้ง KeepAwake.command` ไว้โฟลเดอร์เดียวกัน
2. ดับเบิลคลิก `ติดตั้ง KeepAwake.command` (ครั้งแรกถ้าโดนเตือน: คลิกขวา > Open)
3. ตัวติดตั้งจะสร้างไอคอน คอมไพล์เป็นแอป ไปไว้ที่ `~/Applications/KeepAwake.app` แล้วเปิดให้

เปิดครั้งต่อไป: Launchpad หรือ Spotlight (Command+Space พิมพ์ KeepAwake)

## วิธีใช้ / Usage

เปิดแอป เลือกเวลา หรือกดปุ่มสีน้ำเงิน "กัน VPN หลุด — จอไม่ดับ"
กด Command+Q เพื่อออกจากโปรแกรม (Mac กลับมาหลับได้ตามปกติ)

รายละเอียดเพิ่มเติมดูใน `วิธีใช้-KeepAwake.md`

## หมายเหตุ / Notes

- แอปไม่ได้เซ็นโค้ด (unsigned) — เพราะคอมไพล์บนเครื่องผู้ใช้เอง จึงไม่ติด Gatekeeper
- ทดสอบบน macOS 26 (Apple Silicon)

## License

MIT — ดูไฟล์ LICENSE
