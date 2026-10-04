#!/bin/bash
# 0.1.19 G26 重复率门禁（方案 §6.3 G26：3% ~ 5%）
#
# 口径（与 G24 文件行数门禁同源）：agentrt/ 八模块下 C/C++ 生产码，排除
#   tests/ 与 third_party/；归一化（剥离注释、压空白、丢空行）后以连续
#   DUP_WINDOW 行窗口做 SHA-1 指纹，出现 ≥ 2 次即克隆组，副本行计入重复行。
# 判据（阈值一律取自 thresholds.conf —— 唯一权威源，本文件不内联字面量）：
#   dup_lines > 基线           → FAIL（新增重复，fail-closed 阻断）
#   rate > DUP_TARGET          → WARN（高于阶梯目标，棘轮持平）
#   rate ≤ DUP_TARGET          → PASS（达成阶梯目标）
# 基线：g26-clone-baseline.txt，首行数值为 dup_lines（归一化重复行绝对值）；
#   每批次收敛后以 --update-baseline 下压，只降不升。
# 口径依据：删除独特死码使分母收缩、rate 被动抬升而重复债务不变——以 rate
#   为棘轮量会误伤删除类消解批次（L4/L5 主线即删除冗余），故棘轮量取重复
#   行绝对值 dup_lines；rate 保留为阶梯目标与展示指标。
# 用法: clone-check.sh [--update-baseline]
# 退出码: 0 = 通过；2 = 警告（高于目标，未超基线）；1 = 超基线（新增重复）；
#         3 = 环境错误（树/基线/检测器缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
BASELINE="$SCRIPT_DIR/g26-clone-baseline.txt"
EXEMPTIONS="$SCRIPT_DIR/g26-clone-exemptions.txt"
DETECTOR="$SCRIPT_DIR/../src/clone_detect.py"
# shellcheck source=../thresholds.conf
source "$SCRIPT_DIR/../thresholds.conf"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 3
fi
if [ ! -f "$DETECTOR" ]; then
    log_err "clone detector not found: ${DETECTOR}"
    exit 3
fi
if [ ! -f "$EXEMPTIONS" ]; then
    log_err "clone exemptions list not found: ${EXEMPTIONS}"
    exit 3
fi
if ! command -v python3 >/dev/null 2>&1; then
    log_err "python3 not found (clone detector requires it)"
    exit 3
fi

# 采集当前重复率（检测器仅在 --json-only 下输出单行 JSON，便于解析；
#   架构镜像豁免清单随命令行传入，门禁脚本不做内联豁免）
JSON="$(python3 "$DETECTOR" --root "$AGENTRT" --window "$DUP_WINDOW" \
        --target "$DUP_TARGET" --ceiling "$DUP_CEIL" \
        --exemptions "$EXEMPTIONS" --json-only)" || {
    log_err "clone detector execution failed"
    exit 3
}
RATE="$(printf '%s' "$JSON" | python3 -c \
    'import json,sys; print("%.4f" % json.load(sys.stdin)["overall_rate"])')" || {
    log_err "failed to parse clone detector output"
    exit 3
}
DUP_LINES="$(printf '%s' "$JSON" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["dup_lines"])')" || {
    log_err "failed to parse clone detector output"
    exit 3
}

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    printf '# 0.1.19 G26 clone baseline (dup_lines, absolute ratchet)\n%s\n' \
        "$DUP_LINES" > "$BASELINE"
    log_info "基线已更新：dup_lines=${DUP_LINES}（g26-clone-baseline.txt）"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    log_err "baseline not found: ${BASELINE} (run --update-baseline to seed)"
    exit 3
fi
BASE_DUP="$(grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' \
            | head -n1 | tr -d '[:space:]')"
if ! printf '%s' "$BASE_DUP" | grep -qE '^[0-9]+$'; then
    log_err "invalid baseline value: '${BASE_DUP}'"
    exit 3
fi

section "0.1.19 G26 clone gate (target<${DUP_TARGET}%, baseline<=${BASE_DUP} dup_lines)"
printf '%s\n' "$JSON"

over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

if [ "$DUP_LINES" -gt "$BASE_DUP" ]; then
    log_err "重复行 ${DUP_LINES} 超基线 ${BASE_DUP}（新增重复，fail-closed 阻断）"
    log_err "0.1.19 G26 clone gate FAILED"
    exit 1
fi

if over "$RATE" "$DUP_TARGET"; then
    log_warn "重复率 ${RATE}% 高于目标 ${DUP_TARGET}%，dup_lines ${DUP_LINES} 未超基线 ${BASE_DUP}（棘轮持平）"
    log_warn "0.1.19 G26 clone gate WARN"
    exit 2
fi

log_ok "重复率 ${RATE}% ≤ 目标 ${DUP_TARGET}%（达成）"
log_ok "0.1.19 G26 clone gate PASSED"
exit 0
