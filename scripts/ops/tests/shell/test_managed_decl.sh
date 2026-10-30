#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# AgentRT 外部托管声明（managed.d 片段）测试
# 覆盖：片段摄取（CORE 追加 + BIN/EP/ARGS upsert）、幂等、非法片段 fail-closed
#       跳过、片段撤销后的悬挂声明清退，以及 airy-local 侧片段收敛。
# 全部断言基于真实文件 IO，不注入替身实现。

AGENTRT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test_framework.sh
source "$AGENTRT_TEST_DIR/test_framework.sh"

MANAGED_TEST_ROOT=""

# 夹具根先于源入确定：bootstrap 顶层按 AIRY_HOME 派生全部路径并建目录，
# 源入阶段绝不能落到真实安装根。库模式置位以跳过依赖探测副作用。
MANAGED_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/airy_decl_test_XXXXXX")"
export AIRY_HOME="$MANAGED_TEST_ROOT"
export AIRY_BOOTSTRAP_LIB=1

# shellcheck source=../bin/agentrt-bootstrap.sh
source "${AGENTRT_SCRIPTS_DIR}/bin/agentrt-bootstrap.sh"
# shellcheck source=../bin/airy-local
source "${AGENTRT_SCRIPTS_DIR}/bin/airy-local"

SILENT=1

setup_case() {
    MANAGED_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/airy_decl_test_XXXXXX")"
    export AIRY_HOME="$MANAGED_TEST_ROOT"
    mkdir -p "${AIRY_HOME}/config/managed.d"
}

teardown_case() {
    [[ -n "$MANAGED_TEST_ROOT" && -d "$MANAGED_TEST_ROOT" ]] && rm -rf "$MANAGED_TEST_ROOT"
    MANAGED_TEST_ROOT=""
}

write_frag() {
    local name="$1" bin="$2" ep="$3" args="$4"
    {
        printf 'AIRYRT_MANAGED_NAME=%s\n' "$name"
        printf 'AIRYRT_MANAGED_BIN=%s\n' "$bin"
        printf 'AIRYRT_MANAGED_EP=%s\n' "$ep"
        [[ -n "$args" ]] && printf 'AIRYRT_MANAGED_ARGS=%s\n' "$args"
    } > "${AIRY_HOME}/config/managed.d/test.env"
}

decl() {
    decl_get "${AIRY_HOME}/config/profile.env" "$1"
}

###############################################################################
# 用例
###############################################################################

test_no_fragment_baseline() {
    setup_case
    sup_write_decl
    local core
    core="$(decl AIRYRT_LAUNCH_CORE)"
    assert_contains "$core" "gateway_d" "CORE 名单应含内置 daemon"
    assert_false "[[ ' $core ' == *' llama_server '* ]]" "无片段时不得出现托管名"
    assert_equal "" "$(decl AIRYRT_LAUNCH_MANAGED)" "无片段时不应写托管名单"
    teardown_case
}

test_fragment_ingested() {
    setup_case
    write_frag "llama_server" "/bin/sh" "tcp:11435" "-m /models/qwen.gguf --port 11435"
    sup_write_decl
    assert_contains " $(decl AIRYRT_LAUNCH_CORE) " " llama_server " "托管名应并入 CORE"
    assert_equal "/bin/sh" "$(decl AIRYRT_LAUNCH_BIN_llama_server)" "BIN 声明应落位"
    assert_equal "tcp:11435" "$(decl AIRYRT_LAUNCH_EP_llama_server)" "EP 声明应落位"
    assert_contains "$(decl AIRYRT_LAUNCH_ARGS_llama_server)" "-m /models/qwen.gguf" "ARGS 声明应落位"
    assert_equal "llama_server" "$(decl AIRYRT_LAUNCH_MANAGED)" "托管名单应登记"
    teardown_case
}

