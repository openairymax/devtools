#!/usr/bin/env python3
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# ttft_probe.py — 0.1.19 G37 性能探针（真实流式端点，非模拟）
#
# 测量口径（方案 §3.6.4）：
#   TTFT = 请求发出 → 首个非空 delta.content（连接已建立，排除 TCP 握手）
#   decode tps = (completion_tokens - 1) / (末个内容块 - 首个内容块)
#                无 usage 时退化为 content 块计数（首块为 prefill 产物）
#
# 证据契约 airy.g37.perf/1（由 g37-evidence-check.py 校验）：
#   schema / release / measured_at / probe_sha256 / machine / measurements
# 同一文件可追加不同 tier 的测量；落盘用 tmp + os.replace，避免半写。
# 本探针不做任何桩测量：端点不可达即失败，绝不产出估算值。
#
# 用法:
#   python3 scripts/ops/benchmark/ttft_probe.py \
#       --base-url http://127.0.0.1:11434/v1 \
#       --model qwen2.5-coder:7b --tier local_gpu --backend sycl \
#       --perf-mode lightweight \
#       --evidence scripts/ci/quality/gates/g37-perf-evidence.json
#
# 退出码: 0 = 测量完成；1 = 参数/响应格式错误；2 = 端点不可达

import argparse
import hashlib
import http.client
import json
import os
import platform
import socket
import statistics
import sys
import time
import urllib.parse
from datetime import datetime, timezone

SCHEMA = "airy.g37.perf/1"
TIERS = ("cloud", "local_gpu", "local_cpu")
MODES = ("full", "lightweight", "auto", "unknown")
PROMPT = ("Reply with exactly this sentence and nothing else: "
          "The quick brown fox jumps over the lazy dog.")


class ProbeError(Exception):
    """参数或响应格式不合约。"""


class UsageRejected(Exception):
    """端点不接受 stream_options，需降级重试。"""


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def read_text(path):
    with open(path, "r", encoding="utf-8") as stream:
        return stream.read().strip()


