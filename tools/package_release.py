# -*- coding: utf-8 -*-
"""重新打包 NovelCraft 发布件（Windows 便携版 / 源码 / APK）并打印大小与 SHA256。

用法（在工程根目录执行）：

    python tools/package_release.py                 # 打包 + 打印校验值
    python tools/package_release.py --version 1.0.0+35
    python tools/package_release.py --no-apk        # 跳过 APK（未构建时）

前置：先跑出构建产物
    flutter build windows --release
    flutter build apk --release

做的事情
--------
1. 把 `build/windows/x64/runner/Release/` 全量镜像到 `<发布根>/novelcraft_<版本>_windows_release/`
   （先清空目标目录，避免残留旧文件）。
2. 打包 `<发布根>/novelcraft_<版本>_windows_release.zip`（扁平结构，无顶层目录）。
3. 打包 `<发布根>/novelcraft_<版本>_source.zip`（来自干净源码快照目录）。
4. 复制 APK 到 `<发布根>/novelcraft_<版本>_release.apk`。
5. 打印三个文件的字节数与 SHA256，可直接贴进发布清单。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import zipfile

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 本仓库布局：<发布根>\Flutter版代码\novelcraft\，因此发布根 = 工程目录的上两级。
# 若工程被放到别处，用 --release-root 指定。
RELEASE_ROOT = os.path.dirname(os.path.dirname(PROJ))

WIN_RELEASE_SRC = os.path.join(
    PROJ, "build", "windows", "x64", "runner", "Release"
)
APK_SRC = os.path.join(
    PROJ, "build", "app", "outputs", "flutter-apk", "app-release.apk"
)


def sha256(path: str, block: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(block)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().upper()


def mirror(src: str, dst: str) -> None:
    """清空 dst 后全量复制 src（dst 必须先存在或可创建）。"""
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(dst):
        p = os.path.join(dst, name)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    for name in os.listdir(src):
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        shutil.copytree(s, d) if os.path.isdir(s) else shutil.copy2(s, d)
        print("    ", name)


def zip_dir(srcdir: str, zippath: str, level: int = 6) -> int:
    count = 0
    with zipfile.ZipFile(zippath, "w", zipfile.ZIP_DEFLATED, compresslevel=level) as z:
        for dirpath, _dirnames, filenames in os.walk(srcdir):
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, srcdir).replace("\\", "/")
                z.write(full, rel)
                count += 1
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version", default="1.0.0+35")
    ap.add_argument("--release-root", default=RELEASE_ROOT,
                    help="发布件所在根目录（默认工程目录的上两级）")
    ap.add_argument("--no-apk", action="store_true")
    ap.add_argument("--no-win", action="store_true")
    ap.add_argument("--no-source", action="store_true")
    args = ap.parse_args()

    release_root = os.path.abspath(args.release_root)
    v = args.version
    win_dir = os.path.join(release_root, "novelcraft_%s_windows_release" % v)
    win_zip = win_dir + ".zip"
    src_zip = os.path.join(release_root, "novelcraft_%s_source.zip" % v)
    apk_dst = os.path.join(release_root, "novelcraft_%s_release.apk" % v)
    source_snapshot = os.path.join(
        release_root, "Novelcraft_Flutter_source_v1.0.0+35"
    )

    produced: list[str] = []

    if not args.no_win:
        if not os.path.isdir(WIN_RELEASE_SRC):
            print("[错误] 缺少 Windows Release 构建产物：", WIN_RELEASE_SRC)
            return 1
        print("== 镜像 Windows 便携版 ==")
        mirror(WIN_RELEASE_SRC, win_dir)
        print("== 打包", os.path.basename(win_zip), "==")
        print("    entries:", zip_dir(win_dir, win_zip))
        produced.append(win_zip)

    if not args.no_source:
        if not os.path.isdir(source_snapshot):
            print("[错误] 缺少干净源码快照：", source_snapshot)
            print("       先运行 python tools/sync_release_snapshot.py")
            return 1
        print("== 打包", os.path.basename(src_zip), "==")
        print("    entries:", zip_dir(source_snapshot, src_zip))
        produced.append(src_zip)

    if not args.no_apk:
        if not os.path.isfile(APK_SRC):
            print("[跳过] 缺少 APK：", APK_SRC)
        else:
            print("== 复制 APK ==")
            shutil.copy2(APK_SRC, apk_dst)
            produced.append(apk_dst)

    print()
    print("文件名|字节数|SHA256")
    for p in produced:
        print("%s|%d|%s" % (os.path.basename(p), os.path.getsize(p), sha256(p)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
