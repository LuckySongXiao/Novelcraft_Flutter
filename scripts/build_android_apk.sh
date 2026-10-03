#!/usr/bin/env bash
# ============================================================
# NovelCraft Android APK 一键构建脚本（Linux / macOS / WSL 通用）
# 前置要求：
#   1. Flutter SDK + Android SDK（cmdline-tools 即可，licenses 已接受）
#   2. JDK 17+
# 用法：bash scripts/build_android_apk.sh
# 产物：build/app/outputs/flutter-apk/app-release.apk
# ============================================================
set -euo pipefail

command -v flutter >/dev/null || { echo "[错误] 未找到 flutter 命令"; exit 1; }
: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
[ -n "$ANDROID_HOME" ] || { echo "[错误] 未设置 ANDROID_HOME"; exit 1; }

cd "$(dirname "$0")/.."

# SDK 路径写入 local.properties（幂等）
grep -q '^sdk.dir=' android/local.properties 2>/dev/null ||
  echo "sdk.dir=$ANDROID_HOME" >> android/local.properties

flutter build apk --release

APK=build/app/outputs/flutter-apk/app-release.apk
[ -f "$APK" ] && echo "构建成功：$APK（直接安装到 Android 设备）"
