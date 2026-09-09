#!/usr/bin/env bash
# ============================================================================
# AgentRT 发布镜像：把 atomgit Release（SSoT）同一附件集镜像到
# GitHub Releases 与 Gitee Releases
#
# 背景（0.1.13 M13，用户实证反馈）：publish-release.sh 仅向 atomgit 上传
# 附件，GitHub/Gitee 长期"只有 tag 没有 Releases（空，无二进制包）"。
# 本脚本在 atomgit 发布成功后，把同一 dist 附件集（平台包 tar.gz/zip +
# sha256 + cosign sig + manifest.<channel>.json + GPG asc + install.sh/ps1）
# 镜像到两平台，附件字节与 atomgit 完全同源（不再经 atomgit 慢通道回拉大件）。
#
# 幂等（同版本重跑安全，对齐 C4 覆盖语义）：
#   - 同名同大小附件 → 跳过（不重复上传、不产生重复附件）；
#   - 同名不同大小附件 → 删除后重传（GH）；Gitee 无附件删除 API，跳过并告警；
#   - Release 元数据（标题/正文/prerelease）每次强制对齐。
#
# 用法：
#   ./publish-mirror.sh v0.1.13-rc9 [DIST_DIR]
# 环境变量：
#   GH_TOKEN            GitHub 令牌（需 contents:write；CI 用 GITHUB_TOKEN）
#   GITEE_TOKEN         Gitee 访问令牌（复用 sync-mirror 的 GT_TOKEN）
#   GITHUB_REPO         默认 openairymax/agentrt
#   GITEE_REPO          默认 openairymax/agentrt
#   FETCH_MISSING=1     dist 缺件时从 atomgit release 下载补齐（历史版本
#                       回填模式：release-dist 工件天然缺 manifest/sig 小件）
#   DRY_RUN=1           模拟（零网络：仅打印将执行的动作）
# 退出：fail-closed——任一平台任一附件失败即非零退出。
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

VERSION="${1:-}"
DIST_DIR="${2:-}"
DRY_RUN="${DRY_RUN:-0}"
FETCH_MISSING="${FETCH_MISSING:-0}"
GITHUB_REPO="${GITHUB_REPO:-openairymax/agentrt}"
GITEE_REPO="${GITEE_REPO:-openairymax/agentrt}"
ATOMGIT_REPO="${ATOMGIT_REPO:-openairymax/agentrt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 凭据脱敏（对齐 publish-release.sh redact 语义）：Gitee access_token 走
# query/form，curl 失败时会把完整 URL 回显到 stderr，必须过滤。
redact() { sed -E 's#(https?://)[^/?]*[^?]*\?*#https://***#' /dev/null; \
           sed -E 's#access_token=[^&" ]*#access_token=***#g'; }

[ -n "$VERSION" ] || { echo "用法: $0 <版本号> [DIST_DIR]"; exit 1; }
[ -n "$DIST_DIR" ] && [ -d "$DIST_DIR" ] || { log_fail "DIST_DIR 不存在: ${DIST_DIR:-<空>}"; exit 1; }

# ─── 通道判定（与 publish-release.sh 同源）─────────────────────────────────
case "$VERSION" in
    *-rc*)     CHANNEL="rc";     PRERELEASE="true" ;;
    *-beta*)   CHANNEL="beta";   PRERELEASE="true" ;;
    *)         CHANNEL="stable"; PRERELEASE="false" ;;
esac
log_info "AgentRT 发布镜像 ${VERSION}（通道: ${CHANNEL}）"
log_info "制品目录: ${DIST_DIR}  目标: ${GITHUB_REPO} (GitHub) + ${GITEE_REPO} (Gitee)"

# ─── 收集附件（与 publish-release.sh 上传清单完全同口径）───────────────────
ARTIFACTS=()
for f in "$DIST_DIR"/agentrt-${VERSION}-*.tar.gz "$DIST_DIR"/agentrt-${VERSION}-*.zip; do
    [ -e "$f" ] || continue
    ARTIFACTS+=("$f")
done
[ "${#ARTIFACTS[@]}" -gt 0 ] || { log_fail "dist 无平台包（agentrt-${VERSION}-*）"; exit 1; }

