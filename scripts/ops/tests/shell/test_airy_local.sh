#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# AgentRT 本地组件 CLI（airy-local）测试
# 离线树外测试：假资产 bundle + 动态生成 pin，零网络依赖。
# 覆盖：bundle 安装、幂等两连跑、毒件 fail-closed、尺寸截断拒绝、
#       remove 净退、status 三态、变体三步回退链、verify 三态语义。

AGENTRT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test_framework.sh
source "$AGENTRT_TEST_DIR/test_framework.sh"

AIRY_LOCAL_BIN="${AGENTRT_SCRIPTS_DIR}/bin/airy-local"

# source 被测 CLI（入口 guard 保证 main 不执行，仅加载函数供直测）
# shellcheck source=../bin/airy-local
source "$AIRY_LOCAL_BIN"

###############################################################################
# 夹具：假 llama-server 资产 + 动态 pin
###############################################################################

FIXTURE_ROOT=""
FIXTURE_ASSET=""
FIXTURE_SIZE=""
FIXTURE_SHA=""
FIXTURE_PIN=""

write_full_pin() {
    local pin_file="$1" size="$2" sha="$3"
    {
        echo "version|btest"
        local os arch
        for os in linux macos win; do
            for arch in x64 arm64; do
                echo "pin|${os}-${arch}-sycl|${FIXTURE_ASSET}|${size}|${sha}"
                echo "pin|${os}-${arch}-cpu|${FIXTURE_ASSET}|${size}|${sha}"
                echo "pin|${os}-${arch}|${FIXTURE_ASSET}|${size}|${sha}"
            done
        done
        echo "mirror|broken|file:///nonexistent-airymax-local-test/{asset}"
    } > "$pin_file"
}

cleanup_fixture() {
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
}

setup_fixture() {
    cleanup_fixture
    FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/airy_local_test_XXXXXX")"
    local stage="${FIXTURE_ROOT}/payload/stage/llama-test-bin"
    mkdir -p "$stage" "${FIXTURE_ROOT}/bundle"

    cat > "${stage}/llama-server" << 'EOF'
#!/bin/sh
echo "llama-server version btest (fake)"
exit 0
EOF
    chmod 0755 "${stage}/llama-server"
    echo "fake ggml data" > "${stage}/libggml-fake.so"

    FIXTURE_ASSET="llama-btest-bin-test.tar.gz"
    tar -czf "${FIXTURE_ROOT}/payload/${FIXTURE_ASSET}" -C "${FIXTURE_ROOT}/payload/stage" .
    cp "${FIXTURE_ROOT}/payload/${FIXTURE_ASSET}" "${FIXTURE_ROOT}/bundle/${FIXTURE_ASSET}"

    FIXTURE_SIZE="$(fetch_file_size "${FIXTURE_ROOT}/payload/${FIXTURE_ASSET}")"
    FIXTURE_SHA="$(fetch_sha256_of "${FIXTURE_ROOT}/payload/${FIXTURE_ASSET}")"

    FIXTURE_PIN="${FIXTURE_ROOT}/pin.list"
    write_full_pin "$FIXTURE_PIN" "$FIXTURE_SIZE" "$FIXTURE_SHA"
}

run_airy_local() {
    local home="$1" bundle="$2" pin="$3"
    shift 3
    (
        export AIRY_HOME="$home"
        export AIRY_LOCAL_BUNDLE="$bundle"
        export AIRY_LOCAL_PIN="$pin"
        "$AIRY_LOCAL_BIN" "$@"
    )
}

# 断言 oracle：与 CLI 相同的平台归一（测试允许知晓期望值）
host_pin_key_base() {
    local plat arch
    case "$(airy_platform_detect)" in
        linux|wsl) plat="linux" ;;
        macos)     plat="macos" ;;
        windows)   plat="win" ;;
    esac
    case "$(airy_arch_detect)" in
        x86_64)        arch="x64" ;;
        arm64|aarch64) arch="arm64" ;;
    esac
    echo "${plat}-${arch}"
}

###############################################################################
# 用例
###############################################################################

test_install_from_bundle() {
    local home="${FIXTURE_ROOT}/home1"
    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?" "install from bundle should succeed"

    local server="${home}/local/llamacpp/bin/llama-server"
    assert_file_exists "$server"
    assert_true "[[ -x ${server} ]]" "llama-server should be executable"

    local registry="${home}/local/llamacpp/installed.env"
    assert_file_exists "$registry"
    assert_equal "$FIXTURE_SHA" "$(airy_config_get "$registry" sha256)" "registry sha256 should match pin"
    assert_equal "btest" "$(airy_config_get "$registry" version)" "registry version should match pin"

    local out
    out="$(run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" status)"
    assert_contains "$out" "status: installed" "status should report installed"
}

test_install_idempotent() {
    local home="${FIXTURE_ROOT}/home2"
    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?" "first install should succeed"

    local sha1
    sha1="$(airy_config_get "${home}/local/llamacpp/installed.env" sha256)"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?" "second install should early-exit 0"

    local sha2
    sha2="$(airy_config_get "${home}/local/llamacpp/installed.env" sha256)"
    assert_equal "$sha1" "$sha2" "registry should be untouched by idempotent run"
}

