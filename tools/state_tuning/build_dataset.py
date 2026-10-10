# -*- coding: utf-8 -*-
"""把 NovelCraft 工艺对齐数据集切成 state tuning 可直接消费的训练 JSONL。

为什么需要这个脚本
------------------
远端 api-7b.rwkvos.com 部署的是 rwkv_lightning_cuda（albatross 引擎），它自带的
`rwkv_state_tune` 二进制只训练 `blocks.N.att.time_state`（冻结其余全部权重），
输入是每行 `{"text": "..."}` 的 JSONL，且**样本会在 `--ctx` 处被直接截断**。

数据集 v2.3 的 `ft_raw_text.jsonl` 已经是 `{"text": ...}` 格式，但样本长度分布为
min 2005 / p50 5044 / p90 6413 字符（约 1250~4000 token）。若沿用官方示例的
`--ctx 512`，**八成以上的内容会被丢掉**。本脚本按**段落边界**把每条样本贪心打包成
不超过目标 token 的块，既压住显存又基本不丢内容。

分工依据
--------
`docs/RWKV-G1K-双模型写作工艺.md` 第 11 行：
  MainAgent 7.2B —— 主线 / 分卷 / 章节大纲 + 逐段润色
  SubAgent  2.9B —— 正文续写
据此把 15 个工艺分卷分成两组（另有规划 JSON、验收 JSON、设定抽取、体系设计归 7.2B）。

格式对齐（关键）
----------------
`--format chat`（默认）把样本拼成工程 state 链路实际使用的格式：

    User: <prompt>\\n\\nAssistant: <completion>

推理时服务端按同一模板拼 prompt（见 `lib/ai/rwkv/rwkv_cloud_state.dart` 的
`buildPrompt`）。若训练文本缺少角色标记，state 学到的上下文位置与推理时错位，
实测表现为输出崩坏 —— 远端已存在的 v13a/v13b 系列 state 就是该症状。
需要退回纯文本拼接时用 `--format raw`。

用法
----
    python tools/state_tuning/build_dataset.py                 # 用默认路径与默认 ctx
    python tools/state_tuning/build_dataset.py --dry-run       # 只统计不写文件
    python tools/state_tuning/build_dataset.py --ctx-main 1024 --ctx-writer 2048
"""
from __future__ import annotations

import argparse
import json
import os
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SRC = os.path.join(
    os.path.dirname(os.path.dirname(PROJ)),
    "定向微调数据集", "NovelCraft对齐微调数据集v2.3",
)

# 双模型分工：key = 产物名前缀，value = 该模型负责的工艺分卷。
GROUPS: dict[str, list[str]] = {
    "main72b": [
        "vol01_main_outline",     # Book/mainOutline       规划组长
        "vol02_volume_outline",   # Book/volumeOutline
        "vol03_chapter_outline",  # Book/chapterOutline
        "vol08_plan_json",        # MultiAgent/planJson
        "vol09_acceptance_json",  # MultiAgent/acceptanceJson
        "vol10_state_extract",    # State/extract          设定档案管理员
        "vol11_polish",           # Polish/polish          主编逐段润色
        "vol15_cultivation",      # World/cultivation      力量体系设计
    ],
    "writer29b": [
        "vol04_solo_chapter",     # Book/soloChapter + leadWriterSystem
        "vol05_serial_segment",   # Book/serialSegment
        "vol06_beam_candidate",   # Book/beamCandidate
        "vol07_writer_team",      # Book/writerSystem + writer
        "vol12_repair",           # Repair/repair          纠偏
        "vol13_continue",         # Continue/continue      续写
        "vol14_rwkv_instruction", # RWKV/instruction        指令遵循
    ],
}


def read_samples(path: str) -> list[tuple[str, str]]:
    """读一个分卷 JSONL，返回 [(prompt, completion)]（兼容只有 {text} 的结构）。"""
    out: list[tuple[str, str]] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                print("  [跳过] %s:%d 解析失败: %s" % (os.path.basename(path), lineno, exc))
                continue
            if isinstance(obj.get("text"), str):
                out.append(("", obj["text"]))
            else:
                out.append((obj.get("prompt") or "", obj.get("completion") or ""))
    return [(p, c) for p, c in out if (p.strip() or c.strip())]


def render(prompt: str, completion: str, fmt: str) -> str:
    """按目标格式把一条样本拼成训练文本。

    `chat` 与工程实际使用的 state 链路格式保持一致
    （`lib/ai/rwkv/rwkv_cloud_state.dart` 的 `buildPrompt`）：
        User: <prompt>\\n\\nAssistant: <completion>
    `raw` 则是 prompt 直接接 completion（等同数据集的 ft_raw_text.jsonl）。

    为什么要对齐格式：state tuning 优化的是**初始 state 先验**，
    推理时服务端按经典 `User:`/`Assistant:` 模板拼 prompt。若训练文本没有
    同样的角色标记，state 学到的上下文位置与推理时错位，实测表现为输出崩坏
    （远端已有的 v13a/v13b 系列 state 就是这个症状）。
    """
    p = prompt.strip()
    c = completion.strip()
    if fmt == "raw":
        return (p + c) if p else c
    if p and c:
        return "User: %s\n\nAssistant: %s" % (p, c)
    if c:
        return "Assistant: %s" % c
    return "User: %s\n\nAssistant:" % p