MANIFEST="$DIST_DIR/manifest.${CHANNEL}.json"
declare -a ASSETS=()
for f in "${ARTIFACTS[@]}" "${ARTIFACTS[@]/%/.sha256}" "${ARTIFACTS[@]/%/.sig}" \
         "$MANIFEST" "$MANIFEST.asc" "$DIST_DIR/install.sh" "$DIST_DIR/install.ps1"; do
    if [ -e "$f" ]; then
        ASSETS+=("$f")
    elif [ "$FETCH_MISSING" = "1" ]; then
        # 回填模式：从 atomgit release 下载缺件（历史版本回填典型场景：
        # release-dist 工件缺 manifest/asc/sig 等发布期生成的小件）
        url="https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}/$(basename "$f")"
        log_warn "dist 缺件，回填: $(basename "$f") <- atomgit"
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN: curl -fsSL -o '$f' '$url'"
            ASSETS+=("$f")   # DRY-RUN 假定回填成功，走通后续打印
        elif curl -fsSL --connect-timeout 20 --retry 3 -o "$f" "$url"; then
            ASSETS+=("$f")
        else
            log_fail "回填失败: $(basename "$f")（atomgit release 无此附件？）"
            echo "fetch:$(basename "$f")" >> "$TMP/failed.txt"
        fi
    else
        log_fail "dist 缺件: $(basename "$f")（FETCH_MISSING=1 可从 atomgit 回填）"
        echo "missing:$(basename "$f")" >> "$TMP/failed.txt"
    fi
done

# 发布说明正文：RELEASE_NOTES / RELEASE_NOTES_FILE 显式传入优先，
# 其次 release job 生成的 notes.txt，最后兜底一行（与 publish-release.sh
# 语义对齐）。body 面向社区公开场合，不得出现内部工程流水。
if [ -n "${RELEASE_NOTES:-}" ]; then
    BODY="$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$RELEASE_NOTES")"
elif [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    BODY="$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1],encoding="utf-8").read()))' "$RELEASE_NOTES_FILE")"
elif [ -f "$DIST_DIR/notes.txt" ]; then
    BODY="$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1],encoding="utf-8").read()))' "$DIST_DIR/notes.txt")"
else
    BODY="$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$(printf "AgentRT ${VERSION}\n\nhttps://atomgit.com/${ATOMGIT_REPO}/releases/tag/${VERSION}")")"
fi

if [ "${#ASSETS[@]}" -eq 0 ]; then
    log_fail "无可镜像附件"; exit 1
fi
log_info "待镜像附件 ${#ASSETS[@]} 个"

# ─── 阶段 1：GitHub Releases ───────────────────────────────────────────────
gh_api() {
    curl -fsS --connect-timeout 20 \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" "$@" 2>&1
}

if [ "${GH_TOKEN:-}" ] && [ "$DRY_RUN" != "1" ]; then
    # 前置：tag 必须已在 GH（sync-mirror 同步）。GH create release 对不存在
    # 的 tag 会静默在默认分支头建 tag——那是错误对象，必须 fail-closed。
    if ! gh_api "https://api.github.com/repos/${GITHUB_REPO}/git/ref/tags/${VERSION}" >/dev/null; then
        log_fail "GitHub 缺 tag ${VERSION}（先由 sync-mirror 同步，再镜像）"
        echo "gh:tag-missing" >> "$TMP/failed.txt"
    else
        rel_json="$(gh_api "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION}" || true)"
        REL_ID=""
        if [ -n "$rel_json" ]; then
            REL_ID="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' <<<"$rel_json" 2>/dev/null || true)"
        fi
        if [ -n "$REL_ID" ]; then
            log_info "GitHub release 已存在 (id=${REL_ID})，对齐元数据…"
        else
            log_info "创建 GitHub release ${VERSION}…"
            create_json="$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"body":json.loads(sys.argv[2]),"prerelease":sys.argv[3]=="true"}))' "$VERSION" "$BODY" "$PRERELEASE")"
            rel_json="$(gh_api -X POST -H "Content-Type: application/json" \
                -d "$create_json" "https://api.github.com/repos/${GITHUB_REPO}/releases" || true)"
            REL_ID=""
            [ -n "$rel_json" ] && REL_ID="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' <<<"$rel_json" 2>/dev/null || true)"
            if [ -n "$REL_ID" ]; then log_ok "GitHub release 已创建 (id=${REL_ID})"; else
                log_fail "GitHub release 创建失败"; echo "gh:create" >> "$TMP/failed.txt"; fi
        fi
        if [ -n "${REL_ID:-}" ]; then
            # 元数据强制对齐（幂等）
            patch_json="$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"body":json.loads(sys.argv[2]),"prerelease":sys.argv[3]=="true"}))' "$VERSION" "$BODY" "$PRERELEASE")"
            gh_api -X PATCH -H "Content-Type: application/json" -d "$patch_json" \
                "https://api.github.com/repos/${GITHUB_REPO}/releases/${REL_ID}" >/dev/null \
                || { log_fail "GitHub release 元数据对齐失败"; echo "gh:patch" >> "$TMP/failed.txt"; }
            # 现有附件清单：name size id。注意 f-string 表达式内不得用 \"
            # 转义（Python<3.12 语法错误，rc9 实证清单恒空→重传撞 422）。
            gh_api "https://api.github.com/repos/${GITHUB_REPO}/releases/${REL_ID}/assets?per_page=100" \
                | python3 -c 'import json,sys
