#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L10n 词表内部一致性审计 + 配置表缺英文审计"""
import re, io, os, json

S = r"F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft\lib\l10n\strings.g.dart"
CJK = re.compile(r'[\u4e00-\u9fff]')

def parse_map(text, name):
    i = text.index("const Map<String, String> %s = <String, String>{" % name)
    j = text.index("\n};", i)
    body = text[i:j]
    out = {}
    for m in re.finditer(r"'((?:[^'\\]|\\.)*)'\s*:\s*'((?:[^'\\]|\\.)*)'\s*,", body):
        out[m.group(1)] = m.group(2)
    return out

txt = io.open(S, encoding="utf-8").read()
zh = parse_map(txt, "zhStrings")
en = parse_map(txt, "enStrings")
print("zh keys=%d en keys=%d" % (len(zh), len(en)))

en_has_cjk = [(k, en[k]) for k in en if CJK.search(en[k])]
print()
print("=" * 90)
print("[1] EN 表里仍含中文 → 切 EN 后显示中文  (%d)" % len(en_has_cjk))
print("=" * 90)
for k, v in sorted(en_has_cjk):
    print("  %-42s %s" % (k, v[:70]))

same = [(k, zh[k]) for k in zh if k in en and zh[k] == en[k] and CJK.search(zh[k])]
print()
print("=" * 90)
print("[2] zh == en 且含中文（中英未分）  (%d)" % len(same))
print("=" * 90)
for k, v in sorted(same):
    print("  %-42s %s" % (k, v[:70]))

ascii_zh = [(k, zh[k]) for k in zh
            if k in en and not CJK.search(zh[k]) and re.fullmatch(r"[A-Za-z0-9 ,.:;!?'()/\-+%&*#\[\]{}<>=_|~$@^`\\\"]{1,40}", zh[k])]
print()
print("=" * 90)
print("[3] zh 值是纯英文短串（切 ZH 仍显示英文，可能是漏译；需人工判定）  (%d)" % len(ascii_zh))
print("=" * 90)
for k, v in sorted(ascii_zh)[:200]:
    print("  %-42s zh=%s | en=%s" % (k, v[:40], en[k][:40]))
