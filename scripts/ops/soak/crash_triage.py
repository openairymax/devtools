#!/usr/bin/env python3
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# crash_triage.py — C-7 崩溃归因证据采集器（airy.c7.crash/1）

# 施工口径（方案 §18.1 C-7）：
#   崩溃归因三选一结论（fixed / workaround / upstream）必须附证据。本工具
#   只采集与打包证据：末 200 行日志、core 文件与 core_pattern、journal 检索
#   命中、复现尝试记录。verdict 与 rationale 由操作者依证据给定（必填），
#   工具绝不自判归因——「严禁猜测」纪律在工具面的落点。
#
# 证据面（全部可缺省；缺席本身记入 error 字段，绝不伪造占位）：
#   log_tail    末 200 行（--log）
#   core        文件存在性 + core_pattern（--core；pattern 读 /proc）
#   journal     journalctl -g 检索命中行（--journal-grep，失败记 error）
#   repro       复现命令执行记录（--repro-command 可选；rc/存活/墙钟）
#   notes       操作者补充证据条目（--evidence 可多次，如文档锚点）
#
# 报告契约 airy.c7.crash/1（顶层键）：
#   schema / release / captured_at / machine / event / proc / exit_code /
#   signal / evidence{log_tail,core,journal,repro,notes} / verdict / rationale
#
# 落盘：tmp + os.replace 原子写，同名报告重跑覆盖。

import argparse
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA = "airy.c7.crash/1"
LOG_TAIL_LINES = 200
CORE_PATTERN_PATH = "/proc/sys/kernel/core_pattern"
VERDICTS = ("fixed", "workaround", "upstream")


def parse_args(argv):
    """CLI 契约：verdict/rationale 必填（操作者裁决），证据面按需给。"""
    parser = argparse.ArgumentParser(description="C-7 crash evidence packer")
    parser.add_argument("--event", required=True,
                        help="崩溃事件一句话描述（原始记录出处）")
    parser.add_argument("--proc", required=True, help="进程名")
    parser.add_argument("--log", default="",
                        help="进程日志路径（取末 %d 行）" % LOG_TAIL_LINES)
    parser.add_argument("--exit-code", type=int, default=None,
                        help="操作者记录的退出码")
    parser.add_argument("--signal", default="", help="如 SIGSEGV")
    parser.add_argument("--core", default="",
                        help="core 文件路径（存在性检查）")
    parser.add_argument("--journal-grep", default="",
                        help="journalctl -g 检索模式")
    parser.add_argument("--journal-lines", type=int, default=200)
    parser.add_argument("--journal-since", default="30 days ago")
    parser.add_argument("--repro-command", default="",
                        help="复现命令（可选；跑满 --repro-duration-s 未退"
                             "即记 survived，视为复现失败）")
    parser.add_argument("--repro-duration-s", type=int, default=60)
    parser.add_argument("--verdict", required=True, choices=VERDICTS)
    parser.add_argument("--rationale", required=True,
                        help="裁决理由（引用证据条目）")
    parser.add_argument("--evidence", action="append", default=[],
                        help="补充证据条目（可多次；coredumpctl/dmesg 等"
                             "在采集机上人工核验后的结论行）")
    parser.add_argument("--report", required=True)
    parser.add_argument("--release-file", default="",
                        help="VERSION 文件路径（缺省 release 为空串）")
    return parser.parse_args(argv)


def read_log_tail(path):
    """末 N 行；文件缺失/不可读取记 error，不抛。"""
    if not path:
        return {"path": "", "tail": "", "error": "no log path given"}
    try:
        with open(path, "rb") as stream:
            lines = stream.read().decode("utf-8", "replace").splitlines()
        return {"path": path, "error": "",
                "tail": "\n".join(lines[-LOG_TAIL_LINES:])}
    except OSError as exc:
        return {"path": path, "tail": "", "error": str(exc)[:120]}


def probe_core(path):
    """core 文件存在性 + 内核 core_pattern（留痕能力在位的证据）。"""
    try:
        with open(CORE_PATTERN_PATH, "r", encoding="utf-8") as stream:
            pattern = stream.read().strip()
    except OSError as exc:
        pattern = "unreadable: %s" % str(exc)[:80]
    if not path:
        return {"core_path": "", "core_exists": None,
                "core_pattern": pattern, "error": "no core path given"}
    return {"core_path": path, "core_exists": os.path.exists(path),
            "core_pattern": pattern, "error": ""}


def probe_journal(pattern, want_lines, since):
    """journalctl -g 检索；不可用（无权限/无 systemd）记 error 不抛。"""
    if not pattern:
        return {"grep": "", "lines": [], "error": "no journal grep given"}
    cmd = ["journalctl", "--no-pager", "-q", "-g", pattern,
           "--since", since, "-n", str(want_lines)]
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"grep": pattern, "lines": [], "error": str(exc)[:120]}
    if done.returncode != 0:
        errs = done.stderr.strip().splitlines()
        reason = errs[-1][:120] if errs else "rc=%d" % done.returncode
        return {"grep": pattern, "lines": [], "error": reason}
    return {"grep": pattern, "lines": done.stdout.splitlines()[-want_lines:],
            "error": ""}


def run_repro(command, duration_s):
    """复现尝试：跑满 duration_s 未退出 = survived（未崩溃，复现失败）；
    自然退出记 rc 与末 10 行输出。无命令时缺席入账。"""
    if not command:
        return {"command": "", "duration_s": 0, "rc": None, "survived": None,
                "stdout_tail": [], "stderr_tail": [],
                "error": "no repro command given"}
    try:
        done = subprocess.run(command, shell=True, capture_output=True,
                              text=True, timeout=duration_s or None)
        return {"command": command, "duration_s": duration_s,
                "rc": done.returncode, "survived": False,
                "stdout_tail": done.stdout.splitlines()[-10:],
                "stderr_tail": done.stderr.splitlines()[-10:], "error": ""}
    except subprocess.TimeoutExpired:
        return {"command": command, "duration_s": duration_s, "rc": None,
                "survived": True, "stdout_tail": [], "stderr_tail": [],
                "error": ""}


def build_report(args):
    release = ""
    if args.release_file:
        try:
            with open(args.release_file, "r", encoding="utf-8") as stream:
                release = stream.read().strip()
        except OSError:
            release = ""
    return {
        "schema": SCHEMA,
        "release": release,
        "captured_at": datetime.now(timezone.utc).isoformat(
            timespec="seconds"),
        "machine": {"node": platform.node(), "arch": platform.machine(),
                    "kernel": platform.release()},
        "event": args.event,
        "proc": args.proc,
        "exit_code": args.exit_code,
        "signal": args.signal,
        "evidence": {
            "log_tail": read_log_tail(args.log),
            "core": probe_core(args.core),
            "journal": probe_journal(args.journal_grep, args.journal_lines,
                                     args.journal_since),
            "repro": run_repro(args.repro_command, args.repro_duration_s),
            "notes": list(args.evidence),
        },
        "verdict": args.verdict,
        "rationale": args.rationale,
    }


def main(argv):
    args = parse_args(argv)
    report = build_report(args)
    tmp = args.report + ".tmp"
    with open(tmp, "w", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=1)
        stream.write("\n")
    os.replace(tmp, args.report)
    missing = [k for k, v in (
        ("log", args.log), ("core", args.core),
        ("journal", args.journal_grep), ("repro", args.repro_command))
        if not v]
    print("crash triage report: %s (verdict=%s)" % (args.report, args.verdict))
    if missing:
        print("evidence faces absent (recorded as absent, not faked): %s"
              % ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
