#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# AgentRT 测试债反查（0.1.21 L-12 / §16.20.6）
#
# 判据：头文件里声明的每个 `airy_*` 导出符号，必须在测试树中被至少引用一次；
#   未被引用者即「测试债」，按符号名排序输出，形成可逐条销账的台账底稿。
#
# 为何以头文件为准：定义可能有多份实现或条件编译，而头文件是调用方唯一可见
#   的契约面——测试没碰过头文件里的符号，就等于没测过该契约。
#
# 为何不判「覆盖率百分比」：百分比会被已有大文件的用例稀释，缺口仍藏得住；
#   逐符号反查是离散账，能把「新加了一个没人测的 API」直接顶到面前。
#
# 用法:
#   test_debt.py --root <agentrt 根>            报告
#   test_debt.py --root <根> --check --base <ref>  新增符号无测试引用即非零退出
# 退出码: 0 = 通过/仅报告；1 = 新增符号无测试引用；2 = 环境错误
import argparse
import os
import re
import subprocess
import sys

BASE_SKIP = {".git", "build", "third_party", "cmake", "packaging", "latest"}
SYM_RE = re.compile(r"\b(airy_[a-z0-9_]+)\s*\(")


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


def declared(root):
    """返回 {符号: 首个声明头文件}；只认看起来像函数原型的行。"""
    found = {}
    for path in walk(root, {".h"}, in_tests=False):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    s = line.strip()
                    if not s or s.startswith(("#", "//", "/*", "*", "typedef", "static", "extern \"C\"")):
                        continue
                    if SYM_RE.search(s):
                        for sym in SYM_RE.findall(s):
                            found.setdefault(sym, os.path.relpath(path, root))
        except OSError:
            continue
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


def added_syms(root, base):
    """从 base 起的头文件新增行里取符号，用于 --check。"""
    try:
        out = subprocess.run(
            ["git", "-C", root, "diff", "-U0", base, "--", "*.h"],
            capture_output=True, text=True, check=False,
        ).stdout
    except OSError:
        return None
    syms = set()
    for line in out.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            syms.update(SYM_RE.findall(line))
    return syms


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
    if not decls:
        print("test-debt: 未发现任何导出符号（检查根目录是否正确）", file=sys.stderr)
        return 2

    hit = {s for s in decls if re.search(r"\b" + re.escape(s) + r"\b", text)}
    miss = sorted(set(decls) - hit)
    total = len(decls)
    print(f"root={args.root}")
    print(f"symbols={total}")
    print(f"tested={len(hit)}")
    print(f"uncovered={len(miss)}")
    print(f"ratio={100.0 * len(hit) / total:.1f}%")
    for sym in miss[: args.limit]:
        print(f"gap {sym} {decls[sym]}")

    rc = 0
    if args.check and args.base:
        new = added_syms(args.root, args.base)
        if new is None:
            print("test-debt: git 调用失败，无法判定新增符号", file=sys.stderr)
            return 2
        bare = sorted(s for s in new if not re.search(r"\b" + re.escape(s) + r"\b", text))
        for sym in bare:
            print(f"new-uncovered {sym}")
        if bare:
            print(f"test-debt: {len(bare)} 个新增导出符号无测试引用（R6）", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
