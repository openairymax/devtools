#!/usr/bin/env bash
# ============================================================================
# AgentRT 发布签名密钥初始化（一次性）
#
# 生成两套密钥，满足发布双轨签名体系：
#   1. GPG   —— manifest.<channel>.json 的权威签名（安装器/自更新器内置公钥）
#   2. cosign—— 每个 tarball 的 sign-blob 签名（可独立验证，防供应链）
#
# 安全约定：
#   - 公钥进仓库 tools/scripts/ci/release/keys/（随源码分发）
#   - 私钥加密导出到 ~/.airymaxrt-signing/（0600），绝不允许提交仓库
#   - 执行后按脚本末尾「CI Secrets 配置清单」把私钥配置到发布流水线
#
# 用法：
#   ./init-signing-keys.sh [输出目录]
# 环境变量：
#   AIRY_GPG_PASSPHRASE   自定义 GPG/cosign 私钥口令（缺省随机生成并打印）
#
# 幂等：已存在相同指纹的 GPG 密钥时跳过生成，仅补齐导出。
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
EXPORT_DIR="${1:-${AIRY_SIGNING_EXPORT:-$HOME/.airymaxrt-signing}}"
mkdir -p "$KEYS_DIR" "$EXPORT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

GPG_NAME="AgentRT Release Signing"
GPG_EMAIL="release@agentrt.airymax.io"
PASSPHRASE="${AIRY_GPG_PASSPHRASE:-}"
if [ -z "$PASSPHRASE" ]; then
    PASSPHRASE="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
fi
PASSPHRASE_FILE="$EXPORT_DIR/.passphrase"
chmod 700 "$EXPORT_DIR"

# ─── 1. GPG 密钥对 ─────────────────────────────────────────────────────────
GPG_KEYID=""
if gpg --batch --list-keys "$GPG_EMAIL" >/dev/null 2>&1; then
    log_info "GPG 密钥已存在，复用: $GPG_EMAIL"
    GPG_KEYID="$(gpg --batch --list-keys --with-colons "$GPG_EMAIL" | awk -F: '/^fpr/{print $10; exit}')"
else
    log_info "生成 GPG 签名密钥对（ed25519, 无过期）…"
    gpg --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" --gen-key <<EOF 2>/dev/null
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: ${GPG_NAME}
Name-Email: ${GPG_EMAIL}
Expire-Date: 0
Passphrase: ${PASSPHRASE}
%commit
EOF
    GPG_KEYID="$(gpg --batch --list-keys --with-colons "$GPG_EMAIL" | awk -F: '/^fpr/{print $10; exit}')"
    [ -n "$GPG_KEYID" ] || { log_fail "GPG 密钥生成失败"; exit 1; }
    log_ok "GPG 密钥已生成（指纹 ${GPG_KEYID}）"
fi

# 公钥进仓库
gpg --batch --armor --export "$GPG_KEYID" > "$KEYS_DIR/agentrt.asc"
printf '%s\n' "$GPG_KEYID" > "$KEYS_DIR/agentrt.fingerprint"
# 私钥加密导出（仅本地保管）
gpg --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" --armor \
    --export-secret-key "$GPG_KEYID" > "$EXPORT_DIR/agentrt.gpg.secret.asc"
chmod 600 "$EXPORT_DIR/agentrt.gpg.secret.asc"
log_ok "GPG 公钥: $KEYS_DIR/agentrt.asc"
log_ok "GPG 私钥: $EXPORT_DIR/agentrt.gpg.secret.asc"

# ─── 2. cosign 密钥对 ──────────────────────────────────────────────────────
if ! command -v cosign >/dev/null 2>&1; then
    log_fail "cosign 未安装。请先安装：curl -sSfL https://ghproxy.net/https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o ~/.local/bin/cosign && chmod +x ~/.local/bin/cosign"
    exit 1
fi
if [ -f "$EXPORT_DIR/cosign.key" ]; then
    log_info "cosign 密钥已存在，复用: $EXPORT_DIR/cosign.key"
else
    log_info "生成 cosign 密钥对（ECDSA P-256）…"
    COSIGN_PASSWORD="$PASSPHRASE" cosign generate-key-pair \
        --output-key-prefix "$EXPORT_DIR/cosign" >/dev/null 2>&1
fi
cp -f "$EXPORT_DIR/cosign.pub" "$KEYS_DIR/cosign.pub"
chmod 600 "$EXPORT_DIR/cosign.key"
log_ok "cosign 公钥: $KEYS_DIR/cosign.pub"
log_ok "cosign 私钥: $EXPORT_DIR/cosign.key"

# 口令记录（仅本地，0600）
umask 077
printf '%s\n' "$PASSPHRASE" > "$PASSPHRASE_FILE"
log_ok "私钥口令已存: $PASSPHRASE_FILE"

# ─── 3. 配置清单输出 ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CI Secrets 配置清单（发布流水线 secrets，切勿外泄）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. GPG_PRIVATE_KEY   = $(cat "$EXPORT_DIR/agentrt.gpg.secret.asc" | base64 -w0)"
echo "  2. GPG_PASSPHRASE    = ${PASSPHRASE}"
echo "  3. COSIGN_PRIVATE_KEY = $(base64 -w0 < "$EXPORT_DIR/cosign.key")"
echo "  4. COSIGN_PASSWORD   = ${PASSPHRASE}"
echo "  5. ATOMGIT_TOKEN     = <atomgit 个人访问令牌（releases 写权限）>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_warn "私钥仅存在于 ${EXPORT_DIR}（0600），请立即备份到安全位置并删除本机副本"
log_ok "初始化完成"
