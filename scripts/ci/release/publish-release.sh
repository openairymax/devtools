#!/usr/bin/env bash
# ============================================================================
# AgentRT 发布流水线：签名 + manifest 生成 + 上传 atomgit Release
#
# 双轨签名体系（防供应链攻击）：
#   1. cosign —— 对每个 tarball 做 sign-blob，产出 <file>.sig
#   2. GPG    —— 对 manifest.<channel>.json 做 detached 签名（权威校验链）
#
# 通道：tag 含 -beta./-rc. → beta 通道；否则 stable。
#   官方制品仓库：https://atomgit.com/openairymax/agentrt（用户指定）
#   制品 URL:      https://atomgit.com/openairymax/agentrt/releases/download/<tag>/<file>
#   安装/更新唯一事实源（B12，0.1.18 乙口径）：releases/download/latest/
#   是 atomgit 平台级「最新 release」别名（302 动态路由到最新 release 附件
#   面，非 git tag），版本发布完成即自动指向新面；阶段 4.6 对其做入口面
#   终验（别名指向 + 入口件可达，fail-closed）：
#      .../releases/download/latest/{install.sh,install.ps1,airymaxrt,agentrt.asc,manifest.<channel>.json(.asc)}
#   仓库代码树 latest/ 目录仅作同源归档快照（阶段 5 commit），不再是
#   客户端读取面——contents/raw 第二事实源已随 B12 废除。
#
# 用法：
#   ./publish-release.sh v0.1.5 [DIST_DIR]              # stable 发布
#   ./publish-release.sh v0.1.5-beta.1 [DIST_DIR]       # beta 发布
# 环境变量：
#   COSIGN_PRIVATE_KEY / COSIGN_PASSWORD   cosign 私钥（base64 或文件路径）
#   GPG_PRIVATE_KEY / GPG_PASSPHRASE       GPG 私钥（base64）+ 口令
#   ATOMGIT_TOKEN / ATOMGIT_REPO           atomgit 令牌 + 目标仓（默认 openairymax/agentrt）
#   RELEASE_NOTES / RELEASE_NOTES_FILE     Release 正文（显式 RELEASE_NOTES
#                                          优先，文件仅兜底）
#   AIRY_NOTES_ONLY=1                       仅对齐 Release 正文后退出（不签名/不上传）
#   AIRY_PRUNE_ONLY=1                       仅执行版本保留处理（窗口收敛）后退出
#   AIRY_KEEP_VERSIONS=N                    每通道保留版本数（默认 3：当前+上两个）
#   SKIP_SIGN=1 跳过签名（仅生成 manifest）  SKIP_UPLOAD=1 不上传  DRY_RUN=1 模拟
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
# 伞仓（源码区）与构建打包台（源码区外）定位：发布工作区 developbuild 已迁出
# 源码区，位于伞仓同级 works-engineering（铁律 4.7 / BAN-33）。
UMBRELLA="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
AIRY_WORKSPACE="${AIRY_WORKSPACE:-$(dirname "$UMBRELLA")/works-engineering}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

VERSION="${1:-}"
DIST_DIR="${2:-${HOME}/.airymaxrt/dist}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_COSIGN="${SKIP_COSIGN:-0}"
SKIP_GPG="${SKIP_GPG:-0}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
ATOMGIT_REPO="${ATOMGIT_REPO:-openairymax/agentrt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() {
    if [ "$DRY_RUN" = "1" ]; then log_info "DRY-RUN: $*"; else "$@"; fi
}

# URL 内嵌凭据脱敏（对齐 sync-mirror.sh redact 语义）：git 等工具失败时
# 会把带 token 的 URL 原样回显到 stderr，本地 fallback 发布无 Actions mask
# 兜底，必须显式过滤（0.1.13 流水线体检：审计发现的 LOW 加固项）。
redact() { sed -E 's#(https?://)[^/@]*:[^/@]*@#\1***:***@#g'; }

[ -n "$VERSION" ] || { echo "用法: $0 <版本号> [DIST_DIR]"; exit 1; }

# ─── 通道判定 ──────────────────────────────────────────────────────────────
# 语义：stable（生产）/ beta（预发布）/ rc（候选发布）。rc 独立通道
# （manifest.rc.json），避免与 beta 混淆（问题 10：rc 通道曾塌缩为 beta）。
# 0.1.13-rc4 实证：旧匹配 `*-rc.*` 只认 rc. 带点写法，rc4/rc5 等无点 tag
# 落入 `*)` 被误判为 stable → rc 候选直写 manifest.stable.json（污染生产
# 通道）。`-rc`（含 rcN 与 rc.N）一律按 rc 通道处理。
case "$VERSION" in
    *-rc*)     CHANNEL="rc";     PRERELEASE="true" ;;
    *-beta*)   CHANNEL="beta";   PRERELEASE="true" ;;
    *)         CHANNEL="stable"; PRERELEASE="false" ;;
esac
log_info "AgentRT 发布 ${VERSION}（通道: ${CHANNEL}）"
log_info "制品目录: ${DIST_DIR}  目标: ${ATOMGIT_REPO}"

# ─── 发布说明正文 ──────────────────────────────────────────────────────────
# 面向社区公开场合，不得出现内部工程流水（bump/CI/镜像等）。显式传入的
# RELEASE_NOTES 优先，RELEASE_NOTES_FILE（release.yml 传 notes.txt）仅
# 在其缺省时兜底——调用方需要「就地覆盖」时必定是显式 notes 语义（如
# mirror-release.yml 的三端正文纠偏），文件兜底不得反向压过它。
NOTES="${RELEASE_NOTES:-}"
if [ -z "$NOTES" ] && [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi
RELEASE_BODY="${NOTES:-AgentRT ${VERSION}}"

API="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}/releases"
# 删 Tag 端点（Gitee v5 兼容）：级联删除对应 Release。atomgit 无 release
# DELETE 端点（/releases/{tag} 返回 405 实证），超窗清理必须走本端点。
API_TAGS="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}/tags"

# atomgit API v5（Gitee 兼容，Base api.atomgit.com）：PRIVATE-TOKEN 认证。
# release 对象无 id 字段，以 tag_name 存在性探测（幂等）：不存在则创建，
# 已存在则 PATCH 强制对齐 name/body/prerelease。对齐是必需的——release
# 正文/名称面向社区公开场合，必须以本次 NOTES 为准，否则首建后永久固化
# （0.1.15 实证：首建正文漏入内部 bump 流水后无纠正通道）。
# 返回值：0=已创建或已对齐；1=创建失败（致命）；2=已存在但正文对齐失败。
align_release_body() {
    local tag="$1" body="$2" pre="$3" exists json
    exists="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        "${API}/tags/${tag}" 2>/dev/null \
        | python3 -c "import sys,json;print(1 if (json.load(sys.stdin) or {}).get('tag_name') else '')" 2>/dev/null || true)"
    if [ -z "$exists" ]; then
        json="$(python3 -c "import json,sys;print(json.dumps({'tag_name':sys.argv[1],'name':sys.argv[1],'body':sys.argv[2],'prerelease':sys.argv[3]}))" "$tag" "$body" "$pre")"
        curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
            -H "Content-Type: application/json" --data-binary "$json" \
            "${API}" >/dev/null 2>&1 || { log_fail "Release 创建失败（检查 ATOMGIT_TOKEN 与 ${ATOMGIT_REPO} 权限）"; return 1; }
        log_ok "Release 已创建: ${tag}（${ATOMGIT_REPO}）"
        return 0
    fi
    json="$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1],'body':sys.argv[2],'prerelease':sys.argv[3]}))" "$tag" "$body" "$pre")"
    curl -fsSL --connect-timeout 20 -X PATCH -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        -H "Content-Type: application/json" --data-binary "$json" \
        "${API}/${tag}" >/dev/null 2>&1 || { log_fail "Release 正文对齐失败: ${tag}"; return 2; }
    log_ok "Release 已存在，正文已对齐: ${tag}（${ATOMGIT_REPO}）"
    return 0
}

