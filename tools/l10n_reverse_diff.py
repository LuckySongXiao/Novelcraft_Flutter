#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P1-12 L10n reverse key diff (PITFALLS §26.3).

Extract every key used in code via l10n.t('K') / l10n.tf('K') / **X.t('K') / tf('K'),
and every key declared in zhStrings / enStrings inside strings.g.dart, then report:
  - code -> table missing (切 EN 会显示中文 fallback 的 exactly 集合)
  - zh exists but en missing (切 EN 显示 fallback 的另一来源)
  - en exists but zh missing
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(r"F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft")
L10N = ROOT / "lib" / "l10n" / "strings.g.dart"

# ---- 1. keys used in code ----
code_keys = set()
code_hits = {}  # key -> list of (file:line)
# match  .t('KEY'  or  .tf('KEY'  or  t('KEY'  (any receiver ending in l10n/context.t)
pat_call = re.compile(r"""(?:\bl10n|\.l10n|\bL10n|context|\w+)\s*\.\s*(?:t|tf)\s*\(\s*'([^']+)'""")
pat_ctx = re.compile(r"""context\s*\.\s*(?:t|tf)\s*\(\s*'([^']+)'""")

dart_files = list(ROOT.rglob("*.dart"))
for f in dart_files:
    # skip generated + build dirs
    s = str(f).replace("\\", "/")
    if "/build/" in s or s.endswith("strings.g.dart") or "/.dart_tool/" in s:
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except Exception:
        continue
    for i, line in enumerate(text.splitlines(), 1):
        for m in pat_call.finditer(line):
            k = m.group(1)
            if re.fullmatch(r"[A-Za-z0-9_.\-/]+", k):
                code_keys.add(k)
                code_hits.setdefault(k, []).append(f"{f.relative_to(ROOT)}:{i}")

# ---- 2. table keys ----
tbl_text = L10N.read_text(encoding="utf-8")
lines = tbl_text.splitlines()

def collect(start_marker):
    """collect keys from the const map starting at the line containing start_marker"""
    start = None
    for i, ln in enumerate(lines):
        if start_marker in ln:
            start = i
            break
    if start is None:
        return None, 1
    keys = set()
    depth = 0
    started = False
    for ln in lines[start:]:
        if not started:
            if "{" in ln:
                started = True
                depth = 1
            continue
        if depth == 0:
            break
        m = re.match(r"\s*'([^']+)'\s*:", ln)
        if m:
            keys.add(m.group(1))
        depth += ln.count("{") - ln.count("}")
    return keys, 0

zh_keys, _ = collect("const Map<String, String> zhStrings")
en_keys, _ = collect("const Map<String, String> enStrings")

missing_en = sorted(k for k in code_keys if k not in en_keys)
missing_zh = sorted(k for k in code_keys if k not in zh_keys)
en_not_zh = sorted(en_keys - zh_keys)
zh_not_en = sorted(zh_keys - en_keys)

print(f"scanned .dart files : {len(dart_files)}")
print(f"code keys           : {len(code_keys)}")
print(f"zhStrings keys      : {len(zh_keys)}")
print(f"enStrings keys      : {len(en_keys)}")
print()
print(f"=== [A] 代码用了但 en 表没有 ({len(missing_en)}) —— 切 EN 不生效 ===")
for k in missing_en:
    print(f"  {k}   <- {code_hits[k][0]}")
print()
print(f"=== [B] 代码用了但 zh 表没有 ({len(missing_zh)}) ===")
for k in missing_zh:
    print(f"  {k}   <- {code_hits[k][0]}")
print()
print(f"=== [C] en 有 zh 无 ({len(en_not_zh)}) ===")
print("  " + ", ".join(en_not_zh[:80]))
print()
print(f"=== [D] zh 有 en 无 ({len(zh_not_en)}) ===")
print("  " + ", ".join(zh_not_en[:80]))
print()
ok = (not missing_en) and (not missing_zh) and (not en_not_zh) and (not zh_not_en)
print("VERDICT:", "PASS (差集为空)" if ok else "FAIL")
sys.exit(0 if ok else 1)
