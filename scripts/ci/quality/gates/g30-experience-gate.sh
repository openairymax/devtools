#!/bin/bash
# 0.1.19 G30 体验门禁（TUI 建设方案 §10.3 / §10.4；台账 §0.8.G）
#
# 判据来源：`0.1.19-TUI建设方案.md` §10.3 G30——CLI 十二机制 golden ≥20/组、
#   命令面 8k~12k 带内、三 venue 共用 command 层；TUI 六域达标、budget.rs 常量
#   有界、主题三级降级、能力矩阵无空格、对标 golden ≥100、§6 交互细节 69 条
#   全落矩阵；TUI = fold(events) 纯投影。
#
# 可实证判据（本脚本强制）：
#   [T1] sdk/tui/src/golden 下 #[test] ≥ 100（Claude 对标 golden 下限）
#   [T2] §6 交互细节 69 条逐条在 sdk/tui/src 有落点引用（归一化 §6.x #n，
#        含 `#1/#2/#6` 组合形式；§6.11 无行为条目，不计入）
#   [T3] budget.rs 界常量 ≥ 34、无 0 / ::MAX 无界值、编译期断言块存在
#   [T4] 主题三级降级（TrueColor / Color256 / Basic + to_256 / to_basic）
#   [T5] 纯投影：present.rs 与 engine/fold.rs 无 client 依赖（零业务决策）
#   [T6] 六域锚点齐备（渲染引擎 / markdown / 组件库 / 键位 / 交互流 / 平台基建）
#   [T7] CLI 命令面 cmd+core+chat 行数 ∈ [8000, 12000]
#   [T8] 三 venue 共用 command 层：CLI_COMMANDS[] 唯一定义、分发点 ≥2、
#        sdk/tui 无自建命令表、TUI 以 cli_bin 委托 CLI 进程
#   [T9] sdk/tui 单文件 ≤ 800 行（基线棘轮，基线外新增超限即 FAIL）
#   [T10] CLI 十二机制 golden：cli-golden-twelve.sh 逐组执行 12 组离线 fixture
#        （0.1.20 方案 §4.1-A2）；二进制经 AIRY_CLI_BIN 提供（树外构建），
#        缺失计入环境告警（exit 2），fixture 缺失或断言失败即 FAIL。
#
# 语义：授权延期是"有据可查的已登记状态"，不是缺陷（不计 WARN）；未经登记
#   的缺口与过期延期均 FAIL——杜绝静默绿与永久红。
#
# 用法: g30-experience-gate.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 判据违例；2 = 环境错误（树缺失 / 工具缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AW_ROOT="${PROJECT_ROOT}/agent-workload"
TUI_DIR="${AW_ROOT}/sdk/tui"
CLI_DIR="${AW_ROOT}/agentrt/tools/airy_cli"
VERSION_FILE="${AW_ROOT}/agentrt/VERSION"
BASELINE="${SCRIPT_DIR}/g30-tui-filelen-baseline.txt"
HARNESS="${SCRIPT_DIR}/cli-golden-twelve.sh"

MAX_TUI_FILE_LINES=800
MIN_GOLDEN=100
MIN_BUDGET_CONSTS=34
CLI_MIN_LINES=8000
CLI_MAX_LINES=12000

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

FAILS=0
ENV_ERR=0

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

fail() {
    log_err "$*"
    FAILS=$((FAILS + 1))
}

need_tree() {
    if [ ! -d "$1" ]; then
        log_err "source tree not found: $1"
        exit 2
    fi
}

