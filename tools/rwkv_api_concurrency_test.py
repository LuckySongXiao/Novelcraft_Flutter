#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""api-7b.rwkvos.com 并发阶梯压测 v2 —— 用 --next 分块，确保每个请求的
响应体与 -w 统计互不串流。"""
import os, json, glob, time, subprocess, statistics

CF_ID = '7e06b7648f552e22842e308939e68be6.access'
CF_SECRET = '8f97be4d651e792df1c29c005533e55aad72354b536ca486f65413b96a93d83a'
URL = 'https://api-7b.rwkvos.com/v1/chat/completions'
MODEL = 'rwkv7-g1j-7.2b-20260831-ctx16384'
T = r'F:/30_Novelcraft_Flutter/_tmp/par2'
os.makedirs(T, exist_ok=True)

body = json.dumps({
    "model": MODEL,
    "messages": [{"role": "user",
                  "content": "请用一句话描述你的推理引擎特点。"}],
    "max_tokens": 48, "temperature": 0.7,
}, ensure_ascii=False)
bp = os.path.join(T, 'body.json')
open(bp, 'w', encoding='utf-8').write(body)

LEVELS = [1, 2, 4, 8, 12, 16, 24, 32]


def run(N):
    for f in glob.glob(os.path.join(T, 'o_*.json')):
        os.remove(f)
    cmd = ['curl', '--parallel', '--parallel-immediate',
           '--parallel-max', str(N), '-s', '--max-time', '240']
    for i in range(N):
        if i:
            cmd.append('--next')
        cmd += ['-H', 'CF-Access-Client-Id: ' + CF_ID,
                '-H', 'CF-Access-Client-Secret: ' + CF_SECRET,
                '-H', 'Content-Type: application/json',
                '-d', '@' + bp,
                '-o', os.path.join(T, 'o_%d.json' % i),
                '-w', 'REQ' + str(i) + ' %{http_code} %{time_total}\n',
                URL]
    t0 = time.monotonic()
    p = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.monotonic() - t0
    return p, wall


print('=' * 92)
print('官方 API 并发阶梯压测   POST /v1/chat/completions   max_tokens=48')
print('=' * 92)
print('并发  200  内容非空  墙钟s   均值s   最快   最慢   吞吐(请求/s)   其他状态码')
print('-' * 92)
rows = []
for N in LEVELS:
    p, wall = run(N)
    codes, times = {}, []
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].startswith('REQ'):
            codes[parts[1]] = codes.get(parts[1], 0) + 1
            try:
                times.append(float(parts[2]))
            except ValueError:
                pass
    ok = codes.get('200', 0)
    good = 0
    for f in glob.glob(os.path.join(T, 'o_*.json')):
        try:
            d = json.load(open(f, encoding='utf-8'))
            c = (d.get('choices') or [{}])[0]
            if ((c.get('message') or {}).get('content') or '').strip():
                good += 1
        except Exception:
            pass
    others = {k: v for k, v in codes.items() if k != '200'}
    tput = N / wall if wall > 0 else 0
    print('%4d  %3d  %6d  %6.2f  %6.2f  %5.2f  %5.2f  %10.2f   %s'
          % (N, ok, good, wall,
             statistics.mean(times) if times else 0,
             min(times) if times else 0,
             max(times) if times else 0, tput, others or '-'))
    if p.stderr.strip():
        print('      stderr: %s' % p.stderr.strip()[:200])
    rows.append((N, ok, good, wall, tput))

print('-' * 92)
allok = [r for r in rows if r[1] == r[0] and r[2] == r[0]]
if allok:
    b = allok[-1]
    print('⇒ 可稳定全成功（200 + 内容非空）的最大并发：N=%d' % b[0])
else:
    print('⇒ 没有任何一档做到 100% 全成功')
best_tp = max(rows, key=lambda r: r[4])
print('⇒ 吞吐峰值：N=%d，%.2f 请求/s' % (best_tp[0], best_tp[4]))
