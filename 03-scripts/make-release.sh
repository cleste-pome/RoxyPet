#!/bin/bash
# Roxy 发布脚本：编译 → 组装 app → 打包成 dmg
# 用法：./make-release.sh（产出 Roxy.dmg；版本号体现在 Release 标签上）
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
DMG="$ROOT/Roxy.dmg"

# 第 1 步：构建 Roxy.app（内部会调用 build.sh）
./build.sh

# 第 2 步：安装舞台：只有两项——Roxy.app（左）+ Applications 快捷方式（右）
echo ""
echo "== 打包 dmg（Roxy.dmg）=="
STAGE="$(mktemp -d /tmp/roxy-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/Roxy.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 第 3 步：可写镜像 → Finder 摆好图标位置 / 窗口大小（由 Finder 弹出时写入 .DS_Store）→ 压成只读 dmg
for v in /Volumes/Roxy*; do [ -d "$v" ] && diskutil eject "$v" > /dev/null 2>&1; done
RW="$(mktemp -d /tmp/roxy-rw.XXXXXX)/Roxy-rw.dmg"
hdiutil create -volname "Roxy" -srcfolder "$STAGE" -ov -format UDRW "$RW" > /dev/null
hdiutil attach "$RW" -nobrowse > /dev/null
MOUNT="$(ls -d /Volumes/Roxy* 2>/dev/null | head -1)"
if [ -n "$MOUNT" ]; then
  osascript <<APPLESCRIPT || true
tell application "Finder"
	set theFolder to (POSIX file "$MOUNT") as alias
	open theFolder
	delay 0.8
	set theWindow to container window of theFolder
	set current view of theWindow to icon view
	set toolbar visible of theWindow to false
	set statusbar visible of theWindow to false
	set bounds of theWindow to {150, 120, 790, 520}
	set theViewOptions to the icon view options of theWindow
	set arrangement of theViewOptions to not arranged
	set icon size of theViewOptions to 128
	set position of item "Roxy.app" of theFolder to {170, 200}
	set position of item "Applications" of theFolder to {470, 200}
	delay 0.6
	close theWindow
	delay 0.5
	eject theFolder
end tell
APPLESCRIPT
  # 兜底：确保卷彻底卸载，否则压缩会失败
  for i in 1 2 3 4 5; do
    [ -d "$MOUNT" ] || break
    diskutil eject "$MOUNT" > /dev/null 2>&1 || hdiutil detach "$MOUNT" > /dev/null 2>&1 || true
    osascript -e 'delay 1' > /dev/null 2>&1 || true
  done
fi
hdiutil convert "$RW" -format UDZO -o "$DMG.new" > /dev/null
mv -f "$DMG.new.dmg" "$DMG"
rm -rf "$(dirname "$RW")"

echo ""
echo "✅ 发布包已生成: $DMG"
echo "   把它拖进 GitHub Releases 即可"
