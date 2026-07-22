#!/bin/bash
# 打包 recognize 云函数为 CloudBase 上传用的 zip。
# 用法：在 云函数/recognize/ 目录执行 ./package-recognize.sh
# 命名规则：recognize-YYYYMMDDx[.suffix].zip（如 20260722e-sensenova），默认生成在脚本所在目录（云函数/recognize/）。
# zip 根目录仅含 index.js + package.json（无 node_modules，云端自动安装依赖）。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# 命名直接跟随 index.js 里的 FN_VERSION（如 '20260720d' 或 '20260722e-sensenova'），保证 zip 名与代码版本一致，不覆盖、不错位。
FN=$(grep -oE "FN_VERSION = '[0-9]{8}[a-z]+(-[a-z]+)?'" "$DIR/index.js" | grep -oE "[0-9]{8}[a-z]+(-[a-z]+)?" | head -1)
if [ -z "$FN" ]; then
  echo "错误：无法从 index.js 读取 FN_VERSION，请检查 const FN_VERSION = 'YYYYMMDDx';"
  exit 1
fi

ZIP="$DIR/recognize-${FN}.zip"
rm -f "$ZIP"
cd "$DIR"
zip -r "$ZIP" index.js package.json >/dev/null
echo "已打包：$ZIP（版本 $FN，与 FN_VERSION 对齐）"
unzip -l "$ZIP"