for a in json.load(sys.stdin): print(a["name"], a["size"], a["id"])' > "$TMP/gh-assets.txt" \
                || { : > "$TMP/gh-assets.txt"; log_warn "GitHub 附件清单获取失败，按全量新传处理"; }
            for f in "${ASSETS[@]}"; do
                b="$(basename "$f")"; sz="$(stat -c%s "$f")"
                line="$(grep -F "$b " "$TMP/gh-assets.txt" | head -1 || true)"
                if [ -n "$line" ]; then
                    esz="$(awk '{print $2}' <<<"$line")"; aid="$(awk '{print $3}' <<<"$line")"
                    if [ "$esz" = "$sz" ]; then log_ok "GitHub 已有（跳过）: ${b}"; continue; fi
                    log_warn "GitHub 同名不同大小（${esz}≠${sz}），删除重传: ${b}"
                    gh_api -X DELETE "https://api.github.com/repos/${GITHUB_REPO}/releases/assets/${aid}" >/dev/null \
                        || { log_fail "GitHub 旧附件删除失败: ${b}"; echo "gh:${b}" >> "$TMP/failed.txt"; continue; }
                fi
                log_info "GitHub 上传: ${b} (${sz}B)"
                if gh_api -X POST -H "Content-Type: application/octet-stream" --data-binary @"$f" \
                    "https://uploads.github.com/repos/${GITHUB_REPO}/releases/${REL_ID}/assets?name=${b}" \
                    >"$TMP/up.out"; then
                    log_ok "GitHub 上传完成: ${b}"
                elif grep -q 'already_exists' "$TMP/up.out" 2>/dev/null; then
                    # 422 already_exists=服务端同名确认（dedup 清单竞态兜底）：
                    # 内容同源（atomgit SSOT 同一 dist），按幂等成功处理，
                    # 不再误报 fail（rc9 实证 18 资产被误报）。
                    log_ok "GitHub 已有（服务端确认，幂等跳过）: ${b}"
                else
                    log_fail "GitHub 上传失败: ${b}（错误体尾部如下）"
                    tail -c 400 "$TMP/up.out" | sed 's/^/    up: /'
                    echo "gh:${b}" >> "$TMP/failed.txt"
                fi
            done
        fi
    fi
else
    [ "$DRY_RUN" = "1" ] && log_info "DRY-RUN: 跳过 GitHub 镜像（${#ASSETS[@]} 个附件）" \
        || { log_fail "缺 GH_TOKEN"; echo "gh:no-token" >> "$TMP/failed.txt"; }
fi

# ─── 阶段 2：Gitee Releases ────────────────────────────────────────────────
gitee_api() {
    local out rc
    out="$(curl -fsS --connect-timeout 20 "$@" 2> >(redact >&2))"; rc=$?
    [ $rc -eq 0 ] && printf '%s' "$out"
    return $rc
}

