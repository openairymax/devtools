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
#   阶段 6  （A-2，0.1.21）安装清单与卸载语义：清单存在且 schema/release 合法
#           → entries 逐件存在 + sha256 一致（无 python，纯 sed/awk）→
#           `--dry-run` 零副作用且 `[PLAN]` 集合与 `--keep-data` 实删逐行一致
#           → data/ 保留、安装件与 releases/ 消失 → `--purge` 后仅剩 data/
#           → 反例：伪造 install.env 重定向必须非零退出且受害根零删除。
#   阶段 U  （U9，可选，第三参 prev tarball 存在时执行）：**旧版升级路径**——
#           旧版离线安装（--from-file）→ 写用户配置 marker → airymaxrt
#           update --file 新版（python-free 离线路径）→ 断言版本升级 + 用户
#           配置保留（config 兼容性）→ update --rollback → 断言版本回退 +
#           配置仍在（D8：回滚回收运行中 daemon）。同版（prev==new）跳过。
#           prev 工件缺陷分类：U9 以**新版安装器**装旧包，与真实旧版用户
#           经旧版安装器落盘不同源；若旧版安装因工件缺运行时库被自检
#           fail-closed 拒绝（三签名：已安装版本 / 安装自检未通过 / 未解析
#           动态库依赖），属 prev 历史工件自身包缺陷（sha256 固定，与本次
#           发布无关），::warning:: 降级继续升级路径验证；其余失败硬失败。
#           离线自举：二进制安装的 bin/airymaxrt 为 thin 包装（仅前端入口），
#           管理命令经 airymaxrt-full 委托（联网时从 agentrt 仓 latest/
#           airymaxrt 拉取）。thin 对 update 命令强制重拉 full（每次刷新，
#           不复用缓存）；clean 容器无 curl/python 不可联网。第四参传入 full
#           启动器（agentrt 仓 latest/airymaxrt，完整 CLI SSoT），U9 前置
#           seed 到 bin/airymaxrt-full 后**直接 exec full**——其内容与 thin
#           联网会拉取的对象同源同版本，仅跳过网络重拉一步，update --file /
#           --rollback 业务路径全程离线执行，与真实用户在线更新行为一致。
#
# 用法（容器内执行）：e2e-clean-room.sh <install.sh> <tarball> [prev_tarball]
#                     [airymaxrt_full]
#   prev_tarball 存在（含相邻 .sha256）时执行阶段 U（U9 升级路径出证）；
#   此时须提供 airymaxrt_full（agentrt 仓 latest/airymaxrt）。
# 本地复现（需 docker.io 可达或已配镜像加速）：
#   docker run --rm -v "$PWD:/w:ro" ubuntu:20.04 \
#     bash /w/_tools/scripts/ci/release/e2e-clean-room.sh \
#       /w/dist/install.sh /w/dist/agentrt-<ver>-linux-x86-64.tar.gz
set -euo pipefail

INSTALLER="${1:?usage: e2e-clean-room.sh <install.sh> <tarball> [prev_tarball] [airymaxrt_full]}"
TARBALL="${2:?usage: e2e-clean-room.sh <install.sh> <tarball> [prev_tarball] [airymaxrt_full]}"
PREV="${3:-}"
FULL="${4:-}"
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

