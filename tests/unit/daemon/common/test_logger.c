/**
 * @file test_logger.c
 * @brief 日志模块单元测试
 * @copyright (c) 2026 SPHARX. All Rights Reserved.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "svc_logger.h"

static void test_logger_level_conversion(void) {
    printf("  test_logger_level_conversion...\n");

    assert(strcmp(airy_log_level_to_string(LOG_LEVEL_DEBUG), "DEBUG") == 0);
    assert(strcmp(airy_log_level_to_string(LOG_LEVEL_INFO), "INFO") == 0);
    assert(strcmp(airy_log_level_to_string(LOG_LEVEL_WARN), "WARN") == 0);
    assert(strcmp(airy_log_level_to_string(LOG_LEVEL_ERROR), "ERROR") == 0);
    assert(strcmp(airy_log_level_to_string(LOG_LEVEL_FATAL), "FATAL") == 0);

    assert(airy_log_level_from_string("DEBUG") == LOG_LEVEL_DEBUG);
    assert(airy_log_level_from_string("INFO") == LOG_LEVEL_INFO);
    assert(airy_log_level_from_string("WARN") == LOG_LEVEL_WARN);
    assert(airy_log_level_from_string("ERROR") == LOG_LEVEL_ERROR);
    assert(airy_log_level_from_string("FATAL") == LOG_LEVEL_FATAL);

    printf("    PASSED\n");
}

static void test_logger_init_shutdown(void) {
    printf("  test_logger_init_shutdown...\n");

    airy_logger_config_t config = {
        .name = "test_agentrt",
        .level = LOG_LEVEL_DEBUG,
        .targets = NULL,
        .target_count = 0,
        .include_source = true,
        .include_trace = true,
        .json_format = false
    };

    int ret = airy_log_init(&config);
    assert(ret == 0);

    airy_log_set_level(LOG_LEVEL_DEBUG);

    airy_log_shutdown();

    printf("    PASSED\n");
}

static void test_logger_trace_context(void) {
    printf("  test_logger_trace_context...\n");

    airy_trace_context_t ctx;
    airy_trace_new(&ctx);
    
    assert(ctx.trace_id[0] != '\0');
    assert(strlen(ctx.trace_id) > 0);

    airy_trace_set_current(&ctx);
    
    const char* current_trace = ctx.trace_id;
    assert(current_trace != NULL);

    airy_trace_set_session_id("test-session-123");
    const char* session_id = airy_trace_get_session_id();
    assert(strcmp(session_id, "test-session-123") == 0);

    printf("    PASSED\n");
}

static void test_logger_macros(void) {
    printf("  test_logger_macros...\n");

    airy_logger_config_t config = {
        .name = "test_agentrt",
        .level = LOG_LEVEL_DEBUG,
        .targets = NULL,
        .target_count = 0,
        .include_source = true,
        .include_trace = true,
        .json_format = false
    };

    airy_log_init(&config);

    /* 测试日志宏 */
    LOG_DEBUG("Test debug message: %d", 42);
    LOG_INFO("Test info message");
    LOG_WARN("Test warn message");
    LOG_ERROR("Test error message");

    /* 测试带追踪上下文的日志 */
    airy_trace_context_t ctx;
    airy_trace_new(&ctx);
    LOG_INFO_T(&ctx, "Test message with trace context");

    airy_log_shutdown();

    printf("    PASSED\n");
}

int main(void) {
    printf("=========================================\n");
    printf("  Logger Module Unit Tests\n");
    printf("=========================================\n");

    test_logger_level_conversion();
    test_logger_init_shutdown();
    test_logger_trace_context();
    test_logger_macros();

    printf("\n✅ All logger module tests PASSED\n");
    return 0;
}
