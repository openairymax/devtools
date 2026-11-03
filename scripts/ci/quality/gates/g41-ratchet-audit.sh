#!/bin/bash
# Gate 41 棘轮漂移审计（0.1.20 方案 §9 Gate 41 / §4.2 A4）
#
# 审计 v16-loc-budget-baseline.txt 的 git 历史：数字 pin 只许降不许升；
# 上升（或新增数字 pin）的 commit 必须在 message 内带一行
# "RATCHET-JUSTIFY: <commit> <+N> <reason>"，缺行即红（fail-closed）。
# 锚点为本脚本首次入库 commit，锚点之前的漂移豁免；
# 环境变量 RATCHET_ANCHOR / RATCHET_REPO / RATCHET_BASELINE 可显式指定
# 锚点、被审 git 仓与基线文件（selfcheck 注入用）。
#
# 用法: g41-ratchet-audit.sh
# 退出码: 0=通过 1=棘轮漂移违例 2=环境错误
#
# 例外登记：同目录 g41-ratchet-waivers.txt，每行 "<sha(≥12)> <理由>"，用于
# 已推送、无法改写的历史 commit 消息缺行事故（内容仍须经实测复核）。豁免
# 文件本身受同等纪律约束：其最近一次改动 commit 必须带
# "RATCHET-WAIVER-JUSTIFY:" 行，否则整个文件不被采信（fail-closed）。
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE_NAME="v16-loc-budget-baseline.txt"

REPO_ROOT="${RATCHET_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -z "$REPO_ROOT" ]; then
    echo "g41: not a git repository" >&2
    exit 2
fi
BASELINE="${RATCHET_BASELINE:-${SCRIPT_DIR}/${BASELINE_NAME}}"

[ -f "$BASELINE" ] || { echo "g41: baseline not found: ${BASELINE}" >&2; exit 2; }
BASELINE_REL="$(realpath --relative-to="$REPO_ROOT" "$BASELINE")"
SELF_REL="$(realpath --relative-to="$REPO_ROOT" "${BASH_SOURCE[0]}")"

ANCHOR="${RATCHET_ANCHOR:-}"
if [ -z "$ANCHOR" ]; then
    ANCHOR="$(git -C "$REPO_ROOT" log --diff-filter=A --format=%H -1 -- "$SELF_REL")"
    if [ -z "$ANCHOR" ]; then
        echo "g41: anchor commit not found (script not committed?)" >&2
        exit 2
    fi
fi

pin_at() {
    git -C "$REPO_ROOT" show "${1}:${BASELINE_REL}" 2>/dev/null |
        sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=\([0-9][0-9]*\)[[:space:]]*$/\1 \2/p'
}

violations=0
WAIVERS="${RATCHET_WAIVERS:-${SCRIPT_DIR}/g41-ratchet-waivers.txt}"
waiver_shas=()
if [ -f "$WAIVERS" ]; then
    waiver_rel="$(realpath --relative-to="$REPO_ROOT" "$WAIVERS" 2>/dev/null || echo "$WAIVERS")"
    waiver_msg="$(git -C "$REPO_ROOT" log -1 --format=%B -- "$waiver_rel" 2>/dev/null || true)"
    if printf '%s\n' "$waiver_msg" | grep -q '^RATCHET-WAIVER-JUSTIFY:'; then
        while read -r w_sha w_rest; do
            case "${w_sha:-}" in ''|'#'*) continue ;; esac
            if [ -z "${w_rest:-}" ]; then
                echo "g41: waiver without reason: ${w_sha}" >&2
                exit 2
            fi
            waiver_shas+=("$w_sha")
        done < "$WAIVERS"
    else
        echo "g41: waivers file lacks a RATCHET-WAIVER-JUSTIFY commit; ignored" >&2
    fi
fi

waived() {
    local c="$1" w
    for w in ${waiver_shas[@]+"${waiver_shas[@]}"}; do
        case "$c" in "$w"*) return 0 ;; esac
    done
    return 1
}

mapfile -t commits < <(git -C "$REPO_ROOT" log --format=%H -- "$BASELINE_REL")

for ((i = 0; i < ${#commits[@]} - 1; i++)); do
    newer="${commits[$i]}"
    older="${commits[$((i + 1))]}"

    if git -C "$REPO_ROOT" merge-base --is-ancestor "$newer" "$ANCHOR"; then
        continue
    fi

    declare -A old_pins=()
    while read -r k v; do old_pins["$k"]="$v"; done < <(pin_at "$older")

    while read -r k v; do
        rose=0
        if [ -n "${old_pins[$k]:-}" ] && [ "$v" -gt "${old_pins[$k]}" ]; then
            rose=1
        elif [ -z "${old_pins[$k]:-}" ]; then
            rose=1
        fi
        if [ "$rose" -eq 1 ]; then
            if ! git -C "$REPO_ROOT" log -1 --format=%B "$newer" | grep -q '^RATCHET-JUSTIFY:'; then
                if waived "$newer"; then
                    echo "g41: WAIVED pin ${k} ${old_pins[$k]:-absent} -> ${v} in ${newer:0:12}"
                    continue
                fi
                echo "g41: FAIL pin ${k} rose ${old_pins[$k]:-absent} -> ${v} in ${newer:0:12} without RATCHET-JUSTIFY"
                violations=$((violations + 1))
            fi
        fi
    done < <(pin_at "$newer")
    unset old_pins
done

if [ "$violations" -gt 0 ]; then
    echo "g41: ${violations} violation(s)"
    exit 1
fi
echo "g41: ratchet audit clean over $(( ${#commits[@]} - 1 )) baseline revisions (anchor ${ANCHOR:0:12})"
exit 0
