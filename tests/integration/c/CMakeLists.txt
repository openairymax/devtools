# AgentRT 集成测试 CMake 配置
# 测试代码豁免 BAN 严格合规：测试允许使用裸 malloc/free/memset 等函数
add_compile_definitions(AIRY_COMPLIANCE_IMPL)
# @owner: team-C
# P1.16m: 12 条连接线集成测试 + P2.8: Hook 系统集成测试
#
# Phase 1.7 重构完成：test_stubs.c 桩文件已完全消除（v0.1.1）
# - 7 个 PURE_DUPLICATE 测试直接迁移到真实库链接
# - 6 个 BEHAVIOR_DIFF/FICTIONAL_API 测试修复行为差异后迁移到真实库链接
# - 全部 13 个集成测试现在链接真实生产库，零桩文件依赖

# ============================================================================
# 公共 include 路径
# ============================================================================
set(INTEGRATION_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/coreloopthree/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/corekern/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/syscall/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/memory
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/memory/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/llm_d/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/tool_d/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/common/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/monit_d/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/gateway_d/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/market_d/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/memory/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/error/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/config_unified/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/logging/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/sync/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/string/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/cache/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/compat/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/network/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/ipc/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/platform/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/cupolas/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/cupolas/src
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ============================================================================
# 辅助函数：配置使用真实库的集成测试（无 test_stubs.c）
# ============================================================================
function(configure_real_lib_test test_name)
    cmake_parse_arguments(TEST "" "" "LIBS" ${ARGN})

    add_executable(${test_name} ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}.c)

    target_include_directories(${test_name} PRIVATE ${INTEGRATION_INCLUDE_DIRS})
    target_compile_features(${test_name} PRIVATE c_std_11)
    target_compile_options(${test_name} PRIVATE
        -Wall -Wextra -g -Wno-unused-function -Wno-unused-variable
        -Wno-unused-parameter
    )

    if(NOT MSVC AND NOT APPLE)
        target_link_libraries(${test_name} PRIVATE
            "-Wl,--start-group"
            ${TEST_LIBS}
            "-Wl,--end-group"
            Threads::Threads
            airy_platform_libs
            m
        )
    else()
        target_link_libraries(${test_name} PRIVATE
            ${TEST_LIBS}
            Threads::Threads
            m
        )
    endif()

    add_test(NAME integration_${test_name}
        COMMAND ${test_name}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )

    airy_print_ok("  [integration] ${test_name}: configured (real libs, no stubs)")
endfunction()

# ============================================================================
# PURE_DUPLICATE 测试（7个）— 直接链接真实库
# ============================================================================

# C-L03: market_d → OpenLab（自包含 mock，仅需头文件）
configure_real_lib_test(test_c_link_03_market_openlab
    LIBS airy_common
)

# C-L06: Orchestrator → CoreLoopThree（orchestrator 真实实现）
# 注意：airy_coreloopthree 已 PUBLIC 链接 svc_common（含 orchestrator.c），
# 链接器自动处理重复符号（仅从首个库提取 .o）
# LTO 链接下 --start-group/--end-group 必须包裹所有传递依赖，
# 否则组外库引用组内库符号时无法回溯解析。
# 显式列出所有传递依赖：
#   - airy_coreloopthree: 主库（含 cognition/engine.c, execution/tool_svc_adapter.c）
#   - airy_llm_service:   提供 llm_service_complete[_stream]/llm_response_free
#   - airy_tool_service:  提供 tool_service_execute/tool_approval_check/tool_result_free
#   - airy_cognition:     传递依赖（引用 tool/llm 符号）
#   - airy_execution:     传递依赖（引用 tool_approval_check）
#   - airy_core:          atoms 内核
#   - airy_memory:        记忆模块
#   - svc_common:            daemon 公共库（含 orchestrator.c, checkpoint.c）
configure_real_lib_test(test_c_link_06_orchestrator_loop
    LIBS airy_coreloopthree airy_llm_service airy_tool_service
         airy_cognition airy_execution airy_core airy_memory svc_common
)