# ─── 阶段 0：仅对齐 Release 正文（AIRY_NOTES_ONLY=1）──────────────────────
# 发布说明修订 / 首建正文有误的事后纠偏，不应触发签名与制品上传全链路：
# 与阶段 4 共用 align_release_body（幂等），避免两处实现漂移。
if [ "${AIRY_NOTES_ONLY:-0}" = "1" ]; then
    [ -n "${ATOMGIT_TOKEN:-}" ] || { log_fail "AIRY_NOTES_ONLY=1 需 ATOMGIT_TOKEN"; exit 1; }
    log_info "仅对齐 Release 正文: ${VERSION}"
    align_release_body "$VERSION" "$RELEASE_BODY" "$PRERELEASE" || exit 1
    exit 0
fi

# ─── 版本保留（社区窗口：每通道仅留最新 N 版）──────────────────────────────
# 社区策略（0.1.17 预先工作定案）：只保留当前版本 + 上两个。按通道分窗
# （stable/rc/beta 各留 AIRY_KEEP_VERSIONS，默认 3），绝不全局统一窗口——
# rc 迭代密集（0.1.13 实证 rc1~rc9+），全局窗口会被 rc 挤占，导致 stable
# 生产通道旧版下载 URL 404，破坏在装用户的自更新链。
# 判定基准 = 远端 Release 全集 ∪ 本地 dist 版本集合：远端列举失败
# （fail-soft，视为空）时仅对本地判窗，保守不误删；AIRY_PRUNE_ONLY 重跑
# 幂等（已删 tag 不再出现，窗口由现存版本构成，判定稳定）。
airy_channel_of() {
    case "$1" in
        *-rc*)   echo "rc" ;;
        *-beta*) echo "beta" ;;
        *)       echo "stable" ;;
    esac
}

# 远端 Release 列举（tag 每行一个，分页 per_page=100）。列表端点匿名可读
# （0.1.16 实证），带 token 更稳。
airy_list_remote() {
    local page=1 batch n
    local -a auth=()
    [ -n "${ATOMGIT_TOKEN:-}" ] && auth=(-H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}")
    while :; do
        batch="$(curl -fsSL --connect-timeout 20 "${auth[@]}" \
            "${API}?per_page=100&page=${page}" 2>/dev/null \
            | python3 -c 'import sys,json; print("\n".join((r.get("tag_name") or "") for r in (json.load(sys.stdin) or [])))' 2>/dev/null || true)"
        batch="$(printf '%s\n' "$batch" | sed '/^$/d')"
        [ -n "$batch" ] || break
        printf '%s\n' "$batch"
        n="$(printf '%s\n' "$batch" | wc -l)"
        [ "$n" -lt 100 ] && break
        page=$((page + 1))
    done
}

# 超窗判定（排序+分窗在共享脚本 airy_release_prune.py 内完成，semver 感知，
# 与 publish-mirror.sh 镜像面严格同源——判定实现只此一份，禁止内联副本）：
#   主/次/补丁版本数值比较；同版本号内分层 正式(4) > 字母后缀(3) >
#   rc(2) > beta(1)；rc/beta 序号数值比较（防 rc10 < rc9 字典序误判）。
# 入参: 1=全部 tag（每行一个） 2=keep 3=当前版本（永不 prune）
# 出参: 每行一个超窗 tag
airy_overkept() {
    printf '%s\n' "$1" | python3 "${SCRIPT_DIR}/airy_release_prune.py" "$2" "$3"
}

# 超窗远端 Release 删除。atomgit 无 release DELETE 端点（/releases/{tag}
# 返回 405 实证），走删 Tag 端点级联删除 Release（Gitee v5 兼容形态，
# v0.1.7 删除+级联消失已实证）；
# fail-soft：无 token 或删除失败仅告警，不阻断发布主链路（下载链不受
# 影响的旧版本多留一期无害，下期发布自动重试收敛）。
airy_delete_remote() {
    local tag="$1"
    if [ -z "${ATOMGIT_TOKEN:-}" ]; then
        log_warn "未配置 ATOMGIT_TOKEN，跳过远端删除: ${tag}（需人工处理或下期重试）"
        return 1
    fi
    if curl -fsS --connect-timeout 20 -X DELETE \
        -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" "${API_TAGS}/${tag}" >/dev/null 2>&1; then
        log_ok "远端 Release 已删除（超窗，经 Tag 级联）: ${tag}"
    else
        log_warn "远端 Release 删除失败（fail-soft，不阻断发布）: ${tag}"
        return 1
    fi
}

airy_prune_old() {
    local keep="${AIRY_KEEP_VERSIONS:-3}"
    log_info "版本保留处理（每通道保留 ${keep} 版，当前 ${VERSION} 永保留）…"
    local remote_tags f base ver all over t
    remote_tags="$(airy_list_remote || true)"
    local -a localv=()
    for f in "$DIST_DIR"/agentrt-*-*.tar.gz "$DIST_DIR"/agentrt-*-*.zip; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        ver="${base#agentrt-}"
        ver="${ver%%-*}"
        case " ${localv[*]-} " in *" ${ver} "*) ;; *) localv+=("$ver") ;; esac
    done
    all="$( { printf '%s\n' "$remote_tags"; printf '%s\n' "${localv[@]-}"; } | sed '/^$/d' | sort -u )"
    if [ -z "$all" ]; then
        log_ok "版本保留处理: 无历史版本，跳过"
        return 0
    fi
    over="$(airy_overkept "$all" "$keep" "$VERSION")"
    if [ -z "$over" ]; then
        log_ok "版本保留处理: 窗口合规（每通道 ${keep} 版）"
        return 0
    fi
    log_info "超窗版本:"
    sed 's/^/  - /' <<<"$over"
    # 本地 dist 台面整理：超窗版本全系文件（tar.gz/sha256/sig）归档
    # archive/<ver>/（既有归档惯例），当前版本文件永不动。dist 台面在
    # 源码区外（works-engineering），归档不触碰源码区（铁律 BAN-33）。
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        local -a mvs=()
        for f in "$DIST_DIR"/agentrt-"$t"-*; do
            [ -e "$f" ] || continue
            mvs+=("$f")
        done
        [ ${#mvs[@]} -gt 0 ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN: mv ${#mvs[@]} 个文件 → archive/${t}/"
        else
            mkdir -p "$DIST_DIR/archive/${t}"
            mv -f "${mvs[@]}" "$DIST_DIR/archive/${t}/"
            log_ok "本地已归档: ${t}（${#mvs[@]} 个文件 → archive/${t}/）"
        fi
    done <<<"$over"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\n' "$remote_tags" | grep -qxF "$t" || continue
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN: DELETE ${API_TAGS}/${t}"
        else
            airy_delete_remote "$t" || true
        fi
    done <<<"$over"
}

# ─── 阶段 0.1：仅执行版本保留处理（AIRY_PRUNE_ONLY=1）─────────────────────
# 版本清理独立成模式：无需签名/上传全链路即可对现状（本地 dist 台面 +
# 远端 Release）执行窗口收敛，与 AIRY_NOTES_ONLY 同为运维后门。
if [ "${AIRY_PRUNE_ONLY:-0}" = "1" ]; then
    log_info "仅执行版本保留处理: ${VERSION}"
    airy_prune_old
    exit 0
fi

# ─── 收集制品 ──────────────────────────────────────────────────────────────
ARTIFACTS=()
for f in "$DIST_DIR"/agentrt-${VERSION}-*.tar.gz "$DIST_DIR"/agentrt-${VERSION}-*.zip; do
    [ -e "$f" ] || continue
    ARTIFACTS+=("$f")
done
[ ${#ARTIFACTS[@]} -gt 0 ] || { log_fail "未找到制品: ${DIST_DIR}/agentrt-${VERSION}-*.{tar.gz,zip}"; exit 1; }
log_info "制品清单:"
for f in "${ARTIFACTS[@]}"; do log_info "  $(basename "$f")"; done

# ─── 阶段 0.5：发布预检（0.1.6f 强化，fail-closed）──────────────────────
# 准确性门禁：版本号格式 / sha256 校验件一致 / 包大小 sanity / 包内
# 启动器语法。任一不过即中止，杜绝发布损坏或错配制品。
# 0.1.7 修复：原 glob 模式 `v[0-9]*.[0-9]*.[0-9]*[-.+a-zA-Z0-9]*` 中
# [0-9]* 为「一位数字+任意串」glob，且末段要求至少一个后缀字符，
# 纯版本号 v0.1.7（无后缀）被误拒，仅带后缀（如 v0.1.6h）可通过。
# 改用正则：vX.Y.Z 可选后接 -/.+ 开头或直接字母数字的后缀段
# （兼容 0.1.6a~0.1.6h 字母后缀系列，与 release.sh 口径一致）。
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.+][a-zA-Z0-9.]+|[a-zA-Z0-9]+)?$ ]]; then
    log_fail "版本号格式非法: ${VERSION}（应为 vX.Y.Z 或带后缀，如 v0.1.6h、v0.1.7-beta.1）"; exit 1