def split_by_paragraph(text: str, max_tokens: int, chars_per_token: float) -> list[str]:
    """按段落边界把长文本切成若干块，尽量让每块不超过 max_tokens。

    贪心累积：能装下就继续装，装不下就收口。单个段落本身超预算时按字符硬切
    （宁可切碎一段，也不整段丢弃）。
    """
    budget_chars = max(64, int(max_tokens * chars_per_token))
    chunks: list[str] = []
    buf = ""

    for para in text.split("\n"):
        piece = para if not buf else "\n" + para
        if len(buf) + len(piece) <= budget_chars:
            buf += piece
            continue
        if buf:
            chunks.append(buf)
            buf = ""
        if len(para) <= budget_chars:
            buf = para
            continue
        # 单段超预算 → 硬切
        for i in range(0, len(para), budget_chars):
            part = para[i:i + budget_chars]
            if len(part) == budget_chars:
                chunks.append(part)
            else:
                buf = part
    if buf:
        chunks.append(buf)
    return [c for c in chunks if c.strip()]


def build_group(group: str, vols: list[str], src: str, ctx_tokens: int,
                chars_per_token: float, reserve: float,
                fmt: str) -> tuple[list[str], dict]:
    """生成一个模型的全部训练块 + 统计。"""
    effective = max(64, int(ctx_tokens * reserve))
    chunks: list[str] = []
    per_vol: dict[str, int] = {}
    raw_chars = 0

    print("\n== %s (ctx=%d, 有效预算≈%d token ≈ %d 字符, 格式=%s) ==" % (
        group, ctx_tokens, effective, int(effective * chars_per_token), fmt))
    for vol in vols:
        path = os.path.join(src, vol + ".jsonl")
        if not os.path.isfile(path):
            print("  [缺失] %s" % path)
            continue
        samples = read_samples(path)
        raw_chars += sum(len(p) + len(c) for p, c in samples)
        vol_chunks: list[str] = []
        for prompt, completion in samples:
            text = render(prompt, completion, fmt)
            vol_chunks.extend(split_by_paragraph(text, effective, chars_per_token))
        chunks.extend(vol_chunks)
        per_vol[vol] = len(vol_chunks)
        print("  %-26s 样本 %5d → 块 %5d" % (vol, len(samples), len(vol_chunks)))

    lens = sorted(len(c) for c in chunks) or [0]
    est_tokens = [int(len(c) / chars_per_token) for c in chunks] or [0]
    stats = {
        "group": group,
        "ctx_tokens": ctx_tokens,
        "effective_tokens": effective,
        "chars_per_token": chars_per_token,
        "format": fmt,
        "sources": vols,
        "chunks": len(chunks),
        "chunks_per_vol": per_vol,
        "raw_chars": raw_chars,
        "chunk_chars_min": lens[0],
        "chunk_chars_p50": lens[len(lens) // 2],
        "chunk_chars_max": lens[-1],
        "est_tokens_total": sum(est_tokens),
        "est_tokens_p50": sorted(est_tokens)[len(est_tokens) // 2],
        "est_tokens_max": max(est_tokens),
    }
    return chunks, stats


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=DEFAULT_SRC, help="微调数据集目录（v2.3）")
    ap.add_argument("--out", default=os.path.join(PROJ, "build", "state_tuning"),
                    help="输出目录（默认在工程 build/ 下，不进源码包）")
    ap.add_argument("--ctx-main", type=int, default=1024,
                    help="7.2B 的 --ctx（显存更紧，默认 1024）")
    ap.add_argument("--ctx-writer", type=int, default=2048,
                    help="2.9B 的 --ctx（默认 2048）")
    ap.add_argument("--chars-per-token", type=float, default=1.6,
                    help="token 估算系数（中文 RWKV 约 1.5~1.8）")
    ap.add_argument("--reserve", type=float, default=0.95,
                    help="留给特殊 token 的余量系数")
    ap.add_argument("--format", default="chat", choices=("chat", "raw"),
                    help="chat（默认）按 User:/Assistant: 模板拼接，与推理端 state 链路一致；"
                         "raw 则 prompt 直接接 completion")
    ap.add_argument("--dry-run", action="store_true", help="只统计，不写文件")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    if not os.path.isdir(src):
        print("[错误] 数据集目录不存在: %s" % src)
        return 1

    ctx_of = {"main72b": args.ctx_main, "writer29b": args.ctx_writer}
    manifest = {
        "source_dir": src,
        "chars_per_token": args.chars_per_token,
        "reserve": args.reserve,
        "format": args.format,
        "groups": {},
    }

    if not args.dry_run:
        os.makedirs(args.out, exist_ok=True)

    for group, vols in GROUPS.items():
        chunks, stats = build_group(group, vols, src, ctx_of[group],
                                    args.chars_per_token, args.reserve, args.format)
        manifest["groups"][group] = stats
        if not args.dry_run:
            dst = os.path.join(args.out, group + ".jsonl")
            with open(dst, "w", encoding="utf-8", newline="\n") as fh:
                for c in chunks:
                    fh.write(json.dumps({"text": c}, ensure_ascii=False) + "\n")
            size = os.path.getsize(dst)
            print("  -> %s  (%d 行, %.1f MB)" % (dst, len(chunks), size / 1048576))
            stats["output_file"] = dst
            stats["output_bytes"] = size

    print("\n===== 汇总 =====")
    total = 0
    for group, st in manifest["groups"].items():
        total += st["chunks"]
        print("  %-10s 块 %5d  ≈%8d token  单块 p50 %d / max %d token" % (
            group, st["chunks"], st["est_tokens_total"],
            st["est_tokens_p50"], st["est_tokens_max"]))
    print("  合计块数: %d" % total)

    if not args.dry_run:
        mpath = os.path.join(args.out, "manifest.json")
        with open(mpath, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=1)
        print("  manifest: %s" % mpath)
    return 0


if __name__ == "__main__":
    sys.exit(main())
