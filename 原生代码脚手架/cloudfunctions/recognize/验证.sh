#!/bin/bash
# 验证 CloudBase recognize 云函数是否部署了最新代码（含规则10服务端兜底）。
# 用法：bash 验证.sh   （需联网；curl 已随 macOS 自带）
EP="https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize"

echo "===== 0) 版本标记：新代码应返回 ver=20260719b（否则说明发布未生效）====="
curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" \
  -d '{"text":"ping","provider":"qwen"}' | cat
echo ""

echo "===== 1) 规则10 关键：「好的」带上下文 → 必须 types:[\"none\"] ====="
curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" \
  -d '{"text":"好的","provider":"qwen","recentMessages":[{"role":"user","text":"提醒我明天写代码"},{"role":"ai","text":"好的，已帮你记下待办「写代码」"}]}' | cat
echo ""

echo "===== 2) 通用回应「可以/嗯/谢谢」→ 必须 none ====="
for w in 可以 嗯 谢谢; do
  echo -n "[$w] "; curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" -d "{\"text\":\"$w\",\"provider\":\"qwen\"}" | cat; echo ""
done

echo "===== 3) 正常新建仍应建待办（功能不丢）====="
curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" \
  -d '{"text":"提醒我后天下午去体检","provider":"qwen"}' | cat
echo ""

echo "===== 4) 含指令的「好的帮我改成周五」→ 应放行给模型（update）====="
curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" \
  -d '{"text":"好的帮我改成周五","provider":"qwen","recentMessages":[{"role":"user","text":"提醒我明天写代码"},{"role":"ai","text":"已记下写代码"}]}' | cat
echo ""

echo "===== 5) chat 模式连通性 ====="
curl -s -m 40 -X POST "$EP" -H "Content-Type: application/json" \
  -d '{"mode":"chat","text":"你好呀","context":{"foods":[],"bills":[],"todos":[]},"provider":"qwen"}' | cat
echo ""
