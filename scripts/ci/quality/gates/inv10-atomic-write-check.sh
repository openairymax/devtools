#!/bin/bash
# INV-10 原子写静态门禁（0.1.21 L-4；方案 §19.2 L-4 判据段）
#
# 不变量：新增写文件点必须先声明类别（atomic / append / reviewed / exempt），
#   其中 atomic 类必须在本文件内有 airy_file_rename() 见证（tmp + rename 落地）。
#   未声明的写调用即判红；存量在清单中逐条显式列出（不按文件整包豁免）。
#
# 写点口径（只认"打开文件写句柄"的调用，不做数据流分析）：
#   fopen/freopen(...,"w|a…")、open/openat/open64(...,O_WRONLY|O_CREAT|O_TRUNC|O_APPEND)、
#   creat()、mkstemp/mkostemp/mkstemps()、tmpfile()。
#   局限（明示，不做静默假设）：模式串为变量的 fopen(…, mode) 不在静态可见范围；
#   跨行书写的 open() 标志位若不在同一行，需靠 reviewed 清单人工补齐。
#
# 清单格式（TAB 分隔，键 = 相对路径 + 归一化写行 SHA8，对行号漂移免疫）：
#   <relpath>\t<hash8>\t<category>\t<reason>
#   同一 (relpath,hash8) 可出现多次，按出现次数与源码逐一对齐（多重集比较）。
#   类别：atomic（同文件有 airy_file_rename 见证）/ append（仅追加日志）/
#         reviewed（人工评审为非持久化或另经同步保证）/ exempt（调试/终端输出，
#         不落业务文件）/ unclassified（未分类，恒判红）。
#
# 用法：
#   inv10-atomic-write-check.sh              判红/判绿（门禁用）
#   inv10-atomic-write-check.sh --emit       输出当前写点清单（供人工分类）
#   inv10-atomic-write-check.sh --self-test  判定矩阵自证（植入必红）
# 退出码: 0=通过 1=违例 2=环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# 自证用可注入根（默认生产根）
ROOT="${INV10_ROOT:-${PROJECT_ROOT}}"
INVENTORY="${INV10_INVENTORY:-${SCRIPT_DIR}/inv10-write-inventory.txt}"

AGENTRT="${ROOT}/agent-workload/agentrt"
CUPOLAS="${ROOT}/agent-workload/products/cupolas"
MODULES=(atoms commons daemons gateway heapstore protocols tools)

# 写点行匹配（ERE；perl 回溯可用时优先，便于排除 "r" 模式）
PATTERN='fopen[[:space:]]*\([^;]*"[wa][b+tex]*"|freopen[[:space:]]*\([^;]*"[wa][b+tex]*"|\bopen(at|64)?[[:space:]]*\([^;]*O_(WRONLY|CREAT|TRUNC|APPEND)|\bcreat[[:space:]]*\(|\bmkstemp[[:space:]]*\(|\bmkostemp[s]?[[:space:]]*\(|\btmpfile[[:space:]]*\('

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

# 归一化写行 → 8 位哈希（去前导缩进、压缩空白、去行尾注释）
line_hash() {
    local raw="$1"
    printf '%s' "$raw" \
        | sed -E 's,[[:space:]]*/\*.*\*/[[:space:]]*$,,; s,[[:space:]]*//.*$,,; s,^[[:space:]]+,,; s,[[:space:]]+, ,g' \
        | sha256sum | cut -c1-8
}

# 枚举写点：输出 "relpath<TAB>hash8<TAB>file:line<TAB>raw"
scan_sites() {
    local rel file num text
    local -a dirs=()
    local m
    for m in "${MODULES[@]}"; do
        if [ -d "$AGENTRT/$m" ]; then dirs+=("$AGENTRT/$m"); fi
    done
    if [ -d "$CUPOLAS" ]; then dirs+=("$CUPOLAS"); fi
    if [ "${#dirs[@]}" -eq 0 ]; then
        return 2
    fi
    while IFS= read -r file; do
        if [ -z "$file" ]; then continue; fi
        rel="${file#"$ROOT"/}"
        while IFS=: read -r num text; do
            case "$text" in
                *O_RDONLY*|*'"r"'*|*'"rb"'*) continue ;;  # 只读不算写点
            esac
            # 纯注释行（行首 /* 、// 、"* " 或 "*/"）不是写点：说明性文本里提到
            # 调用形态不构成可执行写路径。注意不能按单字符 '*' 判——解引用赋值
            # （如 `*out = fopen(dst, "wb");`）是真实写点，曾因该误判而漏检。
            case "${text#"${text%%[![:space:]]*}"}" in
                '/*'*|'//'*|'* '*) continue ;;
            esac
            printf '%s\t%s\t%s:%s\t%s\n' "$rel" "$(line_hash "$text")" "$rel" "$num" "$text"
        done < <(grep -nE "$PATTERN" "$file" 2>/dev/null || true)
    done < <(find "${dirs[@]}" -type f -name '*.c' 2>/dev/null | grep -v '/tests/' || true)
}

emit_inventory() {
    scan_sites | sort -t $'\t' -k1,1 -k2,2 | awk -F'\t' 'BEGIN{OFS="\t"}{print $1,$2,"unclassified","pending-review"}'
}