# [T1] Claude 对标 golden 下限
check_golden() {
    section "T1 TUI golden tests (>= ${MIN_GOLDEN})"
    local n
    n=$(grep -rh --include='*.rs' '#\[test\]' "$TUI_DIR/src/golden" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$n" -ge "$MIN_GOLDEN" ]; then
        log_ok "golden #[test] = ${n}"
    else
        fail "golden #[test] = ${n} < ${MIN_GOLDEN}"
    fi
}

# [T2] §6 交互细节 69 条落格
check_spec_items() {
    section "T2 §6 interaction details (69 items)"
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not found: §6 item coverage skipped"
        ENV_ERR=1
        return 0
    fi
    local out rc=0
    out=$(python3 - "$TUI_DIR/src" <<'PY'
import pathlib
import re
import sys

expected = {1: 4, 2: 7, 3: 6, 4: 8, 5: 5, 6: 5,
            7: 5, 8: 6, 9: 6, 10: 6, 12: 6, 13: 5}
root = pathlib.Path(sys.argv[1])
pat = re.compile(r'§6\.(\d+)\s*#(\d+)((?:\s*/\s*#\d+)*)')
seen = set()
for path in root.rglob('*.rs'):
    text = path.read_text(encoding='utf-8', errors='ignore')
    for m in pat.finditer(text):
        sec = int(m.group(1))
        items = [int(m.group(2))] + [int(x) for x in re.findall(r'#(\d+)', m.group(3))]
        for item in items:
            seen.add((sec, item))
missing = [(s, i) for s, n in expected.items()
           for i in range(1, n + 1) if (s, i) not in seen]
total = sum(expected.values())
if missing:
    print("missing: " + " ".join(f"§6.{s}#{i}" for s, i in missing))
    sys.exit(1)
print(f"covered {total}/{total}")
PY
    ) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "§6 item coverage: ${out}"
    else
        log_ok "§6 items: ${out}"
    fi
}

# [T3] budget.rs 界常量有界
check_budget() {
    section "T3 budget.rs bounded constants (>= ${MIN_BUDGET_CONSTS})"
    local f="$TUI_DIR/src/budget.rs"
    if [ ! -f "$f" ]; then
        fail "budget.rs not found: $f"
        return 0
    fi
    local n
    n=$(grep -cE '^[[:space:]]*pub(\(crate\))? const [A-Z][A-Z0-9_]*' "$f" || true)
    if [ "$n" -ge "$MIN_BUDGET_CONSTS" ]; then
        log_ok "bounded constants = ${n}"
    else
        fail "bounded constants = ${n} < ${MIN_BUDGET_CONSTS}"
    fi
    local unbounded
    unbounded=$(grep -nE '^[[:space:]]*pub(\(crate\))? const [A-Z][A-Z0-9_]*:[^=]+=[[:space:]]*(0|usize::MAX|u64::MAX|u32::MAX|u16::MAX|i64::MAX|i32::MAX|isize::MAX)[[:space:]]*;' "$f" || true)
    if [ -n "$unbounded" ]; then
        fail "unbounded constant value (0 or ::MAX):"
        echo "$unbounded" | sed 's/^/    /'
    fi
    if ! grep -q 'const _: () =' "$f"; then
        fail "compile-time assertion block (const _: () = { ... }) missing in budget.rs"
    fi
}

# [T4] 主题三级降级
check_theme() {
    section "T4 theme three-level degradation"
    local f="$TUI_DIR/src/style/depth.rs"
    if [ ! -f "$f" ]; then
        fail "style/depth.rs not found: $f"
        return 0
    fi
    local sym
    for sym in 'enum ColorDepth' 'TrueColor' 'Color256' 'Basic' 'fn to_256' 'fn to_basic'; do
        if ! grep -q "$sym" "$f"; then
            fail "depth.rs missing: ${sym}"
        fi
    done
    log_ok "ColorDepth{TrueColor,Color256,Basic} + to_256/to_basic present"
}

# 模块路径解析：src/x.rs 与 src/x/mod.rs 等价（模块可按职责拆成目录）
mod_path() {
    local rel="$1"
    if [ -f "$TUI_DIR/src/$rel.rs" ]; then
        echo "$TUI_DIR/src/$rel.rs"
    elif [ -f "$TUI_DIR/src/$rel/mod.rs" ]; then
        echo "$TUI_DIR/src/$rel/mod.rs"
    fi
}

# [T5] TUI = fold(events) 纯投影
# 取证面为「投影单元全集」：模块拆分成目录后，任一子文件混入 client
# 依赖都算违规，不得因拆分而缩窄检查范围。
check_purity() {
    section "T5 pure projection (present + fold)"
    local f hit files=()
    if [ -d "$TUI_DIR/src/present" ]; then
        while IFS= read -r f; do files+=("$f"); done \
            < <(find "$TUI_DIR/src/present" -name '*.rs' | sort)
    else
        files+=("$TUI_DIR/src/present.rs")
    fi
    files+=("$TUI_DIR/src/engine/fold.rs")
    for f in "${files[@]}"; do
        if [ ! -f "$f" ]; then
            fail "projection file not found: ${f}"
            continue
        fi
        hit=$(grep -n 'crate::client' "$f" || true)
        if [ -n "$hit" ]; then
            fail "client dependency in pure projection ${f}:"
            echo "$hit" | sed 's/^/    /'
        fi
    done
    log_ok "present/ + engine/fold.rs carry no client dependency (${#files[@]} files)"
}

# [T6] 六域锚点
check_domains() {
    section "T6 six-domain anchors"
    local d
    for d in engine markdown panels app; do
        if [ ! -d "$TUI_DIR/src/$d" ]; then
            fail "domain anchor missing: src/${d}/"
        fi
    done
    local f p
    for f in keys engine/probe engine/notify engine/sanitize \
             engine/term style/depth; do
        p=$(mod_path "$f")
        if [ -z "$p" ]; then
            fail "domain anchor missing: src/${f}"
        fi
    done
    log_ok "render/markdown/components/keys/interaction/platform anchors present"
}

# [T7] 命令面行数带
check_cmd_surface() {
    section "T7 CLI command surface (${CLI_MIN_LINES}..${CLI_MAX_LINES} lines)"
    local dirs=() d
    for d in cmd core chat; do
        if [ -d "$CLI_DIR/src/$d" ]; then
            dirs+=("$CLI_DIR/src/$d")
        else
            fail "CLI surface dir missing: src/${d}/"
        fi
    done
    if [ "${#dirs[@]}" -eq 0 ]; then
        return 0
    fi
    local n
    n=$(find "${dirs[@]}" -type f -name '*.c' -print0 | xargs -0 -r cat | wc -l | tr -d ' ')
    if [ "$n" -ge "$CLI_MIN_LINES" ] && [ "$n" -le "$CLI_MAX_LINES" ]; then
        log_ok "command surface = ${n} lines (in band)"
    else
        fail "command surface = ${n} lines (out of band ${CLI_MIN_LINES}..${CLI_MAX_LINES})"
    fi
}

# [T8] 三 venue 共用 command 层
check_single_owner() {
    section "T8 single command table (three venues)"
    local defs calls tui_refs
    defs=$(grep -rE '^[[:space:]]*const cli_command_t CLI_COMMANDS\[\][[:space:]]*=' "$CLI_DIR/src" | wc -l | tr -d ' ' || true)
    if [ "$defs" -ne 1 ]; then
        fail "CLI_COMMANDS[] definitions = ${defs} (must be 1)"
    else
        log_ok "CLI_COMMANDS[] defined once"
    fi
    calls=$(grep -rn 'cli_dispatch_command(' "$CLI_DIR/src" \
        | grep -v 'int cli_dispatch_command' | wc -l | tr -d ' ' || true)
    if [ "$calls" -ge 2 ]; then
        log_ok "dispatch call sites = ${calls} (interactive + one-shot)"
    else
        fail "dispatch call sites = ${calls} < 2 (three venues need one command layer)"
    fi
    tui_refs=$(grep -rn 'CLI_COMMANDS' "$TUI_DIR/src" | wc -l | tr -d ' ' || true)
    if [ "$tui_refs" -ne 0 ]; then
        fail "sdk/tui owns a parallel command table (${tui_refs} refs)"
    fi
    if grep -q 'cli_bin' "$TUI_DIR/src/entry.rs"; then
        log_ok "TUI delegates to CLI process (cli_bin)"
    else
        fail "entry.rs no cli_bin delegation: TUI bypasses the shared command layer"
    fi
}

# [T9] 单文件行数基线棘轮
scan_tui_over_limit() {
    find "$TUI_DIR/src" -type f -name '*.rs' -print0 \
        | xargs -0 -r wc -l 2>/dev/null \
        | awk -v max="$MAX_TUI_FILE_LINES" -v root="$TUI_DIR/src/" '
            $2 == "total" { next }
            $1 > max { p = $2; sub("^" root, "", p); printf "%s %d\n", p, $1 }' \
        | sort
}

check_file_length() {
    section "T9 TUI file length (<= ${MAX_TUI_FILE_LINES} lines/file, baseline ratchet)"
    local cur
    cur=$(scan_tui_over_limit)
    if [ "$UPDATE_BASELINE" -eq 1 ]; then
        {
            echo "# 0.1.19 G30 TUI single-file length baseline (<= ${MAX_TUI_FILE_LINES} lines/file)"
            echo "# Paths relative to agent-workload/sdk/tui/src/; new over-limit files outside this list FAIL."
            if [ -n "$cur" ]; then
                echo "$cur" | awk '{ print $1 }' | sort -u
            fi
        } > "$BASELINE"
        log_info "baseline updated: $(grep -cvE '^[[:space:]]*(#|$)' "$BASELINE") entries (g30-tui-filelen-baseline.txt)"
        exit 0
    fi
    if [ ! -f "$BASELINE" ]; then
        log_err "baseline not found: ${BASELINE} (run --update-baseline to seed)"
        exit 2
    fi
    local known=0 new=0 path lines
    while read -r path lines; do
        [ -n "$path" ] || continue
        if grep -qxF "$path" "$BASELINE"; then
            known=$((known + 1))
            log_warn "baseline debt (${lines} lines): ${path}"
        else
            new=$((new + 1))
            log_err "new over-limit file (${lines} lines): ${path}"
        fi
    done <<< "$cur"
    if [ "$new" -gt 0 ]; then
        fail "new over-limit TUI files = ${new} (split or record in ledger)"
    else
        log_ok "no new over-limit files (baseline debt ${known})"
    fi
}

# [T10] CLI 十二机制 golden（0.1.20 方案 §4.1-A2：harness 逐组强制执行）
check_cli_golden() {
    section "T10 CLI twelve-mechanism golden (cli-golden-twelve)"
    if [ ! -x "$HARNESS" ]; then
        fail "harness missing or not executable: ${HARNESS}"
        return 0
    fi
    if [ -z "${AIRY_CLI_BIN:-}" ] || [ ! -x "${AIRY_CLI_BIN:-}" ]; then
        ENV_ERR=$((ENV_ERR + 1))
        log_warn "AIRY_CLI_BIN unset or not executable: build airy_cli out-of-tree, export AIRY_CLI_BIN=<path>"
        return 0
    fi
    local rc=0
    bash "$HARNESS" "$AIRY_CLI_BIN" || rc=$?
    if [ "$rc" -eq 2 ]; then
        ENV_ERR=$((ENV_ERR + 1))
        log_warn "harness environment error (rc=2): ${HARNESS}"
    elif [ "$rc" -ne 0 ]; then
        fail "twelve-mechanism golden FAILED (rc=${rc})"
    else
        log_ok "twelve-mechanism golden PASS (12/12)"
    fi
}

need_tree "$TUI_DIR"
need_tree "$CLI_DIR"
if [ ! -f "$VERSION_FILE" ]; then
    log_err "version file not found: ${VERSION_FILE}"
    exit 2
fi

section "0.1.19 G30 experience gate"

check_golden
check_spec_items
check_budget
check_theme
check_purity
check_domains
check_cmd_surface
check_single_owner
check_file_length
check_cli_golden

section "0.1.19 G30 experience gate"
if [ "$FAILS" -gt 0 ]; then
    log_err "G30 experience gate FAILED (${FAILS} violation(s))"
    exit 1
fi
if [ "$ENV_ERR" -gt 0 ]; then
    log_warn "G30 experience gate PASSED with environment warnings (manual review)"
    exit 2
fi
log_ok "0.1.19 G30 experience gate PASSED"
exit 0
