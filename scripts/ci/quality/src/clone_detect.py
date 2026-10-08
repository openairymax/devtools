#!/usr/bin/env python3
# clone_detect.py - G26 重复率检测器（归一化行窗口口径）
#
# 立意：重复率门禁（方案 §6.3 G26：3% ~ 5%）原先依赖 jscpd（npm 全局依赖），
#   在 Windows/macOS/Linux 三端与离网 CI 环境均不可靠，且阈值无法纳入 SSoT
#   体系。本检测器以 Python 标准库实现，无外部依赖，可移植于三端；阈值一律
#   由 thresholds.conf（唯一权威源）经命令行传入，本文件内不内联任何阈值。
#
# 判据：
#   1. 仅扫描生产码 *.c *.h *.cc *.cpp *.cxx *.hpp *.hxx，排除 tests/ 与
#      third_party/（与 G24 文件行数门禁同口径）；
#   2. 归一化：剥离 C/C++ 注释（保留行结构）、行内连续空白压为单空格、丢弃空行；
#   3. 克隆判定：同一文件内 W 个连续归一化行的 SHA-1 指纹，若在不同位置出现
#      ≥ 2 次（跨文件；或同文件且窗口首行相距 ≥ W，以排除同一区段的自身重叠），
#      即判为克隆组；指纹用 SHA-1 而非内建 hash()，保证跨进程/跨平台可复现；
#   4. 重复行数：克隆组中除首个出现外的副本行计入重复行（冗余副本口径，取值
#      保守且单调）；overall = 重复行数 / 归一化总行数；
#   5. 架构镜像豁免：--exemptions 指定清单（每行一对 agentrt 相对路径与理由
#      标签，'|' 分隔）；克隆组内全部文件都属于清单中某一对时整组豁免——
#      仅用于分层决议强制的镜像（如 corekern freestanding 不得依赖 commons），
#      组内若涉及第三个文件则绝不豁免，杜绝清单被用作普遍放水口。
#
# 用法: clone_detect.py [--root DIR] [--modules M ...] [--window N]
#                       [--target X] [--ceiling Y] [--top N] [--exemptions F]
#                       [--json-only]
# 退出码: 0 = PASS（≤ target）；2 = WARN（target ~ ceiling）；1 = FAIL（> ceiling）；
#         3 = 环境错误（根目录不存在）

import argparse
import hashlib
import json
import os
import sys

EXTS = ('.c', '.h', '.cc', '.cpp', '.cxx', '.hpp', '.hxx')
SKIP_DIRS = ('tests', 'third_party')
DEFAULT_MODULES = ('atoms', 'commons', 'daemons', 'gateway',
                   'heapstore', 'protocols', 'tools')


def strip_comments(text):
    """剥离 C/C++ 注释，保留换行结构；字符串/字符字面量内的注释符不误判。"""
    out = []
    i = 0
    n = len(text)
    state = ''
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if state == '':
            if c == '/' and nxt == '*':
                state = 'block'
                i += 2
                continue
            if c == '/' and nxt == '/':
                state = 'line'
                i += 2
                continue
            if c == '"' or c == "'":
                state = 'str' if c == '"' else 'chr'
            out.append(c)
            i += 1
            continue
        if state == 'block':
            if c == '*' and nxt == '/':
                state = ''
                i += 2
                continue
            if c == '\n':
                out.append('\n')
            i += 1
            continue
        if state == 'line':
            if c == '\n':
                state = ''
                out.append('\n')
            i += 1
            continue
        if c == '\\':
            out.append(c)
            if nxt:
                out.append(nxt)
            i += 2
            continue
        out.append(c)
        if state == 'str' and c == '"':
            state = ''
        elif state == 'chr' and c == "'":
            state = ''
        i += 1
    return ''.join(out)


def norm_lines(path):
    """返回 (归一化行文本, 原始行号) 平行列表；不可读返回 None。

    原始行号须随文本一并保留：克隆组报告定位到源码行才能用于整改。
    """
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
            text = fh.read()
    except OSError:
        return None
    texts = []
    lines = []
    for no, raw in enumerate(strip_comments(text).split('\n'), 1):
        s = ' '.join(raw.split())
        if s:
            texts.append(s)
            lines.append(no)
    return texts, lines


def collect_files(root, modules):
    """按模块顺序收集源文件（确定性排序），返回 [(模块名, 绝对路径)]。"""
    found = []
    for m in modules:
        base = os.path.join(root, m)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if name.endswith(EXTS):
                    found.append((m, os.path.join(dirpath, name)))
    return found


def load_exemptions(path):
    """加载架构镜像豁免清单，返回 [frozenset({a, b}), ...]。

    每行格式 `<relpath A> | <relpath B> | <reason>`；空行与 '#' 注释行忽略。
    路径归一为正斜杠分隔的相对形式，与克隆组文件集合直接比对；格式残缺
    的行以环境错误退出（fail-closed），绝不静默放过。
    """
    pairs = []
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            parts = [p.strip() for p in line.split('|')]
            if len(parts) != 3 or not parts[0] or not parts[1] or not parts[2]:
                print("[ERR] bad exemption line: %s" % line, file=sys.stderr)
                sys.exit(3)
            pair = set()
            for p in (parts[0], parts[1]):
                pair.add(os.path.normpath(p).replace(os.sep, '/'))
            pairs.append(frozenset(pair))
    return pairs


