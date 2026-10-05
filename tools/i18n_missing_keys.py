#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""扫描 lib/ 下所有 `l10n.t('K', '兜底')` / `.tf('K', '兜底', ...)` 调用，
检查 key 是否存在于 strings.g.dart 的 enStrings —— 缺 key 时英文界面会静默
退回中文兜底，这正是"英文界面仍是中文"这类 i18n 缺口的成因。

用法：
    python tools/i18n_missing_keys.py            # 只报告缺失
    python tools/i18n_missing_keys.py --all      # 连 zh 缺失一起报告
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "lib", "l10n", "strings.g.dart")

CALL = re.compile(
    r"""\.(?:t|tf)\(\s*'((?:[^'\\]|\\.)*)'\s*,\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")""",
    re.S,
)


def load_tables():
    src = io.open(GEN, encoding="utf-8").read()
    zh_start = src.index("const Map<String, String> zhStrings")
    en_start = src.index("const Map<String, String> enStrings")
    pat = re.compile(r"^\s*'((?:[^'\\]|\\.)*)':", re.M)
    zh = set(pat.findall(src[zh_start:en_start]))
    en = set(pat.findall(src[en_start:]))
    return zh, en


def main() -> None:
    zh, en = load_tables()
    show_all = "--all" in sys.argv

    missing_en = {}
    missing_zh = {}
    total = 0
    for base, _dirs, files in os.walk(os.path.join(ROOT, "lib")):
        for name in files:
            if not name.endswith(".dart"):
                continue
            path = os.path.join(base, name)
            text = io.open(path, encoding="utf-8").read()
            for m in CALL.finditer(text):
                key = m.group(1)
                total += 1
                rel = os.path.relpath(path, ROOT)
                line = text.count("\n", 0, m.start()) + 1
                if key not in en:
                    missing_en.setdefault(key, []).append("%s:%d" % (rel, line))
                if key not in zh:
                    missing_zh.setdefault(key, []).append("%s:%d" % (rel, line))

    print("调用点: %d 处，enStrings 词条: %d 条" % (total, len(en)))
    print("英文表缺失 key: %d" % len(missing_en))
    for key in sorted(missing_en):
        sites = missing_en[key]
        print("  ✗ %s  (%d 处)  %s" % (key, len(sites), ", ".join(sites[:4])))
    if show_all:
        print("中文表缺失 key: %d" % len(missing_zh))
        for key in sorted(missing_zh):
            print("  ✗ %s  %s" % (key, ", ".join(missing_zh[key][:4])))

    sys.exit(1 if missing_en else 0)


if __name__ == "__main__":
    main()
