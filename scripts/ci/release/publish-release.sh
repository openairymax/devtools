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
#      URL: https://atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<channel>.json
#      （0.1.6b：主域 raw 路径。raw.atomgit.com 子域对非 Markdown 返回
#      "暂不支持预览"403，部分网络不可达，安装器/更新器一律用主域。）
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
    if [ -z "$size" ] || [ "$size" -lt 5000000 ]; then
        log_fail "制品异常小（疑似损坏）: $(basename "$f")（${size:-?} 字节）"; PREFAIL=1
    fi
done
# 包内关键组件预检（0.1.6h 漏件教训：启动器 bin/airymaxrt 由安装器
# 生成、包内不含，旧检查 grep 'bin/airymaxrt' 永远不命中形同虚设）。
# 改为 fail-closed：关键二进制缺任一即中止；包内脚本做语法预检。
REQUIRED_BIN="airy_cli agentrt-bootstrap.sh gateway_d llm_d think_d sched_d tool_d mem_d agent_d"
for f in "${ARTIFACTS[@]}"; do
    listing="$(tar -tzf "$f" 2>/dev/null || true)"
    miss=""
    for b in $REQUIRED_BIN; do
        case "$listing" in *"bin/$b"*) ;; *) miss="$miss $b" ;; esac
    done
    if [ -n "$miss" ]; then
        log_fail "包内缺少关键组件（漏件）: $(basename "$f"):$miss"; PREFAIL=1
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
log_ok "发布预检通过: ${#ARTIFACTS[@]} 个制品（sha256 一致 + 大小正常 + 启动器语法 OK）"

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
NOTES="${RELEASE_NOTES:-}"
if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi
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

# 0.1.6f 社区反馈（2026-08-30）：旧安装器（≤0.1.6d）以 uname 原始名
# （linux-x86_64/aarch64/armv7l/i686）查 manifest，而 0.1.6e 起制品改用
# 数字形式命名（linux-x64/arm64/arm32/x86），旧安装器报"当前平台无可用
# 制品"且无法自举。系统性修复：manifest 为标准平台键补充旧命名别名
# （同一 url/sha256/size），一次发布惠及全部存量旧安装器。
ALIAS = {
    "linux-x64":    ["linux-x86_64"],
    "linux-x86":    ["linux-i686"],
    "linux-arm64":  ["linux-aarch64"],
    "linux-arm32":  ["linux-armv7l"],
    "linux-riscv64": ["linux-riscv64"],
    "macos-x64":    ["macos-x86_64"],
    "macos-arm64":  ["macos-aarch64"],
    "win-x64":      ["win-x86_64"],
    "win-x86":      ["win-i686"],
    "win-arm64":    ["win-aarch64"],
}
for plat in list(artifacts):
    for alias in ALIAS.get(plat, ()):
        artifacts.setdefault(alias, artifacts[plat])

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

API="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}/releases"
RELEASE_BODY="${NOTES:-AgentRT ${VERSION}}"
log_info "创建/更新 Release ${VERSION}…"
# atomgit API v5（Gitee 兼容，Base api.atomgit.com）：PRIVATE-TOKEN 认证。
# release 对象无 id 字段，以 tag_name 存在性探测（幂等），不存在则创建。
TAG_EXISTS="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    "${API}/tags/${VERSION}" 2>/dev/null | python3 -c "import sys,json;print(1 if (json.load(sys.stdin) or {}).get('tag_name') else '')" 2>/dev/null || true)"
if [ -z "$TAG_EXISTS" ]; then
    curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$(python3 -c "import json,sys;print(json.dumps({'tag_name':sys.argv[1],'name':'AgentRT '+sys.argv[1],'body':sys.argv[2],'prerelease':sys.argv[3]}))" "$VERSION" "$RELEASE_BODY" "$PRERELEASE")" \
        "${API}" >/dev/null 2>&1 || { log_fail "Release 创建失败（检查 ATOMGIT_TOKEN 与 ${ATOMGIT_REPO} 权限）"; exit 1; }
fi
log_ok "Release 就绪: ${VERSION}（${ATOMGIT_REPO}）"

# 附件上传走预签名两步流（POST /releases/{tag}/attach_files 端点不存在，
# 服务端 404）：GET /releases/{tag}/upload_url?file_name=X 返回 OBS 预签名
# {url, headers}，再 PUT 文件体到预签名 URL。
# 同名附件已存在则跳过（重跑幂等续传）；任一失败累计后 fail-closed，
# 绝不假报成功——自更新链依赖附件与 manifest 一致。
UP_FAILED=0
EXISTING_ASSETS="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    "${API}/tags/${VERSION}" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(a.get('name','') for a in (json.load(sys.stdin).get('assets') or [])))" 2>/dev/null || true)"

