#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# c7-soak-gate.sh — C-7 长压测基线门禁（airy.c7.soak/1 报告裁决）
#
# 用法:
#   c7-soak-gate.sh [--report <path>] --mode ci|runtime
#     --report  默认 ${SCRIPT_DIR}/c7-soak-baseline.json（随证据入库）
#     --mode ci      短档：时长 >= ci_min_duration_s（流水线档）
#     --mode runtime 长档：时长 >= runtime_min_duration_s（>=30min 基线档）
#
# 裁决全部由 c7-soak-budget.txt（SSoT）驱动，本脚本不内嵌任何阈值。
# 退出码（三值三码纪律）: 0=已验证达标 1=已验证违例 2=报告/环境错误
#                          3=无报告（未验证，不静默放行）
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPORT="${SCRIPT_DIR}/c7-soak-baseline.json"
DEFAULT_BUDGET="${SCRIPT_DIR}/../../../ops/soak/c7-soak-budget.txt"

report=""
mode=""
budget="${DEFAULT_BUDGET}"
while [ $# -gt 0 ]; do
    case "$1" in
        --report) report="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --budget) budget="$2"; shift 2 ;;
        *) echo "[ERR] unknown option: $1"; exit 2 ;;
    esac
done

if [ "$mode" != "ci" ] && [ "$mode" != "runtime" ]; then
    echo "[ERR] --mode must be ci or runtime"
    exit 2
fi
if [ -z "$report" ]; then
    report="${DEFAULT_REPORT}"
fi
if [ ! -f "$report" ]; then
    echo "[SKIP] soak report absent: ${report} (unverified, not silent-pass)"
    exit 3
fi
if [ ! -f "$budget" ]; then
    echo "[ERR] budget SSoT missing: ${budget}"
    exit 2
fi

exec python3 - "$report" "$mode" "$budget" <<'PYEOF'
import json
import sys

SCHEMA = "airy.c7.soak/1"
report_path, mode, budget_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(report_path, "r", encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, ValueError) as exc:
    print("[ERR] unreadable report: %s" % exc)
    sys.exit(2)
if data.get("schema") != SCHEMA:
    print("[ERR] schema mismatch: %r" % data.get("schema"))
    sys.exit(2)

profile = data.get("profile")
summary = data.get("summary") or {}
resources = summary.get("resources") or {}
budget = {}
with open(budget_path, "r", encoding="utf-8") as stream:
    prefix = str(profile) + "."
    for line in stream:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.startswith(prefix):
            try:
                budget[key[len(prefix):]] = float(value)
            except ValueError:
                pass

required = ("ci_min_duration_s", "runtime_min_duration_s", "max_fail_rate",
            "max_ttft_p50_ms", "max_ttft_p99_ms", "min_decode_tps_p50",
            "max_fd_peak", "max_rss_growth_mb")
missing = [key for key in required if key not in budget]
if missing:
    print("[ERR] budget %s missing keys for %s: %s"
          % (budget_path, profile, ",".join(missing)))
    sys.exit(2)

wall = float(summary.get("wall_duration_s") or 0.0)
fail_rate = float(summary.get("fail_rate") if summary.get("fail_rate")
                  is not None else 1.0)
ttft = summary.get("ttft_ms") or {}
tps = summary.get("decode_tps") or {}
fd_peak = resources.get("fd_count") or {}
rss = resources.get("rss_mb") or {}

min_key = "ci_min_duration_s" if mode == "ci" else "runtime_min_duration_s"
failures = []
if wall < budget[min_key]:
    failures.append("duration %.0fs < %s=%.0fs" % (wall, min_key,
                                                   budget[min_key]))
if fail_rate > budget["max_fail_rate"]:
    failures.append("fail_rate %.4f > max_fail_rate=%.4f"
                    % (fail_rate, budget["max_fail_rate"]))
p50 = ttft.get("p50")
if p50 is None or float(p50) > budget["max_ttft_p50_ms"]:
    failures.append("ttft p50 %s vs max_ttft_p50_ms=%.0f"
                    % (p50, budget["max_ttft_p50_ms"]))
p99 = ttft.get("p99")
if p99 is None or float(p99) > budget["max_ttft_p99_ms"]:
    failures.append("ttft p99 %s vs max_ttft_p99_ms=%.0f"
                    % (p99, budget["max_ttft_p99_ms"]))
tps_p50 = tps.get("p50")
if tps_p50 is None or float(tps_p50) < budget["min_decode_tps_p50"]:
    failures.append("decode p50 %s vs min_decode_tps_p50=%.1f"
                    % (tps_p50, budget["min_decode_tps_p50"]))
fd = fd_peak.get("peak")
if fd is None or float(fd) > budget["max_fd_peak"]:
    failures.append("fd peak %s vs max_fd_peak=%.0f"
                    % (fd, budget["max_fd_peak"]))
growth = 0.0
if rss.get("first") is not None and rss.get("last") is not None:
    growth = max(float(rss["last"]) - float(rss["first"]), 0.0)
if growth > budget["max_rss_growth_mb"]:
    failures.append("rss growth %.1fMB > max_rss_growth_mb=%.0fMB"
                    % (growth, budget["max_rss_growth_mb"]))
if mode == "runtime" and int(resources.get("samples_n") or 0) < 2:
    failures.append("resource curve too thin for runtime tier "
                    "(samples_n=%s)" % resources.get("samples_n"))

if failures:
    for item in failures:
        print("[FAIL] %s" % item)
    print("[FAIL] soak baseline violated budget (%s mode, profile=%s)"
          % (mode, profile))
    sys.exit(1)

print("[OK] soak baseline within budget (%s mode, profile=%s, "
      "wall=%.0fs, fail_rate=%.4f, ttft_p50=%s, tps_p50=%s)"
      % (mode, profile, wall, fail_rate, p50, tps_p50))
sys.exit(0)
PYEOF