def split_url(base_url):
    parts = urllib.parse.urlsplit(base_url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ProbeError("invalid base url: %s" % base_url)
    path = (parts.path or "").rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions"
    if not path.startswith("/"):
        path = "/" + path
    return parts, path


def open_conn(parts, timeout):
    cls = (http.client.HTTPSConnection if parts.scheme == "https"
           else http.client.HTTPConnection)
    conn = cls(parts.hostname, parts.port, timeout=timeout)
    conn.connect()
    return conn


def build_headers(api_key):
    headers = {"Content-Type": "application/json",
               "Accept": "text/event-stream",
               "Connection": "close"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    return headers


def read_stream(resp, t0):
    first = None
    last = None
    blocks = 0
    tokens = None
    while True:
        line = resp.readline()
        if not line:
            break
        text = line.decode("utf-8", "replace").strip()
        if not text.startswith("data:"):
            continue
        data = text[5:].strip()
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except ValueError:
            continue
        if event.get("error"):
            raise ProbeError("stream error: %s" % event["error"])
        usage = event.get("usage") or {}
        if isinstance(usage.get("completion_tokens"), int):
            tokens = usage["completion_tokens"]
        for choice in event.get("choices") or []:
            content = (choice.get("delta") or {}).get("content")
            if not content:
                continue
            now = time.perf_counter()
            if first is None:
                first = now
            last = now
            blocks += 1
    if first is None:
        raise ProbeError("stream produced no content")
    window = max(last - first, 1e-9)
    count = tokens if tokens else blocks
    return {"ttft_ms": (first - t0) * 1000.0,
            "decode_tps": max(count - 1, 0) / window,
            "completion_tokens": count}


def stream_once(conn, path, payload, headers, use_usage):
    body = dict(payload)
    if use_usage:
        body["stream_options"] = {"include_usage": True}
    t0 = time.perf_counter()
    conn.request("POST", path, body=json.dumps(body), headers=headers)
    resp = conn.getresponse()
    if resp.status in (400, 422) and use_usage:
        resp.read()
        raise UsageRejected()
    if resp.status != 200:
        detail = resp.read(512).decode("utf-8", "replace").strip()
        raise ProbeError("HTTP %d: %s" % (resp.status, detail))
    return read_stream(resp, t0)


def measure_run(args, parts, path, payload, headers, use_usage):
    conn = open_conn(parts, args.timeout)
    try:
        return stream_once(conn, path, payload, headers, use_usage)
    finally:
        conn.close()


def machine_fp():
    uname = platform.uname()
    return {"system": uname.system, "release": uname.release,
            "machine": uname.machine, "node": uname.node,
            "processor": platform.processor() or uname.processor,
            "cpu_count": os.cpu_count(),
            "python": platform.python_version()}


def merge_evidence(path, record):
    data = {"schema": SCHEMA, "measurements": {}}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
        if data.get("schema") != SCHEMA:
            raise ProbeError("evidence schema mismatch: %s"
                             % data.get("schema"))
    merged = dict(data.get("measurements") or {})
    merged.update(record["measurements"])
    data.update(record)
    data["schema"] = SCHEMA
    data["measurements"] = merged
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(tmp, path)


def parse_args(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", "..", "..", ".."))
    default_evidence = os.path.join(here, "..", "..", "ci", "quality",
                                    "gates", "g37-perf-evidence.json")
    default_version = os.path.join(root, "agent-workload", "agentrt", "VERSION")
    parser = argparse.ArgumentParser(description="G37 streaming TTFT probe")
    parser.add_argument("--base-url", required=True,
                        help="OpenAI 兼容 base，如 http://host:11434/v1")
    parser.add_argument("--model", required=True)
    parser.add_argument("--tier", required=True, choices=TIERS)
    parser.add_argument("--backend", default="any",
                        help="实测后端: sycl/vulkan/cpu/cuda/metal/openai")
    parser.add_argument("--perf-mode",
                        default=os.environ.get("AIRY_PERF_MODE", "unknown"))
    parser.add_argument("--api-key-env", default="",
                        help="存放 API key 的环境变量名（不落证据）")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--max-tokens", type=int, default=64)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--evidence", default=default_evidence)
    parser.add_argument("--release-file", default=default_version)
    return parser.parse_args(argv)


def validate_args(args):
    if args.runs < 1:
        raise ProbeError("--runs must be >= 1")
    if args.warmup < 0:
        raise ProbeError("--warmup must be >= 0")
    if args.perf_mode not in MODES:
        raise ProbeError("invalid --perf-mode: %s" % args.perf_mode)
    if not args.backend or not all(c.isalnum() or c == "_"
                                   for c in args.backend):
        raise ProbeError("invalid --backend: %s" % args.backend)


def build_record(args, runs):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ttft = statistics.median(r["ttft_ms"] for r in runs)
    tps = statistics.median(r["decode_tps"] for r in runs)
    measurement = {"tier": args.tier, "backend": args.backend.lower(),
                   "model": args.model, "perf_mode": args.perf_mode,
                   "endpoint": args.base_url, "samples": len(runs),
                   "ttft_ms": round(ttft, 1), "decode_tps": round(tps, 2),
                   "runs": runs}
    return {"schema": SCHEMA, "release": read_text(args.release_file),
            "measured_at": stamp,
            "probe_sha256": sha256_file(os.path.abspath(__file__)),
            "machine": machine_fp(), "measurements": {args.tier: measurement}}


def main(argv):
    args = parse_args(argv)
    validate_args(args)
    parts, path = split_url(args.base_url)
    api_key = os.environ.get(args.api_key_env, "") if args.api_key_env else ""
    headers = build_headers(api_key)
    payload = {"model": args.model, "stream": True, "temperature": 0,
               "max_tokens": args.max_tokens,
               "messages": [{"role": "user", "content": PROMPT}]}
    use_usage = True
    for _ in range(args.warmup):
        try:
            measure_run(args, parts, path, payload, headers, use_usage)
        except UsageRejected:
            use_usage = False
            measure_run(args, parts, path, payload, headers, use_usage)
    runs = []
    for index in range(args.runs):
        try:
            result = measure_run(args, parts, path, payload, headers, use_usage)
        except UsageRejected:
            use_usage = False
            result = measure_run(args, parts, path, payload, headers, use_usage)
        runs.append(result)
        print("[run %d] ttft=%.1fms decode=%.2ftok/s tokens=%d"
              % (index + 1, result["ttft_ms"], result["decode_tps"],
                 result["completion_tokens"]))
    try:
        merge_evidence(args.evidence, build_record(args, runs))
    except OSError as exc:
        raise ProbeError("cannot write evidence: %s" % exc)
    print("[OK] evidence written: %s (tier=%s, median ttft=%.1fms, "
          "median decode=%.2ftok/s)"
          % (args.evidence, args.tier,
             statistics.median(r["ttft_ms"] for r in runs),
             statistics.median(r["decode_tps"] for r in runs)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ProbeError as exc:
        print("[ERR] %s" % exc, file=sys.stderr)
        sys.exit(1)
    except (OSError, socket.timeout, http.client.HTTPException) as exc:
        print("[ERR] endpoint unreachable: %s" % exc, file=sys.stderr)
        sys.exit(2)