fi
PREFAIL=0
for f in "${ARTIFACTS[@]}"; do
    if [ ! -f "$f.sha256" ]; then
        log_fail "缺少校验文件: $(basename "$f").sha256"; PREFAIL=1; continue
    fi
    computed="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    declared="$(awk '{print $1}' "$f.sha256" 2>/dev/null)"
    if [ -z "$computed" ] || [ "$computed" != "$declared" ]; then
        log_fail "sha256 不匹配: $(basename "$f")"; PREFAIL=1
    fi
    size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)"
    # 下限 1MB（原 5MB 会误伤小而完整的包，如 macOS-arm64 ~4.6MB）；
    # 仍能拦截 qemu 静默空包（~3KB）等损坏制品。
    if [ -z "$size" ] || [ "$size" -lt 1000000 ]; then
        log_fail "制品异常小（疑似损坏）: $(basename "$f")（${size:-?} 字节）"; PREFAIL=1
    fi
done
# 包内关键组件预检（0.1.6h 漏件教训：启动器 bin/airymaxrt 由安装器
# 生成、包内不含，旧检查 grep 'bin/airymaxrt' 永远不命中形同虚设）。
# 改为 fail-closed：关键二进制缺任一即中止；包内脚本做语法预检。
# 0.1.13 补全（2026-09-06）：此前 REQUIRED_BIN 只列 8 项，漏 7 个 daemon
# （market_d/monit_d/notify_d/channel_d/a2a_d/cupolas_d/maths_d/hook_d）——
# 漏件门禁形同虚设，正是"总是缺东西"的一手原因。现列全 15 daemon 服务 +
# airy_cli + bootstrap；并对全部发布包断言"完整能力"（TUI/config/Python
# 运行时），任一缺失即中止，杜绝半成品出库。
REQUIRED_BIN="airy_cli agentrt-bootstrap.sh gateway_d llm_d think_d sched_d tool_d mem_d agent_d market_d monit_d notify_d channel_d a2a_d cupolas_d maths_d hook_d"
# 完整能力清单（tar.gz 与 zip 通用；Windows 侧二进制带 .exe 后缀，匹配
# 逻辑对 "bin/$b" 与 "bin/$b.exe" 双态容忍）。config/* 由 lf-package 统一
# 注入，lib/{airymax_agents,airymax_agents_rs,orchestration,agentrt} 由
# 各腿构建期拷贝——此前均为 `|| true` 容忍拷贝，缺失即静默漏件。
REQUIRED_SUBTREE="bin/agentrt-tui config/agentrt.yaml config/model.yaml config/secrets.env.example config/permission_rules.yaml lib/airymax_agents lib/airymax_agents_rs lib/orchestration lib/agentrt"
for f in "${ARTIFACTS[@]}"; do
    listing="$(tar -tzf "$f" 2>/dev/null || true)"
    # zip 制品：GNU tar 无法读 zip（listing 空），改用 python 标准库枚举
    if [ -z "$listing" ] && [[ "$f" == *.zip ]]; then
        listing="$(python3 - "$f" <<'PYEOF'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        print("\n".join(z.namelist()))
except Exception:
    pass
PYEOF
)"
    fi
    miss=""
    for b in $REQUIRED_BIN; do
        case "$listing" in
            *"bin/$b"*|*"bin/$b.exe"*) ;;
            *) miss="$miss $b" ;;
        esac
    done
    if [ -n "$miss" ]; then
        log_fail "包内缺少关键组件（漏件）: $(basename "$f"):$miss"; PREFAIL=1
    fi
    # 完整能力断言：缺失即 fail（读完整发布包的组件目录层级）
    miss2=""
    for c in $REQUIRED_SUBTREE; do
        # config 模板在 tar 内位于 config/ 顶目录；zip 内同名
        case "$listing" in
            *"$c"*) ;;
            *) miss2="$miss2 $c" ;;
        esac
    done
    if [ -n "$miss2" ]; then
        log_fail "包内缺少能力组件（半成品）: $(basename "$f"):$miss2"; PREFAIL=1
    fi
    tmpext="$(mktemp -d)"
    if echo "$listing" | grep -q 'bin/agentrt-bootstrap.sh'; then
        if tar -xzf "$f" -C "$tmpext" --wildcards '*/bin/agentrt-bootstrap.sh' 2>/dev/null; then
            script="$(find "$tmpext" -name 'agentrt-bootstrap.sh' -type f | head -1)"
            if [ -n "$script" ] && ! bash -n "$script" 2>/dev/null; then
                log_fail "包内 agentrt-bootstrap.sh 语法预检失败: $(basename "$f")"; PREFAIL=1
            fi
        fi
    fi
    rm -rf "$tmpext"
done
[ "$PREFAIL" = "0" ] || { log_fail "发布预检未通过（${PREFAIL} 项），中止"; exit 1; }
log_ok "发布预检通过: ${#ARTIFACTS[@]} 个制品（sha256 一致 + 大小正常 + 关键二进制齐 + 能力组件齐 + 启动器语法 OK）"

# ─── 阶段 1：cosign 签名每个制品 ──────────────────────────────────────────
if [ "$SKIP_SIGN" = "1" ] || [ "$SKIP_COSIGN" = "1" ]; then
    log_warn "跳过 cosign 制品签名（SKIP_SIGN/SKIP_COSIGN）"
