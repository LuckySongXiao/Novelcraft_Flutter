"""把文件顶部（第一个 import 之前）的 /// 库文档注释改成 // 普通注释。

Dart 的 `dangling_library_doc_comments` 规则：文件开头紧跟 /// 且后面没有
`library` 声明时，该注释会被当作"悬空的库文档注释"报警。
这些注释只是说明性文字，降级为 // 即可保留内容又消警。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "lib"


def fix(path: pathlib.Path) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    # 找到第一个 import / library / part / export 的位置
    start = None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith(("import ", "library ", "part ", "export ")):
            start = i
            break
    if start is None or start == 0:
        return False

    changed = False
    for i in range(start):
        if lines[i].lstrip().startswith("///"):
            lines[i] = lines[i].replace("///", "//", 1)
            changed = True
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
    return changed


def main() -> None:
    n = 0
    for p in sorted(ROOT.rglob("*.dart")):
        if fix(p):
            n += 1
            print(f"fixed {p.relative_to(ROOT)}")
    print(f"-- {n} files updated")
    return 0 if n or True else 1


if __name__ == "__main__":
    sys.exit(main())
