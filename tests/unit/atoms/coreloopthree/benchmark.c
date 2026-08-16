/**
 * @file benchmark.c
 * @brief 核心循环性能基准测试
 * @copyright (c) 2026 SPHARX. All Rights Reserved.
 */

#include "loop.h"
#include "agentrt.h"
#include <stdio.h>
#include <stdlib.h>

/* Unified base library compatibility layer */
#include "memory_compat.h"
#include "string_compat.h"
#include <string.h>
#include <time.h>

/**
 * @brief 基准测试：记忆写入性能
 */
static void benchmark_memory_write() {
    airy_memory_engine_t* engine = NULL;
    airy_error_t err = airy_memory_create(NULL, &engine);
    if (err != AIRY_SUCCESS) {
        printf("benchmark_memory_write: Failed to create engine\n");
        return;
    }

    int num_records = 1000;
    char** record_ids;
    SAFE_MALLOC_ARRAY(record_ids, num_records, sizeof(char*));
    if (!record_ids) {
        airy_memory_destroy(engine);
        return;
    }

    airy_memory_record_t record = {
        .memory_record_id = NULL,
        .memory_record_id_len = 0,
        .memory_record_type = AIRY_MEMTYPE_TEXT,
        .memory_record_timestamp_ns = 0,
        .memory_record_source_agent = "test_agent",
        .memory_record_source_len = strlen("test_agent"),
        .memory_record_trace_id = "test_trace",
        .memory_record_trace_len = strlen("test_trace"),
        .memory_record_data = (void*)"test data",
        .memory_record_data_len = strlen("test data"),
        .memory_record_importance = 0.5f,
        .memory_record_access_count = 0
    };

    clock_t start = clock();
    for (int i = 0; i < num_records; i++) {
        err = airy_memory_write(engine, &record, &record_ids[i]);
        if (err != AIRY_SUCCESS) {
            printf("benchmark_memory_write: Failed to write record %d\n", i);
            break;
        }
    }
    clock_t end = clock();
    double elapsed = (double)(end - start) / CLOCKS_PER_SEC;

    printf("benchmark_memory_write: %d records in %.3f seconds (%.3f records/sec)\n",
           num_records, elapsed, num_records / elapsed);

    for (int i = 0; i < num_records; i++) {
        if (record_ids[i]) {
            AIRY_FREE(record_ids[i]);
        }
    }
    AIRY_FREE(record_ids);

    airy_memory_destroy(engine);
}

/**
 * @brief 基准测试：记忆查询性能
 */
static void benchmark_memory_query() {
    airy_memory_engine_t* engine = NULL;
    airy_error_t err = airy_memory_create(NULL, &engine);
    if (err != AIRY_SUCCESS) {
        printf("benchmark_memory_query: Failed to create engine\n");
        return;
    }

    int num_records = 1000;
    for (int i = 0; i < num_records; i++) {
        airy_memory_record_t record = {
            .memory_record_id = NULL,
            .memory_record_id_len = 0,
            .memory_record_type = AIRY_MEMTYPE_TEXT,
            .memory_record_timestamp_ns = 0,
            .memory_record_source_agent = "test_agent",
            .memory_record_source_len = strlen("test_agent"),
            .memory_record_trace_id = "test_trace",
            .memory_record_trace_len = strlen("test_trace"),
            .memory_record_data = (void*)"test data",
            .memory_record_data_len = strlen("test data"),
            .memory_record_importance = 0.5f,
            .memory_record_access_count = 0
        };

        char* record_id = NULL;
        err = airy_memory_write(engine, &record, &record_id);
        if (err == AIRY_SUCCESS && record_id) {
            AIRY_FREE(record_id);
        }
    }

    airy_memory_query_t query = {
        .memory_query_text = "test",
        .memory_query_text_len = strlen("test"),
        .memory_query_start_time = 0,
        .memory_query_end_time = 0,
        .memory_query_source_agent = NULL,
        .memory_query_trace_id = NULL,
        .memory_query_limit = 10,
        .memory_query_offset = 0,
        .memory_query_include_raw = 1
    };

    int num_queries = 100;
    clock_t start = clock();
    for (int i = 0; i < num_queries; i++) {
        airy_memory_result_ext_t* result = NULL;
        err = airy_memory_query(engine, &query, &result);
        if (err == AIRY_SUCCESS && result) {
            airy_memory_result_free(result);
        }
    }
    clock_t end = clock();
    double elapsed = (double)(end - start) / CLOCKS_PER_SEC;

    printf("benchmark_memory_query: %d queries in %.3f seconds (%.3f queries/sec)\n",
           num_queries, elapsed, num_queries / elapsed);

    airy_memory_destroy(engine);
}

int main() {
    printf("=== Running Benchmark Tests ===\n");
    benchmark_memory_write();
    benchmark_memory_query();
    printf("=== Benchmark Tests Complete ===\n");
    return 0;
}