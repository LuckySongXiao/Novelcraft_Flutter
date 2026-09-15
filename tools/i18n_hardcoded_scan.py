#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""剔除 l10n.t(...)/l10n.tf(...) 调用后，统计真正硬编码的中文"""
import re, os, io
from collections import Counter

UI = r"F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft\lib\ui"
CJK = re.compile(r'[\u4e00-\u9fff]')
SKIP_CALL = re.compile(r"\.(info|warning|severe|fine|shout|log|debug)\s*\(")

def strip_l10n_calls(t):
    """把 l10n.t( ... ) / l10n.tf( ... ) 的整段调用替换为空白（保留换行数）"""
    out = []
    i = 0
    n = len(t)
    while i < n:
        m = re.compile(r"\.t[f]?\(").search(t, i)
        if not m:
            out.append(t[i:])
            break
        out.append(t[i:m.start()])
        # 从 '(' 开始配对
        j = m.end() - 1
        depth = 0
        while j < n:
            c = t[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            elif c == "'":  # 跳过字符串
                j += 1
                while j < n and t[j] != "'":
                    if t[j] == '\\':
                        j += 1
                    j += 1
            j += 1
        seg = t[m.start():j + 1]
        out.append("\n" * seg.count("\n"))
        i = j + 1
    return "".join(out)

cnt = Counter()
samples = {}
for dp, dn, fn in os.walk(UI):
    for f in fn:
        if not f.endswith(".dart"):
            continue
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, UI)
        with io.open(p, encoding="utf-8") as fh:
            src = fh.read()
        stripped = strip_l10n_calls(src)
        lines = stripped.split("\n")
        orig = src.split("\n")
        for i, line in enumerate(lines, 1):
            code = line.split("//")[0]
            if SKIP_CALL.search(code):
                continue
            if CJK.search(code):
                cnt[rel] += 1
                samples.setdefault(rel, []).append((i, orig[i - 1].strip()[:110]))

print("=" * 100)
print("真正硬编码中文（已剔除 l10n.t/tf 调用与日志）")
print("=" * 100)
for rel, n in cnt.most_common():
    print("\n### %s   (%d 行)" % (rel, n))
    for i, s in samples[rel][:22]:
        print("    %-5d %s" % (i, s))
print("\n合计 %d 文件 / %d 行" % (len(cnt), sum(cnt.values())))
