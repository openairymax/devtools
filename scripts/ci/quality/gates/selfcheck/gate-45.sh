#!/bin/bash
# Gate 45 selfcheck 文档-代码一致性（0.1.20 方案 §9.3 / §9.1.1 Gate 45）
#
# 职责：验证 doc-consistency-check.sh 的判定矩阵——自指门禁的
#   审计器自身必须可证伪（红绿双向闭合，T4 纪律）。
#
# 用例：
#   T1 生产形态正向绿：真实清单 + 真实仓根全链 rc=0
#      （四级指针归拢后运行；归拢前 Q13 子检查红属预期语义）
#   T2 隔离全绿：tmp 根 + 合法引用 + 非空证据 → rc=0
#      （同时验证 A 正路径 / B 正路径 / C 隔离跳过三链路）
#   T3 幽灵引用 + 越界行号：缺文件引用与超窗口行号 → rc=1
#   T4 证据未验收：缺席条目与 0 字节证据 → rc=1
#   T5 环境错误 fail-closed：受辖文档缺席 / 清单缺席 → rc=2
#   T6 清单完整性：主脚本与两清单必须在册
#   T7 符号链接装配面（CI 数据集形态）：源码经 ln -s 挂进审计根时，
#      合法引用必须仍可解析 → rc=0；同面越界引用必须仍判负 → rc=1；
#      自环链接不得使遍历不终止
#
# 用法: selfcheck/gate-45.sh
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守
#
# T7 存在的原因（不可删）：T2 用真实目录构造隔离根，恰好绕过了
# os.walk 默认不跟随符号链接这一盲区。CI 把 agentrt 装配成符号链接，
# 同一份文档在本地 160/160 全绿、在 CI 判 66 处 file-not-found——
# 假红持续存在直到被取证通道看见（run 40961445385）。判据环境的装配
# 形态必须与被测面同构，否则门禁验的是自己的遍历能力。
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="${GATES_DIR}/doc-consistency-check.sh"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_rc() {
    local name="$1" want="$2" rc="$3"
    if [ "$rc" -eq "$want" ]; then
        log_ok "${name}: exit ${rc}（期望 ${want}）"
    else
        log_err "${name}: exit ${rc}，期望 ${want}"
        exit 1
    fi
}

# 隔离根构造器：src/foo.c(10 行) + doc.md + 两清单
# $1=根目录；$2=引用文本追加模式（ok|bad）
make_isolated_root() {
    local root="$1" mode="$2"
    mkdir -p "$root/src" "$root/docs"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        echo "line $i" >> "$root/src/foo.c"
    done
    {
        echo "# 隔离测试文档"
        echo "正路径引用 src/foo.c:8"
        if [ "$mode" = "bad" ]; then
            echo "幽灵引用 ghost.c:1"
            echo "越界引用 src/foo.c:99"
        fi
    } > "$root/docs/doc.md"
    echo "docs/doc.md" > "$root/docs-manifest.txt"
    echo "src/foo.c" > "$root/evidence-manifest.txt"
    echo "evidence-ok" > "$root/src/foo.c.evidence"
    echo "src/foo.c.evidence" >> "$root/evidence-manifest.txt"
}

run_iso() {
    local root="$1" manifest="$2"
    DOC_CONSISTENCY_ROOT="$root" \
    DOC_CONSISTENCY_DOCS="$root/${manifest}" \
    DOC_CONSISTENCY_EVIDENCE="$root/evidence-manifest.txt" \
    bash "$CHECK"
}

# ── T1: 生产形态正向绿（归拢后运行）─────────────────────────
section "T1: production manifests full-chain green"
rc=0
bash "$CHECK" >/dev/null 2>&1 || rc=$?
expect_rc "T1 production audit" 0 "$rc"

# ── T2: 隔离全绿（A 正路径 + B 正路径 + C 隔离跳过）─────────
section "T2: isolated all-green (A ok / B ok / C skip)"
T2="$TMP/t2"
make_isolated_root "$T2" ok
rc=0
run_iso "$T2" docs-manifest.txt >/dev/null 2>&1 || rc=$?
expect_rc "T2 isolated green" 0 "$rc"

# ── T3: 幽灵引用 + 越界行号 → rc=1 ──────────────────────────
section "T3: ghost ref + out-of-window line must map red"
T3="$TMP/t3"
make_isolated_root "$T3" bad
T3_OUT="$(run_iso "$T3" docs-manifest.txt 2>&1)" && rc=0 || rc=$?
expect_rc "T3 violations detected" 1 "$rc"
printf '%s\n' "$T3_OUT" | grep -q 'ghost.c:1' \
    || { log_err "T3 缺文件引用未被检出"; exit 1; }
printf '%s\n' "$T3_OUT" | grep -q 'foo.c:99' \
    || { log_err "T3 越界行号未被检出"; exit 1; }
log_ok "T3 两类违例均被点名"

