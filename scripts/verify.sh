#!/bin/bash
# 交付前的硬校验：架构 / 平台 / 签名 / 权限 / 包结构。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:-$ROOT/dist/IPADecrypt-1.0-adhoc.ipa}"
APP_NAME="IPADecrypt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== IPA: $IPA"
unzip -tq "$IPA" >/dev/null || fail "IPA 压缩包损坏"
unzip -q "$IPA" -d "$TMP"
APP="$TMP/Payload/$APP_NAME.app"
BIN="$APP/$APP_NAME"

echo "-- 架构"
ARCH="$(file "$BIN")"
echo "$ARCH"
[[ "$ARCH" == *"Mach-O 64-bit executable arm64"* ]] || fail "不是 arm64"

echo "-- 平台"
BUILD="$(otool -l "$BIN")"
grep -A4 LC_BUILD_VERSION <<< "$BUILD" | grep -q "platform 2" || fail "LC_BUILD_VERSION 不是 iOS"
grep -A4 LC_BUILD_VERSION <<< "$BUILD" | grep -q "minos 16.0" || fail "minos 不是 16.0"

MODE="adhoc"
case "$IPA" in *unsigned*) MODE="unsigned";; esac

echo "-- 签名（${MODE}）"
if [ "$MODE" = "adhoc" ]; then
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail "签名不完整"
  SIG="$(codesign -dv "$APP" 2>&1)"
  grep -q "Signature=adhoc" <<< "$SIG" || fail "不是 ad-hoc 签名"
  ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
  grep -q "com.apple.security.application-groups" <<< "$ENT" || fail "缺少 App Group 权限"
else
  [ ! -d "$APP/_CodeSignature" ] || fail "未签名包内仍有 _CodeSignature"
  if codesign -dv "$APP" >/dev/null 2>&1; then fail "未签名包仍带签名"; fi
fi

echo "-- 包结构"
PATHS="$(unzip -Z1 "$IPA")"
if grep -v "^Payload/" <<< "$PATHS" | grep -q .; then fail "IPA 内有 Payload 之外的文件"; fi
[ -f "$APP/Info.plist" ] || fail "缺 Info.plist"
[ -f "$BIN" ] || fail "缺可执行文件"
[ -f "$APP/AppIcon60x60@3x.png" ] || fail "缺图标"
plutil -lint "$APP/Info.plist" >/dev/null || fail "Info.plist 非法"
grep -q "UILaunchScreen" "$APP/Info.plist" || fail "缺 UILaunchScreen"

echo "-- Info"
plutil -p "$APP/Info.plist" | grep -E "CFBundleIdentifier|CFBundleShortVersionString|CFBundleDisplayName|MinimumOSVersion|UIDeviceFamily|FairPlayAppGroup"
EXPECTED_NAME="$(python3 "$ROOT/scripts/genstrings.py" --get app.title)"
ACTUAL_NAME="$(plutil -extract CFBundleDisplayName raw "$APP/Info.plist" 2>/dev/null)"
[ "$ACTUAL_NAME" = "$EXPECTED_NAME" ] || fail "显示名与 strings.json 不一致：$ACTUAL_NAME != $EXPECTED_NAME"

echo "OK: 校验通过"
