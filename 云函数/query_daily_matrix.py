#!/usr/bin/env python3
import subprocess, json, sys, datetime

CLI = "/Users/daxing/.workbuddy/binaries/node/workspace/node_modules/.bin/cloudbase"
ENV = "cloud1-d1ga55pizf294dbe9"

FUNCS = ["aia-sync", "recognize", "getOpenid", "subscribeMessage",
         "saveData", "loadData", "lookupFood", "cleanupShare", "recognizeFood"]

# 最近 7 天（含今天 2026-07-29）
end_day = datetime.date(2026, 7, 29)
days = [(end_day - datetime.timedelta(days=i)) for i in range(6, -1, -1)]  # 旧->新

def count_inv(fname, day):
    start_s = f"{day} 00:00:00"
    end_s = f"{day} 23:59:59"
    query = f'function_name:"{fname}" | select count(distinct request_id) as invocations'
    cmd = [CLI, "logs", "search", "-e", ENV, "-q", query, "-t", f"{start_s},{end_s}", "-l", "1", "--json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return ("ERR", out.stderr[:200])
    text = out.stdout
    idx = text.find("{")
    if idx < 0:
        return ("ERR", "no json")
    try:
        data = json.loads(text[idx:])
    except Exception as e:
        return ("ERR", str(e))
    ar = data.get("data", {}).get("analysisRecords", [])
    if not ar:
        return 0
    return ar[0].get("invocations", 0)

# 构建矩阵
matrix = {f: {} for f in FUNCS}
for f in FUNCS:
    for d in days:
        n = count_inv(f, d)
        matrix[f][str(d)] = n
        if isinstance(n, int):
            sys.stderr.write(f"{f} {d}: {n}\n")
        else:
            sys.stderr.write(f"{f} {d}: {n}\n")

# 输出 CSV 矩阵
day_strs = [str(d) for d in days]
header = "function," + ",".join(day_strs) + ",TOTAL"
print(header)
for f in FUNCS:
    row = [f]
    total = 0
    for d in days:
        v = matrix[f][str(d)]
        if isinstance(v, int):
            row.append(str(v)); total += v
        else:
            row.append(str(v))
    row.append(str(total))
    print(",".join(row))
