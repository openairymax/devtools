#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# contract-sso.sh — 跨团队合约 SSoT 宿主解析与版本声明解析
#
# 单一事实源：合约头的物理宿主候选集与版本声明形式集中于此，Gate 4
# （contract-version-check.sh）与 Gate 5（cross-repo-verify.sh）共用，
# 禁止各门禁各自硬编码路径或版本正则——两份判据必然漂移。
#
# 用法（由门禁脚本 source）：
#   source "${SCRIPT_DIR}/lib/contract-sso.sh"

# 解析合约 SSoT 宿主。成功输出路径并返回 0；
# 候选目录存在但零合约头 → 返回 1（判据为空，须判红）；
# 候选全部缺席 → 返回 2（本树不含合约数据集，未判定）。
csso_root() {
    local root="$1" cand seen=0
    for cand in \
        "${root}/contracts" \
        "${root}/agent-workload/agentrt/contracts" \
        "${root}/docs/docs-closed/agent-workload-dev/06-contracts"; do
        [ -d "$cand" ] || continue
        seen=1
        if compgen -G "${cand}/contract_*.h" >/dev/null 2>&1; then
            echo "$cand"
            return 0
        fi
    done
    [ "$seen" -eq 1 ] && return 1
    return 2
}

# 从标准输入读取合约头文本，解析 $1 声明的版本，输出规范化 M.m.p。
# 接受三种等价形式（现行 SSoT 为语义串，其余为历史兼容）：
#   #define CONTRACT_X_VERSION "1.2.3"
#   #define CONTRACT_X_VERSION 0x00010203
#   #define CONTRACT_X_VERSION_MAJOR / _MINOR / _PATCH
# 无任何声明 → 返回 1（调用方须按判据缺失处理，不得静默通过）。
csso_ver() {
    local macro="$1" text sem hex maj min pat
    text=$(cat)
    sem=$(printf '%s\n' "$text" | grep -oP "#define\s+${macro}\s+\"\K[0-9]+(\.[0-9]+)*" | head -1 || true)
    if [ -n "$sem" ]; then
        echo "$sem"
        return 0
    fi
    hex=$(printf '%s\n' "$text" | grep -oP "#define\s+${macro}\s+0x\K[0-9a-fA-F]+" | head -1 || true)
    if [ -n "$hex" ]; then
        printf '%d.%d.%d\n' \
            "$(( (0x${hex} >> 24) & 0xFF ))" \
            "$(( (0x${hex} >> 16) & 0xFF ))" \
            "$(( 0x${hex} & 0xFFFF ))"
        return 0
    fi
    maj=$(printf '%s\n' "$text" | grep -oP "#define\s+${macro}_MAJOR\s+\K[0-9]+" | head -1 || true)
    min=$(printf '%s\n' "$text" | grep -oP "#define\s+${macro}_MINOR\s+\K[0-9]+" | head -1 || true)
    pat=$(printf '%s\n' "$text" | grep -oP "#define\s+${macro}_PATCH\s+\K[0-9]+" | head -1 || true)
    if [ -n "$maj" ] && [ -n "$min" ] && [ -n "$pat" ]; then
        echo "${maj}.${min}.${pat}"
        return 0
    fi
    return 1
}
