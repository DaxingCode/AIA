#!/usr/bin/env bash
# aia-ads 打包脚本（在 ads 目录内运行）
# 用法：./package-ads.sh
# 产物：aia-ads-YYYYMMDD.zip（含 index.js + package.json）
# 说明：wx-server-sdk 由云端运行时提供，无需打包 node_modules。
#       生成的 zip 需手动上传 CloudBase 控制台「云函数 aia-ads」重新部署（gitignored）。
set -e
cd "$(dirname "$0")"
DATE=$(date +%Y%m%d)
ZIP="aia-ads-${DATE}.zip"
rm -f "$ZIP"
zip -r "$ZIP" index.js package.json
echo "✅ 已生成 $ZIP"
echo "请手动上传到 CloudBase 控制台「云函数 aia-ads」重新部署（HTTP 触发路径 /ads，需与 /recognize、/sync 同环境同集成响应设置）。"
echo "部署后到云函数环境变量设置 DEV_PASSCODE（与 App 端 DeveloperGate.passcode 一致）。"
