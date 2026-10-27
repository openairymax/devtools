#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# AgentRT 模型拉取层（airy-local model）测试
# 离线树外测试：假 gguf bundle + 动态生成模型 pin，零网络依赖。
# 覆盖：bundle 安装、幂等两连跑、毒件 fail-closed、size 漂移重对账、
#       remove 净退回退、list 两态、status 模型条目可见、未知名拒绝。

AGENTRT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test_framework.sh
source "$AGENTRT_TEST_DIR/test_framework.sh"

AIRY_LOCAL_BIN="${AGENTRT_SCRIPTS_DIR}/bin/airy-local"

# source 被测 CLI（入口 guard 保证 main 不执行，仅加载函数供直测）
# shellcheck source=../bin/airy-local
source "$AIRY_LOCAL_BIN"

###############################################################################
# 夹具：假 gguf 工件 + 动态模型 pin
###############################################################################

FIXTURE_ROOT=""
MODEL_ASSET=""
MODEL_SIZE=""
MODEL_SHA=""
MODEL_PIN=""

write_model_pin() {
    local pin_file="$1" size="$2" sha="$3"
    {
        echo "version|1"
        echo "model|test-model|${MODEL_ASSET}|${size}|${sha}"
        echo "mirror|broken|file:///nonexistent-airymax-model-test/{asset}"
    } > "$pin_file"
}

cleanup_fixture() {
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
}

setup_fixture() {
    cleanup_fixture
    FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/airy_model_test_XXXXXX")"
    mkdir -p "${FIXTURE_ROOT}/bundle"

    MODEL_ASSET="test-model-Q8_0.gguf"
    # 假 gguf：magic 头 + 随机体（实际格式由 llama-server 冒烟负责，此处仅测链路）
    { printf 'GGUF'; head -c 2041 /dev/urandom; } > "${FIXTURE_ROOT}/payload.raw"
    cp "${FIXTURE_ROOT}/payload.raw" "${FIXTURE_ROOT}/bundle/${MODEL_ASSET}"

    MODEL_SIZE="$(fetch_file_size "${FIXTURE_ROOT}/payload.raw")"
    MODEL_SHA="$(fetch_sha256_of "${FIXTURE_ROOT}/payload.raw")"

    MODEL_PIN="${FIXTURE_ROOT}/models.list"
    write_model_pin "$MODEL_PIN" "$MODEL_SIZE" "$MODEL_SHA"
}

run_airy_local() {
    local home="$1"
    shift
    (
        export AIRY_HOME="$home"
        export AIRY_LOCAL_MODEL_BUNDLE="${FIXTURE_ROOT}/bundle"
        export AIRY_LOCAL_MODEL_PIN="$MODEL_PIN"
        "$AIRY_LOCAL_BIN" "$@"
    )
}

###############################################################################
# 用例
###############################################################################

test_model_install_from_bundle() {
    local home="${FIXTURE_ROOT}/home1"
    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "model install from bundle should succeed"

    local target="${home}/local/models/${MODEL_ASSET}"
    assert_file_exists "$target"

    local registry="${home}/local/models/installed.env"
    assert_file_exists "$registry"
    assert_equal "$MODEL_SHA" "$(airy_config_get "$registry" model.test-model.sha256)" "registry sha256 should match pin"
    assert_equal "$MODEL_SIZE" "$(airy_config_get "$registry" model.test-model.size)" "registry size should match pin"
    assert_equal "$MODEL_ASSET" "$(airy_config_get "$registry" model.test-model.asset)" "registry asset should match pin"

    local list_out
    list_out="$(run_airy_local "$home" model list)"
    assert_contains "$list_out" "test-model [installed]" "list should show installed state"
}

test_model_install_idempotent() {
    local home="${FIXTURE_ROOT}/home2"
    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "first install should succeed"

    local status_first
    status_first="$(run_airy_local "$home" model list)"

    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "second install should be idempotent success"

    local status_second
    status_second="$(run_airy_local "$home" model list)"
    assert_equal "$status_first" "$status_second" "two consecutive installs must converge to the same state"
}

