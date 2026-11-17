#!/bin/bash
# Gate 47 提交审计（0.1.21 L-11 / §16.20.5 R1~R9）
#
# 判据：对 `AIRY_COMMIT_BASE..HEAD` 的每个新增提交，按 commit-rules.sh
#   的同一套规则复判——R1/R2/R3/R9 违规即红，R4 只告警，R5 强红，
#   R7（身份落在 .mailmap 规范集内）与 R8（子模块指针说明）强红。
#
# 为何只判新增提交：历史不改写（§2.3 第 4 条），旧提交的问题由 L-10
#   普查出具报告、登记在 COMMIT-AUDIT.md；门禁只对「此刻起」负责，
#   否则门禁第一天就永久红，等于被迫关闭。
#
# 未设 AIRY_COMMIT_BASE 时不判红，只打印普查摘要（首次接入/本地直跑）。
# 用法: g47-commit-audit.sh [--survey [仓库路径]]
# 环境变量: AIRY_COMMIT_BASE / AIRY_COMMIT_REPO / G47_ROOT / G47_RULES / G47_SURVEY
# 退出码: 0 = 通过或仅报告；1 = 违例；2 = 环境错误
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${G47_ROOT:-$(cd "${SCRIPT_DIR}/../../../../.." && pwd)}"
RULES="${G47_RULES:-${SCRIPT_DIR}/../../../git/commit-rules.sh}"
SURVEY="${G47_SURVEY:-${SCRIPT_DIR}/../../../git/commit-survey.sh}"
REPO="${AIRY_COMMIT_REPO:-${ROOT}/agent-workload/agentrt}"
BASE="${AIRY_COMMIT_BASE:-}"

[ -r "$RULES" ] || { echo "g47: 规则文件缺失：${RULES}" >&2; exit 2; }
# shellcheck source=commit-rules.sh
. "$RULES"

if [ "${1:-}" = --survey ]; then
    [ -x "$SURVEY" ] || [ -r "$SURVEY" ] || { echo "g47: 普查脚本缺失：${SURVEY}" >&2; exit 2; }
    shift
    exec bash "$SURVEY" "$@"
fi

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "g47: 非 git 仓库：${REPO}" >&2; exit 2; }

if [ -z "$BASE" ]; then
    echo "g47: AIRY_COMMIT_BASE 未设置，跳过新增提交判定（仅报告历史）"
    bash "$SURVEY" "$REPO" || exit 2
    exit 0
fi

git -C "$REPO" rev-parse --verify -q "${BASE}^{commit}" >/dev/null || {
    echo "g47: 基线不可解析：${BASE}" >&2
    exit 2
}

# 规范身份集：.mailmap 中出现的全部邮箱即「已登记身份」；无 .mailmap 时不判 R7。
CANON=""
if [ -r "${REPO}/.mailmap" ]; then
    CANON=$(grep -vE '^[[:space:]]*(#|$)' "${REPO}/.mailmap" | sed -nE 's/.*<([^>]+)>.*/\1/p' | sort -u)
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/g47.XXXXXX") || exit 2
trap 'rm -f "$TMP" "$TMP.msg"' EXIT

total=0 bad=0 warn=0
while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    total=$((total + 1))
    git -C "$REPO" log -1 --format='%s%n%n%b' "$sha" >"$TMP.msg"
    subj=$(git -C "$REPO" log -1 --format='%s' "$sha")
    {
        git -C "$REPO" diff-tree --no-commit-id --name-only -r --root "$sha"
        git -C "$REPO" diff-tree --raw --no-commit-id -r --root "$sha" \
            | awk '$2 == "160000" && $1 ~ /^:/ {print "SUBMODULE", $6}'
    } >"$TMP"
    out=$(cr_msg "$TMP.msg" "$TMP" 2>&1) || {
        CR_ERRS=0
        echo "g47: FAIL ${sha:0:12} ${subj}"
        printf '%s\n' "$out" | sed '/^$/d' | sed 's/^/    /'
        bad=$((bad + 1))
    }
    case "$out" in *'WARN'*) warn=$((warn + 1)) ;; esac
done < <(git -C "$REPO" log --no-merges --format=%H "${BASE}..HEAD")

if [ -n "$CANON" ]; then
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        ae=$(git -C "$REPO" log -1 --format='%ae' "$sha")
        printf '%s\n' "$CANON" | grep -qxF "$ae" && continue
        echo "g47: FAIL ${sha:0:12} R7 身份未登记于 .mailmap：${ae}"
        bad=$((bad + 1))
    done < <(git -C "$REPO" log --no-merges --format=%H "${BASE}..HEAD")
fi

rm -f "$TMP.msg"
echo "g47: base=${BASE} commits=${total} violations=${bad} warnings=${warn}"
[ "$bad" -eq 0 ] || { echo "g47: 提交审计未通过（§16.20.5）"; exit 1; }
exit 0
