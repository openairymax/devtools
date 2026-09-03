#!/usr/bin/env python3
"""
P0.20.8 端到端冒烟测试 — 启动 monit_d daemon 并验证 IPC 通信

测试流程:
1. 启动 monit_d daemon (Unix socket 模式)
2. 等待 socket 就绪
3. 发送 JSON-RPC 2.0 请求 (health_check + get_metrics)
4. 测试 Prometheus /metrics HTTP 端点
5. 优雅关闭 daemon (SIGTERM)

使用方法:
    python3 smoke_test_daemon.py [--binary PATH] [--timeout SEC]
"""

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import tempfile

DEFAULT_BINARY = "/home/spharx/SpharxWorks/build/bin/monit_d"
DEFAULT_SOCKET = "/tmp/agentrt/monit.sock"
DEFAULT_TIMEOUT = 10  # seconds


def log_ok(msg):
    print(f"  \033[32m✓\033[0m {msg}")


def log_fail(msg):
    print(f"  \033[31m✗\033[0m {msg}")


def log_info(msg):
    print(f"  \033[34mℹ\033[0m {msg}")


def wait_for_socket(sock_path, timeout_sec):
    """轮询连接 socket，等待 daemon 就绪"""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if os.path.exists(sock_path):
            try:
                test_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                test_sock.settimeout(0.5)
                test_sock.connect(sock_path)
                test_sock.close()
                return True
            except (ConnectionRefusedError, OSError):
                pass
        time.sleep(0.1)
    return False


def send_jsonrpc(sock_path, method, params=None, req_id=1, timeout=3.0):
    """发送 JSON-RPC 2.0 请求并返回响应"""
    req = {
        "jsonrpc": "2.0",
        "method": method,
        "id": req_id,
    }
    if params is not None:
        req["params"] = params

    req_str = json.dumps(req) + "\n"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(sock_path)
    sock.sendall(req_str.encode("utf-8"))

    response_data = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_data += chunk
        except socket.timeout:
            break

    sock.close()
    return response_data.decode("utf-8", errors="replace").strip()


def send_http_metrics(sock_path, timeout=3.0):
    """发送 HTTP GET /metrics 请求"""
    req = "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(sock_path)
    sock.sendall(req.encode("utf-8"))

    response_data = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_data += chunk
        except socket.timeout:
            break

    sock.close()
    return response_data.decode("utf-8", errors="replace").strip()


