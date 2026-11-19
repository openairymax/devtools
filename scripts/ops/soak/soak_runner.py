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
import json
import os
import sys
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
    raise NotImplementedError("C-7 implementation slice")


def load_budget(path, profile):
    """读 SSoT 并按 profile 取阈值；返回 dict，键去掉档位前缀。"""
    raise NotImplementedError("C-7 implementation slice")


def machine_fp():
    raise NotImplementedError("C-7 implementation slice")


def probe_once(base_url, model, prompt, max_tokens, temperature,
               timeout_s, api_key):
    """单请求流式测量；返回 {ok, ttft_ms, total_ms, decode_tps,
    completion_tokens, error}。"""
    raise NotImplementedError("C-7 implementation slice")


def sample_resources(pid):
    """采样 /proc/<pid>；pid 无效返回 None。"""
    raise NotImplementedError("C-7 implementation slice")


def quantile(sorted_values, q):
    """线性插值分位数；空表返回 None。"""
    raise NotImplementedError("C-7 implementation slice")


def run_soak(args, budget, api_key):
    """主循环：到 --duration-s 为止按并发驱动 probe_once，周期采样资源；
    返回 (summary, raw_records)。"""
    raise NotImplementedError("C-7 implementation slice")


def build_report(args, budget, summary):
    raise NotImplementedError("C-7 implementation slice")


def write_json(path, data):
    raise NotImplementedError("C-7 implementation slice")


def main(argv):
    args = parse_args(argv)
    try:
        budget = load_budget(args.budget, args.profile)
        api_key = os.environ.get(args.api_key_env, "") if args.api_key_env else ""
        summary, raw = run_soak(args, budget, api_key)
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