# ─── 阶段 U（U9 升级路径，可选）：旧版→新版 配置兼容 + 回滚 ──────────────
if [ -n "$PREV" ] && [ -f "$PREV" ]; then
    info "阶段 U（U9）升级路径: $(basename "$PREV") -> $(basename "$TARBALL")"
    v_of() { local n; n="${1#agentrt-}"; echo "${n%-linux-x86-64.tar.gz}"; }
    norm() { echo "${1#v}"; }
    PREV_VER="$(v_of "$(basename "$PREV")")"
    NEW_VER="$(v_of "$(basename "$TARBALL")")"
    if [ "$(norm "$PREV_VER")" = "$(norm "$NEW_VER")" ]; then
        info "U9 跳过：prev($PREV_VER) == new($NEW_VER)（稳定版同版重发，无升级路径语义）"
    else
        [ -n "$FULL" ] && [ -f "$FULL" ] || fail "U9: 缺 airymaxrt full 启动器（第四参，agentrt 仓 latest/airymaxrt）"
        PREV_SHA="$PREV.sha256"
        [ -f "$PREV_SHA" ] || fail "U9: 缺 prev sha256 校验件: $PREV_SHA"
        [ -f "$TARBALL.sha256" ] || fail "U9: 缺 new sha256 校验件: $TARBALL.sha256"
        # U9a：安装旧版 + 写入用户侧配置（config 兼容性判据）。失败时按
        # 三签名分类（见头注释）：仅「落盘完整 + 自检拒绝 + 缺库诊断」同时
        # 命中才判定为 prev 工件自身包缺陷，::warning:: 带痕降级；其余仍
        # fail-closed 硬失败。
        if ! PREV_OUT="$(bash "$INSTALLER" --from-file "$PREV" 2>&1)"; then
            if printf '%s\n' "$PREV_OUT" | grep -q "已安装版本" \
                && printf '%s\n' "$PREV_OUT" | grep -q "安装自检未通过" \
                && printf '%s\n' "$PREV_OUT" | grep -q "未解析动态库依赖"; then
                echo "::warning::U9: prev 工件自身包缺陷（sha256 固定，与本次发布无关），降级继续升级路径验证"
                printf '%s\n' "$PREV_OUT" | sed 's/^/    /' | tail -15
            else
                fail "U9: 旧版离线安装失败"
            fi
        fi
        CUR="$(sed -n 's/^AIRY_VERSION=//p' "$AH/config/install.env" 2>/dev/null | tr -d '"')"
        [ -n "$CUR" ] || fail "U9: 旧版安装后 install.env 无 AIRY_VERSION"
        echo "u9-user-marker: $(date +%s)" > "$AH/config/user-marker.cfg"
        info "U9a: 旧版 $CUR 已装，用户配置 marker 已写"
        # U9b：离线自举 full 启动器并**直接 exec**（thin 对 update 强制重拉
        # full 且不复用缓存，离线不可达；seeded full 即 thin 联网拉取的同源
        # 对象，见头注释）。ensure_full 幂等：apply_package 保留 bin/
        # airymaxrt-full（不删），双入口安全兜底。
        _FULL="$AH/bin/airymaxrt-full"
        ensure_full() {
            [ -s "$_FULL" ] || { cp -f "$FULL" "$_FULL"; chmod 755 "$_FULL"; }
            [ -x "$_FULL" ] || fail "U9: full 启动器缺失: $_FULL"
        }
        ensure_full
        # U9c：离线升级到新版（update --file，python-free 路径；跨版本直接
        # 比对 install.env AIRY_VERSION）
        NEW_SHAV="$(awk '{print $1}' "$TARBALL.sha256")"
        ensure_full
        bash "$_FULL" update --file "$TARBALL" --sha256 "$NEW_SHAV" \
            || fail "U9: airymaxrt update --file 升级失败"
        CUR="$(sed -n 's/^AIRY_VERSION=//p' "$AH/config/install.env" 2>/dev/null | tr -d '"')"
        [ "$(norm "$CUR")" = "$(norm "$NEW_VER")" ] \
            || fail "U9: 升级版本断言失败（期望 $NEW_VER，实得 $CUR）"
        [ -f "$AH/config/user-marker.cfg" ] || fail "U9: 升级后用户配置丢失（config 兼容性失败）"
        info "U9c: 升级至 $CUR，用户配置保留"
        # U9d：回滚（apply_package 备份恢复；D8 回滚回收运行中 daemon）
        ensure_full
        bash "$_FULL" update --rollback || fail "U9: update --rollback 失败"
        CUR="$(sed -n 's/^AIRY_VERSION=//p' "$AH/config/install.env" 2>/dev/null | tr -d '"')"
        [ "$(norm "$CUR")" = "$(norm "$PREV_VER")" ] \
            || fail "U9: 回滚版本断言失败（期望 $PREV_VER，实得 $CUR）"
        [ -f "$AH/config/user-marker.cfg" ] || fail "U9: 回滚后用户配置丢失"
        info "U9d: 回滚至 $CUR，用户配置保留"
        # 预重置至新版（后续 Phase 1 以新制品做标准离线安装冒烟；失败仅告警，
        # Phase 1 将再次完整安装——set -e 下这里用显式 if 防误中止）
        bash "$INSTALLER" --from-file "$TARBALL" >/dev/null 2>&1 \
            || info "U9: 预重置至新版失败（Phase 1 将重新安装）"
    fi