upload_asset() {
    local f="$1" b upjson upurl
    b="$(basename "$f")"
    # 幂等跳过：同名附件已存在则跳过（重跑续传）。制品内容变更（如版本
    # 号修复后同 tag 重新发布）时需 AIRY_FORCE_UPLOAD=1 强制覆盖——OBS
    # 预签名 PUT 按文件名覆盖写入，远端即更新。
    if [ "${AIRY_FORCE_UPLOAD:-0}" != "1" ] && grep -qxF "$b" <<<"$EXISTING_ASSETS"; then
        log_warn "跳过（远端已存在同名附件，AIRY_FORCE_UPLOAD=1 可强制覆盖）: ${b}"
        return 0
    fi
    log_info "上传: ${b}…"
    upjson="$(curl -fsSG --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        --data-urlencode "file_name=${b}" "${API}/${VERSION}/upload_url")" \
        || { log_fail "upload_url 获取失败: ${b}"; return 1; }
    upurl="$(python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("url",""))' <<<"$upjson")"
    [ -n "$upurl" ] || { log_fail "upload_url 为空: ${b}"; return 1; }
    local -a uphdr=()
    mapfile -t uphdr < <(python3 -c 'import json,sys
for k, v in ((json.load(sys.stdin) or {}).get("headers") or {}).items():
    print("-H"); print(f"{k}: {v}")' <<<"$upjson")
    if curl -fsS --connect-timeout 20 --max-time 900 -X PUT \
        "${uphdr[@]}" --upload-file "$f" "$upurl" >/dev/null; then
        # 上传后完整性校验（0.1.6f 强化，fail-closed）：GET 实际下载
        # 大小必须等于本地大小，防 OBS 截断/静默失败（此前无校验）。
        local local_size dl
        local_size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)"
        dl="$(curl -fsSL --connect-timeout 20 --max-time 300 -o /dev/null -w '%{size_download}' \
            "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}/${b}" 2>/dev/null || echo 0)"
        if [ "$dl" = "$local_size" ] && [ "$dl" != "0" ]; then
            log_ok "已上传并校验: ${b}（${dl} 字节）"
        else
            log_fail "上传完整性校验失败: ${b}（远端 ${dl:-0} != 本地 ${local_size:-0} 字节）"
            return 1
        fi
    else
        log_fail "上传失败: ${b}"
        return 1
    fi
}

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
# 安装器快照同步（SSoT → developbuild 离线归档快照，0.1.6 根治历史漂移）：
# agentrt/scripts/install.{sh,ps1} 是安装器唯一权威源（SSoT）；发布时必须
# 同步到 developbuild/agentrt/scripts 快照（离线介质 install-offline.sh 的
# 自包含依赖），否则两处脚本再次分叉（历史教训：0.1.5 快照残留旧公钥与
# 旧版本号，导致离线安装与在线安装行为不一致）。
SNAPSHOT_DIR="${AIRY_DEVELOPBUILD_SNAPSHOT_DIR:-${SCRIPT_DIR}/../../../../developbuild/agentrt/scripts}"
if [ -d "$SNAPSHOT_DIR" ] && [ -f "$INSTALLER_SRC" ] && [ -f "$INSTALLER_PS1_SRC" ]; then
    cp -f "$INSTALLER_SRC" "$SNAPSHOT_DIR/install.sh"
    cp -f "$INSTALLER_PS1_SRC" "$SNAPSHOT_DIR/install.ps1"
    log_ok "安装器快照已同步: ${SNAPSHOT_DIR}"
fi
# 并行上传（0.1.6f 强化）：6 架构 × 3 附件 + manifest/installer 约 24 文件，
# 串行 PUT 大包（35-45MB）耗时显著；限 3 并发（避免打爆 atomgit API 限流），
# 任一失败记入失败清单，全部结束后 fail-closed 中止。
UPLOAD_PAR=3
UP_FAIL_LOG="$TMP/upfailed.txt"
rm -f "$UP_FAIL_LOG"
for f in "${ARTIFACTS[@]}" "${ARTIFACTS[@]/%/.sha256}" "${ARTIFACTS[@]/%/.sig}" "$MANIFEST" "$MANIFEST.asc" "$INSTALLER" "$INSTALLER_PS1"; do
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
        # 完整更新器随 latest/ 发布（latest/airymaxrt）：二进制模式轻量启动器
        # 的 update 自举源。sdk 仓私有，匿名 contents API 不可达，自举源必须
        # 在公开 agentrt 仓内（与 manifest 同路径域，无需额外凭据）。
        LAUNCHER_SRC="${AIRY_LAUNCHER_SRC:-${SCRIPT_DIR}/../../../../agent-workload/sdk/tui/scripts/airymaxrt}"
        if [ -f "$LAUNCHER_SRC" ]; then
            cp -f "$LAUNCHER_SRC" "$LATEST_DIR/latest/airymaxrt"
        else
            log_warn "未找到更新器源: ${LAUNCHER_SRC}（二进制模式 update 自举将不可用）"
        fi
        # 仓库 .gitignore 为白名单制（默认忽略一切），latest/ 天然被忽略，
        # 必须 -f 强制加入，否则 add 静默失败且 set -e 中止整个发布。
        git -C "$LATEST_DIR" add -A -f latest/
        git -C "$LATEST_DIR" -c user.name="agentrt-bot" -c user.email="release@agentrt.airymax.io" \
            commit -m "release: update manifest.${CHANNEL}.json for ${VERSION}" >/dev/null 2>&1 || \
            log_warn "latest/ 无变更或提交失败"
        git -C "$LATEST_DIR" push origin HEAD:main >/dev/null 2>&1 || \
            log_warn "latest/ push 失败（可手动同步）"
        log_ok "latest/manifest.${CHANNEL}.json 已更新"
    fi
fi

log_ok "发布完成: ${VERSION}（${CHANNEL}）"