else
    command -v cosign >/dev/null 2>&1 || { log_fail "cosign 未安装"; exit 1; }
    COSIGN_KEY_FILE="${COSIGN_PRIVATE_KEY:-}"
    if [ -n "$COSIGN_KEY_FILE" ] && [ ! -f "$COSIGN_KEY_FILE" ]; then
        COSIGN_KEY_FILE="$TMP/cosign.key"
        printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 -d > "$COSIGN_KEY_FILE" 2>/dev/null || \
            printf '%s\n' "${COSIGN_PRIVATE_KEY}" > "$COSIGN_KEY_FILE"
        chmod 600 "$COSIGN_KEY_FILE"
    fi
    [ -n "$COSIGN_KEY_FILE" ] || { log_fail "缺少 COSIGN_PRIVATE_KEY"; exit 1; }
    for f in "${ARTIFACTS[@]}"; do
        if [ -s "${f}.sig" ]; then
            log_ok "cosign 签名已存在: $(basename "$f").sig"
            continue
        fi
        log_info "cosign 签名: $(basename "$f")…"
        # --tlog-upload=false：静态密钥签名无需透明日志（避免交互确认与
        # 公网 tlog 依赖，企业/离线场景更友好）；--yes 跳过 cosign 确认提示。
        run env COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign-blob \
            --key "$COSIGN_KEY_FILE" --tlog-upload=false --yes \
            --output-signature "${f}.sig" "$f" >/dev/null
        [ "$DRY_RUN" = "1" ] || [ -s "${f}.sig" ] || { log_fail "签名失败: $f"; exit 1; }
        log_ok "cosign 签名: $(basename "$f").sig"
    done
fi

# ─── 阶段 2：生成 manifest.<channel>.json ─────────────────────────────────
MANIFEST="$DIST_DIR/manifest.${CHANNEL}.json"
RELEASE_BASE="https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}"
log_info "生成 manifest（${CHANNEL}）…"
# 幂等保护：manifest 已存在则不重生成——updated_at 漂移会使既有 .asc 签名
# 失配（GPG 对整文件签名），断点重跑场景下绝不能静默漂移已签名内容。
# 需强制重建时删除旧 manifest 再跑。
if [ -s "$MANIFEST" ]; then
    log_ok "manifest 已存在，跳过重生成（保护既有签名一致性）: $(basename "$MANIFEST")"
else
python3 - "$VERSION" "$CHANNEL" "$DIST_DIR" "$RELEASE_BASE" "$NOTES" "$MANIFEST" <<'PYEOF'
import json, os, sys, datetime

version, channel, dist_dir, release_base, notes, out = sys.argv[1:7]
artifacts = {}
for fn in sorted(os.listdir(dist_dir)):
    # 匹配 agentrt-<version>-<os>-<arch>.{tar.gz,zip}
    prefix = f"agentrt-{version}-"
    if not fn.startswith(prefix):
        continue
    suffix = fn[len(prefix):]
    if not (suffix.endswith(".tar.gz") or suffix.endswith(".zip")):
        continue
    plat = suffix[: -len(".tar.gz")] if suffix.endswith(".tar.gz") else suffix[: -len(".zip")]
    path = os.path.join(dist_dir, fn)
    sha = ""
    sha_file = path + ".sha256"
    if os.path.exists(sha_file):
        sha = open(sha_file).read().strip().split()[0]
    if not sha:
        import hashlib
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    artifacts[plat] = {
        "url": f"{release_base}/{fn}",
        "sha256": sha,
        "size": os.path.getsize(path),
    }

# 平台命名规范（0.1.10 起，用户定案）：OS-架构族-位宽（linux-x86-64 /
# macos-arm-64 / windows-x86-64 …），弃用 i686/armv7l/x64/arm64 行话。
# manifest 主键即文件名平台段；此处为存量客户端补两代旧命名别名（同一
# url/sha256/size），一次发布惠及全部旧安装器/更新器：
#   gen2（0.1.6e~0.1.10）：linux-x64/x86/arm64/arm32、macos-x64/arm64、
#     windows-x64/win-x64 …（win- 前缀仅历史存在，未曾实际发布）
#   gen1（≤0.1.6d）：uname 原始名 linux-x86_64/i686/aarch64/armv7l …
# 与 install.sh / airymaxrt plat_legacy_name 同口径（SSoT）。
ALIAS = {
    "linux-x86-64":   ["linux-x64", "linux-x86_64"],
    "linux-x86-32":   ["linux-x86", "linux-i686"],
    "linux-arm-64":   ["linux-arm64", "linux-aarch64"],
    "linux-arm-32":   ["linux-arm32", "linux-armv7l"],
    "linux-riscv-64": ["linux-riscv64"],
    "linux-riscv-32": ["linux-riscv32"],
    "macos-x86-64":   ["macos-x64", "macos-x86_64"],
    "macos-arm-64":   ["macos-arm64", "macos-aarch64"],
    "windows-x86-64": ["windows-x64", "windows-x86_64", "win-x64", "win-x86_64"],
    "windows-x86-32": ["windows-x86", "windows-i686", "win-x86", "win-i686"],
    "windows-arm-64": ["windows-arm64", "windows-aarch64", "win-arm64", "win-aarch64"],
}
for plat in list(artifacts):
    for alias in ALIAS.get(plat, ()):
        artifacts.setdefault(alias, artifacts[plat])

manifest = {
    "schema": 1,
    "channel": channel,
    # U-02（2026-09-13）：显式声明通道状态。active=本通道有真实制品；
    # reserved=保留通道（无制品，见 emit_channel_declarations）。客户端据此
    # 在“网络异常”与“该通道无制品”之间确定性区分，不再依赖 404 猜测。
    "state": "active",
    "latest": version,
    "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "releases": {
        version: {
            "yanked": False,
            "notes": notes,
            "artifacts": artifacts,
        }
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"manifest 已生成: {out}（{len(artifacts)} 平台键，含旧命名别名）")
PYEOF
fi
log_ok "manifest: $(basename "$MANIFEST")"

# ─── 阶段 3：GPG 签名 manifest（权威） ───────────────────────────────────
if [ "$SKIP_SIGN" = "1" ] || [ "$SKIP_GPG" = "1" ]; then
    log_warn "跳过 manifest GPG 签名（SKIP_SIGN/SKIP_GPG）"
else
    command -v gpg >/dev/null 2>&1 || { log_fail "gpg 未安装"; exit 1; }
    if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
        printf '%s' "${GPG_PRIVATE_KEY}" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null || \
            printf '%s\n' "${GPG_PRIVATE_KEY}" | gpg --batch --import 2>/dev/null
    fi
    # 校验公钥指纹与仓库内置一致（防私钥张冠李戴）：取导入私钥的真实指纹
    # 与 keys/agentrt.fingerprint 硬比对，不符立即失败，杜绝签出客户端
    # 无法验证的 manifest。
    BUILTIN_FPR="$(cat "$KEYS_DIR/agentrt.fingerprint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$BUILTIN_FPR" ]; then
        IMPORTED_FPR="$(gpg --batch --list-keys --with-colons 2>/dev/null | \
            awk -F: '$1=="fpr" {print $10}' | head -1)"
        if [ -n "$IMPORTED_FPR" ] && [ "$(echo "$IMPORTED_FPR" | tr -d '[:space:]')" != "$BUILTIN_FPR" ]; then
            log_fail "GPG 指纹不匹配：导入私钥 ${IMPORTED_FPR} != 内置基线 ${BUILTIN_FPR}"
            exit 1
        fi
        log_info "公钥指纹基线: ${BUILTIN_FPR}（与导入私钥一致）"
    fi
    if [ -f "$MANIFEST.asc" ]; then
        log_warn "已存在签名，跳过: $(basename "$MANIFEST").asc"
    else
        run gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${GPG_PASSPHRASE:-}" --armor --detach-sign \
            -o "$MANIFEST.asc" "$MANIFEST"
        [ "$DRY_RUN" = "1" ] || [ -s "$MANIFEST.asc" ] || { log_fail "GPG 签名失败"; exit 1; }
        log_ok "GPG 签名: $(basename "$MANIFEST").asc"
    fi
