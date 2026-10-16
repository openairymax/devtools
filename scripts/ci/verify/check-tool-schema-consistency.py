#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT 跨仓同步点一致性校验（0.1.6 SSoT S-6）。

对比两处工具 schema 定义：
- Python 侧：ecosystem/agents/airymax_agents/base.py 的 BUILTIN_TOOL_SCHEMAS
  （Python SDK 注册给 LLM 的工具 schema）
- C 侧：agentrt/daemons/tool_d 的能力格注册表（数据化 SSoT）：
  src/rpc/service_builtin.c 的 BTOOL("id", ...) 元数据表 +
  src/builtin/builtin.c 的 g_builtin_slots[] 分发槽

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


def load_c_tools(service_builtin_c, builtin_c):
    """提取 C 侧内建工具能力格（数据化 SSoT）的工具 id 集合。

    0.1.19 根因修复：本函数原以 builtin.c 内 `strcmp(tool_id, "...") == 0`
    分发链为提取源。内建工具注册数据化后，该模式在树内消失（builtin.c 改为
    `g_builtin_slots[]` 槽表 + `tool_builtin_run()` 纯查表），旧正则提取恒空，
    致 Python 侧全部工具被误判为「仅 Python」（假阳门禁）。改为读取注册表本体：
      - service_builtin.c 的 `BTOOL("id", ...)` 元数据表（工具 id 权威宿主）；
      - builtin.c 的 `g_builtin_slots[]` 分发槽（`{"id", <fn>_tool}` 行），
        与元数据表并集加固。两表应逐项一致，取并集既不漏报也不误报。
    """
    ids = set()
    for path in (service_builtin_c, builtin_c):
        if not os.path.exists(path):
            continue
        src = open(path, encoding="utf-8").read()
        ids |= set(re.findall(r'BTOOL\(\s*"([^"]+)"', src))
        ids |= set(re.findall(
            r'\{\s*"([^"]+)"\s*,\s*[A-Za-z_][A-Za-z0-9_]*_tool\s*\}', src))
    return ids


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../"))
    root = os.path.normpath(root)

    base_py = os.path.join(root, "agent-workload/ecosystem/agents/airymax_agents/base.py")
    builtin_c = os.path.join(
        root, "agent-workload/agentrt/daemons/tool_d/src/builtin/builtin.c")
    service_builtin_c = os.path.join(
        root, "agent-workload/agentrt/daemons/tool_d/src/rpc/service_builtin.c")

    if (not os.path.exists(base_py) or not os.path.exists(builtin_c)
            or not os.path.exists(service_builtin_c)):
        print(f"FAIL: 未找到对比源（{base_py} / {service_builtin_c} / {builtin_c}）",
              file=sys.stderr)
        return 1

    py_tools = load_python_tools(base_py)
    c_tools = load_c_tools(service_builtin_c, builtin_c)

    only_py = sorted(py_tools - c_tools)
    only_c = sorted(c_tools - py_tools)

    print(f"[INFO] Python BUILTIN_TOOL_SCHEMAS: {len(py_tools)} 个")
    print(f"[INFO] C tool_builtin_run ids:      {len(c_tools)} 个")
    if only_c:
        print(f"[INFO] 仅 C 侧（能力隔离，允许）: {only_c}")
    if only_py:
        print(f"[FAIL] 仅 Python 侧（SSoT 违反）：{only_py}")
        return 1
    print("[ OK ] Python 工具集为 C 侧子集，一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