# C-L07: Checkpoint → CoreLoopThree（checkpoint_adapter 真实实现）
configure_real_lib_test(test_c_link_07_checkpoint_loop
    LIBS airy_coreloopthree
)

# C-L08: ServiceDiscovery → All Daemons（service_discovery 真实实现）
configure_real_lib_test(test_c_link_08_service_discovery
    LIBS svc_common
)

# C-L09: IPC Bus → All Daemons（ipc_bus_helper 真实实现）
configure_real_lib_test(test_c_link_09_ipc_bus
    LIBS svc_common
)

# C-L10: monit_d → Prometheus（prometheus_exporter 真实实现）
configure_real_lib_test(test_c_link_10_monit_prometheus
    LIBS airy_monit_service
)

# P2.8: Hook System Integration（hook_registry/executor/interceptor/timeout 真实实现）
# SP04: hook 系统核心已迁移到 airy_coreloopthree，不再链接 airy_hook_service
configure_real_lib_test(test_hook_system
    LIBS airy_coreloopthree
)

# ============================================================================
# BEHAVIOR_DIFF / FICTIONAL_API 测试（6个）— v0.1.1 修复后迁移到真实库
# 全部 6 个测试已修复行为差异/虚构 API，链接真实生产库：
#   test_01 ✅ config_unified 6 个 bug 修复
#   test_02 ✅ llm_svc_adapter 真实实现验证
#   test_04 ✅ tool_svc_adapter 真实实现验证
#   test_05 ✅ daemon_security ACL 注册 API 补全
#   test_11 ✅ gateway detect_proto 真实实现
#   test_12 ✅ memoryrovol_bridge builtin 降级
# ============================================================================

# C-L01: Manager → CoreLoopThree（已迁移到真实库 airy_common）
# v0.1.1 修复：memory_source_load 补全 yaml 分支（Bug A），env_source_load
# 使用双分隔符 __ 作为层级分隔符 + lowercase + int 优先解析（Bug B），
# 对齐桩函数行为。测试 env var 从 AGENTRT_KERNEL_MAX_ALLOC_MB 改为
# AGENTRT_KERNEL__MAX_ALLOC_MB（双下划线分隔层级）。
configure_real_lib_test(test_c_link_01_manager_loop
    LIBS airy_common
)

# C-L02: llm_d → CoreLoopThree（已迁移到真实库）
# v0.1.1 修正：CMake 注释此前误标为 FICTIONAL_API，实际 coreloopthree 的
# llm_svc_adapter.h 提供 llm_svc_adapter_* API（与测试一致），真实实现完整存在。
# 真实 create 会启动 SD+IPC 引导，与 test_04 同模式。
configure_real_lib_test(test_c_link_02_llm_loop
    LIBS airy_cognition airy_core svc_common
)

# C-L04: tool_d → CoreLoopThree（已迁移到真实库）
# v0.1.1 修正：is_connected 在 create 成功后行为与桩一致（都返回 true）。
# 真实 create 会启动 SD+IPC 引导，但 ipc_bus_helper_register_channel 按 ibh 实例
# 独立注册（非全局 channel 名唯一性检查），多实例同 channel 名不冲突。
configure_real_lib_test(test_c_link_04_tool_loop
    LIBS airy_execution airy_core svc_common airy_tool_service
)

# C-L05: Cupolas SafetyGuard → tool_d（已迁移到真实库）
# v0.1.1 修复：真实 daemon_security 采用 fail-closed，新增 daemon_security_add_acl_rule
# 公开 API 允许测试预注册 ACL 条目。测试 main() 初始化 ACL 表为所需的
# (agent_id, tool_name) 组合授权，"restricted-agent"+"shell_exec" 不注册以验证拒绝路径。
# 并发测试改用固定 tool_name（真实 ACL 精确匹配，不支持通配符）。
configure_real_lib_test(test_c_link_05_safety_tool
    LIBS airy_tool_service svc_common cupolas
)

