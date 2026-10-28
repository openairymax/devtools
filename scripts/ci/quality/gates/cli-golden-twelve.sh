#!/bin/bash
# Gate 28 CLI 十二机制 golden harness（0.1.20 方案 §4.1-A2）
#
# 对 airy_cli 以离线确定性环境逐组执行十二组 fixture，断言 CLI 分发面的
# 结构化摘要（exit code + stdout ERE），不逐字节比对。十二机制与命令映射：
#   version-selfcheck  --version                    构建期 VERSION SSoT 注入
#   health-probe       -p /daemons                  13 ns + 网关离线面
#   plan-emit          -p /rpc sched.dag_submit     计划产出路由
#   adjudicate         -p /perm                     权限裁决路由
#   partial-failure    -p /tasks                    同命令双 RPC 序列
#   rollback           -p /rpc sched.checkpoint_save 状态回滚路由
#   metering           -p /stats llm                计费面路由
#   cache-hit          -p /rpc mem.cache_stats      缓存面路由
#   timeout-tiering    -p /rpc llm.complete         分诊分层（refused ≠ 超时）
#   config-hotload     -p /rpc cupolas.policy.load  配置热载路由
#   canary-propose     -p /rpc cupolas.policy.activate 金丝雀提案路由
#   canary-rollback    -p /rpc cupolas.policy.rollback 金丝雀回滚路由
#
# 确定性根基：AIRY_HOME 指向空沙箱（daemon 发现回退编译期默认表）、
#   AIRY_GATEWAY_URL 指向 port 1（refused 快速失败）、stdin=/dev/null。
# 断言 DSL（expected 每行一条）：exit:<n> / has:<ERE> / !has:<ERE>；
#   @VERSION@ 展开为 agentrt/VERSION 内容（bump 零维护）。
#
# 用法: cli-golden-twelve.sh <airy_cli-binary>
#   二进制也可经 AIRY_CLI_BIN 提供；二进制/VERSION 缺失为环境错误。
# 退出码: 0 = 全部 PASS；1 = fixture 缺失或断言失败；2 = 环境错误
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX_DIR="$SCRIPT_DIR/cli-golden-twelve"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
VERSION_FILE="${PROJECT_ROOT}/agent-workload/agentrt/VERSION"
BIN="${1:-${AIRY_CLI_BIN:-}}"
OFFLINE_URL="http://127.0.0.1:1"

if [ ! -x "$BIN" ]; then
    echo "[ENV] airy_cli binary not executable: '${BIN:-<unset>}'"
    echo "[ENV] build out-of-tree, then: export AIRY_CLI_BIN=<path>"
    exit 2
fi
if [ ! -f "$VERSION_FILE" ]; then
    echo "[ENV] version file not found: $VERSION_FILE"
    exit 2
fi
EXPECT_VER="$(tr -d '[:space:]' < "$VERSION_FILE")"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

CASES=(version-selfcheck health-probe plan-emit adjudicate partial-failure
       rollback metering cache-hit timeout-tiering config-hotload
       canary-propose canary-rollback)

FAILS=0
PASS_N=0

run_case() {
    local name="$1"
    local args_file="$FIX_DIR/$name.args"
    local exp_file="$FIX_DIR/$name.expected"
    if [ ! -f "$args_file" ] || [ ! -f "$exp_file" ]; then
        echo "FAIL $name: missing fixture ($name.args / $name.expected)"
        FAILS=$((FAILS + 1))
        return
    fi
    local -a argv=()
    mapfile -t argv < "$args_file"
    local out rc
    out=$(AIRY_HOME="$SANDBOX" AIRY_GATEWAY_URL="$OFFLINE_URL" \
          "$BIN" ${argv+"${argv[@]}"} 2>/dev/null </dev/null)
    rc=$?
    local line bad=0
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        line="${line//@VERSION@/$EXPECT_VER}"
        case "$line" in
            exit:*)
                [ "$rc" = "${line#exit:}" ] || { echo "FAIL $name: exit=$rc want=${line#exit:}"; bad=1; } ;;
            has:*)
                printf '%s\n' "$out" | grep -qE -- "${line#has:}" \
                    || { echo "FAIL $name: expected match: ${line#has:}"; bad=1; } ;;
            '!has:'*)
                printf '%s\n' "$out" | grep -qE -- "${line#\!has:}" \
                    && { echo "FAIL $name: forbidden match: ${line#\!has:}"; bad=1; } ;;
            *)
                echo "FAIL $name: unknown assertion: $line"; bad=1 ;;
        esac
    done < "$exp_file"
    if [ "$bad" -eq 0 ]; then
        echo "PASS $name"
        PASS_N=$((PASS_N + 1))
    else
        FAILS=$((FAILS + 1))
    fi
}

for c in "${CASES[@]}"; do
    run_case "$c"
done

echo "cli-golden-twelve: ${PASS_N}/${#CASES[@]} passed, ${FAILS} failed"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
