#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# AgentRT 发布版本保留判定（publish-release.sh 与 publish-mirror.sh 共享实现，
# 两平台面判定必须严格同源，禁止各自内联副本）。
#
# 输入（stdin）：候选 tag，每行一个。
# 输出（stdout）：超出保留窗口的 tag，每行一个。
#
# 窗口策略：按通道（stable/rc/beta）分窗，各保留最近 KEEP 版；当前版本永不
# 输出。排序规则（semver 感知）：主/次/补丁数值比较；同号内分层 正式(4) >
# 字母后缀(3) > rc(2) > beta(1)；rc/beta 序号数值比较（防 rc10 < rc9 字典序
# 误判）。
#
# 用法：airy_release_prune.py <keep> <current> < tags.txt

import re
import sys


def chan(t):
    if "-rc" in t:
        return "rc"
    if "-beta" in t:
        return "beta"
    return "stable"


def vkey(t):
    m = re.match(r"^v(\d+)\.(\d+)\.(\d+)(.*)$", t)
    if not m:
        return (0, 0, 0, 0, 0, "", t)
    maj, mnr, pat, suf = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
    rank, num, sfx = 4, 0, ""
    m2 = re.match(r"^[-.]?(rc|beta)[-.]?(\d+)", suf)
    if m2:
        rank = 2 if m2.group(1) == "rc" else 1
        num = int(m2.group(2)) if m2.group(2) else 0
    elif suf:
        rank = 3
        sfx = suf.lstrip("-.")
    return (maj, mnr, pat, rank, num, sfx, t)


def main():
    keep = int(sys.argv[1])
    current = sys.argv[2]
    tags = [t.strip() for t in sys.stdin.read().splitlines() if t.strip()]

    groups = {}
    for t in tags:
        groups.setdefault(chan(t), []).append(t)
    for ch in sorted(groups):
        ts = sorted(groups[ch], key=vkey)
        for t in ts[:-keep]:
            if t != current:
                print(t)


if __name__ == "__main__":
    main()
