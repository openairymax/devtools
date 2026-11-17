#!/bin/bash
# AgentRT 提交规则单一真相（0.1.21 L-11 / §16.20.5 R1~R9）
#
# 立意：规则只写一次。commit-msg 钩子（本地）与 g47 提交审计门禁（CI）
#   都 source 本文件，避免「钩子一套、CI 一套」的双口径——两套口径必然
#   在某一侧先放松，最后两边都不可信。
#
# 规则表（编号沿用 §16.20.5，勿擅自改号）：
#   R1 主题 `<subsystem>: <summary>`，祈使句、无句号、≤72 列；
#   R2 必须 Signed-off-by 且为自然人（禁机器人/代理/发布账号）；
#   R3 修复类必须有单行 `Fixes: <hash≥12>`；
#   R4 跨 ≥3 顶层子系统且无 `Split-` 声明 → 告警（不阻断）；
#   R5 删除/弱化门禁必须单独提交，且 body 以 `Gate-change:` 说明；
#   R6 新增导出符号必须有测试引用（由 g48 判，不在本文件）；
#   R7 身份由 .mailmap 归并，署名必须落在规范身份内；
#   R8 子模块指针 bump 必须写明被 bump 仓与起止 hash；
#   R9 禁工具内部路径（/tmp/trae-*、job-*、cwd.txt 等）进入提交信息。
#
# 用法：source 后调用 cr_msg <消息文件>，或 cr_diff <base>..<head> 追加判定。
# 退出码：0 通过（含 R4 告警）；1 违例；2 环境错误。
# 本地开关：AIRY_COMMIT_GATE=off 仅供开发者跳过本地钩子，CI 不读该变量。

CR_MAX_SUBJ=72
CR_FIX_HASH_MIN=12

# 主题前缀：允许 revert/merge 由 git 生成的固定形态，其余必须是 subsystem 前缀。
CR_SUB_RE='^[a-z0-9][a-z0-9._/+-]*: .+'
CR_FIX_RE='^(fix|hotfix|bugfix)(\([a-z0-9._/-]+\))?: '
CR_SIGN_RE='^Signed-off-by: ([^<]+) <([^>]+)>[[:space:]]*$'
CR_FIXES_RE='^Fixes: ([0-9a-fA-F]+)'
CR_SUBMOD_RE='^Submodule: [^ ]+ [0-9a-f]{7,}\.\.[0-9a-f]{7,}[[:space:]]*$'
CR_SPLIT_RE='^Split-[A-Za-z-]*:'
CR_GATE_RE='^Gate-change:'

# R9 禁入路径：工具运行态痕迹只属本机，入库即随公开仓分发。
CR_PATH_RE='(/tmp/trae-|/\.trae-cn/|(^|[^a-z])job-[0-9]+|cwd\.txt|/home/[a-z])'

CR_ERRS=0
cr_err() { echo "commit-rules: $*" >&2; CR_ERRS=$((CR_ERRS + 1)); }
cr_warn() { echo "commit-rules: WARN $*" >&2; }

# 列宽以字符计（中文主题按字计，不按字节误杀）；locale 缺失时回退字节数。
cr_chars() {
    local n
    n=$(printf '%s' "$1" | LC_ALL=C.UTF-8 wc -m 2>/dev/null | tr -d '[:space:]')
    case "$n" in '' | *[!0-9]*) n=${#1} ;; esac
    printf '%s\n' "$n"
}

# 修复类判定决定 R3 是否强制：只看前缀，不看正文自述。
cr_kind() {
    if printf '%s' "$1" | grep -qE "$CR_FIX_RE"; then echo fix; else echo feature; fi
}

cr_subj() {
    local subj="$1"
    case "$subj" in
        'Merge '* | 'Revert "') return 0 ;;
    esac
    local n
    n=$(cr_chars "$subj")
    [ "$n" -le "$CR_MAX_SUBJ" ] || cr_err "R1 主题 ${n} 列，超过 ${CR_MAX_SUBJ}"
    printf '%s' "$subj" | grep -qE "$CR_SUB_RE" || cr_err "R1 主题缺少 '<subsystem>: ' 前缀：${subj}"
    case "$subj" in
        *.) cr_err "R1 主题以句号结尾" ;;
        *' ') cr_err "R1 主题以空白结尾" ;;
    esac
}

# 自然人判定：代理/机器人/发布账号一律不认；正例不设白名单，避免新同事被挡。
# 拆成纯谓词 cr_sig_bad 供普查复用，避免 survey 与钩子出现两套「谁算机器」。
cr_sig_bad() {
    local name="$1" mail="$2" ln lm
    ln=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    lm=$(printf '%s' "$mail" | tr '[:upper:]' '[:lower:]')
    case "$lm" in noreply@* | *@noreply.*) return 0 ;; esac
    case "$ln" in
        *bot* | *agent* | *automation* | *robot* | 'spharx ltd') return 0 ;;
    esac
    return 1
}

cr_person() {
    local name="$1" mail="$2"
    if cr_sig_bad "$name" "$mail"; then
        cr_err "R2 禁机器/组织身份署名：${name} <${mail}>"
        return 1
    fi
    return 0
}

