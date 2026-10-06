# MacHub

แอปบน menu bar ที่รวมเครื่องมือเล็กๆ ไว้ในแอปเดียว

| ฟีเจอร์ | วิธีใช้ |
|---|---|
| 🌡 อุณหภูมิ + RAM | menu bar แสดงอุณหภูมิของ "จุดที่ร้อนที่สุด" ณ ตอนนั้น คลิกเพื่อดูว่าเป็นจุดไหน, ค่าเฉลี่ย/สูงสุดของ CPU และ GPU, แบต, SSD, Wi-Fi และเซ็นเซอร์ทั้งหมด |
| 📋 ประวัติ Clipboard | กด `⌘⇧V` → พิมพ์ค้นหา → `↑↓` เลือก → `⏎` วางให้อัตโนมัติ (เก็บข้อความ รูป และไฟล์ 50 รายการล่าสุด) |
| 🎨 เลือกสีจากหน้าจอ | กด `⌘⌥C` → แว่นขยายตามเมาส์ → คลิกเลือกสี → copy เป็น HEX / RGB / HSL (เก็บประวัติ 12 สี) |
| 🧽 ล็อกคีย์บอร์ดเพื่อทำความสะอาด | เมนู → "ล็อกคีย์บอร์ดเพื่อทำความสะอาด" ทุกปุ่มกดไม่ติด 2 นาที หรือเอาเมาส์กด "เสร็จแล้ว" |
| 🔋 จัดการแบต | เมนู → "ตั้งค่าแบต…" จำกัด % การชาร์จ, Discharge, กันร้อน, กันชาร์จเกินตอน sleep (ทำงานแม้ปิด MacHub) |

## ติดตั้ง

1. ติดตั้ง Command Line Tools (ครั้งแรกครั้งเดียว ไม่ต้องลง Xcode เต็ม):
   ```bash
   xcode-select --install
   ```
2. Build และติดตั้ง:
   ```bash
   cd ~/development/MacHub
   chmod +x build.sh
   ./build.sh install
   ```
3. อนุญาตสิทธิ์ **Accessibility** ใน **System Settings → Privacy & Security** → เปิด MacHub (ใช้ดักคีย์ลัดและล็อกคีย์บอร์ด)

## โครงสร้างโค้ด

```
Sources/MacHub/
├── main.swift               จุดเริ่มต้นแอป
├── AppDelegate.swift        status bar, เมนู และเชื่อมทุกส่วนเข้าด้วยกัน
├── SystemMonitor.swift      อ่าน RAM และอุณหภูมิ
├── KeyboardInterceptor.swift ดักคีย์บอร์ดทั้งระบบ (คีย์ลัด + โหมดล็อก)
├── Clipboard.swift          เก็บประวัติ clipboard + หน้าตา
├── ColorPicker.swift        เลือกสีจากหน้าจอ
├── CleaningLock.swift       หน้าจอล็อกคีย์บอร์ดตอนทำความสะอาด
├── BatteryManager.swift     ติดตั้ง/สั่งงานตัวช่วยจัดการแบต
├── BatterySettings.swift    หน้าต่างตั้งค่าแบต
├── Permissions.swift        ตรวจ/ขอสิทธิ์
└── KeyCode.swift            รหัสปุ่มคีย์บอร์ด
Sources/SMCKit/              อ่าน/เขียนชิป SMC + รูปแบบค่าตั้ง (ใช้ร่วมกันทั้งแอปและตัวช่วย)
Sources/MacHubChargeHelper/  ตัวช่วยจัดการแบต (LaunchDaemon รันเป็น root)
```

## ข้อควรรู้

- **อุณหภูมิ** อ่านจากชิป SMC (แหล่งเดียวกับแอป Stats) ถ้าอ่านไม่ได้จะถอยไปใช้ HID sensor และถ้าอ่านไม่ได้ทั้งคู่จะแสดง `--°C`
- ไอคอนแอปอยู่ที่ `Resources/AppIcon.icns`
- **Clipboard + ไฟล์**: copy ไฟล์จาก Finder จะเก็บเป็นไฟล์ (ไม่ใช่แค่ชื่อ) ไฟล์รูปจะวางเป็นตัวรูป ไฟล์อื่นวางเป็นไฟล์ เก็บแค่ที่อยู่ไฟล์ ถ้าไฟล์ต้นฉบับถูกลบ/ย้ายจะวางไม่ได้ (มีเสียงเตือน)
- **⌘⇧V** จะแทนที่ "Paste and Match Style" ของบางแอป ถ้าต้องการเปลี่ยนคีย์ ให้แก้ใน `AppDelegate.swift` ตรง `isClipboardHotKey` (⌘⌥C แก้ตรง `isColorPickerHotKey`)
- **ล็อกคีย์บอร์ด** ล็อกปุ่ม Power/Touch ID ไม่ได้ (macOS ไม่ให้แอปดัก) และไฟ Caps Lock อาจยังติด/ดับได้
- **จัดการแบต** ใช้ตัวช่วยที่เป็น LaunchDaemon (รันเป็น root ตั้งแต่เปิดเครื่อง แม้ไม่ได้เปิด MacHub) ครั้งแรกต้องกด "ติดตั้ง" ในหน้าต่างตั้งค่าแบตแล้วใส่รหัส admin
  - ไฟล์ที่ติดตั้ง: `/Library/PrivilegedHelperTools/com.phuwadech.machub.chargehelper`, `/Library/LaunchDaemons/com.phuwadech.machub.chargehelper.plist`, กฎ sudo `/etc/sudoers.d/machub` (อนุญาตให้รันได้แค่ตัวช่วยนี้ตัวเดียว), ค่าตั้ง/สถานะใน `/Library/Application Support/MacHub/`
  - **จำกัด %**: ถึงค่าที่ตั้ง → หยุดชาร์จ (ใช้ไฟจากสาย แบตไม่ลด) แบตลดลง 3% → ชาร์จต่อ
  - **Discharge**: ตัดไฟจากสาย ให้ใช้แบตทั้งที่เสียบสาย มีแบบอัตโนมัติ (เกิน limit → ลงมาที่ limit) และแบบสั่งครั้งเดียว ระหว่าง sleep จะไม่ discharge
  - **กันร้อน**: แบตร้อนถึงค่าที่ตั้ง (ค่าเริ่มต้น 35°C) → หยุดชาร์จ เย็นลง 2°C → ชาร์จต่อ
  - **Sleep**: เสียบสายและยังชาร์จไม่ถึง limit → ไม่ให้ sleep (เหมือน `caffeinate -s`) ถ้าเครื่อง sleep ไปก่อน จะหยุดชาร์จไว้ระหว่าง sleep
  - ถอนการติดตั้ง: ปุ่ม "ถอนการติดตั้ง…" ในหน้าต่างตั้งค่าแบต (การชาร์จกลับเป็นปกติ)
  - ตรวจปัญหา: `/Library/PrivilegedHelperTools/com.phuwadech.machub.chargehelper probe` และ `cat "/Library/Application Support/MacHub/charge-status.json"`
- `build.sh` สร้างใบรับรองชื่อ "MacHub Self-Signed" ไว้ใน Keychain (ครั้งแรกครั้งเดียว) แล้วใช้เซ็นแอปทุกครั้ง ลายเซ็นจึงคงที่ build ใหม่กี่ครั้งก็ไม่ต้องกดอนุญาตสิทธิ์ใหม่ (ถ้าระบบถาม "codesign wants to use key" ให้กด **Always Allow**)
