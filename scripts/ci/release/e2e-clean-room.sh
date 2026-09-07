#!/usr/bin/env bash
# e2e-clean-room.sh — 容器洁净 e2e：离线安装 → daemon 群启动 → CLI 冒烟
# （0.1.13 H2：一次 rc 全链出证，接入 release 门禁）
#
# 背景：spec H2 载体 = release-dist 聚合后，以 docker run 洁净 ubuntu:20.04
# 挂载制品，执行 install.sh → 启动 daemon 群 → airy_cli 冒烟。容器内无任何
# 开发工具链（fail-closed 断言），等价用户干净机；glibc 2.31 基线与
# build-linux-x86-64 腿工具链镜像同源（该腿在 ubuntu:20.04 工具链镜像内
# 构建），动态链接兼容判定等价。
#
# 镜像引用说明（不用 digest 钉版的理由）：ubuntu:20.04 已 EOS（standard
# support 2025-05 结束），官方 tag 冻结不再重推，浮动风险趋零；glibc 基线
# 由 tag 本身绑定。未来切换基线（22.04/24.04）时，构建腿工具链镜像与本
# 脚本宿主（release.yml 的 e2e-clean-room job）必须同步切换并恢复 digest
# 钉版。
#
# 判定语义（fail-closed，stdout 为断言面）：
#   阶段 0  洁净性：gcc/cc/clang/python3/pip3/cargo/cmake/make/git/curl
#           任一存在即 FAIL（存在开发工具链 = 非洁净，会掩盖动态链接破绽）；
#           出证 uname -srm 与 ldd 版本（glibc 基线）。
#   阶段 1  离线安装：install.sh --from-file <tarball>（零网络全链），先
#           显式 sha256sum -c 出证（相邻 .sha256），再断言安装产物
#           （bin/airy_cli、bin/agentrt-bootstrap.sh、config/install.env）。
#   阶段 2  启动：agentrt-bootstrap.sh -s -t 180（无参=启动，阻塞至全绿或
#           健康超时）。
#   阶段 3  gateway TCP：按 run/gateway.port 探测（防端口漂移误报）。
#   阶段 4  CLI 冒烟：airy_cli -p /daemons（CLI→run/*.sock→daemon→gateway
#           全链出证，无 LLM 依赖；print 模式恒退出 0，断言只能锚定输出
#           文本），断言 gateway online、无任何 offline、汇总行 N==M 且 M>0。
#   阶段 5  收尾：stop daemon 群（失败仅告警，容器 --rm 兜底回收），打印
#           PASS 证据（glibc 基线 / N=M / gateway 端口）。
#
# 用法（容器内执行）：e2e-clean-room.sh <install.sh> <tarball>
# 本地复现（需 docker.io 可达或已配镜像加速）：
#   docker run --rm -v "$PWD:/w:ro" ubuntu:20.04 \
#     bash /w/_tools/scripts/ci/release/e2e-clean-room.sh \
#       /w/dist/install.sh /w/dist/agentrt-<ver>-linux-x86-64.tar.gz
set -euo pipefail

INSTALLER="${1:?usage: e2e-clean-room.sh <install.sh> <tarball>}"
TARBALL="${2:?usage: e2e-clean-room.sh <install.sh> <tarball>}"
AH="$HOME/.airymaxrt"

fail() { echo "::error::$*" >&2; exit 1; }
info() { echo "  -- $*"; }

[ -f "$INSTALLER" ] || fail "install.sh 不存在: $INSTALLER"
[ -f "$TARBALL" ] || fail "tarball 不存在: $TARBALL"

# ─── 阶段 0：洁净性断言 + 基线出证 ────────────────────────────────────────
info "阶段 0 洁净性检查（宿主: $(uname -srm)）"
ldd --version 2>/dev/null | head -1 || true
DIRTY=""
for t in gcc cc clang python3 pip3 cargo cmake make git curl; do
    if command -v "$t" >/dev/null 2>&1; then DIRTY="$DIRTY $t"; fi
