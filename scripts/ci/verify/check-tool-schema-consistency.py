#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT 跨仓同步点一致性校验（0.1.6 SSoT S-6）。

对比两处工具 schema 定义：
- Python 侧：ecosystem/agents/airymax_agents/base.py 的 BUILTIN_TOOL_SCHEMAS
  （Python SDK 注册给 LLM 的工具 schema）
- C 侧：agentrt/daemons/tool_d/src/service_builtin.c 的 .id（运行时工具注册表）

约束（SSoT）：Python 侧是 C 侧的能力子集——Python 不得声明 C 侧不存在的
工具（防 LLM 调用到运行时无法执行的工具）；C 侧多出未在 Python 暴露的
工具属有意能力隔离（如 git_*/maths_* 无 Python 分发器），允许。

退出码：0 一致；1 不一致（CI 门禁失败）。
用法：check-tool-schema-consistency.py [伞仓根]
"""

import ast
import os
import re
import sys


def load_python_tools(base_py):
    """提取 BUILTIN_TOOL_SCHEMAS 的工具 id 集合。"""
    src = open(base_py, encoding="utf-8").read()
    tree = ast.parse(src)
    tools = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name)
                and node.target.id == "BUILTIN_TOOL_SCHEMAS"
                and isinstance(node.value, ast.Dict)):
            for k in node.value.keys:
                if isinstance(k, ast.Constant):
                    tools.add(k.value)
    return tools


def load_c_tools(service_builtin_c):
    """提取 service_builtin.c 中工具注册的 .id 集合。"""
    src = open(service_builtin_c, encoding="utf-8").read()
    return set(re.findall(r'\.id\s*=\s*"([^"]+)"', src))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../"))
    root = os.path.normpath(root)

    base_py = os.path.join(root, "agent-workload/ecosystem/agents/airymax_agents/base.py")
    builtin_c = os.path.join(root, "agent-workload/agentrt/daemons/tool_d/src/service_builtin.c")

    if not os.path.exists(base_py) or not os.path.exists(builtin_c):
        print(f"FAIL: 未找到对比源（{base_py} / {builtin_c}）", file=sys.stderr)
        return 1

    py_tools = load_python_tools(base_py)
    c_tools = load_c_tools(builtin_c)

    only_py = sorted(py_tools - c_tools)
    only_c = sorted(c_tools - py_tools)

    print(f"[INFO] Python BUILTIN_TOOL_SCHEMAS: {len(py_tools)} 个")
    print(f"[INFO] C service_builtin .id:       {len(c_tools)} 个")
    if only_c:
        print(f"[INFO] 仅 C 侧（能力隔离，允许）: {only_c}")
    if only_py:
        print(f"[FAIL] 仅 Python 侧（SSoT 违反）：{only_py}")
        return 1
    print("[ OK ] Python 工具集为 C 侧子集，一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
