#!/bin/bash
# M3 (0.1.9 §4.2 持续横切 x-cutting-a): 函数名长度门禁
#
# 规则：生产函数名 ≤ 20 字节（"一般不超过 20 个字节"）。
# 豁免：test_/cmocka_ 测试函数（描述性命名）；DAEMON_DECLARE_* 宏；全大写宏名。
#
# 基线门禁（技术债台账）：function-name-baseline.txt 记录现存超长函数名。
#   - 扫描出的超长名若不在基线内 → fail-closed（阻止新增债务）
#   - 基线中已消失的名字 → 提示"已缩减"（批量重命名后台账自动收敛）
#   - FUNCTION_NAME_STRICT=1 → 任何超长名即失败（台账清零后的强门禁）
#   - --update-baseline → 以当前树重新生成基线（重命名批次落地后收敛台账）
#
# 用法:
#   function-name-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在新增超长函数名
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
MAX_NAME_LEN=20
BASELINE="$SCRIPT_DIR/function-name-baseline.txt"
UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }

scan_dirs=(
    "${PROJECT_ROOT}/agent-workload/agentrt/atoms"
    "${PROJECT_ROOT}/agent-workload/agentrt/commons"
    "${PROJECT_ROOT}/agent-workload/agentrt/cupolas"
    "${PROJECT_ROOT}/agent-workload/agentrt/daemons"
    "${PROJECT_ROOT}/agent-workload/agentrt/gateway"
    "${PROJECT_ROOT}/agent-workload/agentrt/heapstore"
    "${PROJECT_ROOT}/agent-workload/agentrt/protocols"
)

# 语句关键字打头 = 多行调用（return foo( ...）而非定义
STMT_KW='^(return|if|for|while|switch|do|else|goto|case|sizeof|break|continue|register|extern|defined|typeof|auto|volatile)([^A-Za-z_]|$)'

# 从 "path:line:content" 提取函数定义名（返回类型与函数名同行）。
# 输出 "path:line:funcname"，仅当名字长度超过 MAX_NAME_LEN。
extract_single_line() {
    awk -F: -v max="$MAX_NAME_LEN" -v kw="$STMT_KW" '
        {
            path = $1; lineno = $2;
            content = $0; sub(/^[^:]+:[0-9]+:[[:space:]]*/, "", content);
            if (content ~ /^static[[:space:]]+/) sub(/^static[[:space:]]+/, "", content);
            n = split(content, tok, /[[:space:]]+/);
            if (tok[1] ~ kw) next;            # 语句关键字打头 = 调用
            for (i = 1; i <= n; i++) {
                gsub(/^\*+/, "", tok[i]);      # 指针返回类型 *name( 取 name
                if (tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*\(/) {
                    fn = tok[i]; sub(/\(.*$/, "", fn);
                    if (fn !~ /[a-z]/) break;  # 全大写 = 宏名
                    if (length(fn) > max) printf "%s:%s:%s\n", path, lineno, fn;
                    break;
                }
            }
        }'
}

# 从 "path:line:content" 提取行首即函数名的定义（返回类型在上一行）。
extract_name_line() {
    awk -F: -v max="$MAX_NAME_LEN" '
        {
            path = $1; lineno = $2;
            content = $0; sub(/^[^:]+:[0-9]+:[[:space:]]*/, "", content);
            fn = content; sub(/\(.*$/, "", fn);
            if (fn !~ /[a-z]/) next;          # 全大写 = 宏名
            if (length(fn) > max) printf "%s:%s:%s\n", path, lineno, fn;
        }'
}

# 收集当前全部违规 "path:line:name"
collect_violations() {
    for dir in "${scan_dirs[@]}"; do
        [ -d "$dir" ] || continue
        grep -rHnP '^\s*(static\s+)?[a-zA-Z_][a-zA-Z0-9_]*(\s+[a-zA-Z_][a-zA-Z0-9_]*)*\s+[*]*\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\([^;]*$' \
             --include="*.c" "$dir" 2>/dev/null | extract_single_line
        grep -rHnP '^(?!(if|for|while|switch|return|sizeof|do|else|case|goto)\b)[a-zA-Z_][a-zA-Z0-9_]*\s*\([^;]*$' \
             --include="*.c" "$dir" 2>/dev/null | extract_name_line
    done | sort -u
}

# 当前违规（待豁免过滤前的原始列表，供基线生成）
TMP_VIOL="$(mktemp)"
trap 'rm -f "$TMP_VIOL"' EXIT
collect_violations | grep -Ev ':([^:]*:)?(test_|cmocka_|DAEMON_DECLARE_)' > "$TMP_VIOL" || true

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    awk -F: '{ print $NF }' "$TMP_VIOL" | sort -u > "$BASELINE"
    log_info "基线已更新：$(wc -l < "$BASELINE") 个超长函数名（function-name-baseline.txt）"
    exit 0
fi

log_info "函数名长度门禁（≤ ${MAX_NAME_LEN} 字节；基线台账 $( [ -f "$BASELINE" ] && wc -l < "$BASELINE" || echo 0 ) 项）"

if [ ! -f "$BASELINE" ]; then
    log_err "缺少基线文件 function-name-baseline.txt，请先运行 --update-baseline 生成"
    exit 1
fi

exit_code=0
new_count=0
known_count=0
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_VIOL" "$TMP_NEW"' EXIT

while IFS= read -r match; do
    [ -n "$match" ] || continue
    file="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    name="${rest#*:}"
    case "$name" in
        test_*|cmocka_*|DAEMON_DECLARE_*) continue ;;
    esac
    if grep -qxF "$name" "$BASELINE"; then
        known_count=$((known_count + 1))
    else
        new_count=$((new_count + 1))
        echo "  ${file#${PROJECT_ROOT}/}:${line}  ${name} (${#name} 字节)" >> "$TMP_NEW"
        exit_code=1
    fi
done < "$TMP_VIOL"

# 基线中已消失的名字 = 本批次缩减成效
TMP_SHRUNK="$(mktemp)"
trap 'rm -f "$TMP_VIOL" "$TMP_NEW" "$TMP_SHRUNK"' EXIT
awk -F: '{ print $NF }' "$TMP_VIOL" | sort -u > "$TMP_SHRUNK"
shrunk=0
while IFS= read -r base_name; do
    [ -n "$base_name" ] || continue
    if ! grep -qxF "$base_name" "$TMP_SHRUNK"; then
        shrunk=$((shrunk + 1))
    fi
done < "$BASELINE"

if [ "$new_count" -gt 0 ]; then
    log_err "新增超长函数名 ${new_count} 个（基线外，须重命名或更新台账）："
    cat "$TMP_NEW"
else
    log_ok "无新增超长函数名（现存台账债务 ${known_count} 项）"
fi
if [ "$shrunk" -gt 0 ]; then
    log_warn "台账较基线已缩减 ${shrunk} 项（重命名批次后请运行 --update-baseline 收敛）"
fi

if [ "${FUNCTION_NAME_STRICT:-0}" = "1" ] && [ "$known_count" -gt 0 ]; then
    log_err "STRICT 模式：现存 ${known_count} 项超长函数名债务未清零"
    exit 1
fi
exit "$exit_code"