fi

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
GWP=""
if [ -s "$AH/run/gateway.port" ]; then
    GWP="$(sed -n '1s/[^0-9]//gp' "$AH/run/gateway.port" | head -1)"
fi
# fallback 取 SSoT agentrt/commons/include/airy_defaults.h 的
# AIRY_PORT_GATEWAY_HTTP；正常路径优先读运行期 run/gateway.port。
GWP="${GWP:-2027}"
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

# ─── 阶段 4b（R17）：真实业务链路（工具执行 + 审计/台账 + run_stream） ────
# 判据出处：docs-closed/agent-workload-dev/0.1.21-架构改进方案.md §24.2 R17
# —— 原 e2e 止于 /daemons 只读视图，业务链路（工具执行、审计落盘、会话
# 流式终结）无任何出证。洁净机无模型，run_stream 一轮只能收敛到"模型
# 缺失"终态，故断言锚定协议信封与终结帧（失败必须显式归因），模型输出
# 本身不作断言，避免以桩/假绿灯换取通过。
info "阶段 4b 真实链路: 工具目录 → 工具执行 → 台账/审计 → run_stream"
CLI="$AH/bin/airy_cli"

# 4b-1 工具目录（只读面，不经审批门）：tool_d 注册表经 gateway 可达。
TOOLS="$(timeout 60 "$CLI" -p '/rpc tool.list_tools' 2>&1 | tr -d '\r')"
printf '%s' "$TOOLS" | grep -q 'fs_list' \
    || fail "R17: tool.list_tools 未返回内置工具（$(printf '%s' "$TOOLS" | head -2)）"

# 4b-2 工具执行：fs_list 无参=列 daemon 工作区自身（不依赖既有内容，也不
# 触碰网络/外部 daemon）。builtin 对 tool_d 主体默认放行，成功即应同时
# 留下作业台账与审计两条持久化痕迹——三面同时出证才算通过。
EXEC="$(timeout 60 "$CLI" -p \
    '/rpc tool.execute_tool {"tool_id":"fs_list","params":{}}' 2>&1 | tr -d '\r')"
printf '%s' "$EXEC" | grep -Eq '"success"[[:space:]]*:[[:space:]]*1' \
    || fail "R17: tool.execute_tool 失败（$(printf '%s' "$EXEC" | head -2)）"
JOB_ID="$(printf '%s' "$EXEC" \
    | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$JOB_ID" ] || fail "R17: execute_tool 未回带 job_id（作业台账未建）"
JOBF="$AH/data/agentrt/jobs/$JOB_ID.json"
[ -f "$JOBF" ] || fail "R17: 作业台账未落盘: $JOBF"
grep -q 'fs_list' "$JOBF" || fail "R17: 台账未记录 tool_id（$JOBF）"
AUD="$AH/data/agentrt/logs/daemon_audit.log"
[ -f "$AUD" ] || fail "R17: 审计日志未落盘: $AUD"
grep 'operation=tool_execute' "$AUD" | grep -q 'resource=fs_list' \
    || fail "R17: 审计缺 tool_execute/fs_list 记录（$AUD）"
