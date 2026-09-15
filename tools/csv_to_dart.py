#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 C# 版的 language-table.csv 转换成 Dart 本地化常量表。

源格式：key,zh,en（首行表头，可能带 UTF-8 BOM）
产出：lib/l10n/strings.g.dart —— 两个 Map<String, String> 常量
"""
import csv
import io
import os

SRC = r"F:\30_Novelcraft_Flutter\C#版源代码\src\NovelManagement.WPF\Localization\language-table.csv"
OUT_DIR = r"F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft\lib\l10n"
OUT = os.path.join(OUT_DIR, "strings.g.dart")


def dart_escape(s: str) -> str:
    """转义为 Dart 单引号字符串字面量内容。"""
    if s is None:
        return ""
    s = s.replace("\\", "\\\\")
    s = s.replace("'", "\\'")
    s = s.replace("$", r"\$")
    s = s.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n")
    s = s.replace("\t", "\\t")
    return s


def main() -> None:
    rows = []
    with io.open(SRC, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            key = (r.get("key") or "").strip()
            if not key:
                continue
            zh = (r.get("zh") or "").strip()
            en = (r.get("en") or "").strip()
            rows.append((key, zh, en))

    seen = set()
    dedup = []
    for key, zh, en in rows:
        if key in seen:
            continue
        seen.add(key)
        dedup.append((key, zh, en))

    buf = io.StringIO()
    buf.write(
        "/// 由 tools/csv_to_dart.py 从 C# 版 language-table.csv 自动生成，**请勿手改**\n"
        "///\n"
        "/// 源表共 %d 条词条（去重后 %d 条），中英双语。\n"
        "/// C# 侧由 Localization/Strings*.cs 的静态字典 + LanguageTableStore 加载 CSV 提供，\n"
        "/// Dart 侧改为编译期常量，避免运行时解析开销。\n"
        "library;\n\n" % (len(rows), len(dedup))
    )

    for name, idx in (("zhStrings", 1), ("enStrings", 2)):
        lang_label = "中文（简体）" if name == "zhStrings" else "English"
        buf.write("/// %s 词条表\n" % lang_label)
        buf.write("const Map<String, String> %s = <String, String>{\n" % name)
        for key, zh, en in dedup:
            value = zh if idx == 1 else en
            buf.write("  '%s': '%s',\n" % (dart_escape(key), dart_escape(value)))
        buf.write("};\n\n")

    os.makedirs(OUT_DIR, exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(buf.getvalue())

    print("写入: %s" % OUT)
    print("词条数: %d (去重后 %d)" % (len(rows), len(dedup)))
    print("文件大小: %.1f KB" % (os.path.getsize(OUT) / 1024.0))


if __name__ == "__main__":
    main()
