#!/bin/bash
# Roxy 发布脚本；--skip-build 打包已经测试过的同一份 Roxy.app。
# 用法：./make-release.sh [--skip-build] [--report PATH] [--backup PATH]
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_BUILD=0
PACKAGE_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --report|--backup)
      if [ "$#" -lt 2 ]; then
        echo "缺少 $1 的路径参数" >&2
        exit 2
      fi
      PACKAGE_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      echo "用法：$0 [--skip-build] [--report PATH] [--backup PATH]"
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法打包 DMG" >&2; exit 1; }
if [ "$SKIP_BUILD" -eq 0 ]; then
  "$SCRIPT_DIR/build.sh"
fi

# 继承旧镜像布局、只读校验、逐文件比对、验签后原子替换；不调用 Finder。
python3 "$SCRIPT_DIR/package-dmg.py" "$PROJECT_ROOT/Roxy.app" "$PROJECT_ROOT/Roxy.dmg" "${PACKAGE_ARGS[@]}"
