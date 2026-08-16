#!/usr/bin/env bash
# aia-sync 打包脚本（在 aia-sync 目录内运行）
# 用法：./package-aia-sync.sh
# 产物：aia-sync-YYYYMMDD.zip（含 index.js + package.json）
# 说明：wx-server-sdk 由云端运行时提供，无需打包 node_modules。
#       生成的 zip 需手动上传 CloudBase 控制台「云函数 aia-sync」重新部署（gitignored）。
set -e
cd "$(dirname "$0")"
DATE=$(date +%Y%m%d)
ZIP="aia-sync-${DATE}.zip"
rm -f "$ZIP"
zip -r "$ZIP" index.js package.json entitlement.js
echo "✅ 已生成 $ZIP"
echo "请手动上传到 CloudBase 控制台「云函数 aia-sync」重新部署（HTTP 触发路径 /sync，集成响应开关与 /recognize 一致）。"
