# -*- coding: utf-8 -*-
"""把当前工程树刷新到发布源码快照目录。

用法（在工程根目录执行）：

    python tools/sync_release_snapshot.py                 # 刷新干净快照
    python tools/sync_release_snapshot.py --working       # 同时刷新历史工作副本
    python tools/sync_release_snapshot.py --dry-run

规则
----
1. 快照里**已存在**的文件，内容不同就从工程覆盖过去（工程是唯一事实来源）。
2. 快照里**独有**的文件（如 `备份说明-v1.0.0+36.md`、`version.txt`）原样保留，
   这类文件是在快照里手工维护的，不属于工程树。
3. 软链接跳过（`linux/flutter/ephemeral/.plugin_symlinks/*` 指向 pub 缓存）。
4. 额外纳入 `docs/images/`（README 流程配图 + 界面截图 + 截图工具），
   使解压后的 README 配图可解析；工程里的构建产物（build/、.dart_tool/、
   rwkv_models/ 等）不会进入干净快照，因为快照中本来就没有这些条目。
5. `lib/ test/ tools/ assets/ docs/ scripts/ integration_test/` 下**工程新增**的
   手写文件会自动补进快照（见 NEW_SOURCE_DIRS）；平台目录（android/ ios/ windows/…）
   只更新已有条目、绝不新增，避免把签名密钥与本地生成物带进对外源码包。
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

DEFAULT_VERSION = "1.0.0+46"

WORKING_SNAPSHOT = os.path.join(RELEASE_ROOT, "Novelcraft_Flutter_source")


def find_clean_snapshot(release_root: str, version: str) -> str:
    """定位干净源码快照目录。

    历史上这个目录改过名（`Novelcraft_Flutter_source_v<版本>` →
    `novelcraft_<版本>_source`），而发布清单里还留着旧名，曾导致
    `sync` 静默跳过、`package_release.py` 拿不到源码目录而中断。
    这里按优先级探测，避免再次断链。
    """
    candidates = [
        os.path.join(release_root, "novelcraft_%s_source" % version),
        os.path.join(release_root, "Novelcraft_Flutter_source_v%s" % version),
    ]
    for path in candidates:
        if os.path.isdir(path):
            return path
    return candidates[0]


CLEAN_SNAPSHOT = find_clean_snapshot(RELEASE_ROOT, DEFAULT_VERSION)

# 允许「工程新增文件」补进快照的目录（都是纯手写源码/文档，纳入是安全的）。
# 其它目录（android/ ios/ windows/ 等平台目录）只更新已有条目、绝不新增，
# 以免把签名密钥（upload-keystore.jks）、local.properties、GeneratedPluginRegistrant
# 之类的本地/生成产物带进对外源码包。
NEW_SOURCE_DIRS = (
    "lib/", "test/", "tools/", "assets/", "docs/", "scripts/", "integration_test/",
)
NEW_SOURCE_EXCLUDE_SEGMENTS = ("__pycache__/", "/__pycache__", ".dart_tool/")
NEW_SOURCE_EXCLUDE_EXT = (".pyc", ".pyo", ".log", ".tmp", ".orig", ".bak", ".out")


def _is_handwritten_source(rel: str) -> bool:
    """判断工程内相对路径是否属于「应当纳入源码包的手写内容」。"""
    if not rel.startswith(NEW_SOURCE_DIRS):
        return False
    if any(seg in rel for seg in NEW_SOURCE_EXCLUDE_SEGMENTS):
        return False
    if rel.endswith(NEW_SOURCE_EXCLUDE_EXT):
        return False
    if os.path.basename(rel).startswith("."):
        return False
    return True

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


def sync(snapshot: str, with_assets: bool, dry_run: bool, add_new: bool = True) -> None:
    if not os.path.isdir(snapshot):
        print("跳过（目录不存在）:", snapshot)
        return

    updated: list[str] = []
    errors: list[str] = []
    kept: list[str] = []
    unchanged = 0

    existing = sorted(rel_files(snapshot))
    existing_set = set(existing)

    for rel in existing:
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

    # 补入工程新增的手写源码/文档（快照里还没有的条目）。
    # 历史缺陷：以前只遍历快照已有条目，导致新建的模块（如
    # lib/ai/rwkv/rwkv_cloud_state.dart）永远进不了对外源码包。
    if add_new:
        for base in NEW_SOURCE_DIRS:
            base_root = os.path.join(PROJ, base.rstrip("/"))
            if not os.path.isdir(base_root):
                continue
            for sub in sorted(rel_files(base_root)):
                rel = base + sub
                if rel in existing_set:
                    continue
                if not _is_handwritten_source(rel):
                    continue
                src = os.path.join(PROJ, rel)
                dst = os.path.join(snapshot, rel)
                if os.path.islink(dst):
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
    ap.add_argument("--no-add-new", action="store_true",
                    help="不把工程新增的手写文件补进快照（只更新已有条目）")
    args = ap.parse_args()

    add_new = not args.no_add_new
    sync(CLEAN_SNAPSHOT, with_assets=True, dry_run=args.dry_run, add_new=add_new)
    if args.working:
        print()
        sync(WORKING_SNAPSHOT, with_assets=False, dry_run=args.dry_run,
             add_new=add_new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
