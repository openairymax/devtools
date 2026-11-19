#!/bin/bash
# L-9 补丁回流门禁（0.1.21 §16.19.6 判据；gate:ci）
#
# 判据：存在未回流的已验证补丁即判红；回流后 §16.13 每项可指到 commit。
# 命令化口径（可判定部分）：
#   1. 清单中每个 done 项必须给出仓库与 commit，且该 commit 在仓库 HEAD 的
#      祖先链上（可 cat-file -e + merge-base --is-ancestor 复核）；
#   2. 每个 na 项必须给出不适用理由（空理由判红——「不适用」不是免检）；
#   3. 工作区不得残留补丁副本（*.patch / *.rej / *.orig / *.bak），
#      否则视为「副本有补丁而仓内无提交」的可观测形态。
# 边界（明示，不静默假设）：285H / 隔离栈的库外副本无法从 CI 机读取，
#   本门禁只判定仓内回流链与本地残留；库外副本核对属人工审计，记于
#   §16.19.6 回执，不由本脚本冒充已判定。
#
# 用法：
#   l9-patch-reflow-gate.sh              判红/判绿
#   l9-patch-reflow-gate.sh --self-test  判定矩阵自证（植入必红）
#   l9-patch-reflow-gate.sh --emit       打印清单解析结果
# 退出码: 0=通过 1=违例 2=环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

ROOT="${L9_ROOT:-${PROJECT_ROOT}}"
WORKLOAD="${L9_WORKLOAD:-${ROOT}/agent-workload}"
MANIFEST="${L9_MANIFEST:-${SCRIPT_DIR}/l9-reflow-manifest.txt}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

repo_path() { # <repo-name> -> 绝对路径
    case "$1" in
        daemons)  echo "${WORKLOAD}/agentrt/daemons" ;;
        products) echo "${WORKLOAD}/products" ;;
        agentrt)  echo "${WORKLOAD}/agentrt" ;;
        *) echo "" ;;
    esac
}

judge() {
    local rc=0 line id status repo commit note n=0
    if [ ! -f "$MANIFEST" ]; then
        log_err "manifest not found: ${MANIFEST} (fail-closed)"
        return 2
    fi

    # 1+2) 逐项判定
    while IFS=$'\t' read -r id status repo commit note; do
        case "${id:-}" in ''|'#'*) continue ;; esac
        n=$((n+1))
        case "$status" in
            done)
                local rp
                rp=$(repo_path "$repo")
                if [ -z "$rp" ] || ! git -C "$rp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                    log_err "L-9/${id}: unknown or non-git repo '${repo}'"; rc=1; continue
                fi
                if ! git -C "$rp" cat-file -e "${commit}^{commit}" 2>/dev/null; then
                    log_err "L-9/${id}: commit ${commit} not found in ${repo}"; rc=1; continue
                fi
                if ! git -C "$rp" merge-base --is-ancestor "${commit}" HEAD 2>/dev/null; then
                    log_err "L-9/${id}: commit ${commit} not an ancestor of ${repo} HEAD (未回流)"; rc=1; continue
                fi
                log_ok "L-9/${id}: reflowed at ${repo}@${commit}"
                ;;
            na)
                if [ -z "${note:-}" ]; then
                    log_err "L-9/${id}: 不适用项缺理由（空理由判红）"; rc=1
                else
                    log_ok "L-9/${id}: not applicable — ${note}"
                fi
                ;;
            *)
                log_err "L-9/${id}: invalid status '${status}' (done|na)"; rc=1
                ;;
        esac
    done < "$MANIFEST"

    if [ "$n" -eq 0 ]; then
        log_err "L-9: manifest has no entries (fail-closed)"; rc=1
    fi

    # 3) 补丁副本残留
    local residue
    residue=$(find "$WORKLOAD" \( -name '.git' -o -name 'build*' \) -prune -o \
        -type f \( -name '*.patch' -o -name '*.rej' -o -name '*.orig' -o -name '*.bak' \) -print 2>/dev/null || true)
    if [ -n "$residue" ]; then
        log_err "L-9: patch residue found (副本有补丁而仓内无提交的形态):"
        printf '%s\n' "$residue" | sed 's/^/    /'
        rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        log_ok "L-9 patch-reflow gate PASSED (${n} item(s))"
    else
        log_err "L-9 patch-reflow gate FAILED"
    fi
    return "$rc"
}

emit_manifest() {
    while IFS=$'\t' read -r id status repo commit note; do
        case "${id:-}" in ''|'#'*) continue ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$status" "$repo" "$commit" "$note"
    done < "$MANIFEST"
}

# 自证：临时 git 仓 + fixture 清单，五臂
self_test() {
    section "L-9 self-test"
    local tmp fails=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/l9-self.XXXXXX")
    local wl="${tmp}/agent-workload"
    mkdir -p "${wl}/agentrt/daemons" "${wl}/products"
    local c1 c2
    c1=$(git -C "${wl}/agentrt/daemons" init -q && git -C "${wl}/agentrt/daemons" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one && git -C "${wl}/agentrt/daemons" rev-parse HEAD)
    c2=$(git -C "${wl}/products" init -q && git -C "${wl}/products" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one && git -C "${wl}/products" rev-parse HEAD)
    local mf="${tmp}/mf.txt"
    local self="${SCRIPT_DIR}/$(basename "$0")"

    expect() { # <name> <want_rc>
        local name="$1" want="$2" got=0
        L9_ROOT="$tmp" L9_WORKLOAD="$wl" L9_MANIFEST="$mf" bash "$self" >/dev/null 2>&1 || got=$?
        if [ "$got" -eq "$want" ]; then
            log_ok "T: ${name} rc=${got} (expected ${want})"
        else
            log_err "T: ${name} rc=${got} (expected ${want})"
            fails=$((fails+1))
        fi
    }

    printf '3\tdone\tdaemons\t%s\tfixture\n4\tdone\tproducts\t%s\tfixture\n1\tna\t-\t-\t宿主层不存在\n' "$c1" "$c2" > "$mf"
    expect "reflowed commits + na reason → green" 0

    printf '3\tdone\tdaemons\tdeadbeef\tfixture\n' > "$mf"
    expect "missing commit → red" 1

    printf '1\tna\t-\t-\t\n' > "$mf"
    expect "na without reason → red" 1

    printf '3\tdone\tnosuch\t%s\tfixture\n' "$c1" > "$mf"
    expect "unknown repo → red" 1

    printf '3\tdone\tdaemons\t%s\tfixture\n' "$c1" > "$mf"
    : > "${wl}/products/leftover.patch"
    expect "patch residue → red" 1

    # 非祖先提交（孤儿分支）→ 红
    rm -f "${wl}/products/leftover.patch"
    local orphan
    orphan=$(git -C "${wl}/products" -c user.email=t@t -c user.name=t commit-tree \
        "$(git -C "${wl}/products" rev-parse HEAD^{tree})" -m orphan)
    printf '4\tdone\tproducts\t%s\tfixture\n' "$orphan" > "$mf"
    expect "non-ancestor commit → red" 1

    rm -rf "$tmp"
    if [ "$fails" -eq 0 ]; then
        log_ok "L-9 self-test PASSED (6 arms)"
        return 0
    fi
    log_err "L-9 self-test FAILED (${fails} arm(s))"
    return 1
}

case "${1:-}" in
    --emit) emit_manifest ;;
    --self-test) self_test ;;
    "")
        section "L-9 Patch-Reflow Gate (0.1.21, gate:ci)"
        judge
        ;;
    *) echo "usage: $0 [--emit|--self-test]" >&2; exit 2 ;;
esac
