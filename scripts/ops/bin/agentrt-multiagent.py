#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT 多 Agent 协作闭环验证脚本（sched.schedule_task 选后派发 → 双角色接力）。

通过 sched_d 的 Unix socket 发起 JSON-RPC 调用，验证真实的多 Agent 协作链路:
    client → sched_d(schedule_task) → agent_d(spawn+invoke) → Python runner
             → openlab → LLM API（产品经理 → 后端开发接力）

链路要点（P2.2 选后派发）:
  - sched.register_agent 注册两个不同角色（product_manager / backend）
  - sched.schedule_task 由调度器按 round-robin 选择角色，并真实派发到 agent_d
  - 任务 1 由产品经理 Agent 产出 PRD 摘要
  - 任务 2 将 PRD 摘要接力给后端开发 Agent，生成实现要点
  - 两次派发的 agent_id 不同 → 证明是两个独立 Agent 协作而非单 Agent 复用

协议: 短连接模型。每次调用新建连接，发送单个 JSON-RPC 请求，
服务端处理完毕后关闭连接（daemon_main.h::daemon_handle_client_*）。
socket 默认取 $AIRY_HOME/run/sched.sock（未设置时 ~/.airymaxrt）。

用法:
    python3 agentrt-multiagent.py [--socket <sched.sock>] [--timeout <秒>]
"""

import argparse
import json
import os
import socket
import sys
import time


def default_socket() -> str:
    airy_home = os.environ.get("AIRY_HOME", os.path.expanduser("~/.airymaxrt"))
    return os.path.join(airy_home, "run", "sched.sock")


def rpc(sock_path: str, method: str, params: dict, timeout: int = 600) -> dict:
    """发送单个 JSON-RPC 请求并读取响应（服务端处理完即断开）。"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        s.sendall(req.encode("utf-8"))
        # 注意：不可 shutdown(SHUT_WR)。服务端 recv 一次读取完整请求，
        # 半关闭的 FIN 会干扰其后续处理/响应，导致响应丢失（已实测）。
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if buf:
                # 响应数据已到：缩短超时收尾等待 EOF，避免服务端
                # close 的 FIN 延迟导致空等至原始超时（实测 30s+）。
                s.settimeout(1.0)
        if not buf:
            return {"error": {"code": -1, "message": "no response from daemon"}}
        return json.loads(buf.decode("utf-8"))
    finally:
        s.close()


def register_agent(sock: str, agent_id: str, agent_name: str, available: bool,
                   timeout: int) -> None:
    """在 sched_d 注册一个 Agent（agent_id 即角色名）。

    sched.register_agent 幂等：重复注册同一 agent_id 只更新指标/可用性。
    演示通过 is_available 精确控制本轮调度选中的角色（不依赖调度器
    round-robin 的历史计数，保证 product_manager → backend 接力顺序确定）。
    """
    agent = {
        "agent_id": agent_id,
        "agent_name": agent_name,
        "load_factor": 0.0,
        "success_rate": 1.0,
        "avg_response_time_ms": 30000,
        "is_available": available,
        "weight": 1.0,
    }
    resp = rpc(sock, "register_agent", {"agent": agent}, timeout)
    if "error" in resp:
        print(f"[FAIL] register_agent({agent_id}) 失败: {json.dumps(resp['error'], ensure_ascii=False)}")
        sys.exit(1)
    state = "可用" if available else "停用"
    print(f"[ OK ] 已注册角色 Agent: {agent_id} ({agent_name}) [{state}]")


