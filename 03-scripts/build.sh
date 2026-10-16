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

echo "== 1/7 语料：从 07-docs/语料/*.md 生成 02-assets/speech/*.json =="
if command -v python3 > /dev/null 2>&1; then
  python3 "$ROOT/03-scripts/import-speech.py"
  rm -rf "$ROOT/03-scripts/__pycache__"
else
  echo "缺 python3：无法从 md 生成语料 JSON，构建中止（请先装 Xcode Command Line Tools）" >&2
  exit 1
fi

echo "== 2/7 编译 =="
swiftc -O -module-cache-path "$TMP/module-cache" -swift-version 5 -target arm64-apple-macosx14.0 "$SRC/main.swift" "$SRC/speech.swift" "$SRC/characters.swift" -o "$TMP/Roxy"

echo "== 3/7 组装 app bundle =="
APP="$TMP/$APPNAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/Roxy" "$APP/Contents/MacOS/Roxy"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$ASSETS/characters/roxy/spritesheet.png" "$APP/Contents/Resources/spritesheet.png"
cp -R "$ASSETS/characters" "$APP/Contents/Resources/characters"
rm -rf "$APP/Contents/Resources/characters/roxy"   # 洛琪希从 Resources/spritesheet.png 读取，避免图集打包两份
if [ -d "$ASSETS/speech" ]; then
  cp -R "$ASSETS/speech" "$APP/Contents/Resources/speech"
fi
if [ -f "$ASSETS/Roxy.icns" ]; then
  cp "$ASSETS/Roxy.icns" "$APP/Contents/Resources/Roxy.icns"
fi

echo "== 4/7 清理扩展属性 =="
xattr -cr "$APP" 2>/dev/null || true

echo "== 5/7 签名（有本机证书则用之，否则 ad-hoc）=="
if security find-certificate -c "RoxyPet Local Signing" > /dev/null 2>&1; then
  codesign --force --deep --sign "RoxyPet Local Signing" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo "== 6/7 验证 =="
codesign --verify "$APP" && echo "signature OK"

echo "== 7/7 输出到仓库根目录 =="
rm -rf "$ROOT/$APPNAME"
cp -R "$APP" "$ROOT/$APPNAME"
echo "构建产物: $ROOT/$APPNAME"
