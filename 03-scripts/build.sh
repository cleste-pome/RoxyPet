#!/bin/bash
# Roxy 构建脚本（仓库版：源码在 01-src/，素材在 02-assets/，产物输出到仓库根目录）
# 需要：macOS 14+（Apple Silicon）+ Xcode Command Line Tools
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
SRC="$ROOT/01-src"
ASSETS="$ROOT/02-assets"
APPNAME="Roxy.app"
TMP="$(mktemp -d /tmp/roxy-build.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== 1/6 编译 =="
swiftc -O -module-cache-path "$TMP/module-cache" -swift-version 5 -target arm64-apple-macosx14.0 "$SRC/main.swift" "$SRC/speech.swift" "$SRC/characters.swift" -o "$TMP/Roxy"

echo "== 2/6 组装 app bundle =="
APP="$TMP/$APPNAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/Roxy" "$APP/Contents/MacOS/Roxy"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$ASSETS/spritesheet.png" "$APP/Contents/Resources/spritesheet.png"
cp -R "$ASSETS/characters" "$APP/Contents/Resources/characters"
if [ -d "$ASSETS/speech" ]; then
  cp -R "$ASSETS/speech" "$APP/Contents/Resources/speech"
fi
if [ -f "$ASSETS/Roxy.icns" ]; then
  cp "$ASSETS/Roxy.icns" "$APP/Contents/Resources/Roxy.icns"
fi

echo "== 3/6 清理扩展属性 =="
xattr -cr "$APP" 2>/dev/null || true

echo "== 4/6 签名（有本机证书则用之，否则 ad-hoc）=="
if security find-certificate -c "RoxyPet Local Signing" > /dev/null 2>&1; then
  codesign --force --deep --sign "RoxyPet Local Signing" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo "== 5/6 验证 =="
codesign --verify "$APP" && echo "signature OK"

echo "== 6/6 输出到仓库根目录 =="
rm -rf "$ROOT/$APPNAME"
cp -R "$APP" "$ROOT/$APPNAME"
echo "构建产物: $ROOT/$APPNAME"