if [ "${GITEE_TOKEN:-}" ] && [ "$DRY_RUN" != "1" ]; then
    # 前置：tag 必须已在 Gitee（sync-mirror 同步）；否则 release 会绑错对象。
    # 端点用列表 GET /tags（Gitee v5 无单 tag 详情端点 /tags/{tag}——即使
    # tag 存在也回 HTML 404 页而非 JSON，rc9 双向实证；/repository/tags 同
    # 样不存在恒 404）。per_page=100 单页覆盖；tag 名精确匹配防前缀误配。
    if ! gitee_api -G "https://gitee.com/api/v5/repos/${GITEE_REPO}/tags" \
            --data-urlencode "access_token=${GITEE_TOKEN}" \
            --data-urlencode "per_page=100" \
            | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if isinstance(d,list) and any(t.get("name")==sys.argv[1] for t in d if isinstance(t,dict)) else 1)' "$VERSION"; then
        log_fail "Gitee 缺 tag ${VERSION}（先由 sync-mirror 同步，再镜像）"
        echo "gitee:tag-missing" >> "$TMP/failed.txt"
    else
        gitee_rel="$(gitee_api -G "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/tags/${VERSION}" \
            --data-urlencode "access_token=${GITEE_TOKEN}" || true)"
        GREL_ID="$(python3 -c 'import json,sys
d=json.load(sys.stdin)
if isinstance(d,list): d=d[0] if d else {}
print(d.get("id",""))' <<<"$gitee_rel" 2>/dev/null || true)"
        if [ -n "$GREL_ID" ]; then
            log_info "Gitee release 已存在 (id=${GREL_ID})，对齐元数据…"
            # JSON 失败自动 form 重试：Gitee v5 部分端点对 JSON PATCH 兼容性
            # 差（与 POST 同源，rc9 实证 POST JSON 400）；对齐失败不阻断。
            if ! gitee_api -X PATCH -H "Content-Type: application/json" \
                "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GREL_ID}?access_token=${GITEE_TOKEN}" \
                -d "$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"body":json.loads(sys.argv[2]),"prerelease":sys.argv[3]=="true"}))' "$VERSION" "$BODY" "$PRERELEASE")" >/dev/null; then
                curl -sS --connect-timeout 20 -X PATCH \
                    "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GREL_ID}" \
                    --data-urlencode "access_token=${GITEE_TOKEN}" \
                    --data-urlencode "name=${VERSION}" \
                    --data-urlencode "body=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]))' "$BODY")" \
                    --data-urlencode "prerelease=${PRERELEASE}" >/dev/null 2>&1 \
                    || { log_warn "Gitee release 元数据对齐失败（不阻断附件上传）"; }
            fi
        else
            log_info "创建 Gitee release ${VERSION}…"
            # 裸 curl + -w %{http_code} 判定（gitee_api 的 -f 吞响应体，
            # 400 无从取证——rc9 实证）。JSON 失败自动 form 编码重试。
            # Gitee v5 创建 release 必填 target_commitish（GitHub 可选；
            # rc9 二次实证缺省 400 {"messages":["target_commitish is
            # missing"]}）。tag 已存在时该字段仅作占位，取仓库默认分支
            # （动态获取防硬编码过时）。
            _GITEE_DEFBRANCH="$(gitee_api -G "https://gitee.com/api/v5/repos/${GITEE_REPO}" \
                --data-urlencode "access_token=${GITEE_TOKEN}" \
                | python3 -c 'import json,sys;print(json.load(sys.stdin).get("default_branch","master"))' 2>/dev/null || echo master)"
            [ -n "$_GITEE_DEFBRANCH" ] || _GITEE_DEFBRANCH=master
            printf '%s' "$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"body":json.loads(sys.argv[2]),"prerelease":sys.argv[3]=="true","target_commitish":sys.argv[4]}))' "$VERSION" "$BODY" "$PRERELEASE" "$_GITEE_DEFBRANCH")" >"$TMP/grel-payload.json"
            _REL_CODE="$(curl -sS --connect-timeout 20 -X POST -H "Content-Type: application/json" \
                "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases?access_token=${GITEE_TOKEN}" \
                --data-binary @"$TMP/grel-payload.json" \
                -o "$TMP/grel.out" -w '%{http_code}' 2>"$TMP/grel.err" || true)"
            if [ "${_REL_CODE}" != "200" ] && [ "${_REL_CODE}" != "201" ]; then
                log_warn "Gitee release JSON 创建 HTTP ${_REL_CODE:-?}: $(tail -c 240 "$TMP/grel.out" 2>/dev/null | tr '\n' ' ' || true)"
                log_info "Gitee release form 编码重试…"
                _REL_CODE="$(curl -sS --connect-timeout 20 -X POST \
                    "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases" \
                    --data-urlencode "access_token=${GITEE_TOKEN}" \
                    --data-urlencode "tag_name=${VERSION}" \
                    --data-urlencode "name=${VERSION}" \
                    --data-urlencode "body=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]))' "$BODY")" \
                    --data-urlencode "prerelease=${PRERELEASE}" \
                    --data-urlencode "target_commitish=${_GITEE_DEFBRANCH}" \
                    -o "$TMP/grel.out" -w '%{http_code}' 2>"$TMP/grel.err" || true)"
            fi
            if [ "${_REL_CODE}" = "200" ] || [ "${_REL_CODE}" = "201" ]; then
                GREL_ID="$(python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("id","") if isinstance(d,dict) else "")' <"$TMP/grel.out" 2>/dev/null || true)"
                log_ok "Gitee release 已创建 (id=${GREL_ID})"
            else
                log_fail "Gitee release 创建失败（HTTP ${_REL_CODE:-?}，错误体尾部如下）"
                tail -c 400 "$TMP/grel.out" 2>/dev/null | sed 's/^/    rel: /' || true
                tail -c 200 "$TMP/grel.err" 2>/dev/null | sed 's/^/    err: /' || true
                echo "gitee:create" >> "$TMP/failed.txt"
            fi
        fi
        if [ -n "${GREL_ID:-}" ]; then
            # 现有附件名清单（Gitee 无附件删除 API：同名一律跳过；大小差异仅告警）
            gitee_api -G "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GREL_ID}/attach_files" \
                --data-urlencode "access_token=${GITEE_TOKEN}" \
                | python3 -c 'import json,sys
