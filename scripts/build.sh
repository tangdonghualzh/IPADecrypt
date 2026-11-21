#!/bin/bash
# 用 CLT 的 clang/swiftc + 独立 iPhoneOS SDK 编译、ad-hoc 签名并打包 IPA。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${SDK:-$HOME/Library/Caches/ios-unsigned-ipa/iPhoneOS26.5.sdk}"
MIN_IOS="${MIN_IOS:-16.0}"
SDK_VERSION="${SDK_VERSION:-26.5}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="IPADecrypt"
BUNDLE_ID="com.eason.ipadecrypt"

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DIST="$ROOT/dist"

if [ ! -d "$SDK" ]; then
  echo "找不到 iPhoneOS SDK：$SDK" >&2
  exit 1
fi

echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$APP" "$DIST" "$BUILD/gen"

echo "==> 生成文案常量（src/strings.json）"
python3 "$ROOT/scripts/genstrings.py" --swift "$BUILD/gen/Strings.swift"
DISPLAY_NAME="$(python3 "$ROOT/scripts/genstrings.py" --get app.title)"
DOC_TYPE="$(python3 "$ROOT/scripts/genstrings.py" --get app.docType)"

echo "==> 编译 C 核心 FairPlayCore"
xcrun clang -target "arm64-apple-ios$MIN_IOS" -isysroot "$SDK" \
  -O2 -fno-objc-arc -Wall -I "$ROOT/vendor/FairPlayCore/include" \
  -c "$ROOT/vendor/FairPlayCore/FairPlayCore.c" -o "$BUILD/obj/FairPlayCore.o"

echo "==> 编译 ZIPFoundation 静态库"
swiftc -target "arm64-apple-ios$MIN_IOS" -sdk "$SDK" -module-name ZIPFoundation \
  -emit-module -emit-library -static -O -swift-version 5 \
  -o "$BUILD/obj/libZIPFoundation.a" \
  -emit-module-path "$BUILD/obj/ZIPFoundation.swiftmodule" \
  "$ROOT"/vendor/ZIPFoundation/ZIPFoundation/*.swift

echo "==> 编译 App"
SWIFT_FILES=("$ROOT"/src/*.swift "$ROOT"/src/Support/*.swift "$ROOT"/src/FairPlay/*.swift "$BUILD/gen/Strings.swift")
SDKROOT="$SDK" swiftc -target "arm64-apple-ios$MIN_IOS" -sdk "$SDK" \
  -parse-as-library -O -swift-version 5 \
  -I "$BUILD/obj" -I "$ROOT/vendor/FairPlayCore/include" \
  -Xcc -I -Xcc "$ROOT/vendor/FairPlayCore/include" \
  "${SWIFT_FILES[@]}" "$BUILD/obj/FairPlayCore.o" \
  -L "$BUILD/obj" -lZIPFoundation \
  -Xlinker -platform_version -Xlinker ios -Xlinker "$MIN_IOS" -Xlinker "$SDK_VERSION" \
  -o "$APP/$APP_NAME"

echo "==> 组装 .app"
cp "$ROOT/src/Info.plist" "$APP/Info.plist"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP/Info.plist"
plutil -replace UTImportedTypeDeclarations.0.UTTypeDescription -string "$DOC_TYPE" "$APP/Info.plist"
plutil -replace CFBundleDocumentTypes.0.CFBundleTypeName -string "$DOC_TYPE" "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null

if [ -f "$ROOT/src/AppIcon60x60@2x.png" ]; then
  cp "$ROOT"/src/AppIcon*.png "$APP/"
fi
printf 'APPL????' > "$APP/PkgInfo"

find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

echo "==> ad-hoc 签名（带 App Group 权限）"
codesign --force --sign - \
  --entitlements "$ROOT/src/IPADecrypt.entitlements" \
  --generate-entitlement-der \
  --timestamp=none \
  "$APP"

echo "==> 校验"
file "$APP/$APP_NAME"
otool -l "$APP/$APP_NAME" | grep -A4 LC_BUILD_VERSION
codesign -d --entitlements :- "$APP" 2>/dev/null || true

echo "==> 打包 ad-hoc IPA"
mkdir -p "$BUILD/package/Payload"
cp -R "$APP" "$BUILD/package/Payload/"
(cd "$BUILD/package" && zip -qry -X "$DIST/IPADecrypt-$VERSION-adhoc.ipa" Payload)

echo "==> 打包未签名 IPA（给自签工具用）"
mkdir -p "$BUILD/package-unsigned/Payload"
cp -R "$APP" "$BUILD/package-unsigned/Payload/"
rm -rf "$BUILD/package-unsigned/Payload/$APP_NAME.app/_CodeSignature"
codesign --remove-signature "$BUILD/package-unsigned/Payload/$APP_NAME.app/$APP_NAME" >/dev/null 2>&1 || true
xattr -cr "$BUILD/package-unsigned/Payload/$APP_NAME.app" 2>/dev/null || true
(cd "$BUILD/package-unsigned" && zip -qry -X "$DIST/IPADecrypt-$VERSION-unsigned.ipa" Payload)

unzip -tq "$DIST/IPADecrypt-$VERSION-adhoc.ipa"
unzip -tq "$DIST/IPADecrypt-$VERSION-unsigned.ipa"
echo "产物："
ls -lh "$DIST"/*.ipa