def schedule_task(sock: str, task_id: str, description: str, timeout: int) -> dict:
    """调用 sched.schedule_task：调度器选角色并真实派发到 agent_d 执行。"""
    t0 = time.time()
    resp = rpc(
        sock,
        "schedule_task",
        {"task": {"task_id": task_id, "task_description": description,
                  "priority": 0, "timeout_ms": timeout * 1000}},
        timeout,
    )
    dt = time.time() - t0
    if "error" in resp:
        print(f"[FAIL] schedule_task({task_id}) 失败 ({dt:.1f}s): "
              f"{json.dumps(resp['error'], ensure_ascii=False)}")
        sys.exit(1)
    result = resp["result"]
    if not result.get("dispatched"):
        print(f"[FAIL] schedule_task({task_id}) 未被派发 (dispatched=false, "
              f"selected={result.get('selected_agent_id')})")
        sys.exit(1)
    print(f"[ OK ] {task_id}: 角色={result['selected_agent_id']} "
          f"agent_id={result['agent_id']} ({dt:.1f}s)")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="AgentRT 多 Agent 协作闭环演示")
    parser.add_argument("--socket", default=default_socket(), help="sched_d unix socket 路径")
    parser.add_argument("--timeout", type=int, default=600, help="单次调用超时（秒）")
    args = parser.parse_args()

    if not os.path.exists(args.socket):
        print(f"[FAIL] socket 不存在: {args.socket}（agentrt 是否已启动？）", file=sys.stderr)
        return 1

    print("=" * 70)
    print("AgentRT 多 Agent 协作闭环演示（sched 选后派发 → agent_d 真实执行）")
    print("=" * 70)

    # 1. 注册两个不同角色的 Agent（幂等：重复注册更新指标/可用性）。
    #    任务 1 仅 product_manager 可用 → 调度器必选产品经理；
    #    任务 2 仅 backend 可用 → 调度器必选后端开发。接力顺序确定。
    register_agent(args.socket, "product_manager", "产品经理", True, args.timeout)
    register_agent(args.socket, "backend", "后端开发", False, args.timeout)

    # 2. 任务 1：产品经理 Agent 产出 PRD 摘要（真实 LLM 回复）
    pm_input = (
        "你是产品经理。请为「面向开发者的智能体任务调度控制台」产出 PRD 摘要，"
        "内容需包含：核心功能需求、主要模块划分、验收标准。控制在 200 字以内，"
        "用中文输出，使用要点列表。"
    )
    print("\n[1/2] 调度并派发任务 task-pm → product_manager Agent")
    pm = schedule_task(args.socket, "task-pm", pm_input, args.timeout)
    pm_output = pm["output"]
    print("---- 产品经理 Agent 真实输出（PRD 摘要） ----")
    print(pm_output)
    print("---- 结束 ----")

    # 3. 角色切换：停用 product_manager，启用 backend，调度器必选后端开发
    register_agent(args.socket, "product_manager", "产品经理", False, args.timeout)
    register_agent(args.socket, "backend", "后端开发", True, args.timeout)

    # 4. 任务 2：将 PRD 摘要接力给后端开发 Agent 生成实现要点
    backend_input = (
        "你是后端开发工程师。以下是产品经理给出的 PRD 摘要，请基于它产出后端实现要点："
        "模块拆分、接口设计、数据模型。控制在 200 字以内，用中文输出，使用要点列表。\n\n"
        "【PRD 摘要】\n" + pm_output
    )
    print("\n[2/2] 调度并派发任务 task-backend → backend Agent（接力 PM 产出）")
    be = schedule_task(args.socket, "task-backend", backend_input, args.timeout)
    be_output = be["output"]
    print("---- 后端开发 Agent 真实输出（实现要点） ----")
    print(be_output)
    print("---- 结束 ----")

    # 5. 校验：两个任务由两个不同 Agent 执行（多 Agent 而非单 Agent 复用）
    print("\n" + "=" * 70)
    if pm["agent_id"] != be["agent_id"]:
        print(f"[PASS] 多 Agent 协作验证通过：product_manager({pm['agent_id'][:16]}…) "
              f"≠ backend({be['agent_id'][:16]}…)，两个独立 Agent 接力完成")
    else:
        print(f"[WARN] 两次派发复用同一 agent_id={pm['agent_id']}，未体现多 Agent 差异")
    if pm_output.strip() and be_output.strip():
        print("[PASS] 两个 Agent 均有真实 LLM 输出（非空），接力链路完整")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