fi

# ─── 阶段 4：上传 atomgit Release ─────────────────────────────────────────
if [ "$SKIP_UPLOAD" = "1" ] || [ -z "${ATOMGIT_TOKEN:-}" ]; then
    log_warn "跳过上传（SKIP_UPLOAD=1 或未配置 ATOMGIT_TOKEN）；产物保留在 ${DIST_DIR}/"
    ls -la "$DIST_DIR" | grep -E "agentrt-${VERSION}|manifest" || true
    exit 0
fi

log_info "创建/更新 Release ${VERSION}…"
align_release_body "$VERSION" "$RELEASE_BODY" "$PRERELEASE" || exit 1

# 附件上传走预签名两步流（POST /releases/{tag}/attach_files 端点不存在，
# 服务端 404）：GET /releases/{tag}/upload_url?file_name=X 返回 OBS 预签名
# {url, headers}，再 PUT 文件体到预签名 URL。
# 同名附件已存在则跳过（重跑幂等续传）；任一失败累计后 fail-closed，
# 绝不假报成功——自更新链依赖附件与 manifest 一致。
# 0.1.10 修复发布实证（2026-09-05）：同名附件"覆盖"上传不可靠——atomgit
# upload_url 每次签发全新 OBS key，PUT 到新对象后 release 附件记录未切绑，
# 下载仍返回旧文件（tar.gz 新旧大小差即暴露，sha256/sig 恒长假绿）。因此
# AIRY_FORCE_UPLOAD=1 的正确语义 = 先 DELETE 同名附件（全新 key 绑定）再 PUT。
# 拉取现有附件 {name<TAB>id}（attach 有数字 id，source 源码包无 id）。
# CUR_TAG 仅版本 tag：latest 下载面是平台「最新 release」别名（阶段 4.6
# 终验），不作为上传目标——自建 latest tag/release 会劫持别名路由，把安装
# 入口翻转到无 tarball 的新面（0.1.18 run5 排障实证），严禁。
CUR_TAG=""
EXISTING_ASSETS=""
fetch_existing_assets() {
    CUR_TAG="$1"
    EXISTING_ASSETS="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        "${API}/tags/${CUR_TAG}" 2>/dev/null \
        | python3 -c "import sys,json;print('\n'.join(f\"{a.get('name','')}\t{a.get('id') or ''}\" for a in (json.load(sys.stdin).get('assets') or [])))" 2>/dev/null || true)"
}
fetch_existing_assets "$VERSION"

# 删除远端同名附件（AIRY_FORCE_UPLOAD=1 先删后传；DELETE 失败仅告警不阻断，
# PUT 本身带幂等，残留旧附件会再暴露于上传后校验并 fail-closed）。
delete_existing_asset() {
    local b="$1" aid
    aid="$(awk -F '\t' -v n="$b" '$1==n{print $2;exit}' <<<"$EXISTING_ASSETS")"
    [ -n "$aid" ] || return 0
    if curl -fsS --connect-timeout 20 -X DELETE -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        "${API}/${CUR_TAG}/attach_files/${aid}" >/dev/null 2>&1; then
        log_ok "已删除远端同名附件（先删后传）: ${b} (asset ${aid})"
    else
        log_warn "远端附件删除失败（upload_url 将签发新 key，残留风险由校验兜底）: ${b}"
    fi
}

# 远端是否已存在同名附件（精确匹配，防文件名含 . 触发的正则误判）
asset_exists() {
    awk -F '\t' -v n="$1" '$1==n{found=1} END{exit !found}' <<<"$EXISTING_ASSETS"
}

# 远端附件内容是否与本地完全一致（sha256）。仅用于 AIRY_FORCE_UPLOAD=1 的
# 同 tag 重发：重传是发布链最长杆（windows zip 实测 43min 502 / 60min 零字节
# timeout，两次 attempt 白耗 >2h），内容已一致者免重传，把带宽集中给真正
# 缺失/变更的附件。下载侧比上传侧快且匿名 GET 直连（不走向 WAF 拦 HEAD 的
# 路径），失败即判不一致（保守回退到先删后传，语义不弱化）。
remote_matches_local() {
    local f="$1" b="$2" dlf dl_sha local_sha
    dlf="$(mktemp)"
    if curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
        --max-time 1800 -o "$dlf" \
        "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${CUR_TAG}/${b}" 2>/dev/null; then
        dl_sha="$(sha256sum "$dlf" | awk '{print $1}')"
        local_sha="$(sha256sum "$f" | awk '{print $1}')"
        rm -f "$dlf"
        [ "$dl_sha" = "$local_sha" ]
    else
        rm -f "$dlf"
        return 1
    fi
}

upload_asset() {
    local f="$1" b upjson upurl
    b="$(basename "$f")"
    # 幂等跳过：同名附件已存在且未强制 → 跳过（重跑续传）。同版本修复重发
    # 必须 AIRY_FORCE_UPLOAD=1：先删后传（delete_existing_asset），否则 OBS
    # 覆盖不生效、下载仍是旧文件（0.1.10 同 tag 重发实证）。
    if asset_exists "$b"; then
        if [ "${AIRY_FORCE_UPLOAD:-0}" != "1" ]; then
            log_warn "跳过（远端已存在同名附件，AIRY_FORCE_UPLOAD=1 可先删后传）: ${b}"
            return 0
        fi
        # 强制重发语义保留（同 tag 重发必须能覆盖 OBS 旧对象），但内容
        # 已一致者免重传——省下的带宽与墙钟全部留给真正需要重传的附件。
        if remote_matches_local "$f" "$b"; then
            log_ok "跳过（远端内容与本地一致，免重传）: ${b}"
            return 0
        fi
        delete_existing_asset "$b"
    fi
    log_info "上传: ${b}…"
    # U-1 看门狗（0.1.13 rc9 实证 2026-09-08）：大包单连接长 PUT 可能长时间
    # 零进度后 502 或白等到 --max-time 3600（windows zip 实测 43min 502 /
    # 60min 0 字节 timeout，两次 attempt 共浪费 >2h）。每文件看门狗重试：
    # curl --speed-limit 1024 --speed-time 240 —— 连续 240s 速率 <1024B/s 即
    # 中断（rc=28），杜绝白等；每次重试重新取 upload_url（预签名或已失效/
    # 残留半对象），先删残留同名再 PUT；重试耗尽仍失败才计入 UP_FAIL_LOG。
    local attempt=0 upjson upurl rc=1
    local -a uphdr=()
    while [ "$attempt" -lt "${UPLOAD_RETRY:-4}" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 1 ]; then
            log_warn "PUT 失败，重试 ${attempt}/${UPLOAD_RETRY:-4}: ${b}"
            sleep "$((attempt * 12))"
            asset_exists "$b" && delete_existing_asset "$b"
        fi
        upjson="$(curl -fsSG --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
            --data-urlencode "file_name=${b}" "${API}/${CUR_TAG}/upload_url")" \
            || { log_warn "upload_url 获取失败(尝试 ${attempt}): ${b}"; continue; }
        upurl="$(python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("url",""))' <<<"$upjson")"
        [ -n "$upurl" ] || { log_warn "upload_url 为空(尝试 ${attempt}): ${b}"; continue; }
        uphdr=()
        mapfile -t uphdr < <(python3 -c 'import json,sys
for k, v in ((json.load(sys.stdin) or {}).get("headers") or {}).items():
    print("-H"); print(f"{k}: {v}")' <<<"$upjson")
        if curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 240 \
            --max-time 3600 -X PUT "${uphdr[@]}" --upload-file "$f" "$upurl" >/dev/null 2>&1; then
            rc=0
            break
        fi
        log_warn "PUT 失败(尝试 ${attempt}, curl rc=$?): ${b}"
    done
    if [ "$rc" != 0 ]; then
        log_fail "上传失败(重试耗尽): ${b}"
        return 1
    fi
    # 上传后完整性校验（0.1.6f 强化，fail-closed）：GET 实际下载
    # 大小必须等于本地大小，防 OBS 截断/静默失败。0.1.10 实证补强：
    # 仅比大小会漏 sha256/sig/manifest 等恒长小文件的覆盖失败（新旧
    # 内容等长），故对非 tar.gz 附件追加 sha256 内容比对（大包受
    # --max-time 300 下载约束，维持大小校验 + 文件名可判别覆盖与否）。
    local local_size dl
    local_size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)"
    dl="$(curl -fsSL --connect-timeout 20 --max-time 300 -o /dev/null -w '%{size_download}' \
        "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${CUR_TAG}/${b}" 2>/dev/null || echo 0)"
    if [ "$dl" = "$local_size" ] && [ "$dl" != "0" ]; then
        case "$b" in
          *.tar.gz|*.zip)
            log_ok "已上传并校验: ${b}（${dl} 字节）" ;;
          *)
            # 恒长小文件（sha256/sig/asc/install.*/manifest）做 sha256 内容
            # 比对，杜绝"等长旧文件假绿"（0.1.10 同 tag 覆盖未生效实证）。
            # 下载走临时文件（set -euo pipefail 下 curl|sha256sum 管道
            # 失败会直接中止脚本而非走失败分支，临时文件 + if 可兜底）。
            local local_sha dl_sha dlf
            local_sha="$(sha256sum "$f" | awk '{print $1}')"
            dlf="$(mktemp)"
            dl_sha=""
            if curl -fsSL --connect-timeout 20 --max-time 120 \
                "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${CUR_TAG}/${b}" \
                -o "$dlf" 2>/dev/null; then
                dl_sha="$(sha256sum "$dlf" | awk '{print $1}')"
            fi
            rm -f "$dlf"
            if [ "$dl_sha" = "$local_sha" ]; then
                log_ok "已上传并校验: ${b}（sha256 一致）"
            else
                log_fail "上传完整性校验失败: ${b}（sha256 不一致，疑似覆盖未生效）"
                return 1
            fi ;;
        esac
    else
        log_fail "上传完整性校验失败: ${b}（远端 ${dl:-0} != 本地 ${local_size:-0} 字节）"
        return 1
    fi
}

