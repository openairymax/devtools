#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
"""AgentRT 端到端调用验证脚本（agent.spawn → agent.invoke → 真实 LLM）。

通过 agent_d 的 Unix socket 发起 JSON-RPC 调用，验证完整链路:
    client → agent_d → Python runner(airymax_agents) → openlab → LLM API

协议: 短连接模型。每次调用新建连接，发送单个 JSON-RPC 请求，
服务端处理完毕后关闭连接（daemon_main.h::daemon_handle_client_*）。
socket 默认取 $AIRY_HOME/run/agent.sock（未设置时 ~/.airymaxrt）。

用法:
    python3 agentrt-e2e.py [--socket <agent.sock>] [--role <role>]
                           [--input <问题>] [--timeout <秒>]
"""

import argparse
import json
import os
import socket
import sys
import time


def default_socket() -> str:
    airy_home = os.environ.get("AIRY_HOME", os.path.expanduser("~/.airymaxrt"))
    return os.path.join(airy_home, "run", "agent.sock")


def rpc(sock_path: str, method: str, params: dict, timeout: int = 300) -> dict:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="AgentRT e2e: agent.spawn + agent.invoke")
    parser.add_argument("--socket", default=default_socket(), help="agent_d unix socket 路径")
    parser.add_argument("--role", default="product_manager", help="agent role（对应 contract.json）")
    parser.add_argument("--input", default="请用一句话介绍你自己，并说明你能做什么。", help="invoke 输入")
    parser.add_argument("--timeout", type=int, default=300, help="单次调用超时（秒）")
    args = parser.parse_args()

    if not os.path.exists(args.socket):
        print(f"[FAIL] socket 不存在: {args.socket}（agentrt 是否已启动？）", file=sys.stderr)
        return 1

    # 1. spawn
    print(f"[1/2] agent.spawn (role={args.role}) -> {args.socket}")
    t0 = time.time()
    spawn = rpc(args.socket, "agent.spawn", {"agent_spec": {"role": args.role}}, args.timeout)
    dt = time.time() - t0
    if "error" in spawn:
        print(f"[FAIL] spawn 失败 ({dt:.1f}s): {json.dumps(spawn['error'], ensure_ascii=False)}")
        return 1
    agent_id = spawn["result"]["agent_id"]
    print(f"[ OK ] agent_id={agent_id} ({dt:.1f}s)")

    # 2. invoke
    print(f"[2/2] agent.invoke (agent_id={agent_id})")
    t0 = time.time()
    inv = rpc(args.socket, "agent.invoke", {"agent_id": agent_id, "input": args.input}, args.timeout)
    dt = time.time() - t0
    if "error" in inv:
        print(f"[FAIL] invoke 失败 ({dt:.1f}s): {json.dumps(inv['error'], ensure_ascii=False)}")
        return 1
    output = inv["result"]["output"]
    print(f"[ OK ] invoke 成功 ({dt:.1f}s)")
    print("---- LLM 输出 ----")
    print(output)
    print("---- 结束 ----")
    return 0


if __name__ == "__main__":
    sys.exit(main())