def run_smoke_test(binary_path, timeout_sec):
    """主测试函数"""
    passed = 0
    failed = 0

    # 清理旧 socket
    if os.path.exists(DEFAULT_SOCKET):
        os.unlink(DEFAULT_SOCKET)
        log_info(f"清理旧 socket: {DEFAULT_SOCKET}")

    # 确保 /tmp/agentrt 目录存在
    os.makedirs(os.path.dirname(DEFAULT_SOCKET), exist_ok=True)

    # 启动 daemon
    log_info(f"启动 daemon: {binary_path}")
    env = os.environ.copy()
    env["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1:abort_on_error=0:log_path=/tmp/asan_monit_d"

    proc = subprocess.Popen(
        [binary_path],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=os.setsid,
    )

    try:
        # 等待 socket 就绪
        log_info(f"等待 socket 就绪 (超时 {timeout_sec}s)...")
        if not wait_for_socket(DEFAULT_SOCKET, timeout_sec):
            log_fail("Socket 未在超时时间内就绪")
            failed += 1
            # 读取 daemon 输出用于诊断
            stdout, stderr = proc.communicate(timeout=2)
            log_info(f"daemon stdout: {stdout.decode()[:500]}")
            log_info(f"daemon stderr: {stderr.decode()[:500]}")
            return passed, failed
        log_ok("Socket 就绪")
        passed += 1

        # 测试 1: health_check
        log_info("测试 1: health_check 请求")
        resp = send_jsonrpc(
            DEFAULT_SOCKET,
            "health_check",
            {"service_name": "monit_d"},
            req_id=1,
        )
        if not resp:
            log_fail("health_check: 空响应")
            failed += 1
        else:
            try:
                resp_json = json.loads(resp)
                if resp_json.get("jsonrpc") == "2.0" and "result" in resp_json:
                    result = resp_json["result"]
                    if "service_name" in result and "healthy" in result:
                        log_ok(f"health_check 成功: service={result.get('service_name')}, "
                               f"healthy={result.get('healthy')}")
                        passed += 1
                    else:
                        log_fail(f"health_check: 缺少字段: {resp}")
                        failed += 1
                elif "error" in resp_json:
                    log_fail(f"health_check 返回错误: {resp_json['error']}")
                    failed += 1
                else:
                    log_fail(f"health_check: 无效响应: {resp}")
                    failed += 1
            except json.JSONDecodeError:
                log_fail(f"health_check: JSON 解析失败: {resp[:200]}")
                failed += 1

        # 检查 daemon 是否仍在运行
        if proc.poll() is not None:
            log_fail("daemon 在 health_check 后崩溃!")
            stdout, stderr = proc.communicate(timeout=2)
            log_info(f"daemon stdout: {stdout.decode()[:500]}")
            log_info(f"daemon stderr: {stderr.decode()[:500]}")
            failed += 1
            return passed, failed
        else:
            log_ok("daemon 在 health_check 后仍存活")
            passed += 1

        # 测试 2: get_metrics
        log_info("测试 2: get_metrics 请求")
        resp = send_jsonrpc(
            DEFAULT_SOCKET,
            "get_metrics",
            {},
            req_id=2,
        )
        if not resp:
            log_fail("get_metrics: 空响应")
            failed += 1
        else:
            try:
                resp_json = json.loads(resp)
                if resp_json.get("jsonrpc") == "2.0" and "result" in resp_json:
                    result = resp_json["result"]
                    if isinstance(result, list):
                        log_ok(f"get_metrics 成功: 返回 {len(result)} 条指标")
                        passed += 1
                    else:
                        log_ok(f"get_metrics 成功: {str(result)[:100]}")
                        passed += 1
                elif "error" in resp_json:
                    log_fail(f"get_metrics 返回错误: {resp_json['error']}")
                    failed += 1
                else:
                    log_fail(f"get_metrics: 无效响应: {resp[:200]}")
                    failed += 1
            except json.JSONDecodeError:
                log_fail(f"get_metrics: JSON 解析失败: {resp[:200]}")
                failed += 1

        # 检查 daemon 是否仍在运行
        if proc.poll() is not None:
            log_fail("daemon 在 get_metrics 后崩溃!")
            stdout, stderr = proc.communicate(timeout=2)
            log_info(f"daemon stdout: {stdout.decode()[:500]}")
            log_info(f"daemon stderr: {stderr.decode()[:500]}")
            failed += 1
            return passed, failed
        else:
            log_ok("daemon 在 get_metrics 后仍存活")
            passed += 1

        # 测试 3: record_metric
        log_info("测试 3: record_metric 请求")
        resp = send_jsonrpc(
            DEFAULT_SOCKET,
            "record_metric",
            {
                "metric": {
                    "name": "smoke_test_counter",
                    "description": "Smoke test metric",
                    "type": 1,
                    "value": 42.0,
                }
            },
            req_id=3,
        )
        if not resp:
            log_fail("record_metric: 空响应")
            failed += 1
        else:
            try:
                resp_json = json.loads(resp)
                if resp_json.get("jsonrpc") == "2.0" and "result" in resp_json:
                    result = resp_json["result"]
                    if result.get("status") == "recorded":
                        log_ok(f"record_metric 成功: {result.get('metric_name')}")
                        passed += 1
                    else:
                        log_fail(f"record_metric: 意外结果: {resp}")
                        failed += 1
                elif "error" in resp_json:
                    log_fail(f"record_metric 返回错误: {resp_json['error']}")
                    failed += 1
                else:
                    log_fail(f"record_metric: 无效响应: {resp[:200]}")
                    failed += 1
            except json.JSONDecodeError:
                log_fail(f"record_metric: JSON 解析失败: {resp[:200]}")
                failed += 1

        # 检查 daemon 是否仍在运行
        if proc.poll() is not None:
            log_fail("daemon 在 record_metric 后崩溃!")
            stdout, stderr = proc.communicate(timeout=2)
            log_info(f"daemon stdout: {stdout.decode()[:500]}")
            log_info(f"daemon stderr: {stderr.decode()[:500]}")
            failed += 1
            return passed, failed
        else:
            log_ok("daemon 在 record_metric 后仍存活")
            passed += 1

        # 测试 4: Prometheus /metrics HTTP 端点
        log_info("测试 4: Prometheus /metrics HTTP 端点")
        resp = send_http_metrics(DEFAULT_SOCKET)
        if resp and ("200 OK" in resp or "200" in resp.split("\r\n")[0] if resp else False):
            log_ok("Prometheus /metrics 返回 HTTP 200")
            passed += 1
        elif resp and ("agentrt" in resp or "#" in resp):
            log_ok("Prometheus /metrics 返回指标数据")
            passed += 1
        else:
            log_fail(f"Prometheus /metrics: 异常响应: {resp[:200] if resp else '(空)'}")
            failed += 1

    finally:
        # 优雅关闭 daemon
        if proc.poll() is None:
            log_info("发送 SIGTERM 关闭 daemon...")
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                proc.wait(timeout=5)
                log_ok("daemon 已优雅关闭")
            except subprocess.TimeoutExpired:
                log_info("SIGTERM 超时，发送 SIGKILL...")
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                proc.wait()
                log_fail("daemon 未能在 5s 内优雅关闭")
        else:
            log_fail(f"daemon 已退出 (code={proc.returncode})")

        # 读取 daemon 输出
        try:
            stdout, stderr = proc.communicate(timeout=2)
            if stderr:
                stderr_text = stderr.decode()
                if "ERROR" in stderr_text or "ASAN" in stderr_text or "Sanitizer" in stderr_text:
                    log_info(f"daemon stderr (最后 500 字符):\n{stderr_text[-500:]}")
        except:
            pass

    return passed, failed


def main():
    parser = argparse.ArgumentParser(description="P0.20.8 端到端冒烟测试")
    parser.add_argument("--binary", default=DEFAULT_BINARY, help="monit_d 二进制路径")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="socket 就绪超时(秒)")
    args = parser.parse_args()

    print(f"\n{'='*60}")
    print(f"  P0.20.8 端到端冒烟测试 — monit_d daemon IPC 通信")
    print(f"{'='*60}\n")

    if not os.path.exists(args.binary):
        log_fail(f"二进制不存在: {args.binary}")
        sys.exit(1)

    passed, failed = run_smoke_test(args.binary, args.timeout)

    print(f"\n{'='*60}")
    print(f"  结果: {passed} 通过, {failed} 失败")
    print(f"{'='*60}\n")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
