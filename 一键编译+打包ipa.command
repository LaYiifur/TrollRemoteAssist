#!/bin/bash
set -euo pipefail

handle_error() {
  code=$?
  echo
  echo "打包失败（错误码 ${code}）。请保留本窗口中的红色错误信息。"
  read -r -p "按回车键关闭窗口……"
  exit "$code"
}
trap handle_error ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$HOME/Desktop/直播远程控制-trollstore"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release-iphoneos/livetest.app"
EXTENSION_OUTPUT="$APP_SOURCE/PlugIns/LiveBroadcast.appex"
WEBRTC_OUTPUT="$APP_SOURCE/Frameworks/WebRTC.framework"
WEBRTC_THIN="$OUTPUT_DIR/WebRTC-arm64"
APP_OUTPUT="$OUTPUT_DIR/直播远程控制.app"
IPA_WORK="$OUTPUT_DIR/ipa-work"
IPA_OUTPUT="$OUTPUT_DIR/直播远程控制.ipa"

if [ ! -d "$SCRIPT_DIR/livetest.xcodeproj" ]; then
  echo "错误：脚本必须放在 livetest.xcodeproj 旁边运行。"
  read -r -p "按回车键关闭窗口……"
  exit 1
fi

# 优先使用完整 Xcode，避免系统当前只选中了 Command Line Tools。
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "错误：找不到完整 Xcode。请确认 Xcode.app 位于“应用程序”文件夹。"
  read -r -p "按回车键关闭窗口……"
  exit 1
fi

echo "正在编译直播远程控制真机版……"
mkdir -p "$OUTPUT_DIR"
chmod +x "$SCRIPT_DIR/Frameworks/WebRTC.framework/WebRTC"

xcodebuild \
  -project "$SCRIPT_DIR/livetest.xcodeproj" \
  -scheme livetest \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [ ! -d "$APP_SOURCE" ]; then
  echo "错误：没有找到编译后的 livetest.app"
  exit 1
fi

if [ ! -f "$WEBRTC_OUTPUT/WebRTC" ]; then
  echo "错误：App 内没有找到 WebRTC.framework"
  exit 1
fi

if [ ! -d "$EXTENSION_OUTPUT" ]; then
  echo "错误：App 内没有找到 LiveBroadcast.appex"
  exit 1
fi

echo "正在提取 WebRTC.framework 的纯 arm64 真机代码……"
xcrun lipo "$WEBRTC_OUTPUT/WebRTC" -verify_arch arm64
rm -f "$WEBRTC_THIN"
xcrun lipo -thin arm64 "$WEBRTC_OUTPUT/WebRTC" -output "$WEBRTC_THIN"
mv -f "$WEBRTC_THIN" "$WEBRTC_OUTPUT/WebRTC"
xcrun lipo "$WEBRTC_OUTPUT/WebRTC" -info

echo "正在修复 WebRTC.framework 的真机签名……"
chmod +x "$WEBRTC_OUTPUT/WebRTC"
/usr/bin/codesign --force --sign - --timestamp=none "$WEBRTC_OUTPUT"
/usr/bin/codesign --verify --strict --verbose=2 "$WEBRTC_OUTPUT"

echo "正在签名直播扩展和主程序远程控制权限……"
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements "$SCRIPT_DIR/LiveBroadcast/LiveBroadcast.entitlements" \
  "$EXTENSION_OUTPUT"
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements "$SCRIPT_DIR/livetest/livetest.entitlements" \
  "$APP_SOURCE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"

echo "正在整理 App 和 IPA……"
rm -rf "$APP_OUTPUT" "$IPA_WORK" "$IPA_OUTPUT"
cp -R "$APP_SOURCE" "$APP_OUTPUT"
mkdir -p "$IPA_WORK/Payload"
cp -R "$APP_SOURCE" "$IPA_WORK/Payload/livetest.app"

(
  cd "$IPA_WORK"
  /usr/bin/zip -qry "$IPA_OUTPUT" Payload
)
rm -rf "$IPA_WORK"

echo
echo "打包完成："
echo "  $APP_OUTPUT"
echo "  $IPA_OUTPUT"
open "$OUTPUT_DIR"