# C-L11: gateway_d → Gateway（已迁移到真实库 airy_gateway_service）
# v0.1.1 修复：detect_proto 真实实现用 strncmp 前缀匹配 + body 检测，
# 默认返回 JSONRPC（非桩的 COUNT）。测试 CHECK 用 `|| proto < COUNT` 宽泛条件，
# 真实实现下仍通过。forward 调用不检查 ret（无后端 daemon 时超时返回错误）。
configure_real_lib_test(test_c_link_11_gateway_forward
    LIBS airy_gateway_service
)

# C-L12: CoreLoopThree → MemoryRovol（已迁移到真实库）
# v0.1.1 修复：真实 memoryrovol_bridge_create 依赖 builtin_init 成功，
# 测试环境无 MemoryRovol 库时优雅降级到 builtin（弱符号机制）。
# config_path 为 NULL 时使用默认路径，builtin_storage_create 会创建目录。
#
# Task #38: memoryrovol.h 是商业产品头文件，仅在 products/memoryrovol 存在时可用。
# 当 MemoryRovol 不可用时跳过该测试（非阻断），避免编译失败。
set(_MEMORYROVOL_INCLUDE_DIR "")
if(TARGET airy_memoryrovol_bridge)
    # 通过 airy_memoryrovol_bridge 接口库获取 include 路径
    get_target_property(_bridge_inc airy_memoryrovol_bridge INTERFACE_INCLUDE_DIRECTORIES)
    if(_bridge_inc)
        set(_MEMORYROVOL_INCLUDE_DIR "${_bridge_inc}")
    endif()
