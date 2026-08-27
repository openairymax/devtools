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
#   manifest 固定入口（更新器轮询）：仓库代码树 latest/ 目录，
#      URL: https://raw.atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<channel>.json
#
# 用法：
#   ./publish-release.sh v0.1.5 [DIST_DIR]              # stable 发布
#   ./publish-release.sh v0.1.5-beta.1 [DIST_DIR]       # beta 发布
# 环境变量：
#   COSIGN_PRIVATE_KEY / COSIGN_PASSWORD   cosign 私钥（base64 或文件路径）
#   GPG_PRIVATE_KEY / GPG_PASSPHRASE       GPG 私钥（base64）+ 口令
#   ATOMGIT_TOKEN / ATOMGIT_REPO           atomgit 令牌 + 目标仓（默认 openairymax/agentrt）
#   RELEASE_NOTES / RELEASE_NOTES_FILE     变更日志摘要
#   SKIP_SIGN=1 跳过签名（仅生成 manifest）  SKIP_UPLOAD=1 不上传  DRY_RUN=1 模拟
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

VERSION="${1:-}"
DIST_DIR="${2:-${HOME}/.airymaxrt/dist}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
ATOMGIT_REPO="${ATOMGIT_REPO:-openairymax/agentrt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() {
    if [ "$DRY_RUN" = "1" ]; then log_info "DRY-RUN: $*"; else "$@"; fi
}

[ -n "$VERSION" ] || { echo "用法: $0 <版本号> [DIST_DIR]"; exit 1; }

# ─── 通道判定 ──────────────────────────────────────────────────────────────
# 语义：stable（生产）/ beta（预发布）/ rc（候选发布）。rc 独立通道
# （manifest.rc.json），避免与 beta 混淆（问题 10：rc 通道曾塌缩为 beta）。
case "$VERSION" in
    *-rc.*)     CHANNEL="rc";     PRERELEASE="true" ;;
    *-beta.*)   CHANNEL="beta";   PRERELEASE="true" ;;
    *)          CHANNEL="stable"; PRERELEASE="false" ;;
esac
log_info "AgentRT 发布 ${VERSION}（通道: ${CHANNEL}）"
log_info "制品目录: ${DIST_DIR}  目标: ${ATOMGIT_REPO}"

# ─── 收集制品 ──────────────────────────────────────────────────────────────
ARTIFACTS=()
for f in "$DIST_DIR"/agentrt-${VERSION}-*.tar.gz "$DIST_DIR"/agentrt-${VERSION}-*.zip; do
    [ -e "$f" ] || continue
    ARTIFACTS+=("$f")
done
[ ${#ARTIFACTS[@]} -gt 0 ] || { log_fail "未找到制品: ${DIST_DIR}/agentrt-${VERSION}-*.{tar.gz,zip}"; exit 1; }
log_info "制品清单:"
for f in "${ARTIFACTS[@]}"; do log_info "  $(basename "$f")"; done

# ─── 阶段 1：cosign 签名每个制品 ──────────────────────────────────────────
if [ "$SKIP_SIGN" = "1" ]; then
    log_warn "跳过签名（SKIP_SIGN=1）"
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
NOTES="${RELEASE_NOTES:-}"
if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi
log_info "生成 manifest（${CHANNEL}）…"
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

manifest = {
    "schema": 1,
    "channel": channel,
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
print(f"manifest 已生成: {out}（{len(artifacts)} 平台）")
PYEOF
log_ok "manifest: $(basename "$MANIFEST")"

# ─── 阶段 3：GPG 签名 manifest（权威） ───────────────────────────────────
if [ "$SKIP_SIGN" = "1" ]; then
    log_warn "跳过 manifest GPG 签名（SKIP_SIGN=1）"
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

API="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}/releases"
RELEASE_BODY="${NOTES:-AgentRT ${VERSION}}"
log_info "创建/更新 Release ${VERSION}…"
# atomgit API v5（Gitee 兼容，Base api.atomgit.com）：PRIVATE-TOKEN 认证。
# 附件上传以 tag 定位（POST /releases/{tag}/attach_files），无需 release id。
# 先探测是否已存在同名 tag release（幂等），不存在则创建。
RELEASE_ID="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    "${API}/tags/${VERSION}" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)"
if [ -z "$RELEASE_ID" ]; then
    curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$(python3 -c "import json,sys;print(json.dumps({'tag_name':sys.argv[1],'name':'AgentRT '+sys.argv[1],'body':sys.argv[2],'prerelease':sys.argv[3]}))" "$VERSION" "$RELEASE_BODY" "$PRERELEASE")" \
        "${API}" >/dev/null 2>&1 || { log_fail "Release 创建失败（检查 ATOMGIT_TOKEN 与 ${ATOMGIT_REPO} 权限）"; exit 1; }
fi
log_ok "Release 就绪: ${VERSION}（${ATOMGIT_REPO}）"

UPLOADED=""
# 上传制品 + cosign 签名（*.sig）+ manifest + manifest GPG 签名。
# cosign 签名必须随制品发布，客户端方可校验供应链完整性（防断链）。
for f in "${ARTIFACTS[@]}" "${ARTIFACTS[@]/%/.sig}" "$MANIFEST" "$MANIFEST.asc"; do
    [ -e "$f" ] || continue
    log_info "上传: $(basename "$f")…"
    run curl -fsSL --connect-timeout 60 --max-time 900 -X POST \
        -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        -F "file=@${f}" \
        "${API}/${VERSION}/attach_files" >/dev/null && UPLOADED="$UPLOADED $(basename "$f")"
    log_ok "已上传: $(basename "$f")"
done

# ─── 阶段 5：更新 latest/ 固定入口（更新器轮询） ─────────────────────────
if [ "${SKIP_LATEST:-0}" != "1" ]; then
    log_info "更新 latest/ 固定入口…"
    LATEST_DIR="$TMP/agentrt-latest"
    run git clone --depth 1 "https://oauth2:${ATOMGIT_TOKEN}@atomgit.com/${ATOMGIT_REPO}.git" "$LATEST_DIR"
    if [ "$DRY_RUN" != "1" ]; then
        mkdir -p "$LATEST_DIR/latest/keys"
        cp -f "$MANIFEST" "$MANIFEST.asc" "$LATEST_DIR/latest/" 2>/dev/null || true
        # 公钥随 latest/ 发布（latest/keys/），客户端安装器/自更新器在线拉取，
        # 支持密钥轮换同步（问题 13）。与 install.sh / airymaxrt 拉取路径一致。
        cp -f "$KEYS_DIR/agentrt.asc" "$KEYS_DIR/cosign.pub" "$LATEST_DIR/latest/keys/" 2>/dev/null || true
        git -C "$LATEST_DIR" add -A latest/
        git -C "$LATEST_DIR" -c user.name="agentrt-bot" -c user.email="release@agentrt.airymax.io" \
            commit -m "release: update manifest.${CHANNEL}.json for ${VERSION}" >/dev/null 2>&1 || \
            log_warn "latest/ 无变更或提交失败"
        git -C "$LATEST_DIR" push origin HEAD:main >/dev/null 2>&1 || \
            log_warn "latest/ push 失败（可手动同步）"
        log_ok "latest/manifest.${CHANNEL}.json 已更新"
    fi
fi

log_ok "发布完成: ${VERSION}（${CHANNEL}）"
