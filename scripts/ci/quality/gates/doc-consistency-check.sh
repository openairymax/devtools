#!/bin/bash
# Gate 45 文档-代码一致性门禁（0.1.20 方案 §9.1.1，本文档自指门禁）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1.1：活跃 SSoT 文档中的
#     <file>:<line> 引用必须可复现——行号引用随代码漂移静默失效，
#     是最隐蔽的假权威；行窗口 ±3 行（同方案 EV-2）。
#   同方案 §8.7：证据必须是文件，没有文件即视为未验收（子检查 B）。
#   同方案 Q13：四级指针归拢子检查，主仓 git submodule status
#     无 + 漂移行（子检查 C，不新开门禁）。
#
# 断言：
#   A 主判据：受辖文档全部 file:line 引用可解析（文件存在 +
#     1 <= n1 且 (n2|n1) <= total_lines + 3；多候选任一命中即绿）
#   B 证据清单逐项存在且非空（0 字节证据 = 未验收）
#   C 主仓子模块指针无漂移（根非 git 仓时隔离模式跳过）
#
# 用法: doc-consistency-check.sh
# 环境变量（selfcheck 隔离注入用）：DOC_CONSISTENCY_ROOT / DOC_CONSISTENCY_DOCS
#   / DOC_CONSISTENCY_EVIDENCE；未注入时走仓根默认值（生产形态）。
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误（清单或受辖文档缺席，fail-closed）
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${DOC_CONSISTENCY_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
DOCS_MANIFEST="${DOC_CONSISTENCY_DOCS:-${SCRIPT_DIR}/doc-consistency-docs.txt}"
EVIDENCE_MANIFEST="${DOC_CONSISTENCY_EVIDENCE:-${SCRIPT_DIR}/doc-evidence-files.txt}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0

# ── 环境前置（fail-closed：清单/受辖文档缺席 = 环境错误 rc=2）──
[ -f "$DOCS_MANIFEST" ] || { echo "受辖文档清单缺失: $DOCS_MANIFEST"; exit 2; }
[ -f "$EVIDENCE_MANIFEST" ] || { echo "证据清单缺失: $EVIDENCE_MANIFEST"; exit 2; }
[ -d "$PROJECT_ROOT" ] || { echo "审计根缺失: $PROJECT_ROOT"; exit 2; }

DOC_COUNT=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    DOC_COUNT=$((DOC_COUNT + 1))
    [ -f "${PROJECT_ROOT}/${line}" ] || {
        echo "受辖文档缺席（fail-closed）: $line"; exit 2
    }
done < "$DOCS_MANIFEST"
[ "$DOC_COUNT" -gt 0 ] || { echo "受辖文档清单为空（fail-closed）"; exit 2; }

# ── 子检查 A：file:line 引用可复现审计（python3，三端可移植）──
section "A: file:line reference audit (+-3 line window, EV-2)"
AUDIT_OUT="$(python3 - "$PROJECT_ROOT" "$DOCS_MANIFEST" <<'PYAUDIT'
import os, re, sys

root, docs_manifest = sys.argv[1], sys.argv[2]
RX = re.compile(
    r'([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:c|h|sh|py|rs|txt|md|json|manifest|toml))'
    r':(\d+)(?:-(\d+))?')

# basename 索引：一次遍历建立 文件名 -> 全路径列表，跳过 .git
#
# followlinks=True 是必需的，不是优化：CI 的门禁数据集把 agentrt 装配成
# 符号链接（quality-gate.yml 的 ln -s "$GITHUB_WORKSPACE"
# "$UMB/agent-workload/agentrt"），而 os.walk 默认不进入符号链接目录，
# 于是整个 agentrt 子树（含其 6 个叶子子模块）对索引不可见，agentrt 的
# file:line 引用全数判为 file-not-found。判的是「审计器看不见」，不是
# 「文档不一致」——假红，且本地真实目录树无法复现（run 40961445385 记
# 66 处违例，同一份文档本地跑 160/160 全绿）。
#
# 跟随符号链接必须配环守卫：realpath 见过即剪空 dirnames 并跳过本层文件，
# 否则 a->a/ 型自环会让遍历不终止。同一物理文件经不同路径重复入索引不影响
# 判定（resolve 走 any()），但会让 TOTAL 计数随链接数膨胀，故按 realpath 去重。
index = {}
seen = set()
for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
    dirnames[:] = [d for d in dirnames if d != '.git']
    try:
        real = os.path.realpath(dirpath)
    except OSError:
        real = dirpath
    if real in seen:
        dirnames[:] = []
        continue
    seen.add(real)
    for fn in filenames:
        index.setdefault(fn, []).append(os.path.join(dirpath, fn))

line_cache = {}

def total_lines(path):
    n = line_cache.get(path)
    if n is None:
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                n = sum(1 for _ in f)
        except OSError:
            n = -1
        line_cache[path] = n
    return n

def resolve(ref):
    # '/'锚定 endswith：quality-gate.sh 不得误吞 gate.sh 形态引用
    hit = [p for p in index.get(os.path.basename(ref), []) if p.endswith('/' + ref)]
    return hit or [p for p in index.get(os.path.basename(ref), [])
                   if os.path.relpath(p, root) == ref]

docs = []
with open(docs_manifest, encoding='utf-8') as f:
    for raw in f:
        raw = raw.strip()
        if raw and not raw.startswith('#'):
            docs.append(raw)

total = ok = 0
viol = []
for doc in docs:
    full = os.path.join(root, doc)
    with open(full, encoding='utf-8', errors='replace') as f:
        for lineno, text in enumerate(f, 1):
            # 剥离行内代码反引号无必要：正则直接扫原文
            for m in RX.finditer(text):
                ref, n1, n2 = m.group(1), int(m.group(2)), m.group(3)
                total += 1
                n_end = int(n2) if n2 else n1
                cands = resolve(ref)
                good = any(
                    1 <= n1 and n_end <= total_lines(p) + 3
                    for p in cands)
                if good:
                    ok += 1
                else:
                    why = 'file-not-found' if not cands else 'line-window-out-of-range'
                    viol.append('%s:%d: %s:%d (%s)' % (doc, lineno, ref, n1, why))

print('TOTAL=%d OK=%d VIOLATIONS=%d' % (total, ok, len(viol)))
for v in viol:
    print(v)
sys.exit(1 if viol else 0)
PYAUDIT
)" || true
echo "$AUDIT_OUT"
AUDIT_VIOL="$(printf '%s\n' "$AUDIT_OUT" \
    | sed -n 's/^TOTAL=[0-9]* OK=[0-9]* VIOLATIONS=\([0-9]*\)$/\1/p')"
