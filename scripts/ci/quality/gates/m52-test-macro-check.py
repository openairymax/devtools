#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 测试运行宏假绿灯静态门禁（0.1.21 S30-P1-13；Gate 52）
#
# 判据（只认这一种可静态证实的形态）：测试运行宏体内调用了用例函数，随后
#   无条件打印 PASS / 累加通过数，且整段宏体没有任何失败面（无 fail 标识、
#   无失败计数、无 FAIL 分支）。这类宏会把用例内的断言失败吞掉——断言只写
#   stderr 或自增 counters，宏照常报 PASS，汇总因此全绿。
#
# 已收窄的写法不报：宏在调用前记录失败计数水位、返回后比较水位；或把 PASS
#   放在 if/else 的通过分支里。两者宏体内都出现失败面，本门禁不再介入。
#
# 口径限制（明示，不做静默假设）：只扫 tests 目录下的 .c/.h；宏体经续行
#   拼接后整体判定，不做数据流分析；单个宏拆成多个宏组合（BEGIN/PASS/END）
#   时，只要存在任一宏调用用例函数且无失败面，即判红。
#
# 用法:
#   m52-test-macro-check.py              扫 agent-workload 全部测试树
#   m52-test-macro-check.py --root DIR   指定根（CI 组装树 / 本地取证）
#   m52-test-macro-check.py --self-test  自证矩阵：植入必红与必绿样本
# 退出码: 0=通过 1=违例 2=环境错误
import argparse
import os
import re
import shutil
import sys
import tempfile

SKIP_DIRS = {".git", "build", "third_party", "cmake", "packaging", "latest"}
DEF_RE = re.compile(r"^\s*#\s*define\s+([A-Za-z_]\w*)\s*\(([^)]*)\)")
PASS_MARK = re.compile(r"\bpass\w*\s*\+\+|\bprintf\s*\(\s*\"PASS")
FAIL_MARK = re.compile(r"fail", re.I)
CALL_RE = re.compile(r"\b([A-Za-z_]\w*)\s*\(")


def walk_tests(root):
    """tests 目录下的 C 源文件；其余目录整枝跳过，避免把产品代码当测试。"""
    for base, dirs, files in os.walk(root):
        rel = os.path.relpath(base, root)
        parts = [] if rel == "." else rel.split(os.sep)
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        if "tests" not in parts:
            continue
        for name in sorted(files):
            if os.path.splitext(name)[1] in (".c", ".h"):
                yield os.path.join(base, name)


def macro_at(lines, idx):
    """从 #define 起按反斜杠续行取宏体；返回 (名称, 形参, 体, 下一行下标)。"""
    m = DEF_RE.match(lines[idx])
    name, raw = m.group(1), m.group(2)
    params = [p.strip() for p in raw.split(",") if p.strip()]
    body = [lines[idx]]
    i = idx
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.rstrip().endswith("\\"):
            break
        if i < len(lines):
            body.append(lines[i])
    return name, params, "\n".join(body), i


def false_green(params, body):
    """宏体是否构成「无条件通过」：有通过面、零失败面、且调用了用例函数。"""
    if not PASS_MARK.search(body):
        return False
    if FAIL_MARK.search(body):
        return False
    if re.search(r"\btest_\w+\s*\(", body):
        return True
    for p in params:
        if re.match(r"^[A-Za-z_]\w*$", p) and re.search(r"\b" + re.escape(p) + r"\s*\(", body):
            return True
    return False


def scan(root):
    """返回 (违规清单, 扫描文件数)；违规项为 (相对路径, 行号, 宏名)。"""
    bad = []
    count = 0
    for path in walk_tests(root):
        count += 1
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        i = 0
        while i < len(lines):
            if not DEF_RE.match(lines[i]):
                i += 1
                continue
            name, params, body, nxt = macro_at(lines, i)
            if false_green(params, body):
                bad.append((os.path.relpath(path, root), i + 1, name))
            i = max(nxt, i + 1)
    return bad, count


def self_test():
    """自证：必红样本被抓住、必绿样本不误报、tests 之外的文件不参与。"""
    tmp = tempfile.mkdtemp(prefix="m52-self-")
    try:
        os.makedirs(os.path.join(tmp, "mod", "tests"))
        os.makedirs(os.path.join(tmp, "mod", "src"))
        with open(os.path.join(tmp, "mod", "tests", "bad.c"), "w", encoding="utf-8") as fh:
            fh.write(
                "static int passed = 0;\n"
                "#define RUN_TEST(name) do { \\\n"
                "    test_##name(); \\\n"
                "    passed++; \\\n"
                '    printf("PASS\\n"); \\\n'
                "} while (0)\n"
            )
        with open(os.path.join(tmp, "mod", "tests", "good.c"), "w", encoding="utf-8") as fh:
            fh.write(
                "static int passed = 0, failed = 0;\n"
                "#define RUN_TEST(name) do { \\\n"
                "    int before = failed; \\\n"
                "    test_##name(); \\\n"
                "    if (failed > before) printf(\"FAIL\\n\"); \\\n"
                "    else { passed++; printf(\"PASS\\n\"); } \\\n"
                "} while (0)\n"
            )
        with open(os.path.join(tmp, "mod", "src", "skip.c"), "w", encoding="utf-8") as fh:
            fh.write("#define RUN_TEST(name) do { test_##name(); passed++; } while (0)\n")
        bad, _ = scan(tmp)
        got = {(p, n) for p, _, n in bad}
        want = {(os.path.join("mod", "tests", "bad.c"), "RUN_TEST")}
        if got != want:
            print(f"self-test: FAILED, got={sorted(got)} want={sorted(want)}", file=sys.stderr)
            return 1
        print("self-test: PASSED (必红命中，必绿与非 tests 目录不报)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default="", help="扫描根（默认 PROJECT_ROOT/agent-workload）")
    ap.add_argument("--self-test", action="store_true", help="判定矩阵自证")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.root:
        here = os.path.dirname(os.path.abspath(__file__))
        args.root = os.path.join(os.path.abspath(os.path.join(here, "../../../../..")), "agent-workload")
    if not os.path.isdir(args.root):
        print(f"m52: 扫描根不存在：{args.root}", file=sys.stderr)
        return 2

    bad, count = scan(args.root)
    print(f"root={args.root}")
    print(f"files={count} violations={len(bad)}")
    for path, line, name in bad:
        print(f"unconditional-pass {path}:{line} {name}")
    if count == 0:
        print("m52: 测试树为空，判据无法成立（fail-closed）", file=sys.stderr)
        return 2
    if bad:
        print(f"m52: {len(bad)} 个测试运行宏无条件报告通过（S30-P1-13）", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
