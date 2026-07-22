#!/bin/bash
# recognize 云函数打包入口（兼容旧路径）。
# 自 2026-07-22 起，recognize 云函数统一在 云函数/recognize/ 下维护与打包，
# 本脚本仅做重定向，确保无论从哪个路径调用，产物都落在 云函数/recognize/。
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../../云函数/recognize/package-recognize.sh"
if [ ! -f "$TARGET" ]; then
  echo "错误：找不到规范打包脚本 $TARGET"
  exit 1
fi
exec "$TARGET" "$@"
