#!/bin/bash
# Gate 43 形态面归属门禁（0.1.20 演化面归属登记，G-W6-1 机械执法）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 43：演化面归属，
#     守护 §5.1 / G-W6-1；判据：新增 *_ops_t 必须登记所属形态面，
#     未登记即红；fail-closed。
#   同方案 §2.4 归属纪律三条 + §5.1 准入三问：形态面归属是准入项，
#   不是文档装饰；INV-4。
#
# 断言（双向闭合，EV-4 纪律）：
#   A1 树内实存 ops 族 ⊆ 登记表（未登记即红——本门禁主判据）
#   A2 登记表 ⊆ 树内实存 ops 族（幽灵条目即红）
#   A3 每行归属字段 ∈ {user, platform, policy, evolution}
#
# 用法: facade-attribution-check.sh
# 环境变量（selfcheck 注入用）：FACADE_SCAN_ROOTS / FACADE_REGISTRY
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
SCAN_ROOTS="${FACADE_SCAN_ROOTS:-${PROJECT_ROOT}/agent-workload/agentrt:${PROJECT_ROOT}/agent-workload/products}"
REGISTRY="${FACADE_REGISTRY:-${SCRIPT_DIR}/facade-attribution.txt}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0

# ── 环境前置 ─────────────────────────────────────────────────
IFS=':' read -r -a ROOTS <<< "$SCAN_ROOTS"
for r in "${ROOTS[@]}"; do
    [ -d "$r" ] || { echo "扫描根缺失: $r"; exit 2; }
done
[ -f "$REGISTRY" ] || { echo "登记表缺失: $REGISTRY"; exit 2; }

# ── A1 前置：提取树内实存族集合 ──────────────────────────────
section "A1: tree ops families (unregistered = red)"
TREE_FAMILIES="$(for r in "${ROOTS[@]}"; do
    grep -rhoE 'static const [a-zA-Z_0-9]+_ops_t' "$r" 2>/dev/null || true
done | sed 's/^static const //' | sort -u)"
if [ -z "$TREE_FAMILIES" ]; then
    echo "树内零 ops 族实例，扫描口径异常: $SCAN_ROOTS"; exit 2
fi
TREE_COUNT="$(printf '%s\n' "$TREE_FAMILIES" | wc -l | tr -d ' ')"
log_ok "A1.pre 树内实存 ${TREE_COUNT} 族"

UNREGISTERED=0
while IFS= read -r fam; do
    [ -z "$fam" ] && continue
    if ! grep -qE "^${fam}\|" "$REGISTRY"; then
        log_err "A1 族未登记形态面归属: ${fam}"
        UNREGISTERED=$((UNREGISTERED + 1))
    fi
done <<< "$TREE_FAMILIES"
if [ "$UNREGISTERED" -eq 0 ]; then
    log_ok "A1 树内全部族已登记"
else
    VIOLATIONS=$((VIOLATIONS + UNREGISTERED))
fi

# ── A2: 登记表无幽灵条目 ────────────────────────────────────
section "A2: registry ghost entries (absent in tree = red)"
GHOSTS=0
REG_LINES="$(grep -vE '^\s*(#|$)' "$REGISTRY" || true)"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    fam="${line%%|*}"
    if ! printf '%s\n' "$TREE_FAMILIES" | grep -qxF "$fam"; then
        log_err "A2 登记表幽灵条目（树内零实例）: ${fam}"
        GHOSTS=$((GHOSTS + 1))
    fi
done <<< "$REG_LINES"
if [ "$GHOSTS" -eq 0 ]; then
    log_ok "A2 登记表无幽灵条目"
else
    VIOLATIONS=$((VIOLATIONS + GHOSTS))
fi

# ── A3: 归属字段四值词表 ────────────────────────────────────
section "A3: facade attribution vocabulary"
BAD_FACADE=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    fam="${line%%|*}"
    facade="${line#*|}"
    case "$facade" in
        user|platform|policy|evolution) ;;
        *)
            log_err "A3 非法归属值: ${fam} -> ${facade}"
            BAD_FACADE=$((BAD_FACADE + 1))
            ;;
    esac
done <<< "$REG_LINES"
if [ "$BAD_FACADE" -eq 0 ]; then
    log_ok "A3 归属字段全部合法"
else
    VIOLATIONS=$((VIOLATIONS + BAD_FACADE))
fi

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 43 形态面归属违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 43 形态面归属双向闭合通过"
exit 0
