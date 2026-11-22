#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT 工具 schema 跨仓同源校验（0.1.21 S-P1-15 重写）。

0.1.21 起模型可调用 schema 不再由策略侧静态声明，而是运行期从 tool_d
目录（``list_tools``，C-16 目录 SSoT）生成。因此本门禁校验三条：

1. ``airymax_agents/base.py`` 不得再定义 ``BUILTIN_TOOL_SCHEMAS``；
2. 该文件必须以 ``tool_list()`` 目录为注册来源（不得另设白名单）；
3. tool_d 的注册元数据（``BTOOL`` 行）与契约表（``k_contract`` 行）必须
   逐项相等——注册了却没有 schema、或有 schema 却未注册，均为门禁失败。

退出码：0 一致；1 不一致（CI 门禁失败）。
用法：check-tool-schema-consistency.py [伞仓根]
"""

import os
import re
import sys

#: 契约表在 service_builtin.c 中的定义起点（提取到匹配的 "};" 为止）。
_CONTRACT_HEAD = "k_contract[] = {"


def load_py_source(base_py):
    """读取策略侧注册实现源码。"""
    with open(base_py, encoding="utf-8") as fh:
        return fh.read()


def load_contract_ids(service_builtin_c):
    """提取 k_contract 表的工具 id 集合。"""
    with open(service_builtin_c, encoding="utf-8") as fh:
        src = fh.read()
    start = src.find(_CONTRACT_HEAD)
    if start < 0:
        return set()
    end = src.find("};", start)
    if end < 0:
        return set()
    return set(re.findall(r'\{\s*"([^"]+)"\s*,', src[start:end]))


def load_btool_ids(service_builtin_c):
    """提取 BTOOL 元数据表的工具 id 集合。"""
    with open(service_builtin_c, encoding="utf-8") as fh:
        src = fh.read()
    return set(re.findall(r'BTOOL\(\s*"([^"]+)"', src))


def check_python_side(base_py):
    """校验策略侧不存在平行静态表，且注册来源是 tool_d 目录。"""
    src = load_py_source(base_py)
    issues = []
    if "BUILTIN_TOOL_SCHEMAS" in src:
        issues.append("base.py 仍定义平行静态表 BUILTIN_TOOL_SCHEMAS")
    if "tool_list(" not in src:
        issues.append("base.py 未以 tool_list() 目录作为注册来源")
    return issues


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../"))
    root = os.path.normpath(root)

    base_py = os.path.join(root, "agent-workload/ecosystem/agents/airymax_agents/base.py")
    service_builtin_c = os.path.join(
        root, "agent-workload/agentrt/daemons/tool_d/src/rpc/service_builtin.c")

    if not os.path.exists(base_py) or not os.path.exists(service_builtin_c):
        print(f"FAIL: 未找到对比源（{base_py} / {service_builtin_c}）", file=sys.stderr)
        return 1

    issues = check_python_side(base_py)
    contract_ids = load_contract_ids(service_builtin_c)
    btool_ids = load_btool_ids(service_builtin_c)

    print(f"[INFO] k_contract: {len(contract_ids)} 个；BTOOL: {len(btool_ids)} 个")
    if not contract_ids or not btool_ids:
        print("FAIL: 未能从 service_builtin.c 提取注册表/契约表", file=sys.stderr)
        return 1

    only_contract = sorted(contract_ids - btool_ids)
    only_btool = sorted(btool_ids - contract_ids)
    if only_contract:
        issues.append(f"有 schema 未注册（仅 k_contract）：{only_contract}")
    if only_btool:
        issues.append(f"已注册无 schema（仅 BTOOL）：{only_btool}")

    if issues:
        for item in issues:
            print(f"[FAIL] {item}", file=sys.stderr)
        return 1
    print("[ OK ] 目录唯一来源；注册表与契约表逐项一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
