#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-10 批次：把「先调大纲再重写 / 矩阵统计与回看」新增词条追加到
lib/l10n/strings.g.dart 的 zhStrings / enStrings 两张表末尾。

沿用 add_l10n_keys_2026_10_04.py 的机制（幂等、zh/en 一一对应）。
"""
import io
import os

SRC = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lib", "l10n", "strings.g.dart",
)

ENTRIES = [
    # ---- 单章重写：先调大纲再重写（CRW.*）----
    ("CRW.PhaseOutline", "正在按前后章节调整本章大纲…",
     "Adjusting this chapter's outline from its neighbours…"),
    ("CRW.RepairAllDrafts", "智能修复全部草稿章",
     "Smart-repair all draft chapters"),
    ("CRW.OutlineRepairFailed",
     "大纲调整失败：模型没有给出可用的大纲内容。本章大纲与正文均未修改，"
     "可先在章节编辑页手工补一段大纲，或在「额外要求」里说明这一章要写什么。",
     "Outline repair failed: the model produced no usable outline. Neither the outline nor the body text was "
     "changed. You can write an outline manually in the chapter editor, or describe what this chapter should "
     "cover under Extra requirements."),
    ("CRW.OutlinePersistFailed", "大纲调整完成，但回写章节失败：{0}",
     "Outline repaired, but saving the chapter failed: {0}"),
    ("CRW.OutlineRepairedFmt", "已按前后章节调整《{0}》的大纲{1}。",
     "Adjusted the outline of \"{0}\" based on the surrounding chapters{1}."),
    ("CRW.OutlineTimeFmt", "（故事时间：{0}）", " (story time: {0})"),

    # ---- 写作动态矩阵：统计行与结束后回看（MAG.*）----
    ("MAG.Phase.OutlineRepair", "调纲重写", "Outline + rewrite"),
    ("MAG.Matrix.CloseDone", "关闭", "Close"),
    ("MAG.Stats.TotalFmt", "共 {0} 章", "{0} chapters"),
    ("MAG.Stats.DoneFmt", "已定稿 {0}", "{0} finalised"),
    ("MAG.Stats.FailedFmt", "草稿/失败 {0}", "{0} drafts/failed"),
    ("MAG.Stats.PendingFmt", "待写 {0}", "{0} pending"),
    ("MAG.Stats.NgRateFmt", "NG 率 {0}", "NG rate {0}"),
    ("MAG.ResultShort", "写作结果", "Writing result"),
    ("MAG.ResultShortNgFmt", "写作结果 · NG {0} 章", "Result · {0} NG chapters"),

    # ---- 项目概览：上次写作回看入口（PO.*）----
    ("PO.LastRunNgFmt", "上次写作：{0} 章里 {1} 章 NG（NG 率 {2}）",
     "Last run: {1} of {0} chapters NG (rate {2})"),
    ("PO.LastRunOkFmt", "上次写作：{0} 章全部定稿",
     "Last run: all {0} chapters finalised"),
    ("PO.LastRunOpen", "查看本次写作详情", "View run details"),

    # ---- 第二批：规划-续写-润色管线（CRW.*）----
    ("CRW.PhasePlan", "正在规划续写切片与目标字数…",
     "Planning continuation slices and word targets…"),
    ("CRW.PhaseWrite", "正在按规划逐片续写正文…",
     "Writing the prose slice by slice…"),
    ("CRW.PhasePolish", "主模型正在逐段审查润色…",
     "Reviewing and polishing paragraph by paragraph…"),
    ("CRW.PhaseProgress", "正在刷新项目进度…", "Refreshing project progress…"),
    ("CRW.WriteFailed",
     "重写失败：续写片没有产出内容，原稿未修改。请检查「AI 配置」里的模型服务后重试。",
     "Rewrite failed: a continuation slice produced no content; the original text was not changed. "
     "Check the model service in AI configuration and retry."),
    ("CRW.TopUpGoal", "补足篇幅：把当前场景写透，不要仓促收尾",
     "Fill out the length: develop the current scene fully; do not wrap up hastily."),
    ("CRW.PlanShortFailed",
     "重写未达标（{0}）：续写后正文 {1} 字，原稿未修改。可重试一次，或先补全本章大纲再重写。",
     "Rewrite did not meet the gate ({0}): {1} characters after continuation; the original text was "
     "not changed. Retry once, or complete the outline first."),
    ("CRW.NoSliceNeeded", "底座已达标，直接进入逐段润色",
     "Existing prose already meets the gate; went straight to polishing"),
    ("CRW.PlanFmt", "已按规划分 {0} 片续写（共约 {1} 字）",
     "Continued in {0} planned slices (about {1} characters total)"),
    ("CRW.PolishDone", "全文已经主模型逐段审查润色",
     "the full text was reviewed and polished paragraph by paragraph by the main model"),
    ("CRW.PolishKept", "润色结果未达保留标准，沿用润色前正文",
     "polish output fell below the keep threshold; the pre-polish text was kept"),
    ("CRW.ProgressFmt", "（项目进度已刷新：{0}%）", " (project progress refreshed: {0}%)"),

    # ---- 第三批：选节 AI 采纳应用（RAI.*）----
    ("RAI.Apply", "采纳应用", "Apply"),
    ("RAI.ApplyTitle", "应用 AI 结果", "Apply AI result"),
    ("RAI.ApplyInsertFmt",
     "将把 AI 结果作为「下一段」插入到所选文本之后（原选中文本保留）。\n\n"
     "选中文本：{0} 字\nAI 结果：{1} 字",
     "The AI result will be inserted as the NEXT paragraph after the selection (the selection is "
     "kept).\n\nSelection: {0} chars\nResult: {1} chars"),
    ("RAI.ApplyReplaceFmt",
     "将用 AI 结果替换当前选中的文本段（原选中文本被覆盖，章节版本号 +1，"
     "可在版本历史中追溯）。\n\n选中文本：{0} 字\nAI 结果：{1} 字",
     "The AI result will REPLACE the selected text (chapter version +1; traceable in version "
     "history).\n\nSelection: {0} chars\nResult: {1} chars"),
    ("RAI.AppliedInsert", "已应用：续写内容已插入为所选文本的下一段",
     "Applied: the continuation was inserted as the next paragraph after the selection"),
    ("RAI.AppliedReplace", "已应用：所选文本已被 AI 结果替换",
     "Applied: the selection was replaced with the AI result"),
    ("RAI.ApplyFailedFmt", "应用失败，正文未修改：{0}", "Apply failed, content unchanged: {0}"),
    ("RAI.ApplyNoId",
     "本章尚未保存，无法写回正文；请先保存章节后再使用采纳应用",
     "This chapter is not saved yet; save it before using Apply"),
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