test_ingest_idempotent() {
    setup_case
    write_frag "llama_server" "/bin/sh" "tcp:11435" ""
    sup_write_decl
    sup_write_decl
    local core count
    core="$(decl AIRYRT_LAUNCH_CORE)"
    count="$(printf '%s\n' "$core" | grep -o 'llama_server' | wc -l | tr -d ' ')"
    assert_equal "1" "$count" "重复摄取不得重复登记托管名"
    assert_equal "llama_server" "$(decl AIRYRT_LAUNCH_MANAGED)" "重复摄取名单不漂移"
    teardown_case
}

test_bad_bin_skipped() {
    setup_case
    write_frag "llama_server" "/nonexistent/llama-server" "tcp:11435" ""
    sup_write_decl
    assert_false "[[ ' $(decl AIRYRT_LAUNCH_CORE) ' == *' llama_server '* ]]" "不可执行 BIN 应被拒收"
    assert_equal "" "$(decl AIRYRT_LAUNCH_BIN_llama_server)" "拒收片段不得落 BIN 键"
    teardown_case
}

test_bad_ep_skipped() {
    setup_case
    write_frag "llama_server" "/bin/sh" "tcp:99999" ""
    sup_write_decl
    assert_false "[[ ' $(decl AIRYRT_LAUNCH_CORE) ' == *' llama_server '* ]]" "越界端口应被拒收"
    assert_equal "" "$(decl AIRYRT_LAUNCH_EP_llama_server)" "拒收片段不得落 EP 键"
    teardown_case
}

test_fragment_retired() {
    setup_case
    write_frag "llama_server" "/bin/sh" "tcp:11435" "-m /models/qwen.gguf"
    sup_write_decl
    rm -f "${AIRY_HOME}/config/managed.d/test.env"
    sup_write_decl
    assert_false "[[ ' $(decl AIRYRT_LAUNCH_CORE) ' == *' llama_server '* ]]" "撤销后 CORE 应剔除托管名"
    assert_equal "" "$(decl AIRYRT_LAUNCH_BIN_llama_server)" "撤销后 BIN 键应出清"
    assert_equal "" "$(decl AIRYRT_LAUNCH_EP_llama_server)" "撤销后 EP 键应出清"
    assert_equal "" "$(decl AIRYRT_LAUNCH_ARGS_llama_server)" "撤销后 ARGS 键应出清"
    assert_equal "" "$(decl AIRYRT_LAUNCH_MANAGED)" "撤销后托管名单应为空"
    teardown_case
}

test_airy_local_decl_sync() {
    setup_case
    local comp="${AIRY_HOME}/local/llamacpp" models="${AIRY_HOME}/local/models"
    mkdir -p "${comp}/bin" "$models"
    cp /bin/sh "${comp}/bin/llama-server"
    : > "${models}/test-model-Q8_0.gguf"
    airy_config_set "${comp}/installed.env" "server" "${comp}/bin/llama-server"
    airy_config_set "${models}/installed.env" "model.test-model.asset" "test-model-Q8_0.gguf"
    airy_config_set "${models}/installed.env" "model.test-model.sha256" "deadbeef"

    airy_local_decl_sync
    local frag="${AIRY_HOME}/config/managed.d/llamacpp.env"
    assert_file_exists "$frag" "组件与模型到位应落声明片段"
    assert_equal "tcp:11435" "$(decl_get "$frag" AIRYRT_MANAGED_EP)" "EP 应取默认端口 11435"
    assert_contains "$(decl_get "$frag" AIRYRT_MANAGED_ARGS)" "test-model-Q8_0.gguf" "ARGS 应绑定在位模型"

    rm -f "${models}/test-model-Q8_0.gguf"
    airy_local_decl_sync
    assert_false "[[ -f '$frag' ]]" "模型撤销后片段应清退"

    teardown_case
}

run_all_tests() {
    local tests=(
        "test_no_fragment_baseline"
        "test_fragment_ingested"
        "test_ingest_idempotent"
        "test_bad_bin_skipped"
        "test_bad_ep_skipped"
        "test_fragment_retired"
        "test_airy_local_decl_sync"
    )

    echo "=========================================="
    echo "  AgentRT managed.d declaration Tests"
    echo "=========================================="
    echo ""

    local test
    for test in "${tests[@]}"; do
        run_test "$test" "$test"
    done

    print_test_report
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi