
# AgentRT 性能基准测试 (TeamC P2-C02)
# 测试代码豁免 BAN 严格合规：测试允许使用裸 malloc/free/memset 等函数
add_compile_definitions(AGENTRT_COMPLIANCE_IMPL)

if(NOT TARGET svc_common)
    airy_print_warn("  [benchmarks] Skipping tests: svc_common not available (BUILD_DAEMON=OFF)")
    return()
endif()

add_executable(test_performance_benchmarks test_performance_benchmarks.c)

target_include_directories(test_performance_benchmarks PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/atoms/corekern/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/atoms/coreloopthree/tests/unit
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/atoms/coreloopthree/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/daemons/common/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/daemons/common/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/atoms/syscall/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/commons/utils/error/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/commons/utils/memory/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/commons/platform/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../agentrt/commons/utils/string/include
)

target_link_libraries(test_performance_benchmarks PRIVATE
    airy_core
    airy_syscall
    -Wl,--whole-archive
    airy_coreloopthree
    -Wl,--no-whole-archive
    svc_common
    airy_llm_service
    airy_tool_service
    Threads::Threads
    airy_platform_libs
    m
)

if(AGENTRT_HAS_CJSON)
    target_link_libraries(test_performance_benchmarks PRIVATE cjson)
endif()

target_compile_features(test_performance_benchmarks PRIVATE c_std_11)
target_compile_options(test_performance_benchmarks PRIVATE
    -Wall -Wextra -g -Wno-unused-function -Wno-unused-variable
)

add_test(NAME performance_benchmarks COMMAND test_performance_benchmarks)

airy_print_ok("  [benchmarks] test_performance_benchmarks: P2-C02 configured")
