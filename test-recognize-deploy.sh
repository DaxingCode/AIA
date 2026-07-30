#!/bin/bash
# recognize 云函数部署后验证脚本
# 用法：bash test-recognize-deploy.sh
# 图片识别（可选）：TEST_IMAGE=/path/to/截图.jpg [TEST_IMAGE_EXPECT=购物] bash test-recognize-deploy.sh
# 验证点：账单分类是否收敛到预设 27 大类（方案1 提示词约束 + 方案2 云端归一化兜底）

ENDPOINT="https://cloud1-d1ga55pizf294dbe9-1445590522.ap-shanghai.app.tcloudbase.com/recognize"

# 图片识别测试（可选）：
#   指定本地截图路径后，会 base64 编码并以 imageBase64 字段 POST，验证视觉模型主路径。
#   用法：TEST_IMAGE=/path/to/screenshot.jpg bash test-recognize-deploy.sh
#   可选期望分类：TEST_IMAGE=/path/to/x.jpg TEST_IMAGE_EXPECT=购物 bash test-recognize-deploy.sh
TEST_IMAGE="${TEST_IMAGE:-}"
TEST_IMAGE_EXPECT="${TEST_IMAGE_EXPECT:-}"

# 测试用例：描述 -> 期望分类
CASES=(
  "在星巴克买了杯拿铁38元|餐饮"
  "滴滴打车32元|交通"
  "永辉超市买菜58元|购物"
  "美团点了个火锅套餐128|餐饮"
  "中石化加了200油|交通"
  "顺丰寄了个快递18|快递"
  "在麦当劳吃了45元|餐饮"
  "优衣库买件衣服99|服饰"
  "医院挂号看病60|医疗"
)

echo "=========================================="
echo " endpoint: $ENDPOINT"
echo " 共 ${#CASES[@]} 个用例"
echo "=========================================="

pass=0
fail=0

for c in "${CASES[@]}"; do
  text="${c%%|*}"
  expect="${c##*|}"

  : > /tmp/recog_resp.json   # 先清空，避免上一条失败残留
  http_code=$(curl -s --max-time 25 -o /tmp/recog_resp.json -w "%{http_code}" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"$text\"}")
  resp=$(cat /tmp/recog_resp.json 2>/dev/null)

  got=$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
res = d.get("result", {})
types = res.get("types", [])
if "bill" in types and isinstance(res.get("bill"), dict):
    print(res["bill"].get("category", ""))
else:
    print("")
' 2>/dev/null)

  if [ "$http_code" != "200" ]; then
    echo "⚠️  [期望 $expect] $text  -> HTTP $http_code（请求未成功）"
    echo "    原始返回: $resp"
    fail=$((fail+1))
  elif [ "$got" = "$expect" ]; then
    echo "✅ [$expect] $text  -> $got"
    pass=$((pass+1))
  elif [ -z "$got" ]; then
    echo "❌ [期望 $expect] $text  -> 实得为空（未在返回中找到 category）"
    echo "    原始返回: $resp"
    fail=$((fail+1))
  else
    echo "❌ [期望 $expect] $text  -> 实得: '$got'"
    fail=$((fail+1))
  fi
done

# ---------------------- 图片识别测试 ----------------------
if [ -n "$TEST_IMAGE" ]; then
  if [ ! -f "$TEST_IMAGE" ]; then
    echo "⚠️  TEST_IMAGE 指定的文件不存在：$TEST_IMAGE（跳过图片测试）"
  else
    echo "------------------------------------------"
    echo "📷 图片识别测试：$TEST_IMAGE"
    b64=$(base64 -i "$TEST_IMAGE" | tr -d '\n')
    : > /tmp/recog_img.json
    http_code=$(curl -s --max-time 30 -o /tmp/recog_img.json -w "%{http_code}" \
      -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "{\"imageBase64\":\"$b64\"}")
    resp=$(cat /tmp/recog_img.json 2>/dev/null)

    # 解析：优先 bill.category；否则 food 名称；否则 首个 type
    parsed=$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
res = d.get("result", {})
types = res.get("types", [])
out = ""
if "bill" in types and isinstance(res.get("bill"), dict):
    out = "bill:" + str(res["bill"].get("category", ""))
elif "food" in types and isinstance(res.get("food"), dict):
    out = "food:" + str(res["food"].get("name", ""))
else:
    out = "/".join(types) if types else ""
print(out)
' 2>/dev/null)

    if [ "$http_code" != "200" ]; then
      echo "⚠️  图片请求 HTTP $http_code（请求未成功）"
      echo "    原始返回: $resp"
      fail=$((fail+1))
    elif [ -z "$parsed" ]; then
      echo "❌ 图片识别未得到结构化结果"
      echo "    原始返回: $resp"
      fail=$((fail+1))
    elif [ -n "$TEST_IMAGE_EXPECT" ]; then
      if printf '%s' "$parsed" | grep -q "bill:$TEST_IMAGE_EXPECT"; then
        echo "✅ [图片/$TEST_IMAGE_EXPECT] $parsed"
        pass=$((pass+1))
      else
        echo "❌ [期望图片/$TEST_IMAGE_EXPECT] 实得: '$parsed'"
        echo "    原始返回: $resp"
        fail=$((fail+1))
      fi
    else
      echo "✅ [图片] 识别结果: $parsed（未设 TEST_IMAGE_EXPECT，仅展示）"
      pass=$((pass+1))
    fi
    echo "------------------------------------------"
  fi
fi

echo "=========================================="
echo " 通过 $pass / 失败 $fail"
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "提示：失败可能是云端未部署成功或返回结构变化。检查："
  echo "  1) 控制台 recognize 是否已『发布』"
  echo "  2) /recognize 的『集成响应』是否关闭（开着会 HTTP 400）"
  echo "  3) 展开云函数日志看 console.error"
  echo "  4) 若原始返回是聊天文本而非结构化账单，说明纯文本走了 agent 聊天路径"
  exit 1
fi
echo "全部通过 ✅"