cr_sign() {
    local msg="$1" line name mail found=0
    while IFS= read -r line; do
        case "$line" in Signed-off-by:*) ;; *) continue ;; esac
        found=$((found + 1))
        if printf '%s' "$line" | grep -qE "$CR_SIGN_RE"; then
            name=$(printf '%s' "$line" | sed -E 's/^Signed-off-by: ([^<]+) <([^>]+)>[[:space:]]*$/\1/' | sed -E 's/[[:space:]]+$//')
            mail=$(printf '%s' "$line" | sed -E 's/^Signed-off-by: ([^<]+) <([^>]+)>[[:space:]]*$/\2/')
            cr_person "$name" "$mail" || true
        else
            cr_err "R2 署名格式不合 '<自然人> <邮箱>'：${line}"
        fi
    done <<EOF
$msg
EOF
    [ "$found" -gt 0 ] || cr_err "R2 缺少 Signed-off-by"
}

cr_fixes() {
    local subj="$1" msg="$2" hash
    [ "$(cr_kind "$subj")" = fix ] || return 0
    hash=$(printf '%s\n' "$msg" | sed -nE "s/^Fixes: ([0-9a-fA-F]+).*/\1/p" | head -n1)
    [ -n "$hash" ] || { cr_err "R3 修复类提交缺少 'Fixes: <hash>'"; return 0; }
    [ "${#hash}" -ge "$CR_FIX_HASH_MIN" ] || cr_err "R3 Fixes 短 hash ${hash}（需 ≥${CR_FIX_HASH_MIN} 位）"
    printf '%s\n' "$msg" | grep -qE "$CR_FIXES_RE" || cr_err "R3 Fixes 行必须独占 'Fixes: <hash>' 前缀"
}

cr_path() {
    local msg="$1" hit
    hit=$(printf '%s\n' "$msg" | grep -nE "$CR_PATH_RE" | head -n3)
    [ -z "$hit" ] || cr_err "R9 提交信息含工具内部路径：${hit}"
}

# R4 只告警：跨子系统常是正当的协同改动，阻断会逼人拆出无法独立绿的提交。
cr_scope() {
    local msg="$1" paths="$2" n
    n=$(printf '%s\n' "$paths" | sed '/^$/d' | cut -d/ -f1 | sort -u | grep -c . || true)
    [ "$n" -ge 3 ] || return 0
    printf '%s\n' "$msg" | grep -qE "$CR_SPLIT_RE" && return 0
    cr_warn "R4 跨 ${n} 个顶层子系统且无 'Split-' 声明"
}

# R5 强红：改门禁可以，但必须自成一体并说明理由，否则门禁会在「顺手改」中失效。
cr_gate() {
    local msg="$1" paths="$2" others gates
    gates=$(printf '%s\n' "$paths" | grep -E '(^|/)\.github/workflows/|[^/]*gate[^/]*\.(sh|yml|yaml)$|[^/]*check[^/]*\.sh$' || true)
    [ -n "$gates" ] || return 0
    others=$(printf '%s\n' "$paths" | grep -vE '(^|/)\.github/workflows/|[^/]*gate[^/]*\.(sh|yml|yaml)$|[^/]*check[^/]*\.sh$' | grep -vE '\.md$' || true)
    if [ -n "$others" ]; then
        cr_err "R5 门禁变更与业务变更混在同一提交，须拆分"
        return 0
    fi
    printf '%s\n' "$msg" | grep -qE "$CR_GATE_RE" || cr_err "R5 门禁提交 body 缺少 'Gate-change:' 说明"
}

# R8 依赖 git 的 raw diff（mode 160000）判定，故由调用方给出子模块变更清单。
cr_submod() {
    local msg="$1" list="$2"
    [ -n "$list" ] || return 0
    printf '%s\n' "$msg" | grep -qE "$CR_SUBMOD_RE" || cr_err "R8 子模块指针变更缺少 'Submodule: <repo> <old>..<new>'"
}

# cr_msg <消息文件> [paths_file]
# paths_file 由 cr_diff 产出（新增/修改路径逐行）；缺省时只判消息类规则。
cr_msg() {
    local file="$1" paths="${2:-}" msg subj
    [ -r "$file" ] || { echo "commit-rules: 消息文件不可读：${file}" >&2; return 2; }
    msg=$(cat "$file")
    subj=$(printf '%s\n' "$msg" | grep -vE '^[[:space:]]*(#|$)' | head -n1)
    [ -n "$subj" ] || { cr_err "空提交信息"; echo "commit-rules: 1 项违例" >&2; return 1; }
    cr_subj "$subj"
    cr_sign "$msg"
    cr_fixes "$subj" "$msg"
    cr_path "$msg"
    if [ -n "$paths" ] && [ -r "$paths" ]; then
        local plist
        plist=$(cat "$paths")
        cr_scope "$msg" "$plist"
        cr_gate "$msg" "$plist"
        cr_submod "$msg" "$(printf '%s\n' "$plist" | grep '^SUBMODULE ' | cut -d' ' -f2-)"
    fi
    if [ "$CR_ERRS" -gt 0 ]; then
        echo "commit-rules: ${CR_ERRS} 项违例（§16.20.5 R1~R9）" >&2
        return 1
    fi
    return 0
}

# cr_diff <base>..<head>：把范围变更写成校验输入，供 CI 复用同一套规则。
cr_diff() {
    local range="$1" out="$2" base head
    base=${range%%..*}
    head=${range##*..}
    git rev-parse --verify -q "$base^{commit}" >/dev/null || return 2
    git rev-parse --verify -q "$head^{commit}" >/dev/null || return 2
    : >"$out"
    git diff --name-only "$base" "$head" >>"$out"
    git diff --raw "$base" "$head" | awk '$2 == "160000" && $1 ~ /^:/ {print "SUBMODULE", $6}' >>"$out"
    return 0
}
