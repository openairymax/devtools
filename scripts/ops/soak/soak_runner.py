#!/usr/bin/env python3
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# soak_runner.py — C-7 可复跑长压测驱动（airy.c7.soak/1）

# 施工口径（方案 §18.1 C-7）：
#   时长、并发、请求分布、判定阈值全部固化（参数默认值 + c7-soak-budget.txt SSoT），
#   产出可复跑基线报告：P50/P95/P99、失败率、RSS 曲线、fd 数。真实端点直测，
#   端点不可达即失败，绝不产出估算值。报告分两层：摘要入库（gates/c7-soak-*.json），
#   逐请求明细经 --raw-out 落盘但不入库。verdict 由 gate c7-soak-gate.sh 依预算裁决，
#   本脚本只记录事实，不自判 PASS。
#
# 测量口径：
#   TTFT = 请求发出 → 首个非空 delta.content（SSE 流式，连接已建立）
#   total_ms = 请求发出 → 末个内容块（含 [DONE] 前全部内容）
#   decode_tps = (completion_tokens - 1) / (末块 - 首块)，无 usage 退化用块计数
#   资源采样 = /proc/<pid>/status VmRSS + /proc/<pid>/fd 计数，周期 --sample-interval-s
#
# 报告契约 airy.c7.soak/1（顶层键，gate 按此消费）：
#   schema / release / machine / profile / params / thresholds / summary / verdict
#   summary: requests_total/ok/failed, fail_rate, wall_duration_s,
#            ttft_ms{p50,p95,p99,max}, total_ms{p50,p95,p99},
#            decode_tps{p50,min}, tokens_total,
#            resources{samples_n, rss_mb{first,last,peak},
#                      fd_count{first,last,peak}}
#   verdict: "measured"（裁决权在 gate；本脚本不写 PASS/FAIL）
#
# 同名报告重跑覆盖（tmp + os.replace 原子落盘）；同文件可追加不同 profile。

import argparse
import http.client
import json
import os
import platform
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone

SCHEMA = "airy.c7.soak/1"

# 请求分布固化：每 profile 固定 prompt 池与生成长度，禁随机分布
# （同参数重跑必须同请求序列，基线才可复跑）。
PROFILES = {
    "local_cpu": {"prompts": 5, "max_tokens": 64, "temperature": 0.0},
    "cloud": {"prompts": 5, "max_tokens": 64, "temperature": 0.0},
}

PROMPTS = (
    "Summarize the CAP theorem in three sentences.",
    "Explain idempotency for HTTP POST with one example.",
    "Describe the difference between latency and throughput.",
    "State the guarantees of an exactly-once message queue.",
    "List three ways to bound tail latency under load.",
)


def parse_args(argv):
    """CLI 契约：见 --help；全部默认值即本版固化形态。"""
    here = os.path.dirname(os.path.abspath(__file__))
    default_budget = os.path.join(here, "c7-soak-budget.txt")
    default_version = os.path.abspath(os.path.join(
        here, "..", "..", "..", "..", "agent-workload", "agentrt", "VERSION"))
    parser = argparse.ArgumentParser(description="C-7 reproducible soak driver")
    parser.add_argument("--base-url", required=True,
                        help="OpenAI 兼容 base，如 http://127.0.0.1:21480/v1")
    parser.add_argument("--model", required=True)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--duration-s", type=int, default=1800,
                        help="压测墙钟（默认 1800 = gate:runtime 档）")
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--sample-interval-s", type=int, default=10)
    parser.add_argument("--timeout-s", type=float, default=120.0)
    parser.add_argument("--pid", type=int, default=0,
                        help="被压目标进程（RSS/fd 采样源；0 = 不采样）")
    parser.add_argument("--api-key-env", default="",
                        help="API key 环境变量名（不落报告）")
    parser.add_argument("--budget", default=default_budget)
    parser.add_argument("--report", required=True,
                        help="摘要报告落盘路径（airy.c7.soak/1）")
    parser.add_argument("--raw-out", default="",
                        help="逐请求明细路径（不入库）")
    parser.add_argument("--release-file", default=default_version)
    return parser.parse_args(argv)


