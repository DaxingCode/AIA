#!/usr/bin/env python3
# 同时拉取两个环境的 10 天(07-20~07-29)各函数每日调用矩阵，输出并排对比。
import subprocess, json, sys, datetime

CLI = "/Users/daxing/.workbuddy/binaries/node/workspace/node_modules/.bin/cloudbase"

ENVS = {
    "main":    ("cloud1-d1ga55pizf294dbe9", ["aia-sync","loadData","subscribeMessage","saveData","recognize","lookupFood","recognizeFood","getOpenid","cleanupShare"]),
    "aizhuli": ("aizhuli-d1ghh20818e926713", ["aia-sync","recognize"]),
}
END = datetime.date(2026, 7, 29)
DAYS = [END - datetime.timedelta(days=i) for i in range(9, -1, -1)]  # 07-20..07-29

def day_counts(env, funcs, day):
    start_s = f"{day} 00:00:00"; end_s = f"{day} 23:59:59"
    query = 'function_name:* | select function_name, count(distinct request_id) as invocations where status_code!=202 AND retry_num=0 group by function_name limit 100'
    cmd = [CLI, "logs", "search", "-e", env, "-q", query, "-t", f"{start_s},{end_s}", "-l", "1", "--json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return {f: "ERR" for f in funcs}
    text = out.stdout; idx = text.find("{");
    if idx < 0: return {f: 0 for f in funcs}
    try: data = json.loads(text[idx:])
    except Exception: return {f: 0 for f in funcs}
    ar = data.get("data", {}).get("analysisRecords", [])
    d = {r["function_name"]: r.get("invocations",0) for r in ar if "function_name" in r}
    return {f: d.get(f, 0) for f in funcs}

results = {}
for name,(env,funcs) in ENVS.items():
    matrix = {f: {} for f in funcs}
    for day in DAYS:
        c = day_counts(env, funcs, day)
        for f in funcs:
            matrix[f][str(day)] = c.get(f, 0)
        tot = sum(v for v in c.values() if isinstance(v, int))
        sys.stderr.write(f"[{name}] {day} 合计 {tot}\n")
    results[name] = (env, funcs, matrix)

# 输出
day_strs = [str(d) for d in DAYS]
for name,(env,funcs,matrix) in results.items():
    print(f"\n##### 环境 {name} ({env}) #####")
    print("function," + ",".join(day_strs) + ",TOTAL")
    for f in funcs:
        row=[f]; tot=0
        for d in day_strs:
            v=matrix[f][d]; row.append(str(v)); tot+= (v if isinstance(v,int) else 0)
        row.append(str(tot)); print(",".join(row))
    env_day_total=[sum(matrix[f][d] for f in funcs if isinstance(matrix[f][d],int)) for d in day_strs]
    print("ENV_DAY_TOTAL," + ",".join(str(x) for x in env_day_total) + f",{sum(env_day_total)}")