try:
    for a in json.load(sys.stdin): print(a.get("name",""), a.get("size",""))
except Exception:
    pass' > "$TMP/gitee-assets.txt" || { : > "$TMP/gitee-assets.txt"; log_warn "Gitee 附件清单获取失败，按全量新传处理"; }
            for f in "${ASSETS[@]}"; do
                b="$(basename "$f")"; sz="$(stat -c%s "$f")"
                if grep -qF "$b" "$TMP/gitee-assets.txt"; then
                    esz="$(awk -v n="$b" '$1==n{print $2}' "$TMP/gitee-assets.txt" | head -1)"
                    if [ -n "$esz" ] && [ "$esz" != "$sz" ]; then
                        log_warn "Gitee 同名不同大小（${esz}≠${sz}，无删除 API 人工核对）: ${b}"
                    fi
                    log_ok "Gitee 已有（跳过）: ${b}"; continue
                fi
                log_info "Gitee 上传: ${b} (${sz}B)"
                if gitee_api -X POST \
                    -F "access_token=${GITEE_TOKEN}" -F "file=@${f}" \
                    "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GREL_ID}/attach_files" >/dev/null; then
                    log_ok "Gitee 上传完成: ${b}"
                else
                    log_fail "Gitee 上传失败: ${b}"; echo "gitee:${b}" >> "$TMP/failed.txt"
                fi
            done
        fi
    fi
else
    [ "$DRY_RUN" = "1" ] && log_info "DRY-RUN: 跳过 Gitee 镜像（${#ASSETS[@]} 个附件）" \
        || { log_fail "缺 GITEE_TOKEN"; echo "gitee:no-token" >> "$TMP/failed.txt"; }
fi

# ─── 汇总（fail-closed）────────────────────────────────────────────────────
if [ -f "$TMP/failed.txt" ] && [ -s "$TMP/failed.txt" ]; then
    log_fail "镜像存在失败项（修复后重跑，幂等续传）:"
    sed 's/^/  /' "$TMP/failed.txt"
    exit 1
fi
log_ok "发布镜像完成: ${VERSION} → GitHub ${GITHUB_REPO} + Gitee ${GITEE_REPO}"