info "工具链路通过: fs_list job_id=$JOB_ID（台账+审计双面落盘）"

# 4b-3 run_stream：CLI 事件出口 → gateway /api/v1/agent/run/stream →
# agent_d task_submit_stream。断言帧头 schema==1、payload 键在（信封为
# 合法 JSON，NDJSON 消费方可直接解析）、payload 带 run_id 键、终结帧
# run_end；终态为 completed 或显式 error+reason，禁止静默收流。
RUN="$(timeout 150 "$CLI" --events ndjson --quiet \
    -p "e2e r17 stream probe" 2>&1 | tr -d '\r' || true)"
printf '%s' "$RUN" | grep -q '"schema":1' \
    || fail "R17: run_stream 无事件帧（$(printf '%s' "$RUN" | head -2)）"
printf '%s' "$RUN" | grep -q '"payload":' \
    || fail "R17: 事件帧缺 payload 键（信封非法 JSON，NDJSON 消费方无法解析）"
printf '%s' "$RUN" | grep -q '"run_id"' \
    || fail "R17: run_stream 帧缺 run_id 键（非真实会话帧）"
printf '%s' "$RUN" | grep -q '"run_end"' \
    || fail "R17: run_stream 缺终结帧 run_end（流未收敛）"
if printf '%s' "$RUN" | grep -q '"completed"'; then
    info "run_stream 通过: 正常完成"
elif printf '%s' "$RUN" | grep -q '"error"'; then
    printf '%s' "$RUN" | grep -q '"reason"' \
        || fail "R17: run_stream 失败帧缺 reason（不可归因）"
    info "run_stream 通过: 洁净机无模型，按可归因失败终态收敛"
else
    fail "R17: run_stream 终态既非 completed 也非显式 error"
fi

# ─── 阶段 5：收尾 ─────────────────────────────────────────────────────────
bash "$AH/bin/agentrt-bootstrap.sh" stop -s >/dev/null 2>&1 \
    || echo "::warning::daemon 群停止失败（容器 --rm 兜底回收，不阻断）"
GLIBC="$(ldd --version 2>/dev/null | head -1 || echo 'glibc ?')"
echo "[OK] 洁净 e2e 通过: $GLIBC | $SUMMARY | gateway 127.0.0.1:$GWP"

