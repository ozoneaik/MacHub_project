#!/bin/bash
# ดับเบิลคลิกไฟล์นี้เพื่อ build และติดตั้ง MacHub ลง /Applications
cd "$(dirname "$0")"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "กำลังเปิดตัวติดตั้ง Command Line Tools... กด Install แล้วรอจนเสร็จ จากนั้นดับเบิลคลิกไฟล์นี้อีกครั้ง"
  xcode-select --install
  read -n 1 -s -r -p "กดปุ่มใดก็ได้เพื่อปิด"
  exit 0
fi
chmod +x build.sh
./build.sh install
echo
read -n 1 -s -r -p "เสร็จแล้ว กดปุ่มใดก็ได้เพื่อปิดหน้าต่างนี้"