# ─── 阶段 4.4：准备 latest/ 发布树（通道全集 + 启动器 + 密钥）─────────────
# B12（0.1.18）：安装/更新面全量收敛到 release 附件——install.sh / install.ps1 /
# airymaxrt 只读 releases/download/<tag>/，不再经 contents API + base64 直读
# 分支。为此 release 附件必须与 latest/ 代码树同构补齐：除当前通道 manifest
# 外，还须附其余通道的 manifest（通道选择 fail-closed 依赖全通道可见）与启动
# 器 airymaxrt（安装器/更新器自举源）、GPG 公钥 agentrt.asc（manifest 验签）。
# 三者缺失会让 install 侧退化成读分支，即第二套事实源（§10-8）。
# 阶段顺序：先备树再上传，最后才切 latest/ 指针——附件不齐绝不切指针。
ALL_CHANNELS="stable rc beta"

# U-02：无制品通道的「声明式 manifest」（通道选择 fail-closed）───────────
# latest/ 必须为通道全集（stable/rc/beta）各备一份 manifest。某通道从未发布
# 过制品时其 manifest 缺失，客户端 fetch 只得 404——「网络异常」与「该通道
# 暂无制品」无从区分，旧文案只能并列两种可能，用户反复无意义重试。发布链
# 在此为「latest/ 中尚无 manifest 的通道」合成显式声明（state=reserved、
# latest 空串、releases 空集）并 GPG 签名，客户端据此确定性 fail-closed 并
# 给出可用通道指引。已有 manifest 的通道一律不动（绝不覆盖真实制品指针）；
# 声明内容幂等（updated_at 取固定哨兵值），重跑不产生无意义 diff。
emit_channel_declarations() { # <latest_repo_dir> <current_channel>
    local ldir="$1" cur="$2" ch decl
    for ch in $ALL_CHANNELS; do
        [ "$ch" = "$cur" ] && continue
        decl="$ldir/latest/manifest.${ch}.json"
        [ -s "$decl" ] && continue
        python3 - "$ch" "$decl" <<'PYEOF'
import json, sys
ch, out = sys.argv[1], sys.argv[2]
manifest = {
    "schema": 1,
    "channel": ch,
    "state": "reserved",
    "latest": "",
    "updated_at": "1970-01-01T00:00:00Z",
    "releases": {},
    "notes": f"{ch} 为保留通道，暂无制品；当前可用：stable（生产）/ rc（候选）。",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF
        run gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${GPG_PASSPHRASE:-}" --armor --detach-sign \
            -o "${decl}.asc" "$decl"
        log_ok "通道声明 manifest: manifest.${ch}.json（state=reserved → 通道选择 fail-closed）"
    done
}

# 启动器源（安装器/更新器自举）：sdk 仓私有，匿名 contents API 不可达，自举
# 源必须落在公开 agentrt 发布面内。
LAUNCHER_SRC="${AIRY_LAUNCHER_SRC:-${SCRIPT_DIR}/../../../../agent-workload/sdk/tui/scripts/airymaxrt}"

LATEST_DIR="$TMP/agentrt-latest"
LATEST_READY=0
if [ "${SKIP_LATEST:-0}" = "1" ]; then
    log_warn "跳过 latest/ 发布树准备（SKIP_LATEST=1）：附件面将缺通道全集与启动器"
elif [ "$DRY_RUN" = "1" ]; then
    log_info "DRY-RUN: 跳过 latest/ 发布树准备"
else
    log_info "准备 latest/ 发布树（通道全集 + 启动器 + 密钥）…"
    # URL 内嵌 PAT 的 clone 失败时 git 会把带 token 的 URL 回显到 stderr，
    # 脱敏后输出（DRY-RUN 的 run() 同样会打印参数，须自行过滤）。
    LATEST_URL="https://oauth2:${ATOMGIT_TOKEN}@atomgit.com/${ATOMGIT_REPO}.git"
    # clone 先于上传：fail-fast（省下数百 MB 上传后才发现指针树不可得），
    # 且保证切指针时附件已齐（原子性绑定）。
    if ! clone_out="$(git clone --depth 1 "$LATEST_URL" "$LATEST_DIR" 2>&1)"; then
        printf '%s\n' "$clone_out" | redact >&2
        log_fail "latest/ 仓 clone 失败（输出已脱敏）"
        exit 1
    fi
    mkdir -p "$LATEST_DIR/latest/keys"
    cp -f "$MANIFEST" "$MANIFEST.asc" "$LATEST_DIR/latest/" 2>/dev/null || true
    # 公钥随 latest/ 发布（latest/keys/），与 install.sh / airymaxrt 拉取路径
    # 一致，支持密钥轮换同步。
    cp -f "$KEYS_DIR/agentrt.asc" "$KEYS_DIR/cosign.pub" "$LATEST_DIR/latest/keys/" 2>/dev/null || true
    if [ -f "$LAUNCHER_SRC" ]; then
        cp -f "$LAUNCHER_SRC" "$LATEST_DIR/latest/airymaxrt"
    else
        log_warn "未找到更新器源: ${LAUNCHER_SRC}（二进制模式 update 自举将不可用）"
    fi
    # 仅在可签名时执行：SKIP_SIGN/SKIP_GPG 下无有效签名，客户端 GPG 验签必然
    # 失败（误导为“签名被篡改”），宁缺不假签。
    if [ "$SKIP_SIGN" = "1" ] || [ "$SKIP_GPG" = "1" ]; then
        log_warn "跳过保留通道声明 manifest（SKIP_SIGN/SKIP_GPG，无法产生有效签名）"
    elif command -v gpg >/dev/null 2>&1; then
        emit_channel_declarations "$LATEST_DIR" "$CHANNEL"
    else
        log_warn "跳过保留通道声明 manifest（gpg 不可用）"
    fi
    LATEST_READY=1
fi

# 附件面 manifest 集：备树成功时取 latest/ 树内通道全集（与代码树逐字节同
# 源），否则退回仅当前通道（SKIP_LATEST/DRY-RUN 的降级路径）。
MANIFEST_ASSETS=()
if [ "$LATEST_READY" = "1" ]; then
    for f in "$LATEST_DIR"/latest/manifest.*.json "$LATEST_DIR"/latest/manifest.*.json.asc; do
        [ -f "$f" ] && MANIFEST_ASSETS+=("$f")
    done
else
    [ -f "$MANIFEST" ] && MANIFEST_ASSETS+=("$MANIFEST")
    [ -f "$MANIFEST.asc" ] && MANIFEST_ASSETS+=("$MANIFEST.asc")
fi

# 启动器附件：备树成功时取树内副本（与代码树同源），否则直接取 sdk 源。
LAUNCHER_ASSET=""
if [ "$LATEST_READY" = "1" ] && [ -f "$LATEST_DIR/latest/airymaxrt" ]; then
    LAUNCHER_ASSET="$LATEST_DIR/latest/airymaxrt"
elif [ -f "$LAUNCHER_SRC" ]; then
    LAUNCHER_ASSET="$LAUNCHER_SRC"
fi

# GPG 公钥：manifest 验签必需件（附件面扁平名，无 keys/ 子路径——release
# 附件域不支持目录结构）。
PUBKEY_ASSET=""
if [ -f "$KEYS_DIR/agentrt.asc" ]; then
    PUBKEY_ASSET="$KEYS_DIR/agentrt.asc"
else
    log_warn "未找到 GPG 公钥: ${KEYS_DIR}/agentrt.asc（客户端将退回内置公钥）"
fi

# ─── 阶段 4.5：并行上传所有附件 ────────────────────────────────────────

# 上传制品 + sha256 校验件 + cosign 签名（*.sig）+ manifest + manifest GPG 签名。
# cosign 签名必须随制品发布，客户端方可校验供应链完整性（防断链）；
# sha256 校验件同步发布，供手动完整性核验（sha256sum -c）。
# 安装器一并随附件发布（releases/download/<tag>/install.sh）：AtomGit raw
# 域对 .sh 返回 HTML 预览页不可直连，contents API 拉取需 curl+python3 三段
# 管道，社区用户体验差；release 附件域匿名 GET 直连可用（2026-08-28 实测，
# HEAD 会被 WAF 拒 401，GET 正常），一键安装命令缩短为一行 curl | bash。
INSTALLER_SRC="${AIRY_INSTALLER_SRC:-${SCRIPT_DIR}/../../../../agent-workload/agentrt/scripts/install.sh}"
INSTALLER_PS1_SRC="${AIRY_INSTALLER_PS1_SRC:-${SCRIPT_DIR}/../../../../agent-workload/agentrt/scripts/install.ps1}"
INSTALLER=""
if [ -f "$INSTALLER_SRC" ]; then
    INSTALLER="$INSTALLER_SRC"
else
    log_warn "未找到安装器源: ${INSTALLER_SRC}（一键安装短链将不可用）"
fi
# Windows 安装器随附件一并发布（raw 域对 .ps1 返回 HTML 不可直连，
# release 附件域匿名 GET 直连可用，PowerShell 一键安装命令缩短为一行）。
INSTALLER_PS1=""
if [ -f "$INSTALLER_PS1_SRC" ]; then
    INSTALLER_PS1="$INSTALLER_PS1_SRC"
else
    log_warn "未找到 Windows 安装器源: ${INSTALLER_PS1_SRC}（PowerShell 一键安装将不可用）"
fi
# 安装器快照同步（SSoT → 发布工作区离线归档快照，0.1.6 根治历史漂移）：
# agentrt/scripts/install.{sh,ps1} 是安装器唯一权威源（SSoT）；发布时必须
# 同步到 works-engineering/developbuild/agentrt/scripts 快照（离线介质
# install-offline.sh 的自包含依赖），否则两处脚本再次分叉（历史教训：0.1.5
# 快照残留旧公钥与旧版本号，导致离线安装与在线安装行为不一致）。
SNAPSHOT_DIR="${AIRY_DEVELOPBUILD_SNAPSHOT_DIR:-${AIRY_WORKSPACE}/developbuild/agentrt/scripts}"
if [ -d "$SNAPSHOT_DIR" ] && [ -f "$INSTALLER_SRC" ] && [ -f "$INSTALLER_PS1_SRC" ]; then
    cp -f "$INSTALLER_SRC" "$SNAPSHOT_DIR/install.sh"
    cp -f "$INSTALLER_PS1_SRC" "$SNAPSHOT_DIR/install.ps1"
    log_ok "安装器快照已同步: ${SNAPSHOT_DIR}"
fi
# 并行上传（0.1.6f 强化）：6 架构 × 3 附件 + manifest/installer 约 24 文件，
# 串行 PUT 大包（35-45MB）耗时显著；限 3 并发（避免打爆 atomgit API 限流），
# 任一失败记入失败清单，全部结束后 fail-closed 中止。
# I-upload（0.1.13）：并发数参数化（UPLOAD_PAR 环境可调）。2026-09-06 正式
# run 34031064018 实证：3 并发下总吞吐 ~80KB/s（178MB/37min，单流 23-64KB/s），
# 疑似单连接级限流 → 提高并发或可线性增益；边界由 upload-speed-probe.sh 在
# runner 侧 A/B 实测（PAR=3/6/8）定界后再调默认值。
UPLOAD_PAR="${UPLOAD_PAR:-3}"
UP_FAIL_LOG="$TMP/upfailed.txt"
rm -f "$UP_FAIL_LOG"
for f in "${ARTIFACTS[@]}" "${ARTIFACTS[@]/%/.sha256}" "${ARTIFACTS[@]/%/.sig}" \
         "$INSTALLER" "$INSTALLER_PS1" "${MANIFEST_ASSETS[@]}" "$PUBKEY_ASSET" "$LAUNCHER_ASSET"; do
    [ -e "$f" ] || continue
    ( upload_asset "$f" || echo "$(basename "$f")" >> "$UP_FAIL_LOG" ) &
    while [ "$(jobs -rp | wc -l)" -ge "$UPLOAD_PAR" ]; do wait -n 2>/dev/null || break; done
done
wait 2>/dev/null || true
if [ -s "$UP_FAIL_LOG" ]; then
    log_fail "存在上传失败附件（$(wc -l < "$UP_FAIL_LOG") 个），中止发布（修复后重跑可续传，已成功附件自动跳过）:"
    sed 's/^/  /' "$UP_FAIL_LOG" | head -10
    exit 1
fi

# ─── 阶段 4.6：滚动 latest 入口面终验（B12 唯一事实源 = 平台别名）────────
# releases/download/latest/ 是 atomgit 平台级「最新 release」别名（302 动态
# 路由到最新 release 附件面，非 git tag——0.1.18 实证：releases/tags/latest
# 404、ls-remote 无 refs/tags/latest、别名面与真实 tag 面同一 OBS 对象）。
# 版本面附件全数上传校验通过（阶段 4.5）后，新 release 即自动成为别名目标；
# 严禁自建 latest tag/release 去「同步」该面——那会劫持别名路由，把安装
# 入口翻转到无 tarball 的新面（run5 排障实证的结构性风险）。本阶段只做
# fail-closed 终验：
#   1. stable 发布：GET /releases/latest 断言 tag_name == VERSION（有界
#      重试覆盖平台索引延迟）；
#   2. rc/beta 预发布：安装入口面恒守稳定版，断言别名 ≠ 本版本；
#   3. 入口件匿名 GET 抽查（本次发布的安装器/启动器/公钥/manifest 全集）
#      逐一 200 可达（附件域 HEAD 被 WAF 拒，用 GET 状态码）。
if [ "$DRY_RUN" = "1" ]; then
    log_info "DRY-RUN: 跳过滚动 latest 入口面终验"
else
    log_info "终验滚动 latest 入口面（平台别名 → 最新 release）…"
    resolve_alias_tag() {
        curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
            "${API}/latest" 2>/dev/null \
            | python3 -c "import sys,json;print((json.load(sys.stdin) or {}).get('tag_name',''))" 2>/dev/null || true
    }
    ALIAS_TAG=""
    ALIAS_TRY=0
    while [ "$ALIAS_TRY" -lt "${ALIAS_VERIFY_RETRY:-8}" ]; do
        ALIAS_TRY=$((ALIAS_TRY + 1))
        ALIAS_TAG="$(resolve_alias_tag)"
        if [ "$PRERELEASE" = "false" ]; then
            [ "$ALIAS_TAG" = "$VERSION" ] && break
        elif [ -n "$ALIAS_TAG" ] && [ "$ALIAS_TAG" != "$VERSION" ]; then
            break
        fi
        sleep 15
    done
    if [ "$PRERELEASE" = "false" ]; then
        [ "$ALIAS_TAG" = "$VERSION" ] || \
            { log_fail "latest 别名未指向 ${VERSION}（现指向: ${ALIAS_TAG:-无}），安装入口面不可信，中止发布"; exit 1; }
    else
        [ -n "$ALIAS_TAG" ] && [ "$ALIAS_TAG" != "$VERSION" ] || \
            { log_fail "latest 别名异常（指向: ${ALIAS_TAG:-无}）：预发布不得翻转安装入口面，中止发布"; exit 1; }
        log_ok "latest 别名恒守稳定版: ${ALIAS_TAG}（预发布 ${VERSION} 不翻转入口面）"
    fi
    LATEST_SPOT=()
    [ -n "$INSTALLER" ] && LATEST_SPOT+=("install.sh")
    [ -n "$INSTALLER_PS1" ] && LATEST_SPOT+=("install.ps1")
    [ -n "$PUBKEY_ASSET" ] && LATEST_SPOT+=("agentrt.asc")
    [ -n "$LAUNCHER_ASSET" ] && LATEST_SPOT+=("airymaxrt")
    for f in "${MANIFEST_ASSETS[@]}"; do LATEST_SPOT+=("$(basename "$f")"); done
    LATEST_SPOT_FAIL=0
    for n in "${LATEST_SPOT[@]}"; do
        code="$(curl -skL --connect-timeout 20 --max-time 120 -o /dev/null -w '%{http_code}' \
            "https://atomgit.com/${ATOMGIT_REPO}/releases/download/latest/${n}" 2>/dev/null || echo 000)"
        if [ "$code" = "200" ]; then
            log_ok "入口件可达: latest/${n}"
        else
            log_warn "入口件不可达: latest/${n}（HTTP ${code}）"
            LATEST_SPOT_FAIL=1
        fi
    done
    [ "$LATEST_SPOT_FAIL" = "0" ] || \
        { log_fail "latest 入口面抽查未全数通过，中止发布"; exit 1; }
    log_ok "滚动 latest 入口面已就绪（别名 → ${ALIAS_TAG}，入口件全 200）"
fi

# ─── 阶段 5：latest/ 代码树归档快照提交 ──────────────────────────────────
# B12（乙口径）后客户端读取面是滚动 latest 别名附件面（阶段 4.6 终验），
# 代码树 latest/ 仅作同源归档快照 + 下轮发布的他通道 manifest 种子。顺序
# 不可倒置：版本 tag 附件校验 → latest 入口面终验 → 树快照提交，客户端
# 永不看到"指针已新、附件未齐"。仓库侧不留任何 latest git tag：下载面按
# release tag_name 经平台别名解析，git tag 与其无关，自建反有劫持风险。
if [ "$LATEST_READY" = "1" ]; then
    # 仓库 .gitignore 为白名单制（默认忽略一切），latest/ 天然被忽略，
    # 必须 -f 强制加入，否则 add 静默失败且 set -e 中止整个发布。
    git -C "$LATEST_DIR" add -A -f latest/
    if git -C "$LATEST_DIR" -c user.name="agentrt-bot" -c user.email="release@agentrt.airymax.io" \
        commit -m "release: update manifest.${CHANNEL}.json for ${VERSION}" >/dev/null 2>&1; then
        log_info "latest/ 归档快照已提交"
    else
        log_warn "latest/ 无变更或提交失败"
    fi
    if git -C "$LATEST_DIR" push origin HEAD:main >/dev/null 2>&1; then
        log_info "latest/ 归档快照已推送 main"
    else
        log_warn "latest/ push 失败（可手动同步）"
    fi
    # P23 根修：manifest commit 双端同步。历史缺陷（6186a5cd1 实证）：
    # 本阶段只 clone/push atomgit，GitHub main 永远收不到 manifest 更新
    # commit，双端分叉只能手动 merge（cef8f277 补丁）。两仓为同一提交图
    # 的镜像，此处向 GitHub main 补推同一 commit（fail-soft：失败仅告警，
    # 不阻断 atomgit 发布主链路）。
    if [ -n "${GITHUB_REPO:-}" ] && [ -n "${GITHUB_PAT:-}" ]; then
        if git -C "$LATEST_DIR" push \
            "https://x-access-token:${GITHUB_PAT}@github.com/${GITHUB_REPO}.git" \
            HEAD:main >/dev/null 2>&1; then
            log_ok "latest/ manifest 已同步 GitHub main"
        else
            log_warn "latest/ manifest 同步 GitHub 失败（双端分叉时 non-fast-forward，需手动 merge）"
        fi
    else
        log_warn "GITHUB_REPO/GITHUB_PAT 未设置，跳过 GitHub manifest 同步"
    fi
    log_ok "latest/manifest.${CHANNEL}.json 已更新"
fi

# ─── 阶段 6：版本保留处理（社区窗口：每通道仅留最新 N 版）─────────────────
# 发布即收敛：窗口处理放在发布主链路末端（latest/ 已更新、manifest.releases
# 只引用当前版本），此时删除超窗旧 Release 不影响本次发布产物一致性。
airy_prune_old

log_ok "发布完成: ${VERSION}（${CHANNEL}）"
