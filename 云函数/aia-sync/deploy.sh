#!/usr/bin/env bash
# aia-sync 部署脚本（在解压后的 aia-sync 目录内运行）
# 用法：./deploy.sh <你的CloudBase环境ID>
set -e

ENV_ID="$1"
if [ -z "$ENV_ID" ]; then
  echo "用法：./deploy.sh <CloudBase环境ID>"
  echo "环境ID 在 CloudBase 控制台「环境 / 总览」查看，形如 cloud1-xxxxxxxx"
  exit 1
fi

echo "==> 安装 CloudBase CLI（如已安装可跳过）"
npm i -g @cloudbase/cli

echo "==> 登录（会自动打开浏览器，按提示扫码授权）"
tcb login

echo "==> 部署云函数 aia-sync 到环境 $ENV_ID"
tcb fn deploy aia-sync --envId "$ENV_ID" --force

echo ""
echo "✅ 函数部署完成。"
echo "请继续在 CloudBase 控制台手动完成（CLI 不易一步到位的步骤）："
echo "  1) 云数据库 → 新建集合 aia_records"
echo "  2) 云函数 aia-sync → 新建 HTTP 触发，路径 /sync，"
echo "     触发器设置请与现有 /recognize 触发器保持一致（尤其是「集成响应」开关）"
echo "  3) 验证："
echo "     curl -X POST <你的/sync地址> -H 'Content-Type: application/json' \\"
echo "       -d '{\"action\":\"pull\",\"userId\":\"test\",\"since\":0}'"
echo "     应返回 {\"ok\":true,\"records\":[],\"count\":0}"
