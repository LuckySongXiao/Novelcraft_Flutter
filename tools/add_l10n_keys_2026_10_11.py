#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-11 批次（v1.0.0+46）：复读守卫拦截提示词条追加到
lib/l10n/strings.g.dart 的 zhStrings / enStrings 两张表末尾。

沿用 add_l10n_keys_2026_10_10.py 的机制（幂等、zh/en 一一对应）。
"""
import io
import os

SRC = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lib", "l10n", "strings.g.dart",
)

ENTRIES = [
    # ---- 复读守卫拦截提示（CRW.*）----
    ("CRW.OutlineRepeatBlocked",
     "大纲调整失败：模型输出疑似整段复读，已被防污染策略拦截。"
     "本章大纲与正文均未修改，可稍后重试；若反复出现，"
     "建议在「额外要求」里写明本章具体要推进的剧情。",
     "Outline repair failed: the model output looked like degenerate repetition and was blocked by the "
     "anti-contamination guard. Neither the outline nor the body text was changed. Please retry; if it keeps "
     "happening, describe the specific plot this chapter should advance under Extra requirements."),
]


def esc(s: str) -> str:
    return (s.replace("\\", "\\\\").replace("'", "\\'").replace("$", r"\$")
            .replace("\n", "\\n"))


def main() -> None:
    with io.open(SRC, encoding="utf-8") as f:
        text = f.read()

    zh_start = text.index("const Map<String, String> zhStrings")
    en_start = text.index("const Map<String, String> enStrings")
    blocks = {
        "zh": text[zh_start:en_start],
        "en": text[en_start:],
    }

    added_zh = []
    added_en = []
    for key, zh, en in ENTRIES:
        if "'%s':" % key in blocks["zh"]:
            continue
        added_zh.append("  '%s': '%s'," % (esc(key), esc(zh)))
        added_en.append("  '%s': '%s'," % (esc(key), esc(en)))

    if not added_zh:
        print("无新增词条（全部已存在）")
        return

    def append_before_close(block: str, lines) -> str:
        idx = block.rindex("};")
        return block[:idx] + "\n".join(lines) + "\n" + block[idx:]

    blocks["zh"] = append_before_close(blocks["zh"], added_zh)
    blocks["en"] = append_before_close(blocks["en"], added_en)

    out = (text[:zh_start] + blocks["zh"] + blocks["en"])
    with io.open(SRC, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("新增 %d 条词条 → %s" % (len(added_zh), SRC))


if __name__ == "__main__":
    main()