done
if [ -n "$DIRTY" ]; then
    fail "容器非洁净（存在开发工具链:$DIRTY），等价干净机判定失效"
fi
info "洁净通过：无开发工具链"

# ─── 阶段 1：离线安装（--from-file 零网络） ───────────────────────────────
info "阶段 1 离线安装: $(basename "$TARBALL")"
SHA_FILE="$TARBALL.sha256"
[ -f "$SHA_FILE" ] || fail "缺 sha256 校验件: $SHA_FILE"
TDIR="$(cd "$(dirname "$TARBALL")" && pwd)"
(cd "$TDIR" && sha256sum -c "$(basename "$SHA_FILE")" >/dev/null) \
    || fail "tarball sha256 校验失败: $(basename "$TARBALL")"
bash "$INSTALLER" --from-file "$TARBALL" || fail "install.sh --from-file 失败"
for f in "$AH/bin/airy_cli" "$AH/bin/agentrt-bootstrap.sh" "$AH/config/install.env"; do
    [ -f "$f" ] || fail "安装产物缺失: $f"
done
info "安装产物齐备: $AH"

# 包内传递依赖兜底（lib/ 注入 LD_LIBRARY_PATH），存在才 source。
if [ -f "$AH/bin/agentrt-env.sh" ]; then
    . "$AH/bin/agentrt-env.sh"
fi

# ─── 阶段 2：启动 daemon 群 ───────────────────────────────────────────────
info "阶段 2 启动 daemon 群（健康超时 180s）"
bash "$AH/bin/agentrt-bootstrap.sh" -s -t 180 \
    || fail "daemon 群启动失败（健康检查未全绿）"

# ─── 阶段 3：gateway TCP 探测 ─────────────────────────────────────────────
info "阶段 3 gateway TCP 探测"
GWP="$(sed -n '1s/[^0-9]//gp' "$AH/run/gateway.port" 2>/dev/null | head -1)"
GWP="${GWP:-8080}"
if (exec 3<>"/dev/tcp/127.0.0.1/$GWP") 2>/dev/null; then
    info "gateway online（127.0.0.1:$GWP）"
else
    fail "gateway TCP 不可达: 127.0.0.1:$GWP"
fi

# ─── 阶段 4：airy_cli 冒烟（/daemons 全链出证） ───────────────────────────
info "阶段 4 CLI 冒烟: airy_cli -p /daemons"
OUT="$(timeout 120 "$AH/bin/airy_cli" -p "/daemons")" \
    || fail "airy_cli 执行失败（超时或异常）"
OUT="$(printf '%s' "$OUT" | tr -d '\r')"
dump() { printf '%s\n' "$OUT" | sed 's/^/    /' | head -20; }
# print 模式无 banner，逐行锚定安全；断言面为输出文本而非退出码（恒 0）。
printf '%s\n' "$OUT" | grep -qx "gateway online" \
    || { dump; fail "冒烟断言失败: gateway 非 online"; }
if printf '%s\n' "$OUT" | grep -q " offline"; then
    dump; fail "冒烟断言失败: 存在 offline daemon"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -E '^online [0-9]+/[0-9]+$' | tail -1)"
[ -n "$SUMMARY" ] || { dump; fail "冒烟断言失败: 缺汇总行 online N/M"; }
N="${SUMMARY#online }"; N="${N%%/*}"
M="${SUMMARY#*/}"
if [ "$N" != "$M" ] || [ "$M" -le 0 ]; then
    fail "冒烟断言失败: 汇总 $SUMMARY（要求 N==M 且 M>0）"
fi
info "CLI 冒烟通过: $SUMMARY"

# ─── 阶段 5：收尾 ─────────────────────────────────────────────────────────
bash "$AH/bin/agentrt-bootstrap.sh" stop -s >/dev/null 2>&1 \
    || echo "::warning::daemon 群停止失败（容器 --rm 兜底回收，不阻断）"
GLIBC="$(ldd --version 2>/dev/null | head -1 || echo 'glibc ?')"
echo "[OK] 洁净 e2e 通过: $GLIBC | $SUMMARY | gateway 127.0.0.1:$GWP"
