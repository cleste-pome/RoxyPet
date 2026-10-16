#!/bin/bash
# RoxyPet 发布脚本：编译 → 组装 app → 打包成 dmg
# 用法：./make-release.sh [版本号]    例如 ./make-release.sh 2.1（默认 2.0）
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VER="${1:-2.0}"
DMG="$ROOT/RoxyPet-v$VER.dmg"

# 第 1 步：构建 RoxyPet.app（内部会调用 build.sh）
./build.sh

# 第 2 步：把 app 装进一个干净的"安装舞台"：app + Applications 快捷方式 + 说明
echo ""
echo "== 打包 dmg（RoxyPet-v$VER.dmg）=="
STAGE="$(mktemp -d /tmp/roxy-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/RoxyPet.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/install-notes.txt" <<'EOF'
RoxyPet · 安装说明

① 把 RoxyPet.app 拖到 Applications（或直接双击运行）
② 首次打开若提示「无法验证开发者」：
   右键 App → 打开 → 再点「打开」；
   或到「系统设置 → 隐私与安全性」里点「仍要打开」
③ 需要 macOS 14 以上（Apple 芯片）
④ 「透视魔法」功能首次使用需要授予「屏幕录制」权限
EOF

# 第 3 步：把"安装舞台"压成一张只读 dmg
hdiutil create -volname "RoxyPet" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo ""
echo "✅ 发布包已生成: $DMG"
echo "   把它拖进 GitHub Releases 即可"