# 判定：多重集比较 + 类别合法性 + atomic 见证
judge() {
    local sites inv
    sites=$(scan_sites) || { log_err "source tree missing (fail-closed)"; return 2; }
    if [ ! -f "$INVENTORY" ]; then
        log_err "inventory not found: ${INVENTORY} (fail-closed)"
        return 2
    fi
    inv=$(grep -vE '^[[:space:]]*(#|$)' "$INVENTORY" || true)

    local rc=0
    # 1) 未声明写点：源码多重集 - 清单多重集
    local undeclared
    undeclared=$(comm -23 \
        <(printf '%s\n' "$sites" | cut -f1,2 | sort) \
        <(printf '%s\n' "$inv" | cut -f1,2 | sort))
    if [ -n "$undeclared" ]; then
        while IFS=$'\t' read -r p h; do
            local wit
            wit=$(printf '%s\n' "$sites" | awk -F'\t' -v p="$p" -v h="$h" '$1==p && $2==h {print $4; exit}')
            log_err "undeclared write point: ${p} (${h}) :: ${wit}"
        done <<< "$undeclared"
        log_err "→ 新增写文件点必须在 ${INVENTORY} 声明类别（atomic/append/reviewed/exempt）"
        rc=1
    fi
    # 2) 失效清单项：清单多重集 - 源码多重集
    local stale
    stale=$(comm -13 \
        <(printf '%s\n' "$sites" | cut -f1,2 | sort) \
        <(printf '%s\n' "$inv" | cut -f1,2 | sort))
    if [ -n "$stale" ]; then
        while IFS=$'\t' read -r p h; do
            log_err "stale inventory entry (site gone or changed): ${p} (${h})"
        done <<< "$stale"
        rc=1
    fi
    # 3) 类别合法性 + atomic 见证
    local cat bad=0
    while IFS=$'\t' read -r p h cat rest; do
        [ -z "${p:-}" ] && continue
        case "$cat" in
            atomic|append|reviewed|exempt) ;;
            *) log_err "invalid/unclassified category '${cat}' at ${p} (${h})"; bad=1 ;;
        esac
        if [ "$cat" = "atomic" ]; then
            if [ -f "${ROOT}/${p}" ] && ! grep -q 'airy_file_rename' "${ROOT}/${p}"; then
                log_err "atomic claim without airy_file_rename() witness: ${p} (${h})"
                bad=1
            fi
        fi
    done <<< "$inv"
    if [ "$bad" -eq 1 ]; then rc=1; fi

    if [ "$rc" -eq 0 ]; then
        local n
        n=$(printf '%s\n' "$inv" | grep -c . || true)
        log_ok "all ${n} write point(s) declared with valid category"
        log_ok "INV-10 atomic-write gate PASSED"
    else
        log_err "INV-10 atomic-write gate FAILED"
    fi
    return "$rc"
}

# 自证：fixture 树 + fixture 清单，五臂（绿/未声明/失效/未分类/atomic 无见证）
self_test() {
    section "INV-10 self-test"
    local tmp rc=0 fails=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/inv10-self.XXXXXX")
    local base="${tmp}/agent-workload/agentrt"
    local f="${base}/commons/demo.c"
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<'EOF'
#include <stdio.h>
static int save(const char *p) {
    FILE *fp = fopen(p, "w");
    fclose(fp);
    return 0;
}
EOF
    local h
    h=$(printf '%s' 'FILE *fp = fopen(p, "w");' | sha256sum | cut -c1-8)
    local inv="${tmp}/inv.txt"
    local self="${SCRIPT_DIR}/$(basename "$0")"

    expect() { # <name> <want_rc>
        local name="$1" want="$2" got=0
        INV10_ROOT="$tmp" INV10_INVENTORY="$inv" bash "$self" >/dev/null 2>&1 || got=$?
        if [ "$got" -eq "$want" ]; then
            log_ok "T: ${name} rc=${got} (expected ${want})"
        else
            log_err "T: ${name} rc=${got} (expected ${want})"
            fails=$((fails+1))
        fi
    }

    printf 'agent-workload/agentrt/commons/demo.c\t%s\treviewed\tfixture\n' "$h" > "$inv"
    expect "declared reviewed → green" 0

    printf 'agent-workload/agentrt/commons/demo.c\t%s\tatomic\tfixture\n' "$h" > "$inv"
    expect "atomic without rename witness → red" 1

    printf 'agent-workload/agentrt/commons/demo.c\t%s\tunclassified\tfixture\n' "$h" > "$inv"
    expect "unclassified → red" 1

    printf '' > "$inv"
    expect "undeclared write → red" 1

    printf 'agent-workload/agentrt/commons/demo.c\t%s\treviewed\tfixture\nagent-workload/agentrt/commons/gone.c\tdeadbeef\treviewed\tstale\n' "$h" > "$inv"
    expect "stale entry → red" 1

    # 新增第二处写点（未声明）→ 红；补齐后可绿
    printf 'static int save2(const char *p){FILE *f=fopen(p,"wb");return f?0:1;}\n' >> "$f"
    expect "second write point undeclared → red" 1

    if [ "$fails" -eq 0 ]; then
        log_ok "INV-10 self-test PASSED (6 arms)"
        return 0
    fi
    log_err "INV-10 self-test FAILED (${fails} arm(s))"
    return 1
}

case "${1:-}" in
    --emit)
        emit_inventory
        ;;
    --self-test)
        self_test
        ;;
    "")
        section "INV-10 Atomic-Write Gate (0.1.21 L-4)"
        judge
        ;;
    *)
        echo "usage: $0 [--emit|--self-test]" >&2
        exit 2
        ;;
esac
