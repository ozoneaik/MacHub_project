#!/bin/bash
# Build MacHub เป็นไฟล์ .app
#   ./build.sh           → build อย่างเดียว ได้ build/MacHub.app
#   ./build.sh install   → build + ติดตั้งลง /Applications + เปิดแอป
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacHub"
BUNDLE_ID="com.phuwadech.machub"
APP_DIR="build/$APP_NAME.app"

# 1) เช็คว่ามี Swift compiler หรือยัง
if ! command -v swift >/dev/null 2>&1; then
  echo "❌ ไม่พบ swift — ติดตั้ง Command Line Tools ก่อนด้วยคำสั่ง:"
  echo "   xcode-select --install"
  exit 1
fi

# 2) compile แบบ release (เร็วกว่า debug)
echo "🔨 กำลัง build..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
HELPER_NAME="MacHubChargeHelper"

# 3) ประกอบโครงสร้าง .app
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$APP_DIR/Contents/MacOS/$HELPER_NAME"  # ตัวช่วยจำกัดการชาร์จ
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# รูปโปรไฟล์หน้า About me (ไม่มีก็ได้ จะใช้ไอคอนแทน)
if [ -f Resources/Profile.png ]; then cp Resources/Profile.png "$APP_DIR/Contents/Resources/Profile.png"; fi

# 4) เซ็นแอปด้วยใบรับรองของเราเอง (self-signed)
#    ทำไม: ถ้าเซ็นแบบ ad-hoc ลายเซ็นจะเปลี่ยนทุกครั้งที่ build → macOS ลืมสิทธิ์ทั้งหมด
#    (เช่น Accessibility) แล้วถามใหม่ทุกครั้ง
#    ใช้ใบรับรองเดิมตลอด → ลายเซ็น "เป็นตัวเดิม" → อนุญาตครั้งเดียวจบ
CERT_NAME="MacHub Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

create_certificate() {
  echo "🔐 สร้างใบรับรองสำหรับเซ็นแอป (ครั้งแรกครั้งเดียว)..."
  local tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  # ใช้ openssl ของ macOS เอง (ไฟล์ .p12 จะ import เข้า Keychain ได้แน่นอน)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cfg" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:machub -name "$CERT_NAME" >/dev/null 2>&1
  # -T /usr/bin/codesign = อนุญาตให้ codesign ใช้ key นี้ได้
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P machub -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
}

cert_hash() {
  security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ {print $NF; exit}'
}

CERT_HASH="$(cert_hash || true)"
if [[ -z "$CERT_HASH" ]]; then
  create_certificate || true
  CERT_HASH="$(cert_hash || true)"
fi

SIGNED_WITH="adhoc"
# เซ็นตัวช่วยก่อน (ไฟล์ข้างในต้องเซ็นก่อนตัวแอป)
if [[ -n "$CERT_HASH" ]] && codesign --force --sign "$CERT_HASH" --identifier "$BUNDLE_ID.chargehelper" "$APP_DIR/Contents/MacOS/$HELPER_NAME" 2>/dev/null \
   && codesign --force --sign "$CERT_HASH" --identifier "$BUNDLE_ID" "$APP_DIR" 2>/dev/null; then
  SIGNED_WITH="$CERT_HASH"
  echo "✍️  เซ็นด้วยใบรับรอง \"$CERT_NAME\""
else
  # สำรอง: ถ้าใช้ใบรับรองไม่ได้ ก็เซ็นแบบ ad-hoc เหมือนเดิม
  codesign --force --sign - --identifier "$BUNDLE_ID.chargehelper" "$APP_DIR/Contents/MacOS/$HELPER_NAME"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
  echo "⚠️  เซ็นแบบ ad-hoc (ต้องกดอนุญาตสิทธิ์ใหม่ทุกครั้งที่ build)"
fi
echo "✅ build เสร็จ: $APP_DIR"

# 5) ติดตั้ง (ถ้าสั่ง ./build.sh install)
if [[ "${1:-}" == "install" ]]; then
  echo "📦 กำลังติดตั้งลง /Applications..."
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" /Applications/
  touch "/Applications/$APP_NAME.app"  # ให้ Finder รีเฟรชไอคอนใหม่

  # ล้างสิทธิ์เก่าเฉพาะเมื่อลายเซ็นเปลี่ยน (ad-hoc หรือเพิ่งเปลี่ยนใบรับรอง)
  # ถ้าเซ็นด้วยใบรับรองเดิม สิทธิ์เดิมยังใช้ได้ ไม่ต้องกดอนุญาตใหม่
  LAST_SIGNED_WITH="$(cat .last-signing 2>/dev/null || true)"
  if [[ "$SIGNED_WITH" == "adhoc" || "$SIGNED_WITH" != "$LAST_SIGNED_WITH" ]]; then
    echo "🔄 ลายเซ็นเปลี่ยน → ล้างสิทธิ์เก่า (ต้องกดอนุญาตใหม่รอบนี้)"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  echo "$SIGNED_WITH" > .last-signing

  open "/Applications/$APP_NAME.app"
  echo "🚀 เปิด MacHub แล้ว — อนุญาตสิทธิ์ Accessibility ตามที่ระบบถาม"
fi