def read_text(path):
    with open(path, "r", encoding="utf-8") as stream:
        return stream.read().strip()


def load_budget(path, profile):
    """读 SSoT 并按 profile 取阈值；返回 dict，键去掉档位前缀。"""
    prefix = profile + "."
    out = {}
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if not key.startswith(prefix):
                continue
            name = key[len(prefix):]
            try:
                out[name] = float(value) if "." in value else int(value)
            except ValueError:
                out[name] = value.strip()
    if not out:
        raise OSError("no budget keys for profile %s in %s" % (profile, path))
    return out


def machine_fp():
    uname = platform.uname()
    return {"system": uname.system, "release": uname.release,
            "machine": uname.machine, "node": uname.node,
            "cpu_count": os.cpu_count(),
            "python": platform.python_version()}


def probe_once(base_url, model, prompt, max_tokens, temperature,
               timeout_s, api_key):
    """单请求流式测量；返回 {ok, ttft_ms, total_ms, decode_tps,
    completion_tokens, error}。失败不抛异常，记录 error 由统计口径消化。"""
    record = {"ok": False, "ttft_ms": None, "total_ms": None,
              "decode_tps": None, "completion_tokens": 0, "error": ""}
    parts = urllib.parse.urlsplit(base_url)
    path = (parts.path or "").rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions"
    if parts.scheme not in ("http", "https") or not parts.hostname:
        record["error"] = "invalid base url"
        return record
    body = {"model": model, "stream": True, "temperature": temperature,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]}
    headers = {"Content-Type": "application/json",
               "Accept": "text/event-stream", "Connection": "close"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    cls = (http.client.HTTPSConnection if parts.scheme == "https"
           else http.client.HTTPConnection)
    conn = cls(parts.hostname, parts.port, timeout=timeout_s)
    t0 = time.perf_counter()
    try:
        conn.request("POST", path, body=json.dumps(body), headers=headers)
        resp = conn.getresponse()
        if resp.status != 200:
            record["error"] = "HTTP %d" % resp.status
            resp.read()
            return record
        first = None
        last = None
        blocks = 0
        tokens = 0
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
            usage = event.get("usage") or {}
            if isinstance(usage.get("completion_tokens"), int):
                tokens = usage["completion_tokens"]
            for choice in event.get("choices") or []:
                if (choice.get("delta") or {}).get("content"):
                    now = time.perf_counter()
                    if first is None:
                        first = now
                    last = now
                    blocks += 1
        if first is None:
            record["error"] = "stream produced no content"
            return record
        window = max(last - first, 1e-9)
        count = tokens if tokens else blocks
        record.update(ok=True, ttft_ms=(first - t0) * 1000.0,
                      total_ms=(last - t0) * 1000.0,
                      decode_tps=max(count - 1, 0) / window,
                      completion_tokens=count)
        return record
    except (OSError, http.client.HTTPException) as exc:
        record["error"] = str(exc)[:120]
        return record
    finally:
        conn.close()


def sample_resources(pid):
    """采样 /proc/<pid>；pid 无效返回 None。"""
    try:
        rss = 0.0
        with open("/proc/%d/status" % pid, "r", encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("VmRSS:"):
                    rss = float(line.split()[1]) / 1024.0
                    break
        fd_count = len(os.listdir("/proc/%d/fd" % pid))
        return {"rss_mb": round(rss, 1), "fd_count": fd_count}
    except OSError:
        return None


def quantile(sorted_values, q):
    """线性插值分位数；空表返回 None。"""
    if not sorted_values:
        return None
    pos = q * (len(sorted_values) - 1)
    low = int(pos)
    high = min(low + 1, len(sorted_values) - 1)
    frac = pos - low
    return sorted_values[low] * (1.0 - frac) + sorted_values[high] * frac


def run_soak(args, budget, api_key):
    """主循环：到 --duration-s 为止按并发驱动 probe_once，周期采样资源；
    返回 (summary, raw_records)。"""
    profile = PROFILES[args.profile]
    started = time.monotonic()
    deadline = started + args.duration_s
    raw = []
    lock = threading.Lock()

    def worker(index):
        slot = 0
        while time.monotonic() < deadline:
            prompt = PROMPTS[(index + slot) % len(PROMPTS)]
            record = probe_once(args.base_url, args.model, prompt,
                                profile["max_tokens"], profile["temperature"],
                                args.timeout_s, api_key)
            record["worker"] = index
            with lock:
                raw.append(record)
            slot += 1

    threads = [threading.Thread(target=worker, args=(i,))
               for i in range(max(args.concurrency, 1))]
    for thread in threads:
        thread.start()
    samples = []
    while any(thread.is_alive() for thread in threads):
        if args.pid:
            snap = sample_resources(args.pid)
            if snap:
                snap["t_s"] = round(time.monotonic() - started, 1)
                samples.append(snap)
        time.sleep(args.sample_interval_s)
    for thread in threads:
        thread.join()

    ok_rows = [r for r in raw if r["ok"]]
    total = len(raw)
    ttfts = sorted(r["ttft_ms"] for r in ok_rows)
    totals = sorted(r["total_ms"] for r in ok_rows)
    tps = sorted(r["decode_tps"] for r in ok_rows)
    rss_vals = [s["rss_mb"] for s in samples]
    fd_vals = [s["fd_count"] for s in samples]
    summary = {
        "requests_total": total,
        "requests_ok": len(ok_rows),
        "requests_failed": total - len(ok_rows),
        "fail_rate": round((total - len(ok_rows)) / total, 4) if total else 1.0,
        "wall_duration_s": round(time.monotonic() - started, 1),
        "ttft_ms": {"p50": round(quantile(ttfts, 0.50), 1),
                    "p95": round(quantile(ttfts, 0.95), 1),
                    "p99": round(quantile(ttfts, 0.99), 1),
                    "max": round(ttfts[-1], 1) if ttfts else None},
        "total_ms": {"p50": round(quantile(totals, 0.50), 1),
                     "p95": round(quantile(totals, 0.95), 1),
                     "p99": round(quantile(totals, 0.99), 1)},
        "decode_tps": {"p50": round(quantile(tps, 0.50), 2),
                       "min": round(tps[0], 2) if tps else None},
        "tokens_total": sum(r["completion_tokens"] for r in raw),
        "resources": {"samples_n": len(samples),
                      "rss_mb": {"first": rss_vals[0] if rss_vals else None,
                                 "last": rss_vals[-1] if rss_vals else None,
                                 "peak": max(rss_vals) if rss_vals else None},
                      "fd_count": {"first": fd_vals[0] if fd_vals else None,
                                   "last": fd_vals[-1] if fd_vals else None,
                                   "peak": max(fd_vals) if fd_vals else None}},
    }
    return summary, raw


def build_report(args, budget, summary):
    return {"schema": SCHEMA,
            "release": read_text(args.release_file),
            "measured_at": datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"),
            "machine": machine_fp(),
            "profile": args.profile,
            "params": {"base_url": args.base_url, "model": args.model,
                       "duration_s": args.duration_s,
                       "concurrency": args.concurrency,
                       "sample_interval_s": args.sample_interval_s,
                       "pid": args.pid},
            "thresholds": budget,
            "summary": summary,
            "verdict": "measured"}


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(tmp, path)


def main(argv):
    args = parse_args(argv)
    try:
        budget = load_budget(args.budget, args.profile)
        api_key = os.environ.get(args.api_key_env, "") if args.api_key_env else ""
        summary, raw = run_soak(args, budget, api_key)
        if summary["requests_ok"] == 0:
            raise OSError("endpoint unreachable: all %d requests failed"
                          % summary["requests_total"])
        write_json(args.report, build_report(args, budget, summary))
        if args.raw_out:
            write_json(args.raw_out, {"schema": SCHEMA, "records": raw})
    except OSError as exc:
        print("[ERR] %s" % exc, file=sys.stderr)
        return 2
    print("[OK] soak report: %s (profile=%s, wall=%.0fs, fail_rate=%.4f)"
          % (args.report, args.profile, summary["wall_duration_s"],
             summary["fail_rate"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
