#!/bin/bash
# 打包 recognize 云函数为 CloudBase 上传用的 zip。
# 用法：在 云函数/recognize/ 目录执行 ./package-recognize.sh
# 命名规则：recognize-YYYYMMDDx[.suffix].zip（如 20260722e-sensenova），默认生成在脚本所在目录（云函数/recognize/）。
# zip 根目录含 index.js + package.json + 4 个 agent 模块（agentHandler/agentPrompt/agentSchema/agentTools，被 index.js require，须随包上传；无 node_modules，云端自动安装依赖）。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# 命名直接跟随 index.js 里的 FN_VERSION（如 '20260720d' 或 '20260722e-sensenova'），保证 zip 名与代码版本一致，不覆盖、不错位。
FN=$(grep -oE "FN_VERSION = '[0-9]{8}[a-z]+(-[a-z]+)*'" "$DIR/index.js" | grep -oE "[0-9]{8}[a-z]+(-[a-z]+)*" | head -1)
if [ -z "$FN" ]; then
  echo "错误：无法从 index.js 读取 FN_VERSION，请检查 const FN_VERSION = 'YYYYMMDDx';"
  exit 1
fi

ZIP="$DIR/recognize-${FN}.zip"
rm -f "$ZIP"
cd "$DIR"
# 主文件必含；agent*.js 为「可单独开关」的只读问答 Agent 模块，云端 require 依赖它们，必须一并打包。
EXTRA=$(ls agent*.js 2>/dev/null || true)
zip -r "$ZIP" index.js package.json $EXTRA >/dev/null
echo "已打包：$ZIP（版本 $FN，与 FN_VERSION 对齐；含 index/package$( [ -n "$EXTRA" ] && echo " + $(echo $EXTRA | wc -w | tr -d ' ') 个 agent 模块" )）"
unzip -l "$ZIP"
