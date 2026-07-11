/**
 * @file test_error.c
 * @brief 错误处理模块单元测试
 * @copyright (c) 2026 SPHARX. All Rights Reserved.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "error.h"

static void test_error_strerror(void) {
    printf("  test_error_strerror...\n");

    assert(strcmp(airy_strerror(AIRY_OK), "Success") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_UNKNOWN), "Unknown error") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_INVALID_PARAM), "Invalid parameter") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_OUT_OF_MEMORY), "Out of memory") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_NOT_FOUND), "Not found") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_TIMEOUT), "Operation timed out") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_IO), "I/O error") == 0);
    assert(strcmp(airy_strerror(AIRY_ERR_PARSE_ERROR), "Parse error") == 0);

    printf("    PASSED\n");
}

static void test_error_chain(void) {
    printf("  test_error_chain...\n");

    airy_error_clear();

    airy_error_push_ex(AIRY_ERR_INVALID_PARAM, __FILE__, __LINE__, __func__, "Invalid param test");

    airy_error_chain_t* chain = airy_error_get_chain();
    assert(chain != NULL);
    assert(chain->code == AIRY_ERR_INVALID_PARAM);
    assert(chain->depth == 1);

    airy_error_clear();
    assert(airy_error_get_chain()->code == AIRY_OK);

    printf("    PASSED\n");
}

static void test_error_macros(void) {
    printf("  test_error_macros...\n");

    assert(AIRY_OK == 0);
    assert(AIRY_ERR_UNKNOWN < 0);
    assert(AIRY_ERR_INVALID_PARAM < 0);
    assert(AIRY_ERR_OUT_OF_MEMORY < 0);
    assert(AIRY_ERR_SERVICE_BASE < 0);
    assert(AIRY_ERR_LLM_BASE < 0);
    assert(AIRY_ERR_TOOL_BASE < 0);

    printf("    PASSED\n");
}

int main(void) {
    printf("=========================================\n");
    printf("  Error Module Unit Tests\n");
    printf("=========================================\n");

    test_error_strerror();
    test_error_chain();
    test_error_macros();

    printf("\n✅ All error module tests PASSED\n");
    return 0;
}