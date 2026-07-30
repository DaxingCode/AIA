#!/usr/bin/env python3
import subprocess, json, sys

CLI = "/Users/daxing/.workbuddy/binaries/node/workspace/node_modules/.bin/cloudbase"
ENV = "cloud1-d1ga55pizf294dbe9"
FUNCS = ["aia-sync", "loadData", "subscribeMessage", "saveData", "recognize",
         "lookupFood", "recognizeFood", "getOpenid", "cleanupShare"]
DAY = "2026-07-27"

def hour_counts(hour):
    hs = f"{hour:02d}"
    start_s = f"{DAY} {hs}:00:00"
    end_s = f"{DAY} {hs}:59:59"
    query = 'function_name:* | select function_name, count(distinct request_id) as invocations where status_code!=202 AND retry_num=0 group by function_name limit 100'
    cmd = [CLI, "logs", "search", "-e", ENV, "-q", query, "-t", f"{start_s},{end_s}", "-l", "1", "--json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return {f: "ERR" for f in FUNCS}
    text = out.stdout
    idx = text.find("{")
    if idx < 0:
        return {f: 0 for f in FUNCS}
    try:
        data = json.loads(text[idx:])
    except Exception:
        return {f: 0 for f in FUNCS}
    ar = data.get("data", {}).get("analysisRecords", [])
    d = {}
    for r in ar:
        if "function_name" in r:
            d[r["function_name"]] = r.get("invocations", 0)
    return {f: d.get(f, 0) for f in FUNCS}

matrix = {f: {} for f in FUNCS}
for h in range(24):
    c = hour_counts(h)
    for f in FUNCS:
        matrix[f][h] = c.get(f, 0)
    tot = sum(v for v in c.values() if isinstance(v, int))
    sys.stderr.write(f"{DAY} {h:02d}:00  合计 {tot}\n")

# 输出 CSV：行=函数，列=小时0~23 + TOTAL
header = "function," + ",".join(f"{h:02d}" for h in range(24)) + ",TOTAL"
print(header)
for f in FUNCS:
    row = [f]
    total = 0
    for h in range(24):
        v = matrix[f][h]
        row.append(str(v) if isinstance(v, int) else str(v))
        if isinstance(v, int):
            total += v
    row.append(str(total))
    print(",".join(row))
# 小时合计行
print("HOUR_TOTAL," + ",".join(str(sum(matrix[f][h] for f in FUNCS if isinstance(matrix[f][h], int))) for h in range(24)) + ",15865")
