#!/usr/bin/env python3
import subprocess, json, sys, datetime

CLI = "/Users/daxing/.workbuddy/binaries/node/workspace/node_modules/.bin/cloudbase"
ENV = "cloud1-d1ga55pizf294dbe9"

# 最近 7 天（含今天），窗口用绝对时间
end = datetime.datetime(2026, 7, 29, 23, 59, 59)
start = end - datetime.timedelta(days=6)
start_s = start.strftime("%Y-%m-%d 00:00:00")
end_s = end.strftime("%Y-%m-%d 23:59:59")
print(f"时间窗口: {start_s}  ~  {end_s}", file=sys.stderr)

# 按函数+按天聚合调用次数（distinct request_id 去重，过滤中间态202与重试）
query = (
    "* | select function_name, "
    "date_format(from_unixtime(cast(start_time as bigint)/1000), '%Y-%m-%d') as day, "
    "count(distinct request_id) as invocations "
    "where status_code!=202 AND retry_num=0 "
    "group by function_name, day "
    "order by day asc, invocations desc "
    "limit 1000"
)

cmd = [CLI, "logs", "search", "-e", ENV, "-q", query, "-t", f"{start_s},{end_s}", "-l", "100", "--json"]
print("CMD:", " ".join(cmd[:6]), "...", file=sys.stderr)
out = subprocess.run(cmd, capture_output=True, text=True)
if out.returncode != 0:
    print("STDERR:", out.stderr, file=sys.stderr)
    print("STDOUT:", out.stdout[:2000], file=sys.stderr)
    sys.exit(1)

# 解析 JSON：stdout 可能在 Loading 行后才是 JSON
text = out.stdout
# 找到第一个 { 开始
idx = text.find("{")
data = json.loads(text[idx:])

results = data.get("data", {}).get("results", [])
rows = []
for r in results:
    c = r.get("content", {})
    rows.append({
        "function_name": c.get("function_name"),
        "day": c.get("day"),
        "invocations": c.get("invocations"),
    })
print(json.dumps(rows, ensure_ascii=False, indent=2))
print(f"\n总行数(函数×天): {len(rows)}", file=sys.stderr)
