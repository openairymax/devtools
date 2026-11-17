#!/bin/bash
# AgentRT 提交历史普查（0.1.21 L-10 / §16.20.1）
#
# 目的：把「工程纪律」从评价变成可复算的数字。同一脚本对任意仓可跑，
#   输出固定键值，任何人重跑得到同一结果，讨论才落在事实上而不是印象上。
#
# 口径（每项定义写死，禁止临时增删）：
#   total        提交总数（不含 merge）
#   no_dco       body 无 Signed-off-by
#   subj_over72  主题按字符计 >72
#   no_prefix    主题无 '<subsystem>: ' 前缀（Merge/Revert 不计）
#   machine_sign 署名主体为机器人/代理/noreply
#   path_leak    主题或 body 含工具内部路径
#   fix_no_hash  修复类提交缺 Fixes，或 hash <12 位
#
# 只读：不 fetch、不 checkout、不改任何对象；历史不做改写（§2.3 第 4 条）。
# 用法: commit-survey.sh [仓库路径] [--limit N]
# 退出码: 0 = 已出报告；2 = 环境错误（非 git 仓等）
set -uo pipefail
export LC_ALL=C.UTF-8

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES="${SRC_DIR}/commit-rules.sh"
[ -r "$RULES" ] || { echo "survey: 规则文件缺失：${RULES}" >&2; exit 2; }
# shellcheck source=commit-rules.sh
. "$RULES"

repo="."
limit=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --limit) limit="${2:?--limit 需要数值}"; shift 2 ;;
        -*) echo "survey: 未知参数 $1" >&2; exit 2 ;;
        *) repo="$1"; shift ;;
    esac
done
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "survey: 非 git 仓库：${repo}" >&2; exit 2; }

args=(log --no-merges --format='%H%x1f%an%x1f%ae%x1f%s%x1f%b%x00')
[ -z "$limit" ] || args+=(-n "$limit")

c_total=0 c_dco=0 c_long=0 c_prefix=0 c_machine=0 c_path=0 c_fix=0
while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    c_total=$((c_total + 1))
    IFS=$'\x1f' read -r -d '' _h _an _ae _subj _body <<<"$rec" || true
    case "$_body" in *$'\nSigned-off-by:'* | Signed-off-by:*) ;; *) c_dco=$((c_dco + 1)) ;; esac
    [ "$(cr_chars "$_subj")" -le 72 ] || c_long=$((c_long + 1))
    case "$_subj" in
        'Merge '* | 'Revert "') ;;
        *) printf '%s' "$_subj" | grep -qE "$CR_SUB_RE" || c_prefix=$((c_prefix + 1)) ;;
    esac
    while IFS= read -r line; do
        case "$line" in Signed-off-by:*) ;; *) continue ;; esac
        nm=$(printf '%s' "$line" | sed -nE 's/^Signed-off-by: ([^<]+) <([^>]+)>.*/\1/p')
        ml=$(printf '%s' "$line" | sed -nE 's/^Signed-off-by: ([^<]+) <([^>]+)>.*/\2/p')
        if [ -n "$ml" ] && cr_sig_bad "$nm" "$ml"; then c_machine=$((c_machine + 1)); break; fi
    done <<<"$_body"
    printf '%s\n%s\n' "$_subj" "$_body" | grep -qE "$CR_PATH_RE" && c_path=$((c_path + 1))
    if [ "$(cr_kind "$_subj")" = fix ]; then
        h=$(printf '%s\n' "$_body" | sed -nE 's/^Fixes: ([0-9a-fA-F]+).*/\1/p' | head -n1)
        [ -n "$h" ] && [ "${#h}" -ge "$CR_FIX_HASH_MIN" ] || c_fix=$((c_fix + 1))
    fi
done < <(git -C "$repo" "${args[@]}" 2>/dev/null)

echo "repo=${repo}"
echo "total=${c_total}"
echo "no_dco=${c_dco}"
echo "subj_over72=${c_long}"
echo "no_prefix=${c_prefix}"
echo "machine_sign=${c_machine}"
echo "path_leak=${c_path}"
echo "fix_no_hash=${c_fix}"
exit 0