test_bad_sha_fail_closed() {
    local home="${FIXTURE_ROOT}/home3"
    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?"
    local server="${home}/local/llamacpp/bin/llama-server"

    local bad_pin="${FIXTURE_ROOT}/pin-badsha.list"
    sed "s/${FIXTURE_SHA}/deadbeef${FIXTURE_SHA:8}/" "$FIXTURE_PIN" > "$bad_pin"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$bad_pin" install
    assert_false "[[ $? -eq 0 ]]" "poisoned artifact must fail the install"

    assert_false "[[ -n \"$(find ${home}/local/tmp -name '*.part' 2>/dev/null)\" ]]" "no .part residue allowed"
    assert_true "[[ -x ${server} ]]" "old install must be preserved on poison"
}

test_size_truncation_rejected() {
    local home="${FIXTURE_ROOT}/home4"
    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?"
    local server="${home}/local/llamacpp/bin/llama-server"

    local bad_pin="${FIXTURE_ROOT}/pin-badsize.list"
    sed "s/|${FIXTURE_SIZE}|/|$((FIXTURE_SIZE + 1))|/" "$FIXTURE_PIN" > "$bad_pin"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$bad_pin" install
    assert_false "[[ $? -eq 0 ]]" "size-mismatched artifact must be rejected"

    assert_true "[[ -x ${server} ]]" "old install must be preserved on size mismatch"
}

test_remove_clean() {
    local home="${FIXTURE_ROOT}/home5"
    mkdir -p "${home}/local/models"
    echo "fake gguf" > "${home}/local/models/model.gguf"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" remove
    assert_equal "0" "$?" "remove should succeed"
    assert_false "[[ -d ${home}/local/llamacpp ]]" "component dir must be gone"
    assert_file_exists "${home}/local/models/model.gguf" "models dir must be kept"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" remove
    assert_equal "0" "$?" "second remove should be a no-op success"
}

test_status_states() {
    local home="${FIXTURE_ROOT}/home6"
    local out
    out="$(run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" status)"
    assert_contains "$out" "status: not installed" "fresh home should report not installed"

    run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" install
    assert_equal "0" "$?"
    out="$(run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" status)"
    assert_contains "$out" "status: installed" "installed home should report installed"

    chmod -x "${home}/local/llamacpp/bin/llama-server"
    out="$(run_airy_local "$home" "${FIXTURE_ROOT}/bundle" "$FIXTURE_PIN" status)"
    assert_contains "$out" "status: broken" "non-executable server should report broken"
}

test_resolve_key_fallback() {
    local base
    base="$(host_pin_key_base)"

    local key
    key="$(airy_local_resolve_key "$FIXTURE_PIN" "sycl")"
    assert_equal "${base}-sycl" "$key" "full pin should hit sycl directly"

    local cpu_pin="${FIXTURE_ROOT}/pin-cpuonly.list"
    {
        echo "version|btest"
        local os arch
        for os in linux macos win; do
            for arch in x64 arm64; do
                echo "pin|${os}-${arch}-cpu|${FIXTURE_ASSET}|${FIXTURE_SIZE}|${FIXTURE_SHA}"
            done
        done
    } > "$cpu_pin"
    key="$(airy_local_resolve_key "$cpu_pin" "sycl")"
    assert_equal "${base}-cpu" "$key" "sycl should fall back to cpu pin"

    local bare_pin="${FIXTURE_ROOT}/pin-bareonly.list"
    {
        echo "version|btest"
        local os arch
        for os in linux macos win; do
            for arch in x64 arm64; do
                echo "pin|${os}-${arch}|${FIXTURE_ASSET}|${FIXTURE_SIZE}|${FIXTURE_SHA}"
            done
        done
    } > "$bare_pin"
    key="$(airy_local_resolve_key "$bare_pin" "sycl")"
    assert_equal "${base}" "$key" "sycl should fall back to bare key"
}

test_fetch_verify_semantics() {
    local f="${FIXTURE_ROOT}/payload/${FIXTURE_ASSET}"

    fetch_verify "$f" "$FIXTURE_SIZE" "$FIXTURE_SHA"
    assert_equal "0" "$?" "verify should pass for matching artifact"

    fetch_verify "$f" "$((FIXTURE_SIZE + 1))" "$FIXTURE_SHA"
    assert_equal "1" "$?" "size mismatch should return 1"

    fetch_verify "$f" "$FIXTURE_SIZE" "deadbeef${FIXTURE_SHA:8}"
    assert_equal "2" "$?" "sha mismatch (poison) should return 2"
}

test_all_sources_fail() {
    local home="${FIXTURE_ROOT}/home7"
    run_airy_local "$home" "" "$FIXTURE_PIN" install
    assert_false "[[ $? -eq 0 ]]" "install with no bundle and dead mirror must fail"

    assert_false "[[ -d ${home}/local/llamacpp ]]" "no component dir on total failure"
    assert_false "[[ -n \"$(find ${home}/local/tmp -name '*.part' 2>/dev/null)\" ]]" "no .part residue"
}

###############################################################################
# 运行所有测试
###############################################################################

run_all_tests() {
    setup_fixture

    local tests=(
        "test_install_from_bundle"
        "test_install_idempotent"
        "test_bad_sha_fail_closed"
        "test_size_truncation_rejected"
        "test_remove_clean"
        "test_status_states"
        "test_resolve_key_fallback"
        "test_fetch_verify_semantics"
        "test_all_sources_fail"
    )

    echo "=========================================="
    echo "  AgentRT airy-local Tests"
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
