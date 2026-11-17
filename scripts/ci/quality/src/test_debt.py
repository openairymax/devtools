#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# AgentRT 测试债反查（0.1.21 L-12 / §16.20.6）
#
# 判据：头文件里以**函数原型**声明的每个 `airy_*` 导出符号，必须在测试树中
#   被至少引用一次；未被引用者即「测试债」，按符号名排序输出，形成可逐条
#   销账的台账底稿。
#
# 为何以头文件为准：定义可能有多份实现或条件编译，而头文件是调用方唯一可见
#   的契约面——测试没碰过头文件里的符号，就等于没测过该契约。
#
# 为何只认原型：`static inline` 是取用方自带实现的私有件，宏体与函数体里的
#   `airy_*(` 是调用而非声明。把头文件里出现的每个 `airy_*(` 都算导出符号，
#   会把私有件与调用混进账（daemons 曾因此虚报 3 条缺口），账不真实也无法销账。
#
# 为何不判「覆盖率百分比」：百分比会被已有大文件的用例稀释，缺口仍藏得住；
#   逐符号反查是离散账，能把「新加了一个没人测的 API」直接顶到面前。
#
# 用法:
#   test_debt.py --root <agentrt 根>            报告
#   test_debt.py --root <根> --check --base <ref>  新增符号无测试引用即非零退出
# 退出码: 0 = 通过/仅报告；1 = 新增符号无测试引用；2 = 环境错误
import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

BASE_SKIP = {".git", "build", "third_party", "cmake", "packaging", "latest"}
DECL_RE = re.compile(
    r"^\s*(?:extern\s+)?[A-Za-z_][A-Za-z0-9_\s\*]*?[\s\*](airy_[a-z0-9_]+)\s*\("
)
HDR_SKIP = ("#", "typedef", "static", "return", 'extern "C"')


def walk(root, exts, in_tests=None):
    """遍历源码/测试树；in_tests=False 跳过测试目录，True 只进测试目录。"""
    for base, dirs, files in os.walk(root):
        rel = os.path.relpath(base, root)
        parts = set() if rel == "." else set(rel.split(os.sep))
        dirs[:] = [d for d in dirs if d not in BASE_SKIP and (in_tests is not False or d != "tests")]
        is_test = "tests" in parts
        if in_tests is not None and is_test != in_tests:
            continue
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


def logical(text):
    """按逻辑行切开：跨行原型拼回一行，宏续行并回一行，到 ; { } 收口。"""
    buf = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not buf:
            if not line or line.startswith(HDR_SKIP):
                continue
            buf = line
        else:
            buf = f"{buf} {line}"
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
            continue
        if buf.endswith((";", "{", "}")):
            yield buf
            buf = ""
    if buf:
        yield buf


def scan_text(text):
    """从一段头文件源码里取导出原型集合。"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    found = set()
    for line in logical(text):
        m = DECL_RE.match(line)
        if m:
            found.add(m.group(1))
    return found


def scan(path):
    """单个头文件的导出原型集合；注释先剥掉，私有件与调用不算导出。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return scan_text(fh.read())
    except OSError:
        return set()


def declared(root):
    """返回 {符号: 首个声明头文件}；只认函数原型。"""
    found = {}
    for path in walk(root, {".h"}, in_tests=False):
        for sym in sorted(scan(path)):
            found.setdefault(sym, os.path.relpath(path, root))
    return found


def corpus(root):
    """测试树全文；一次读完，避免逐符号 grep 造成 N 次遍历。"""
    chunks = []
    for path in walk(root, {".c", ".h", ".py", ".rs", ".sh"}, in_tests=True):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                chunks.append(fh.read())
        except OSError:
            continue
    return "\n".join(chunks)


def _git(root, *args):
    """成功返回 stdout 字节，失败返回 None（由调用方区分「无变更」与「出错」）。"""
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True, check=False)
    except OSError:
        return None
    return p.stdout if p.returncode == 0 else None


def _tree_syms(root, rev):
    """某个提交全部头文件的原型集合；用归档导出，不碰工作树。"""
    arc = _git(root, "archive", "--format=tar", rev, "--", "*.h")
    if arc is None:
        return None
    tmp = tempfile.mkdtemp(prefix="test-debt-")
    try:
        with tarfile.open(fileobj=io.BytesIO(arc), mode="r:") as tar:
            tar.extractall(tmp, filter="data")
        return set(declared(tmp))
    except (tarfile.TarError, OSError):
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def declared_at(root, base):
    """base 侧全部导出原型；子模块按 base 记录的 gitlink 各自回看。

    只比 base..HEAD 的变更行会把「头文件搬家」误判成新增 API，因此取 base
    全树的原型集合做差；子模块是独立仓，`git show base:path` 取不到其中
    头文件，必须按 gitlink 提交在子仓里导出。
    """
    found = _tree_syms(root, base)
    if found is None:
        print(f"test-debt: 基线 {base} 不可读", file=sys.stderr)
        return None
    tree = _git(root, "ls-tree", "-r", base)
    if tree is None:
        print(f"test-debt: 基线 {base} 的树不可读", file=sys.stderr)
        return None
    for line in tree.decode("utf-8", "replace").splitlines():
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) < 3 or parts[0] != "160000":
            continue
        old = parts[2]
        got = _tree_syms(os.path.join(root, path), old)
        if got is None:
            print(f"test-debt: 子模块 {path} 在基线 {old} 不可读", file=sys.stderr)
            return None
        found |= got
    return found


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--base")
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        print(f"test-debt: 根目录不存在：{args.root}", file=sys.stderr)
        return 2
    decls = declared(args.root)
    text = corpus(args.root)
    if not decls and not any(True for _ in walk(args.root, {".h"}, in_tests=False)):
        print("test-debt: 根目录下没有任何头文件（检查 --root 是否正确）", file=sys.stderr)
        return 2

    hit = {s for s in decls if re.search(r"\b" + re.escape(s) + r"\b", text)}
    miss = sorted(set(decls) - hit)
    total = len(decls)
    print(f"root={args.root}")
    print(f"symbols={total}")
    print(f"tested={len(hit)}")
    print(f"uncovered={len(miss)}")
    print(f"ratio={100.0 * len(hit) / total:.1f}%" if total else "ratio=0.0%")
    for sym in miss[: args.limit]:
        print(f"gap {sym} {decls[sym]}")

    rc = 0
    if args.check and args.base:
        base_decls = declared_at(args.root, args.base)
        if base_decls is None:
            print(f"test-debt: 基线 {args.base} 不可读，新增符号无法判定", file=sys.stderr)
            return 2
        bare = sorted(s for s in set(decls) - base_decls
                      if not re.search(r"\b" + re.escape(s) + r"\b", text))
        print(f"check-base={args.base} new-symbols={len(set(decls) - base_decls)}")
        for sym in bare:
            print(f"new-uncovered {sym}")
        if bare:
            print(f"test-debt: {len(bare)} 个新增导出符号无测试引用（R6）", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
