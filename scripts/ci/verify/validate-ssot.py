#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT SSoT 技术点权威源校验（0.1.6 P2-3）。

从 docs/AirymaxRT/50-engineering-standards/09-ssot-registry.md §1.7
技术点单一权威源清单中提取 agentrt 技术点（TP-012~016）登记的
权威源/被引用方路径（反引号内，伞仓根相对），校验其全部存在。
CI 门禁：任何登记路径缺失即退出码 1，防止"文档登记了不存在的
权威源"漂移。仅校验 #>=12 的 agentrt 技术点行；前 11 行的
[SC]/[SS] 路径属 AirymaxOS 子仓，不在本校验范围。

退出码：0 一致；1 不一致（CI 门禁失败）。
用法：validate-ssot.py [伞仓根]
"""

import os
import re
import sys

REGISTRY = "docs/AirymaxRT/50-engineering-standards/09-ssot-registry.md"
AGENTRT_TECH_START = 12  # TP-012 起为 agentrt 用户态技术点


def parse_table_paths(md, section_start, section_end):
    """从 §1.7 表格解析每行 (编号, 权威源路径, 物理宿主路径集)。"""
    lines = md.splitlines()
    rows = []
    in_table = False
    for line in lines:
        if section_start in line:
            in_table = True
            continue
        if in_table and section_end in line:
            break
        if not in_table:
            continue
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 5:
            continue
        num = cells[0].strip()
        if not num.isdigit():
            continue
        if int(num) < AGENTRT_TECH_START:
            continue
        # 权威源文档列：markdown 相对链接（锚点剥离）或纯文本
        doc_link = re.search(r"\]\(([^)]+)\)", cells[3])
        auth_doc = None
        if doc_link:
            target = doc_link.group(1).split("#")[0]
            if not target.startswith("http"):
                auth_doc = target
        # 物理宿主列：全部反引号内路径（含 / 者）
        host_paths = []
        for tick in re.findall(r"`([^`]+)`", cells[4]):
            if "/" in tick and not tick.startswith("<"):
                host_paths.append(tick)
        rows.append((int(num), auth_doc, host_paths))
    return rows


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../"))
    root = os.path.normpath(root)

    reg_path = os.path.join(root, REGISTRY)
    if not os.path.exists(reg_path):
        print(f"FAIL: 未找到 SSoT 注册表（{reg_path}）", file=sys.stderr)
        return 1

    md = open(reg_path, encoding="utf-8").read()
    rows = parse_table_paths(md, "### 1.7 技术点单一权威源清单", "**使用规则**")
    if not rows:
        print("FAIL: §1.7 未解析到 agentrt 技术点登记（TP-012~016）", file=sys.stderr)
        return 1

    reg_dir = os.path.dirname(reg_path)
    missing = []
    checked = 0
    for num, auth_doc, host_paths in sorted(rows):
        print(f"[INFO] TP-{num:03d}: 校验 {len(host_paths)} 个物理宿主 + 1 个权威源文档")
        # 权威源文档（相对注册表所在目录解析）
        if auth_doc:
            checked += 1
            target = os.path.normpath(os.path.join(reg_dir, auth_doc))
            if not os.path.exists(target):
                missing.append(f"TP-{num:03d} 权威源文档: {auth_doc}")
            else:
                print(f"  [OK ] 权威源文档 {auth_doc}")
        # 物理宿主/引用方路径（伞仓根相对）
        for p in host_paths:
            checked += 1
            target = os.path.normpath(os.path.join(root, p))
            if not os.path.exists(target):
                missing.append(f"TP-{num:03d} 物理宿主: {p}")
            else:
                print(f"  [OK ] 物理宿主 {p}")

    if missing:
        print(f"\nFAIL: {len(missing)} 个登记路径缺失（SSoT 漂移）：", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        return 1
    print(f"\n[ OK ] SSoT 技术点权威源全部存在（TP-012~016，共 {checked} 个路径）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
