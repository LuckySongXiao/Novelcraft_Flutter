# -*- coding: utf-8 -*-
"""把当前工程树刷新到发布源码快照目录。

用法（在工程根目录执行）：

    python tools/sync_release_snapshot.py                 # 刷新干净快照
    python tools/sync_release_snapshot.py --working       # 同时刷新历史工作副本
    python tools/sync_release_snapshot.py --dry-run

规则
----
1. 快照里**已存在**的文件，内容不同就从工程覆盖过去（工程是唯一事实来源）。
2. 快照里**独有**的文件（如 `备份说明-v1.0.0+35.md`、`version.txt`）原样保留，
   这类文件是在快照里手工维护的，不属于工程树。
3. 软链接跳过（`linux/flutter/ephemeral/.plugin_symlinks/*` 指向 pub 缓存）。
4. 额外纳入 `docs/images/`（README 流程配图 + 界面截图 + 截图工具），
   使解压后的 README 配图可解析；工程里的构建产物（build/、.dart_tool/、
   rwkv_models/ 等）不会进入干净快照，因为快照中本来就没有这些条目。
"""
from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 本仓库布局：<发布根>\Flutter版代码\novelcraft\，因此发布根 = 工程目录的上两级。
RELEASE_ROOT = os.path.dirname(os.path.dirname(PROJ))

CLEAN_SNAPSHOT = os.path.join(RELEASE_ROOT, "Novelcraft_Flutter_source_v1.0.0+35")
WORKING_SNAPSHOT = os.path.join(RELEASE_ROOT, "Novelcraft_Flutter_source")

# 干净快照里额外补入的文档资源（快照原本只收 docs/*.md 与 docs/rwkv_lightning_api/）
EXTRA_ASSETS = [
    "docs/images/generate_readme_images.py",
    "docs/images/novelcraft-overview-en.png",
    "docs/images/novelcraft-overview.png",
    "docs/images/writing-workflow-en.png",
    "docs/images/writing-workflow.png",
    "docs/images/tools/capture_screenshots.ps1",
    "docs/images/tools/seed_demo_data.py",
]


def rel_files(root: str) -> list[str]:
    out = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            out.append(os.path.relpath(full, root).replace("\\", "/"))
    return out


def sync(snapshot: str, with_assets: bool, dry_run: bool) -> None:
    if not os.path.isdir(snapshot):
        print("跳过（目录不存在）:", snapshot)
        return

    updated: list[str] = []
    errors: list[str] = []
    kept: list[str] = []
    unchanged = 0

    for rel in sorted(rel_files(snapshot)):
        src = os.path.join(PROJ, rel)
        dst = os.path.join(snapshot, rel)
        if os.path.islink(dst):
            continue
        if not os.path.exists(src):
            kept.append(rel)
            continue
        try:
            if os.path.getsize(src) == os.path.getsize(dst) and filecmp.cmp(
                src, dst, shallow=False
            ):
                unchanged += 1
                continue
            if not dry_run:
                shutil.copy2(src, dst)
            updated.append(rel)
        except OSError as exc:
            errors.append("%s : %s" % (rel, exc))

    added: list[str] = []
    if with_assets:
        for rel in EXTRA_ASSETS:
            src = os.path.join(PROJ, rel)
            dst = os.path.join(snapshot, rel)
            if not os.path.exists(src):
                errors.append("缺少资源: " + rel)
                continue
            if os.path.exists(dst) and filecmp.cmp(src, dst, shallow=False):
                continue
            if not dry_run:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
            added.append(rel)

    print("快照:", snapshot)
    print("  未变 %d  更新 %d  新增 %d  快照独有(保留) %d  失败 %d"
          % (unchanged, len(updated), len(added), len(kept), len(errors)))
    for x in updated:
        print("    UPD ", x)
    for x in added:
        print("    ADD ", x)
    for x in kept:
        print("    KEEP", x)
    for x in errors:
        print("    ERR ", x)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--working", action="store_true",
                    help="同时刷新历史工作副本 Novelcraft_Flutter_source")
    ap.add_argument("--dry-run", action="store_true", help="只报告不写入")
    args = ap.parse_args()

    sync(CLEAN_SNAPSHOT, with_assets=True, dry_run=args.dry_run)
    if args.working:
        print()
        sync(WORKING_SNAPSHOT, with_assets=False, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
