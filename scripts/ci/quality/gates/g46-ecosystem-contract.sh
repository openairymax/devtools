#!/bin/bash
# Gate 46 生态四模块契约（0.1.20 方案 §12.4 #9 收口）
#
# 判据：ecosystem 四个策略模块的守卫必须在门禁内**真实执行并通过**。
#   「有测试」≠「测试在跑」——四守卫此前独立可跑，但 CI 工作流与
#   gates/*.sh 对其零引用，属 §12.4 #8/#9 同型缺口（格存在但格不转）。
#   agents  词表一致性   tests/test_vocab_consistency.py（unittest 直跑）
#   markets 合约一致性   tests/test_contract_consistency.py（pytest）
#   prompts 注册表校验   scripts/validate_registry.py（直跑）
#   skills  Skill 契约   tests/test_skills.py（pytest + aiohttp）
#
# fail-closed：解释器依赖（PyYAML / pytest / aiohttp）或守卫文件缺席时
#   一律判红并打印安装指引，**不提供 skip 分支**——fail-open 的门禁比没有
#   门禁更危险（§12.4 #9）。故本脚本只有绿/红两种终态。
#
# 环境变量（selfcheck 注入用）：
#   G46_ECO_ROOT  生态根，默认按 SCRIPT_DIR 上溯 5 级定位
#                 agent-workload/ecosystem（与 quality-gate.sh 同锚点）
#
# 用法: g46-ecosystem-contract.sh
# 退出码: 0=四模块守卫全绿 1=守卫失败/文件缺席/依赖缺失（一律红）
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
ECO="${G46_ECO_ROOT:-${ROOT}/agent-workload/ecosystem}"
MODS=(agents markets prompts skills)

# 模块 → "解释器|守卫相对路径"。守卫命令即模块自带的原生入口，
# 不在门禁侧重写一遍判据（判据单点在模块仓库内）。
guard_spec() {
    case "$1" in
        agents)  echo "unittest|tests/test_vocab_consistency.py" ;;
        markets) echo "pytest|tests/test_contract_consistency.py" ;;
        prompts) echo "script|scripts/validate_registry.py" ;;
        skills)  echo "pytest|tests/test_skills.py" ;;
        *) return 1 ;;
    esac
}

precheck() {
    local missing=""
    command -v python3 >/dev/null 2>&1 || missing="python3"
    python3 -c 'import yaml' 2>/dev/null || missing="${missing} python3-yaml"
    python3 -c 'import aiohttp' 2>/dev/null || missing="${missing} python3-aiohttp"
    python3 -m pytest --version >/dev/null 2>&1 || missing="${missing} python3-pytest"
    if [ -n "$missing" ]; then
        echo "g46: FAIL 解释器依赖缺失:${missing}" >&2
        echo "g46: 安装: sudo apt-get install -y --no-install-recommends \\" >&2
        echo "g46:   python3 python3-yaml python3-pytest python3-aiohttp" >&2
        echo "g46: 缺依赖即判红（fail-closed，不 skip；§12.4 #9）" >&2
        return 1
    fi
    # skills 守卫在插件模块内 `from agentrt.plugin_types import ...`，依赖
    # agentrt Python SDK：要么已安装该包，要么伞仓布局下的源码树
    # agent-workload/sdk/sdk-python（插件自带该兜底路径）。两者皆不可达时
    # 报错是导入失败、指针落在插件源码行上，会把「SDK 子模块未 init」读成
    # 代码缺陷——CI run 41122590599 就是这样红的。故在此显式前置判定，
    # 让红因指向装配缺口。
    local sdk="${ROOT}/agent-workload/sdk/sdk-python"
    if ! python3 -c 'import agentrt' 2>/dev/null && \
       [ ! -f "${sdk}/agentrt/__init__.py" ]; then
        echo "g46: FAIL agentrt Python SDK 不可达（skills 守卫依赖）" >&2
        echo "g46: 期望已安装 agentrt 包，或 ${sdk}/agentrt 存在" >&2
        echo "g46: CI 侧须 init sdk 仓的 sdk-python 子模块" >&2
        return 1
    fi
    if [ ! -d "$ECO" ]; then
        echo "g46: FAIL 生态根不存在: ${ECO}" >&2
        echo "g46: 期望 agent-workload/ecosystem（CI 需递归 init 其子模块）" >&2
        return 1
    fi
    return 0
}

# 返回 0=绿 1=红；捕获输出末 6 行，判据行不被截尾挤出视图
run_guard() {
    local mod="$1" kind file dir out rc=0
    local spec
    spec="$(guard_spec "$mod")" || { echo "g46: FAIL 未知模块 ${mod}"; return 1; }
    kind="${spec%%|*}"
    file="${spec#*|}"
    dir="${ECO}/${mod}"

    if [ ! -f "${dir}/${file}" ]; then
        echo "g46: FAIL ${mod} 守卫缺席: ${dir}/${file}（fail-closed）"
        return 1
    fi

    case "$kind" in
        unittest) out="$(cd "$dir" && python3 "$file" 2>&1)" || rc=$? ;;
        pytest)   out="$(cd "$dir" && python3 -m pytest -q "$file" 2>&1)" || rc=$? ;;
        script)   out="$(cd "$dir" && python3 "$file" 2>&1)" || rc=$? ;;
        *) echo "g46: FAIL ${mod} 守卫类型未知: ${kind}"; return 1 ;;
    esac

    if [ "$rc" -ne 0 ]; then
        echo "g46: FAIL ${mod} 守卫判红 (rc=${rc}, ${kind}, ${file})"
        printf '%s\n' "$out" | tail -6
        return 1
    fi
    printf 'g46: PASS %-7s %-32s %s\n' "$mod" "$file" \
        "$(printf '%s\n' "$out" | tail -1)"
    return 0
}

precheck || exit 1

red=0
for m in "${MODS[@]}"; do
    run_guard "$m" || red=$((red+1))
done

if [ "$red" -ne 0 ]; then
    echo "g46: ${red}/${#MODS[@]} 模块守卫判红——策略面执法链断开（§12.4 #9）"
    exit 1
fi
echo "g46: 四模块守卫全绿（agents/markets/prompts/skills）"
exit 0
