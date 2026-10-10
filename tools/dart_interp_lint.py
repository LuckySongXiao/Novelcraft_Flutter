# -*- coding: utf-8 -*-
"""扫描 Dart 源码里「字符串插值漏写花括号」的致命模式。

用法（工程根执行）：

    python tools/dart_interp_lint.py            # 扫 lib/ 与 test/
    python tools/dart_interp_lint.py --selftest # 只验证扫描器自身

为什么需要它
------------
Dart 的 `$identifier` **只能**插值简单标识符。写成

    File('...${sep}$_fileOf(key)')      # ← 错

插进去的不是调用结果，而是**函数对象本身**，后面的 `(key)` 退化成字面文本，
路径变成

    ...\\internal\\Closure: (String) => String from Function '_fileOf@...': static (key)

`File.existsSync()` / `writeAsString` 随即抛 `PathNotFoundException (errno 123)`。
这个 bug 已在 `key_value_store_native.dart` 真实发生并导致 **Windows 端启动即崩**。

⚠ **类型检查发现不了**：插值一个函数是合法 Dart，`dart analyze` 报 0 error
（本轮就是这么漏过去的）。它只在运行期炸，且炸在启动路径上 —— 必须靠静态扫描兜住。

判定规则：在**字符串字面量内部**出现 `$<标识符>` 且紧跟 `(`。
    * `'$foo(bar)'`   → 命中（`foo` 被插值，`(bar)` 是字面文本）
    * `'${foo(bar)}'` → 不命中（花括号形式，正确）
    * `$_aliasNameGenerator(x)` → 不命中（不在字符串里，是普通代码）
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_DIRS = ("lib", "test")

# 生成的代码不扫（`database.g.dart` 里有大量 `$_aliasNameGenerator(...)` 形式的
# 普通代码调用，虽不会误报，但没必要扫）。
SKIP_SUFFIX = (".g.dart", ".freezed.dart", ".mocks.dart")

ID_START = re.compile(r"[A-Za-z_]")
ID_CHAR = re.compile(r"[A-Za-z0-9_]")

# 命中模式：$标识符(          —— 仅当它出现在字符串里
HIT = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\s*\(")


def scan_text(text: str):
    """返回 [(行号, 该行文本)]。"""
    hits = []
    # 跨行跟踪字符串状态：None / "'" / '"' / '"""' / "'''"
    in_str = None
    lines = text.split("\n")
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        # 整行注释跳过（注释里出现该模式无副作用）
        is_comment_line = stripped.startswith("//") or stripped.startswith("*")
        j = 0
        n = len(line)
        while j < n:
            ch = line[j]
            if in_str is None:
                # 进入字符串？先跳过行注释
                if ch == "/" and j + 1 < n and line[j + 1] == "/":
                    break
                if ch == "r" and j + 1 < n and line[j + 1] in "'\"":
                    j += 1
                    ch = line[j]
                if ch in "'\"":
                    if line.startswith(ch * 3, j):
                        in_str = ch * 3
                        j += 3
                        continue
                    in_str = ch
                    j += 1
                    continue
                j += 1
                continue
            # ---- 在字符串内部 ----
            if ch == "\\":
                j += 2
                continue
            if in_str in ("'", '"'):
                if ch == in_str:
                    in_str = None
                    j += 1
                    continue
            else:  # 多行三引号
                if line.startswith(in_str, j):
                    in_str = None
                    j += 3
                    continue
            if ch == "$":
                nxt = line[j + 1] if j + 1 < n else ""
                if nxt == "{":
                    # `${...}` 正确形式：跳过整个插值块（含嵌套花括号）
                    depth = 0
                    k = j + 1
                    while k < n:
                        if line[k] == "{":
                            depth += 1
                        elif line[k] == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        k += 1
                    j = k + 1
                    continue
                if nxt and ID_START.match(nxt):
                    k = j + 1
                    while k < n and ID_CHAR.match(line[k]):
                        k += 1
                    # 允许 `$foo.bar(` 这样的链式取值
                    m = k
                    while m < n and line[m] == ".":
                        m += 1
                        while m < n and ID_CHAR.match(line[m]):
                            m += 1
                    if m < n and line[m] == "(":
                        hits.append((i, line.rstrip()))
                    j = m
                    continue
            j += 1
        if is_comment_line:
            continue
    return hits


def run(dirs=SCAN_DIRS):
    total = 0
    files = 0
    for base in dirs:
        base_abs = os.path.join(ROOT, base)
        for dirpath, _dirnames, filenames in os.walk(base_abs):
            for name in sorted(filenames):
                if not name.endswith(".dart") or name.endswith(SKIP_SUFFIX):
                    continue
                full = os.path.join(dirpath, name)
                with open(full, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
                files += 1
                for lineno, line in scan_text(text):
                    total += 1
                    rel = os.path.relpath(full, ROOT).replace("\\", "/")
                    print("%s:%d" % (rel, lineno))
                    print("    %s" % line.strip())
    print("扫描 %d 个 .dart 文件，命中 %d 处" % (files, total))
    return total


def selftest():
    bad = [
        "    final f = File('...${sep}$_fileOf(key)');",
        "  print('值=$compute(3)');",
        "  var s = \"$render(x)\";",
    ]
    good = [
        "  final f = File('...${sep}${_fileOf(key)}');",
        "  print('值=${compute(3)}');",
        "  aliasName: $_aliasNameGenerator(db.a, db.b),",
        "  // 注释里的 $foo( 不该命中",
        "  print('纯文本 (paren)');",
        r"  final s = '\$escaped(x)';",
    ]
    ok = True
    for s in bad:
        if not scan_text(s):
            print("SELFTEST FAIL 应命中却未命中: %s" % s)
            ok = False
    for s in good:
        if scan_text(s):
            print("SELFTEST FAIL 误报: %s" % s)
            ok = False
    print("SELFTEST %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    n = run()
    sys.exit(1 if n else 0)