elseif(DEFINED MEMORYROVOL_DIR AND EXISTS "${MEMORYROVOL_DIR}/include/memoryrovol.h")
    set(_MEMORYROVOL_INCLUDE_DIR "${MEMORYROVOL_DIR}/include")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../../products/memoryrovol/include/memoryrovol.h")
    set(_MEMORYROVOL_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../products/memoryrovol/include")
endif()

if(_MEMORYROVOL_INCLUDE_DIR AND (TARGET airy_memoryrovol OR TARGET airy_memoryrovol_bridge))
    configure_real_lib_test(test_c_link_12_memoryrovol_bridge
        LIBS airy_coreloopthree airy_memory airy_core svc_common
    )
    if(TARGET airy_memoryrovol)
        target_link_libraries(test_c_link_12_memoryrovol_bridge PRIVATE airy_memoryrovol)
    elseif(TARGET airy_memoryrovol_bridge)
        target_link_libraries(test_c_link_12_memoryrovol_bridge PRIVATE airy_memoryrovol_bridge)
    endif()
    if(NOT TARGET airy_memoryrovol)
        target_include_directories(test_c_link_12_memoryrovol_bridge PRIVATE ${_MEMORYROVOL_INCLUDE_DIR})
    endif()
else()
    airy_print_warn("  [integration] test_c_link_12_memoryrovol_bridge: SKIPPED (MemoryRovol commercial library not built — set AGENTRT_WITH_MEMORYROVOL=ON and build products/memoryrovol)")
endif()

# ============================================================================
# 已有测试 (保留)
# ============================================================================

# 端到端核心测试 (P2-C01)
if(TARGET svc_common)
    add_executable(test_e2e_core test_e2e_core.c)

    target_include_directories(test_e2e_core PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/corekern/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/coreloopthree/tests/unit
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/coreloopthree/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/common/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/common/src
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms/syscall/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/error/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/memory/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/platform/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/string/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons/utils/cache/include
    )

    target_link_libraries(test_e2e_core PRIVATE
        airy_core
        airy_syscall
        -Wl,--whole-archive
        airy_coreloopthree
        -Wl,--no-whole-archive
        svc_common
        -Wl,--start-group
        airy_cognition
        airy_execution
        airy_memory
        airy_atoms
        airy_llm_service
        airy_tool_service
        -Wl,--end-group
        Threads::Threads
        airy_platform_libs
        m
    )

    if(AGENTRT_HAS_CJSON OR CJSON_FOUND)
        target_link_libraries(test_e2e_core PRIVATE cjson)
    endif()

    target_compile_features(test_e2e_core PRIVATE c_std_11)
    target_compile_options(test_e2e_core PRIVATE
        -Wall -Wextra -g -Wno-unused-function -Wno-unused-variable
    )

    add_test(NAME e2e_core COMMAND test_e2e_core
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

    airy_print_ok("  [integration] test_e2e_core: P2-C01 E2E integration tests configured")
else()
    airy_print_warn("  [integration] Skipping test_e2e_core: svc_common not available (BUILD_DAEMON=OFF)")
endif()

# LLM Routing Integration Test (INT-15)
set(LLM_D_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/llm_d)
set(COMMONS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/commons)
set(ATOMIC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/atoms)
set(SYSCALL_INCLUDE_DIR ${ATOMIC_DIR}/syscall/include)
set(COREKERN_INCLUDE_DIR ${ATOMIC_DIR}/corekern/include)

set(LLM_IMPL_SOURCES
    ${LLM_D_DIR}/src/service.c
    ${LLM_D_DIR}/src/cache.c
    ${LLM_D_DIR}/src/token_counter.c
    ${LLM_D_DIR}/src/response.c
    ${LLM_D_DIR}/src/cost_tracker.c
    ${LLM_D_DIR}/src/providers/registry.c
    ${LLM_D_DIR}/src/providers/provider.c
    ${LLM_D_DIR}/src/providers/openai.c
    ${LLM_D_DIR}/src/providers/anthropic.c
    ${LLM_D_DIR}/src/providers/deepseek.c
    ${LLM_D_DIR}/src/providers/google.c
    ${LLM_D_DIR}/src/providers/local.c
    ${LLM_D_DIR}/src/router/llm_router.c
    ${LLM_D_DIR}/src/router/cost_aware_router.c
    ${LLM_D_DIR}/src/router/round_robin_router.c
    ${LLM_D_DIR}/src/router/least_latency_router.c
    ${LLM_D_DIR}/src/router/quality_first_router.c
)

add_executable(test_llm_d_routing test_llm_d_routing.c ${LLM_IMPL_SOURCES})

target_include_directories(test_llm_d_routing PRIVATE
    ${LLM_D_DIR}/include
    ${LLM_D_DIR}/src
    ${LLM_D_DIR}/src/providers
    ${COMMONS_DIR}
    ${COMMONS_DIR}/platform/include
    ${COMMONS_DIR}/utils/error/include
    ${COMMONS_DIR}/utils/logging/include
    ${COMMONS_DIR}/utils/config_unified/include
    ${COMMONS_DIR}/utils/memory/include
    ${COMMONS_DIR}/utils/string/include
    ${COMMONS_DIR}/utils/sync/include
    ${COMMONS_DIR}/utils/cache/include
    ${COMMONS_DIR}/utils/compat/include
    ${SYSCALL_INCLUDE_DIR}
    ${COREKERN_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../agentrt/daemons/common/include
)

target_link_libraries(test_llm_d_routing PRIVATE
    svc_common
    Threads::Threads
)

if(AGENTRT_HAS_CJSON OR CJSON_FOUND)
    target_link_libraries(test_llm_d_routing PRIVATE cjson)
endif()

if(AGENTRT_HAS_CURL)
    if(CURL_INCLUDE_DIRS)
        target_include_directories(test_llm_d_routing PRIVATE ${CURL_INCLUDE_DIRS})
    endif()
    if(CURL_LIBRARIES)
        target_link_libraries(test_llm_d_routing PRIVATE ${CURL_LIBRARIES})
    elseif(LIBCURL_LIBRARIES)
        target_link_libraries(test_llm_d_routing PRIVATE ${LIBCURL_LIBRARIES})
    elseif(PC_CURL_LIBRARIES)
        target_link_libraries(test_llm_d_routing PRIVATE ${PC_CURL_LIBRARIES})
    else()
        target_link_libraries(test_llm_d_routing PRIVATE curl)
    endif()
endif()

target_compile_features(test_llm_d_routing PRIVATE c_std_11)
target_compile_options(test_llm_d_routing PRIVATE
    -Wall -Wextra -g -Wno-unused-function -Wno-unused-variable
)

add_test(NAME llm_d_routing COMMAND test_llm_d_routing
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

airy_print_ok("  [integration] test_llm_d_routing: INT-15 LLM routing integration tests configured")
