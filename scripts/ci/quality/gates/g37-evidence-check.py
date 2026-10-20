#!/usr/bin/env python3
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# g37-evidence-check.py — 0.1.19 G37 证据契约校验（只读，可单测）
#
# 输入：
#   预算 SSoT  g37-perf-budget.txt（tier|ttft_max_ms|decode_min_tps|backend|perf_mode|note）
#   证据文件   airy.g37.perf/1（由 ttft_probe.py 在真实端点测得）
# 判定：
#   1. 证据 schema / release 与 VERSION 一致；
#   2. probe_sha256 与当前探针字节一致（防手改证据）；
#   3. measured_at 未超过 --max-age-days（默认 180 天）；
#   4. 每个预算档都有实测，且 TTFT / decode tps / backend / perf_mode 达标。
#
# 退出码: 0 = 全部达标；1 = 契约或阈值违例；2 = 环境缺失（预算/证据/探针/版本）
# 注意：某档未测属于环境限制（rc 2），不是违例；已测但超阈值才是违例（rc 1）。

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

SCHEMA = "airy.g37.perf/1"
TIERS = ("cloud", "local_gpu", "local_cpu")
STAMP_FMT = "%Y-%m-%dT%H:%M:%SZ"


class EnvError(Exception):
    """环境缺失：无法做出判定。"""


def read_text(path):
    with open(path, "r", encoding="utf-8") as stream:
        return stream.read().strip()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def load_budget(path):
    tiers = {}
    try:
        text = read_text(path)
    except OSError as exc:
        raise EnvError("budget not readable: %s" % exc)
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = [field.strip() for field in line.split("|")]
        if len(fields) != 6:
            raise EnvError("budget line %d: expected 6 fields" % lineno)
        tier = fields[0]
        if tier not in TIERS:
            raise EnvError("budget line %d: unknown tier %s" % (lineno, tier))
        if tier in tiers:
            raise EnvError("budget line %d: duplicate tier %s" % (lineno, tier))
        if not fields[1].isdigit() or not fields[2].isdigit():
            raise EnvError("budget line %d: non-numeric threshold" % lineno)
        tiers[tier] = {"ttft_max_ms": int(fields[1]),
                       "decode_min_tps": int(fields[2]),
                       "backend": fields[3], "perf_mode": fields[4]}
    missing = [tier for tier in TIERS if tier not in tiers]
    if missing:
        raise EnvError("budget missing tiers: %s" % ",".join(missing))
    return tiers


def load_evidence(path):
    if not os.path.isfile(path):
        raise EnvError("evidence not found (not measured): %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, ValueError) as exc:
        raise EnvError("evidence unreadable: %s" % exc)


def check_meta(data, version, probe, max_age):
    problems = []
    if data.get("schema") != SCHEMA:
        problems.append("schema mismatch: %s" % data.get("schema"))
    if data.get("release") != version:
        problems.append("release %s != VERSION %s"
                        % (data.get("release"), version))
    if data.get("probe_sha256") != sha256_file(probe):
        problems.append("probe_sha256 does not match current probe")
    stamp = data.get("measured_at", "")
    try:
        when = datetime.strptime(stamp, STAMP_FMT).replace(tzinfo=timezone.utc)
    except ValueError:
        problems.append("measured_at malformed: %s" % stamp)
        return problems
    age_days = (datetime.now(timezone.utc) - when).total_seconds() / 86400.0
    if age_days < -1.0:
        problems.append("measured_at is in the future: %s" % stamp)
    elif age_days > max_age:
        problems.append("evidence is stale: %.0f days > %d days"
                        % (age_days, max_age))
    return problems


def check_tier(tier, budget, measured):
    problems = []
    label = "tier %s" % tier
    if not isinstance(measured, dict):
        return ["%s: measurement missing" % label], True
    for key in ("ttft_ms", "decode_tps", "backend", "perf_mode", "samples"):
        if key not in measured:
            problems.append("%s: missing field %s" % (label, key))
    if problems:
        return problems, False
    if measured["samples"] < 1:
        problems.append("%s: samples < 1" % label)
    if measured["ttft_ms"] > budget["ttft_max_ms"]:
        problems.append("%s: ttft %.1fms > %dms"
                        % (label, measured["ttft_ms"], budget["ttft_max_ms"]))
    if (budget["decode_min_tps"] > 0
            and measured["decode_tps"] < budget["decode_min_tps"]):
        problems.append("%s: decode %.2ftok/s < %dtok/s"
                        % (label, measured["decode_tps"],
                           budget["decode_min_tps"]))
    if (budget["backend"] != "any"
            and measured["backend"] != budget["backend"]):
        problems.append("%s: backend %s != required %s"
                        % (label, measured["backend"], budget["backend"]))
    if (budget["perf_mode"] != "any"
            and measured["perf_mode"] != budget["perf_mode"]):
        problems.append("%s: perf_mode %s != required %s"
                        % (label, measured["perf_mode"],
                           budget["perf_mode"]))
    return problems, False


def parse_args(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", "..", "..", "..", ".."))
    parser = argparse.ArgumentParser(description="G37 evidence contract check")
    parser.add_argument("--budget",
                        default=os.path.join(here, "g37-perf-budget.txt"))
    parser.add_argument("--evidence",
                        default=os.path.join(here, "g37-perf-evidence.json"))
    parser.add_argument("--probe",
                        default=os.path.join(here, "..", "..", "..", "ops",
                                             "benchmark", "ttft_probe.py"))
    parser.add_argument("--version-file",
                        default=os.path.join(root, "agent-workload", "agentrt",
                                             "VERSION"))
    parser.add_argument("--max-age-days", type=int, default=180)
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    budget = load_budget(args.budget)
    if not os.path.isfile(args.probe):
        raise EnvError("probe not found: %s" % args.probe)
    try:
        version = read_text(args.version_file)
    except OSError as exc:
        raise EnvError("VERSION not readable: %s" % exc)
    data = load_evidence(args.evidence)

    violations = check_meta(data, version, args.probe, args.max_age_days)
    limits = []
    for tier in TIERS:
        measured = (data.get("measurements") or {}).get(tier)
        problems, absent = check_tier(tier, budget[tier], measured)
        if absent:
            limits.extend(problems)
        else:
            violations.extend(problems)
            if not problems:
                print("[OK] %s: ttft %.1fms <= %dms, decode %.2ftok/s >= %d,"
                      " backend=%s, mode=%s"
                      % (tier, measured["ttft_ms"], budget[tier]["ttft_max_ms"],
                         measured["decode_tps"], budget[tier]["decode_min_tps"],
                         measured["backend"], measured["perf_mode"]))
    for problem in violations:
        print("[ERR] %s" % problem)
    for limit in limits:
        print("[WARN] %s" % limit)
    if violations:
        return 1
    if limits:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except EnvError as exc:
        print("[ERR] %s" % exc, file=sys.stderr)
        sys.exit(2)