# ─── 阶段 6（A-2）：安装清单 + 卸载语义 ───────────────────────────────────
# 判定三值：以下任一断言失败即 FAIL；全部通过才落 [OK] a2。容器无 python，
# 清单为单行 JSON 条目，纯 sed/awk 抽取（与 manifest_write 的发射格式同源）。
info "阶段 6 安装清单与卸载语义（A-2）"
MF="$AH/install-manifest.json"
[ -f "$MF" ] || fail "A-2: 缺安装清单 $MF"
grep -q '"schema": 1' "$MF" || fail "A-2: 清单 schema 非 1"
REL="$(sed -n 's/^  "release": "\([^"]*\)",$/\1/p' "$MF" | head -1)"
[ -n "$REL" ] || fail "A-2: 清单缺 release 字段"
grep -q '"release_env_sha256": "[0-9a-f]\{64\}"' "$MF" \
    || fail "A-2: 清单缺 release.env 摘要"
grep '^  "build": "v[^"]*"' "$MF" >/dev/null || fail "A-2: 清单缺 build 字段"
CNT=0
while IFS= read -r L; do
    P="$(printf '%s' "$L" | sed -n 's/^  {"path": "\([^"]*\)".*/\1/p')"
    S="$(printf '%s' "$L" | sed -n 's/.*"sha256": "\([0-9a-f]*\)".*/\1/p')"
    [ -n "$P" ] || continue
    [ -f "$AH/$P" ] || fail "A-2: 清单件缺失: $P"
    # 归属由清单声明（install.sh rt_owned）：运行期自有件在首次启动时被启动器
    # 改写，装机摘要必然过期，断言存在性与卸载语义即可；其余件仍按字节比对。
    case "$L" in
        *'"mutable": 1'*) ;;
        *)
            [ "$(sha256sum "$AH/$P" | awk '{print $1}')" = "$S" ] \
                || fail "A-2: 清单摘要不一致: $P"
            ;;
    esac
    CNT=$((CNT + 1))
done <<EOF
$(grep '^  {"path":' "$MF")
EOF
[ "$CNT" -ge 20 ] || fail "A-2: 清单条目过少（$CNT），未覆盖安装面"
info "清单逐件校验通过: $REL，$CNT 件"

DATAF="$AH/data/e2e-keep.txt"
mkdir -p "$AH/data" && echo keep > "$DATAF"
bash "$INSTALLER" --uninstall --keep-data --dry-run --yes > /tmp/a2-dry.log 2>&1 \
    || fail "A-2: --dry-run 失败"
[ -f "$AH/bin/airy_cli" ] || fail "A-2: --dry-run 产生副作用（安装件被删）"
grep '^\[PLAN\]' /tmp/a2-dry.log | sort > /tmp/a2-dry.plan
[ "$(wc -l < /tmp/a2-dry.plan)" -gt 10 ] || fail "A-2: --dry-run 待删集合过小"
bash "$INSTALLER" --uninstall --keep-data --yes > /tmp/a2-real.log 2>&1 \
    || fail "A-2: --keep-data 卸载失败"
grep '^\[PLAN\]' /tmp/a2-real.log | sort > /tmp/a2-real.plan
cmp -s /tmp/a2-dry.plan /tmp/a2-real.plan \
    || fail "A-2: 干跑集合 != 实删集合（逐行 diff 不一致）"
[ -f "$DATAF" ] || fail "A-2: --keep-data 未保留 data/"
[ ! -f "$MF" ] || fail "A-2: 卸载后清单仍存在"
[ ! -e "$AH/releases" ] || fail "A-2: 卸载后 releases/ 残留"
info "--keep-data 通过: 集合一致、data/ 保留、安装件清净"

echo stray > "$AH/e2e-stray.txt"
bash "$INSTALLER" --uninstall --purge --yes > /tmp/a2-purge.log 2>&1 \
    || fail "A-2: --purge 失败"
[ -f "$DATAF" ] || fail "A-2: --purge 未保留 data/"
LEFT="$(find "$AH" -mindepth 1 -maxdepth 1 ! -name data | wc -l)"
[ "$LEFT" -eq 0 ] || fail "A-2: --purge 后仍有 $LEFT 项残留（要求仅剩 data/）"
info "--purge 通过: 仅剩 data/"

VICTIM="$HOME/e2e-victim"
FORGED="$HOME/e2e-forged"
# 伪造根必须具备本产品自证物（data/agentrt）才会走到 install.env 校验，
# 否则只证明了「非安装根拒绝」而非「重定向拒绝」。
mkdir -p "$VICTIM/releases/x/bin" "$FORGED/config" "$FORGED/data/agentrt"
echo keep > "$VICTIM/releases/x/bin/keep"
echo "AIRY_HOME=$VICTIM" > "$FORGED/config/install.env"
if bash "$INSTALLER" --prefix "$FORGED" --uninstall --yes > /tmp/a2-forged.log 2>&1; then
    fail "A-2: 伪造 install.env 重定向未被拒绝"
fi
[ -f "$VICTIM/releases/x/bin/keep" ] || fail "A-2: 伪造重定向造成误删"
info "反例通过: 伪造 install.env 被拒且零删除"

echo "[OK] a2: 清单 $CNT 件 | 干跑/实删集合一致 | keep-data 保留 data/"