if [ -z "$AUDIT_VIOL" ]; then
    # 审计器异常输出（崩溃/无汇总行）= 无法判定 = fail-closed
    echo "A 审计器异常输出（无 TOTAL 汇总行）"; exit 2
fi
if [ "$AUDIT_VIOL" -gt 0 ]; then
    log_err "A ${AUDIT_VIOL} 处 file:line 引用不可复现"
    VIOLATIONS=$((VIOLATIONS + AUDIT_VIOL))
else
    log_ok "A 全部 file:line 引用可复现"
fi

# ── 子检查 B：证据文件存在且非空（§8.7）─────────────────────
section "B: evidence files non-empty (SSoT 8.7)"
B_BAD=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    f="${PROJECT_ROOT}/${line}"
    if [ ! -f "$f" ]; then
        log_err "B 证据文件缺席: $line"
        B_BAD=$((B_BAD + 1))
    elif [ ! -s "$f" ]; then
        log_err "B 证据文件 0 字节（未验收）: $line"
        B_BAD=$((B_BAD + 1))
    fi
done < "$EVIDENCE_MANIFEST"
if [ "$B_BAD" -eq 0 ]; then
    log_ok "B 证据文件全部在册且非空"
else
    VIOLATIONS=$((VIOLATIONS + B_BAD))
fi

# ── 子检查 C：主仓四级指针归拢（Q13，不新开门禁）─────────────
section "C: submodule pointer drift (Q13)"
if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DRIFT="$(git -C "$PROJECT_ROOT" submodule status 2>/dev/null | grep -E '^\+' || true)"
    if [ -n "$DRIFT" ]; then
        echo "$DRIFT"
        log_err "C 主仓存在未归拢子模块指针（+ 漂移）"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        log_ok "C 主仓子模块指针全部归拢"
    fi
else
    # 隔离模式（selfcheck tmp 根非 git 仓）：Q13 不适用，非静默降级
    log_info "C 根非 git 工作树，Q13 不适用（隔离模式）"
fi

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 45 文档-代码一致性违例 ${VIOLATIONS} 项"
    exit 1
fi
log_ok "Gate 45 文档-代码一致性通过（A/B/C 三合一）"
exit 0
