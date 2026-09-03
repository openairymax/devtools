/**
 * @file test_error.c
 * @brief error.h 单元测试
 * @copyright (c) 2026 SPHARX. All Rights Reserved.
 */

#include <stdio.h>
#include <stdlib.h>

/* Unified base library compatibility layer */
#include "memory_compat.h"
#include "string_compat.h"
#include <string.h>
#include <assert.h>

#include "error.h"

/* ==================== 测试辅助宏 ==================== */

#define TEST_ASSERT(condition, message) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "[FAIL]: %s\n", message); \
            return 1; \
        } \
    } while (0)

#define TEST_RUN(test_func) \
    do { \
        printf("[TEST] Running %s...\n", #test_func); \
        if (test_func() != 0) { \
            fprintf(stderr, "[FAIL] Test failed: %s\n", #test_func); \
            failed_tests++; \
        } else { \
            printf("[PASS] %s\n", #test_func); \
            passed_tests++; \
        } \
    } while (0)

static int passed_tests = 0;
static int failed_tests = 0;

/* ==================== 测试用例 ==================== */

/**
 * @brief 测试错误码定义（对齐 SSoT error.h）
 */
static int test_error_codes(void) {
    /* 成功码 */
    TEST_ASSERT(AIRY_EOK == 0, "AIRY_EOK should be 0");

    /* 扩展错误码（对齐 error.h L52-53, L139, L142, L145） */
    TEST_ASSERT(AIRY_ERR_UNKNOWN == -99, "AIRY_ERR_UNKNOWN should be -99");
    TEST_ASSERT(AIRY_ERR_INVALID_PARAM == -36, "AIRY_ERR_INVALID_PARAM should be -36");
    TEST_ASSERT(AIRY_ERR_NULL_POINTER == -3, "AIRY_ERR_NULL_POINTER should be -3");
    TEST_ASSERT(AIRY_ERR_OUT_OF_MEMORY == -59, "AIRY_ERR_OUT_OF_MEMORY should be -59");

    printf("  Error codes: OK\n");
    return 0;
}

/**
 * @brief 测试错误字符串转换（airy_err_str）
 */
static int test_error_strings(void) {
    const char *str;

    str = airy_err_str(AIRY_EOK);
    TEST_ASSERT(str != NULL, "Error string for EOK should not be NULL");

    str = airy_err_str(AIRY_ERR_UNKNOWN);
    TEST_ASSERT(str != NULL, "Error string for UNKNOWN should not be NULL");

    str = airy_err_str(AIRY_ERR_INVALID_PARAM);
    TEST_ASSERT(str != NULL, "Error string for INVALID_PARAM should not be NULL");

    str = airy_err_str(AIRY_ERR_OUT_OF_MEMORY);
    TEST_ASSERT(str != NULL, "Error string for OUT_OF_MEMORY should not be NULL");

    str = airy_err_str(-999); /* 未知错误码 */
    TEST_ASSERT(str != NULL, "Error string for unknown code should not be NULL");

    printf("  Error strings: OK\n");
    return 0;
}

/**
 * @brief 测试错误链操作（airy_err_push_ex + airy_err_get_chain）
 */
static int test_error_chain(void) {
    airy_err_chain_t *chain;
    int depth;

    /* 清除已有错误链 */
    airy_err_clear();

    /* 推入两个错误 */
    airy_err_push_ex(AIRY_ERR_INVALID_PARAM, __FILE__, __LINE__, __func__, "%s", "First error");
    airy_err_push_ex(AIRY_ERR_OUT_OF_MEMORY, __FILE__, __LINE__, __func__, "%s", "Second error");

    /* 获取当前线程错误链 */
    chain = airy_err_get_chain();
    TEST_ASSERT(chain != NULL, "Error chain should be available");

    /* 验证链深度 */
    depth = airy_err_chain_get_depth(chain);
    TEST_ASSERT(depth == 2, "Error chain should have 2 errors");

    /* 验证最新错误码 */
    TEST_ASSERT(airy_err_chain_get_latest_error(chain) == AIRY_ERR_OUT_OF_MEMORY,
                "Latest error should be OUT_OF_MEMORY");

    /* 验证最早错误码（root） */
    TEST_ASSERT(airy_err_chain_get_root_error(chain) == AIRY_ERR_INVALID_PARAM,
                "Root error should be INVALID_PARAM");

    /* 清理 */
    airy_err_clear();

    printf("  Error chain: OK\n");
    return 0;
}

/* ==================== 主函数 ==================== */

int main(void) {
    printf("===========================================\n");
    printf("  agentrt/commons/error 单元测试\n");
    printf("===========================================\n\n");

    TEST_RUN(test_error_codes);
    TEST_RUN(test_error_strings);
    TEST_RUN(test_error_chain);

    printf("\n===========================================\n");
    printf("  测试结果: %d 通过, %d 失败\n", passed_tests, failed_tests);
    printf("===========================================\n");

    return failed_tests > 0 ? 1 : 0;
}