# ── T4: 证据未验收（缺席 + 0 字节）→ rc=1 ───────────────────
section "T4: missing/empty evidence must map red"
T4="$TMP/t4"
make_isolated_root "$T4" ok
rm -f "$T4/src/foo.c.evidence"
: > "$T4/src/empty.evidence"
echo "src/empty.evidence" >> "$T4/evidence-manifest.txt"
T4_OUT="$(run_iso "$T4" docs-manifest.txt 2>&1)" && rc=0 || rc=$?
expect_rc "T4 evidence violations detected" 1 "$rc"
printf '%s\n' "$T4_OUT" | grep -q '证据文件缺席' \
    || { log_err "T4 缺席证据未被检出"; exit 1; }
printf '%s\n' "$T4_OUT" | grep -q '0 字节' \
    || { log_err "T4 空证据未被检出"; exit 1; }
log_ok "T4 缺席与 0 字节证据均未验收"

# ── T5: 环境错误 fail-closed → rc=2 ─────────────────────────
section "T5: missing governed doc / manifest = env error"
T5="$TMP/t5"
make_isolated_root "$T5" ok
rm -f "$T5/docs/doc.md"
rc=0
run_iso "$T5" docs-manifest.txt >/dev/null 2>&1 || rc=$?
expect_rc "T5a governed doc missing" 2 "$rc"

T5B="$TMP/t5b"
make_isolated_root "$T5B" ok
rc=0
run_iso "$T5B" no-such-manifest.txt >/dev/null 2>&1 || rc=$?
expect_rc "T5b docs manifest missing" 2 "$rc"

# ── T6: 清单完整性（真实 gates 目录）────────────────────────
section "T6: manifest integrity in real gates dir"
for f in doc-consistency-check.sh doc-consistency-docs.txt doc-evidence-files.txt; do
    [ -f "${GATES_DIR}/${f}" ] || { log_err "T6 缺件: ${f}"; exit 1; }
done
log_ok "T6 主脚本与两清单全部在册"

# ── T7: 符号链接装配面（CI 数据集形态）──────────────────────
# 被测根的源码目录以 ln -s 挂入，与 quality-gate.yml 的
# `ln -s "$GITHUB_WORKSPACE" "$UMB/agent-workload/agentrt"` 同构。
# 审计器若不跟随符号链接，整个 agentrt 子树对其不可见，合法引用会被
# 判成 file-not-found——这是假红，且真实目录布局下检不出来。
section "T7: symlink-assembled source dir must stay resolvable"
mk_real_dir() { # <物理源码目录>
    mkdir -p "$1"
    for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i" >> "$1/bar.c"; done
}
mk_link_root() { # <审计根> <追加引用>
    local root="$1" extra="$2"
    mkdir -p "$root/docs"
    ln -s "$REAL" "$root/src"
    {
        echo "# 符号链接装配测试文档"
        echo "合法引用 src/bar.c:8"
        [ -n "$extra" ] && echo "$extra"
    } > "$root/docs/doc.md"
    echo "docs/doc.md" > "$root/docs-manifest.txt"
    : > "$root/evidence-manifest.txt"
}

T7="$TMP/t7"; REAL="$TMP/t7_real"; mk_real_dir "$REAL"
mk_link_root "$T7" ""
rc=0
run_iso "$T7" docs-manifest.txt >/dev/null 2>&1 || rc=$?
expect_rc "T7a symlink ref resolvable" 0 "$rc"

# 反向闭合：同一符号链接面内的越界引用必须仍判负，否则 T7a 只是
# 「一律放行」的同义反复。
T7B="$TMP/t7b"; REAL="$TMP/t7b_real"; mk_real_dir "$REAL"
mk_link_root "$T7B" "越界引用 src/bar.c:99"
T7B_OUT="$(run_iso "$T7B" docs-manifest.txt 2>&1)" && rc=0 || rc=$?
expect_rc "T7b symlink out-of-window detected" 1 "$rc"
printf '%s\n' "$T7B_OUT" | grep -q 'bar.c:99' \
    || { log_err "T7b 符号链接面内的越界引用未被点名"; exit 1; }
log_ok "T7b 符号链接面内越界引用仍被点名（非放行）"

# 环守卫：自指符号链接不得让遍历不终止。超时即判失守。
T7C="$TMP/t7c"; REAL="$TMP/t7c_real"; mk_real_dir "$REAL"
mk_link_root "$T7C" ""
ln -s "$T7C" "$T7C/selfloop"
rc=0
timeout 30 bash -c 'DOC_CONSISTENCY_ROOT="'"$T7C"'" \
    DOC_CONSISTENCY_DOCS="'"$T7C"'/docs-manifest.txt" \
    DOC_CONSISTENCY_EVIDENCE="'"$T7C"'/evidence-manifest.txt" \
    bash "'"$CHECK"'"' >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 124 ]; then
    log_err "T7c 自环链接使遍历不终止（超时）"; exit 1
fi
expect_rc "T7c self-loop terminates" 0 "$rc"
log_ok "T7 符号链接装配面可判且环守卫成立"

section "Gate 45 selfcheck verdict"
log_ok "全部断言符合预期（T1-T7）"
exit 0
