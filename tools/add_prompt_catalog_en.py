#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""给 writing_prompt_catalog.dart 的每个 WritingPromptStage 补上
`titleEn` / `variablesEn`（英文界面用）。

做法：按括号配平扫出每个 `WritingPromptStage( ... ),` 块，插入两个新字段，
其余文本（含 defaultBody 的 raw string）原样保留 —— 幂等，可重复执行。
"""
import io
import os
import re

SRC = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lib", "application", "services", "writing_prompt_catalog.dart",
)

TITLE_EN = {
    "Review/reviewerSystem": "7B Reviewer Role & Output Format",
    "Review/reviewer": "7B Chapter Content Review",
    "Review/seniorSystem": "13B Chief Reviewer Role & Output Format",
    "Review/senior": "13B Re-review & Improvement Advice",
    "Review/writerSystem": "Post-review Rewrite · Writer Role",
    "Review/writer": "Post-review Text Improvement",
    "Review/guestSystem": "Guest Reader Role",
    "Review/guest": "Guest Reader Commentary",
    "State/system": "State Ledger Update · Archivist",
    "State/extract": "State Ledger Extraction & Format Correction",
    "Book/planningLeader": "Outline Chief Editor Role",
    "Book/planningWriter": "Outline Planner Role",
    "Book/polishSystem": "Continue-pick · Chief Editor Polish Role",
    "Book/polish": "Continue-pick · Passage Polish",
    "Book/repairSystem": "Text Pollution Repair Role",
    "Book/repair": "Text Pollution Repair Writing",
    "Book/mainOutline": "Main Outline",
    "Book/volumeOutline": "Volume Outline",
    "Book/chapterOutline": "Chapter Outline",
    "Book/leaderSystem": "Team Lead Role",
    "Book/writerSystem": "Biased Writer Role",
    "Book/leadWriterSystem": "Lead Writer Role",
    "Book/soloChapter": "Single-pass Chapter",
    "Book/serialSegment": "Serial Segments",
    "Book/beamCandidate": "Continue-pick Candidate",
    "Book/plan": "Team Assignment",
    "Book/writer": "Team Segmented Writing",
    "Book/acceptance": "Team Acceptance & Update Extraction",
    "Book/rework": "Writer Rework",
    "Book/leaderRewrite": "Team Lead Rewrite",
    "Book/assembly": "Chapter Assembly & Polish",
}

VAR_EN = {
    "章节标题": "Chapter title",
    "大纲": "Outline",
    "待审查正文": "Text under review",
    "客座读者意见": "Guest reader comments",
    "待复核正文": "Text under re-review",
    "已有评论": "Existing comments",
    "章节大纲": "Chapter outline",
    "审查意见": "Review comments",
    "待改进正文": "Text to improve",
    "读者称呼": "Reader name",
    "该读者的品味配置": "This reader's taste profile",
    "章节正文": "Chapter text",
    "模块输入输出模板（必须保留）": "Module I/O schema (must be kept)",
    "已有实体名称": "Existing entity names",
    "正文分片": "Text chunk",
    "格式失败时的重试要求": "Retry requirement after a format failure",
    "规划写手编号": "Planner slot number",
    "待润色的正文片段": "Passage to polish",
    "本章大纲": "This chapter's outline",
    "已修复的前文摘要": "Summary of the repaired preceding text",
    "书名": "Book title",
    "作者": "Author",
    "目标卷数": "Target volume count",
    "每卷章数": "Chapters per volume",
    "主线大纲": "Main outline",
    "卷号或段号": "Volume or segment number",
    "本卷大纲（含缺省说明）": "This volume's outline (with fallback note)",
    "章节序号": "Chapter index",
    "所有写手的偏向说明": "Bias descriptions of all writers",
    "写手编号": "Writer slot number",
    "写手偏向名称": "Writer bias name",
    "写手偏向要求": "Writer bias requirement",
    "主线大纲摘要": "Main outline summary",
    "本卷大纲": "This volume's outline",
    "本章大纲（含缺省说明）": "This chapter's outline (with fallback note)",
    "目标字数": "Target word count",
    "上文结尾与续写衔接要求": "Preceding ending & continuation bridging requirement",
    "上一段过短时的补足要求": "Top-up requirement when the last segment was too short",
    "本卷背景": "This volume's background",
    "候选叙事侧重": "Candidate narrative focus",
    "写手总数": "Total writer count",
    "章节目标字数": "Target chapter word count",
    "段落编号": "Segment number",
    "总段数": "Total segment count",
    "段落标题": "Segment title",
    "段落任务": "Segment task",
    "段落边界": "Segment boundary",
    "段落目标字数": "Segment target word count",
    "待验收的段落正文": "Submitted segment text",
    "验收问题": "Acceptance issues",
    "上一稿参考片段": "Reference passage from the previous draft",
    "段落数量": "Segment count",
    "已验收的全部段落": "All accepted segments",
}


def dart_str(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("$", r"\$") + "'"


def find_blocks(text):
    """返回 [(start, end_exclusive)]，覆盖每个 WritingPromptStage( ... ),"""
    out = []
    needle = "WritingPromptStage("
    i = 0
    while True:
        start = text.find(needle, i)
        if start < 0:
            break
        j = start + len(needle)
        depth = 1
        while j < len(text) and depth:
            ch = text[j]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            j += 1
        # j 停在配平后的下一个字符
        end = j
        out.append((start, end))
        i = end
    return out


def process(text):
    blocks = find_blocks(text)
    # 逆序改，避免位移
    for start, end in reversed(blocks):
        block = text[start:end]
        if "titleEn:" in block:
            continue
        m_id = re.search(r"id:\s*'([^']*)'", block)
        if not m_id:
            continue
        sid = m_id.group(1)
        m_title = re.search(r"^(\s*)title:\s*'([^']*)',\s*$", block, re.M)
        if not m_title:
            continue
        indent = m_title.group(1)
        zh_title = m_title.group(2)
        en_title = TITLE_EN.get(sid)
        if not en_title:
            raise SystemExit("缺少英文标题：%s（%s）" % (sid, zh_title))

        new_block = block
        # 1) title 之后插入 titleEn
        title_line = m_title.group(0)
        new_block = new_block.replace(
            title_line,
            title_line + "\n" + indent + "titleEn: %s," % dart_str(en_title),
            1,
        )

        # 2) variables 块之后插入 variablesEn
        m_var = re.search(r"^(\s*)variables:\s*\{(.*?)\},\s*$", new_block,
                          re.M | re.S)
        if m_var and m_var.group(2).strip():
            entries = re.findall(r"'([^']*)':\s*'([^']*)'", m_var.group(2))
            indent = m_var.group(1)
            lines = ["%svariablesEn: {" % indent]
            for k, v in entries:
                en = VAR_EN.get(v)
                if not en:
                    raise SystemExit("缺少变量说明英文：%s（阶段 %s）" % (v, sid))
                lines.append("%s  %s: %s," % (indent, dart_str(k), dart_str(en)))
            lines.append("%s}," % indent)
            new_block = new_block.replace(
                m_var.group(0),
                m_var.group(0) + "\n" + "\n".join(lines),
                1,
            )
        text = text[:start] + new_block + text[end:]
    return text


def main():
    with io.open(SRC, encoding="utf-8") as f:
        text = f.read()
    out = process(text)
    if out == text:
        print("无需改动（已有英文标题）")
        return
    with io.open(SRC, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("已写入: %s" % SRC)


if __name__ == "__main__":
    main()