test_model_bad_sha_fail_closed() {
    local home="${FIXTURE_ROOT}/home3"
    local bad_pin="${FIXTURE_ROOT}/bad-sha.list"
    write_model_pin "$bad_pin" "$MODEL_SIZE" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

    local rc=0
    (
        export AIRY_HOME="$home"
        export AIRY_LOCAL_MODEL_BUNDLE="${FIXTURE_ROOT}/bundle"
        export AIRY_LOCAL_MODEL_PIN="$bad_pin"
        "$AIRY_LOCAL_BIN" model install test-model
    ) || rc=$?
    assert_false "[[ ${rc} -eq 0 ]]" "poisoned model artifact must be refused"

    assert_false "[[ -f ${home}/local/models/${MODEL_ASSET} ]]" "poisoned artifact must not land"
    assert_false "[[ -n \"$(find ${home}/local/tmp -name '*.part' 2>/dev/null)\" ]]" "no .part residue allowed"
}

test_model_size_drift_reconciles() {
    local home="${FIXTURE_ROOT}/home4"
    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "initial install should succeed"

    # pin size 漂移：幂等不得早退，重对账走下载路径且无源可用，保旧工件
    local drifted_pin="${FIXTURE_ROOT}/drifted.list"
    write_model_pin "$drifted_pin" "$((MODEL_SIZE + 1))" "$MODEL_SHA"

    local rc=0
    (
        export AIRY_HOME="$home"
        export AIRY_LOCAL_MODEL_BUNDLE="${FIXTURE_ROOT}/bundle"
        export AIRY_LOCAL_MODEL_PIN="$drifted_pin"
        "$AIRY_LOCAL_BIN" model install test-model
    ) || rc=$?
    assert_false "[[ ${rc} -eq 0 ]]" "size drift must trigger reconciliation, not early exit"

    assert_true "[[ -f ${home}/local/models/${MODEL_ASSET} ]]" "old model artifact must be preserved on failed reconciliation"
}

test_model_remove_reverts() {
    local home="${FIXTURE_ROOT}/home5"
    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "install before remove should succeed"

    run_airy_local "$home" model remove test-model
    assert_equal "0" "$?" "remove should succeed"

    assert_false "[[ -f ${home}/local/models/${MODEL_ASSET} ]]" "artifact must be deleted on remove"
    local registry="${home}/local/models/installed.env"
    assert_equal "" "$(airy_config_get "$registry" model.test-model.sha256)" "registry entry must be deleted on remove"

    local list_out
    list_out="$(run_airy_local "$home" model list)"
    assert_contains "$list_out" "test-model [pinned]" "list should fall back to pinned after remove"
}

test_model_unknown_fatal() {
    local home="${FIXTURE_ROOT}/home6"
    local rc=0
    run_airy_local "$home" model install no-such-model || rc=$?
    assert_false "[[ ${rc} -eq 0 ]]" "unknown model must fail closed"
}

test_model_status_visible() {
    local home="${FIXTURE_ROOT}/home7"
    run_airy_local "$home" model install test-model
    assert_equal "0" "$?" "install should succeed"

    local status_out
    status_out="$(run_airy_local "$home" status)"
    assert_contains "$status_out" "model: test-model" "status should list the registered model entry"
}

run_all_tests() {
    setup_fixture

    local tests=(
        "test_model_install_from_bundle"
        "test_model_install_idempotent"
        "test_model_bad_sha_fail_closed"
        "test_model_size_drift_reconciles"
        "test_model_remove_reverts"
        "test_model_unknown_fatal"
        "test_model_status_visible"
    )

    echo "=========================================="
    echo "  AgentRT airy-local model Tests"
    echo "=========================================="
    echo ""

    for test in "${tests[@]}"; do
        run_test "$test" "$test"
    done

    cleanup_fixture
    print_test_report
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