def group_exempt(places, paths, root, exemptions):
    """克隆组内全部文件都属于清单中某一对时豁免；涉及第三文件即不豁免。"""
    files = set()
    for fidx, _ in places:
        files.add(os.path.relpath(paths[fidx], root).replace(os.sep, '/'))
    return any(files <= pair for pair in exemptions)


def scan(root, modules, window, top, exemptions):
    """扫描并返回 (每模块统计, 路径表, 原始行号表, 克隆组表)。

    统计项为 [总行, 重复行]；克隆组表元素为 [(文件下标, 归一化行下标), ...]。
    """
    entries = collect_files(root, modules)
    paths = []
    texts_all = []
    origs_all = []
    file_module = []
    for m, full in entries:
        parsed = norm_lines(full)
        if parsed is None:
            continue
        texts, origs = parsed
        paths.append(full)
        texts_all.append(texts)
        origs_all.append(origs)
        file_module.append(m)

    occ = {}
    for fidx, texts in enumerate(texts_all):
        for i in range(len(texts) - window + 1):
            fp = hashlib.sha1(
                '\n'.join(texts[i:i + window]).encode('utf-8')).hexdigest()
            occ.setdefault(fp, []).append((fidx, i))

    dup = [set() for _ in texts_all]
    groups = []
    for places in occ.values():
        if len(places) < 2:
            continue
        filtered = []
        prev = None
        for p in places:
            if prev is not None and p[0] == prev[0] and p[1] - prev[1] < window:
                continue
            filtered.append(p)
            prev = p
        if len(filtered) < 2:
            continue
        if exemptions and group_exempt(filtered, paths, root, exemptions):
            continue
        for fidx, start in filtered[1:]:
            dup[fidx].update(range(start, start + window))
        if top > 0:
            groups.append(filtered)

    stats = {m: [0, 0] for m in modules}
    for fidx, texts in enumerate(texts_all):
        st = stats[file_module[fidx]]
        st[0] += len(texts)
        st[1] += len(dup[fidx])

    if top > 0:
        groups.sort(key=lambda g: (-len(g), g[0][0], g[0][1]))
        groups = groups[:top]
    return stats, paths, origs_all, groups


def human_report(stats, modules, window, target, ceiling, groups, paths, origs,
                 n_exempt):
    """打印人读报告，返回 (总行, 重复行, 重复率)。"""
    total_lines = 0
    total_dup = 0
    print("[INFO] G26 clone scan: window=%d lines, target<%.1f%%, "
          "ceiling<=%.1f%%, exemptions=%d"
          % (window, target, ceiling, n_exempt))
    print("%-12s %10s %10s %8s" % ("module", "lines", "dup", "rate"))
    for m in modules:
        lines, d = stats[m]
        total_lines += lines
        total_dup += d
        rate = (100.0 * d / lines) if lines else 0.0
        print("%-12s %10d %10d %7.2f%%" % (m, lines, d, rate))
    total_rate = (100.0 * total_dup / total_lines) if total_lines else 0.0
    print("%-12s %10d %10d %7.2f%%" % ("TOTAL", total_lines, total_dup,
                                       total_rate))
    for places in groups:
        fidx0, i0 = places[0]
        print("[CLONE] %d copies, window=%d, head=%s:%d"
              % (len(places), window, paths[fidx0], origs[fidx0][i0]))
        for fidx, start in places[1:]:
            print("        copy: %s:%d" % (paths[fidx], origs[fidx][start]))
    return total_lines, total_dup, total_rate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='.')
    ap.add_argument('--modules', nargs='*', default=list(DEFAULT_MODULES))
    ap.add_argument('--window', type=int, default=10)
    ap.add_argument('--target', type=float, default=3.0)
    ap.add_argument('--ceiling', type=float, default=5.0)
    ap.add_argument('--top', type=int, default=0)
    ap.add_argument('--exemptions', default=None)
    ap.add_argument('--json-only', action='store_true')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print("[ERR] root not found: %s" % root, file=sys.stderr)
        return 3

    exemptions = []
    if args.exemptions:
        if not os.path.isfile(args.exemptions):
            print("[ERR] exemptions list not found: %s" % args.exemptions,
                  file=sys.stderr)
            return 3
        exemptions = load_exemptions(args.exemptions)

    stats, paths, origs, groups = scan(root, args.modules, args.window,
                                       args.top, exemptions)
    if args.json_only:
        total_lines = sum(stats[m][0] for m in args.modules)
        total_dup = sum(stats[m][1] for m in args.modules)
        total_rate = (100.0 * total_dup / total_lines) if total_lines else 0.0
    else:
        total_lines, total_dup, total_rate = human_report(
            stats, args.modules, args.window, args.target, args.ceiling,
            groups, paths, origs, len(exemptions))

    payload = {
        "window": args.window,
        "total_lines": total_lines,
        "dup_lines": total_dup,
        "overall_rate": round(total_rate, 4),
        "target": args.target,
        "ceiling": args.ceiling,
        "modules": {m: {"lines": stats[m][0], "dup": stats[m][1],
                        "rate": round(100.0 * stats[m][1] / stats[m][0], 4)
                        if stats[m][0] else 0.0}
                    for m in args.modules},
    }
    if args.json_only:
        print(json.dumps(payload))
        return 0
    if total_rate > args.ceiling:
        return 1
    if total_rate > args.target:
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
