#!/bin/bash
# 双击本文件：编译 Roxy.app 并自动打开
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ 没有找到 swiftc —— 请先安装 Xcode 命令行工具："
  echo "   在终端运行：xcode-select --install"
  echo ""
  read -n 1 -s -r -p "按任意键关闭…"
  exit 1
fi

echo "== 开始构建 Roxy =="
chmod +x ./build.sh 2>/dev/null
./build.sh || { echo ""; echo "❌ 构建失败，请把上面的报错发给我"; read -n 1 -s -r -p "按任意键关闭…"; exit 1; }

echo ""
echo "✅ 构建完成，正在打开桌宠…（右键她可以看到菜单）"
open "../Roxy.app"

echo ""
read -n 1 -s -r -p "按任意键关闭本窗口"
