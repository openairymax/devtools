// SPDX-FileCopyrightText: 2026 SPHARX Ltd.
// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// @owner: team-C
/**
 * @file test_c_link_09_ipc_bus.c
 * @brief C-L09 Integration Test: IPC Bus → all daemons
 *
 * Tests the IPC Bus helper surface that survives 8.3.4 (0.1.15):
 * 1. Normal path: Init → register channel → register handler → shutdown
 * 2. Normal path: multiple channel registration
 * 3. Error path: NULL handling
 * 4. Error path: invalid channel operations
 * 5. Error path: request to non-existent target
 * 6. Concurrent path: multiple helper instances
 *
 * 8.3.4: the tests for the removed send/notify/route/endpoint/
 * backpressure/routing-stats wrappers were deleted together with the
 * API family they exercised.
 */

#include <stdio.h>
#include <string.h>

#include "ipc_bus_helper.h"

/* ============================================================================
 * Test Helpers
 * ============================================================================ */

static int g_tests_passed = 0;
static int g_tests_failed = 0;
static int g_tests_total = 0;

#define TEST(name) do { \
    g_tests_total++; \
    printf("  [TEST] %s ... ", name); \
} while(0)

#define PASS() do { \
    g_tests_passed++; \
    printf("PASS\n"); \
} while(0)

#define FAIL(reason) do { \
    g_tests_failed++; \
    printf("FAIL: %s\n", reason); \
} while(0)

#define CHECK(cond, reason) do { \
    if (!(cond)) { FAIL(reason); return; } \
} while(0)

#define CHECK_EQ(a, b, reason) do { \
    if ((a) != (b)) { \
        char buf[256]; \
        snprintf(buf, sizeof(buf), "%s (got %d, expected %d)", reason, \
                 (int)(a), (int)(b)); \
        FAIL(buf); return; \
    } \
} while(0)

/* ============================================================================
 * Message handler for testing
 * ============================================================================ */

static int g_handler_call_count = 0;

static int test_message_handler(ipc_bus_channel_t channel, const ipc_bus_message_t *msg,
                                             void *user_data) {
    (void)channel;
    (void)msg;
    (void)user_data;
    g_handler_call_count++;
    return 0;
}

/* ============================================================================
 * P1.16i-1: Normal Path — IPC Bus helper lifecycle
 * ============================================================================ */

static void test_normal_ipc_bus_lifecycle(void) {
    TEST("C-L09 Normal: IPC Bus helper init → register channel → shutdown");

    ipc_bus_helper_t *ibh = ipc_bus_helper_init("test_daemon", NULL);
    CHECK(ibh != NULL, "ipc_bus_helper_init returned NULL");

    /* Register a channel for this daemon */
    int ret = ipc_bus_helper_register_channel(ibh, "test", IPC_BUS_PROTO_JSON_RPC);
    CHECK_EQ(ret, 0, "Register channel should succeed");

    /* Register a message handler */
    g_handler_call_count = 0;
    ret = ipc_bus_helper_register_handler(ibh, test_message_handler, NULL);
    CHECK_EQ(ret, 0, "Register handler should succeed");

    ipc_bus_helper_shutdown(ibh);
    PASS();
}

/* ============================================================================
 * P1.16i-3: Normal Path — Multiple channel registration
 * ============================================================================ */

static void test_normal_multiple_channels(void) {
    TEST("C-L09 Normal: Multiple channel registration");

    ipc_bus_helper_t *ibh = ipc_bus_helper_init("multi_channel_daemon", NULL);
    CHECK(ibh != NULL, "ipc_bus_helper_init returned NULL");

    /* Register multiple channels; only the first one takes effect (the
     * helper carries a single channel), repeats must stay harmless */
    const char *channels[] = { "llm", "tool", "agent", "market" };
    ipc_bus_proto_t protos[] = {
        IPC_BUS_PROTO_JSON_RPC,
        IPC_BUS_PROTO_MCP,
        IPC_BUS_PROTO_A2A,
        IPC_BUS_PROTO_OPENAI
    };

    for (int i = 0; i < 4; i++) {
        int ret = ipc_bus_helper_register_channel(ibh, channels[i], protos[i]);
        CHECK_EQ(ret, 0, "Register channel should succeed");
    }

    ipc_bus_helper_shutdown(ibh);
    PASS();
}

/* ============================================================================
 * P1.16i-4: Error Path — NULL handling
 * ============================================================================ */

static void test_error_null_handling(void) {
    TEST("C-L09 Error: NULL IPC Bus helper handling");

    /* NULL shutdown should be safe */
    ipc_bus_helper_shutdown(NULL);

    /* NULL register channel should fail */
    int ret = ipc_bus_helper_register_channel(NULL, "test", IPC_BUS_PROTO_JSON_RPC);
    CHECK(ret != 0, "NULL ibh register channel should fail");

    /* NULL register handler should fail */
    ret = ipc_bus_helper_register_handler(NULL, test_message_handler, NULL);
    CHECK(ret != 0, "NULL ibh register handler should fail");

    PASS();
}

/* ============================================================================
 * P1.16i-5: Error Path — Invalid channel operations
 * ============================================================================ */

static void test_error_invalid_channel(void) {
    TEST("C-L09 Error: Invalid channel operations");

    ipc_bus_helper_t *ibh = ipc_bus_helper_init("invalid_daemon", NULL);
    CHECK(ibh != NULL, "ipc_bus_helper_init returned NULL");

    /* Register with NULL channel name should fail */
    int ret = ipc_bus_helper_register_channel(ibh, NULL, IPC_BUS_PROTO_JSON_RPC);
    CHECK(ret != 0, "NULL channel name should fail");

    /* Register with NULL handler should fail */
    ret = ipc_bus_helper_register_handler(ibh, NULL, NULL);
    CHECK(ret != 0, "NULL handler should fail");

    ipc_bus_helper_shutdown(ibh);
    PASS();
}

/* ============================================================================
 * P1.16i-6: Error Path — Request to non-existent target
 * ============================================================================ */

static void test_request_nonexistent_target(void) {
    TEST("C-L09 Error: Request to non-existent service");

    ipc_bus_helper_t *ibh = ipc_bus_helper_init("timeout_daemon", NULL);
    CHECK(ibh != NULL, "ipc_bus_helper_init returned NULL");

    int ret = ipc_bus_helper_register_channel(ibh, "timeout", IPC_BUS_PROTO_JSON_RPC);
    CHECK_EQ(ret, 0, "Register channel should succeed");

    /* Send a request to a target that cannot exist */
    ipc_bus_message_t request;
    memset(&request, 0, sizeof(request));
    request.header.msg_type = IPC_BUS_MSG_REQUEST;
    request.header.protocol = IPC_BUS_PROTO_JSON_RPC;
    const char *payload_str = "{\"op\": \"ping\"}";
    request.payload = (void *)payload_str;
    request.payload_size = strlen(payload_str);

    ipc_bus_message_t response;
    memset(&response, 0, sizeof(response));

    ret = ipc_bus_helper_request(ibh, "non_existent_service", &request,
                                  &response, 100);
    /* Must fail since target doesn't exist */
    CHECK(ret != 0, "Request to non-existent service should fail");

    ipc_bus_helper_shutdown(ibh);
    PASS();
}

/* ============================================================================
 * P1.16i-7: Concurrent Path — Multiple bus helpers
 * ============================================================================ */

#define IPC_CONCURRENT_INSTANCES 4

static void test_concurrent_ipc_bus_helpers(void) {
    TEST("C-L09 Concurrent: Multiple IPC Bus helper instances");

    ipc_bus_helper_t *helpers[IPC_CONCURRENT_INSTANCES];
    const char *names[] = { "daemon_a", "daemon_b", "daemon_c", "daemon_d" };

    /* Create and init multiple instances */
    for (int i = 0; i < IPC_CONCURRENT_INSTANCES; i++) {
        helpers[i] = ipc_bus_helper_init(names[i], NULL);
        CHECK(helpers[i] != NULL, "ipc_bus_helper_init returned NULL");

        int ret = ipc_bus_helper_register_channel(helpers[i], names[i],
                                                   IPC_BUS_PROTO_JSON_RPC);
        CHECK_EQ(ret, 0, "Register channel should succeed");
    }

    /* Cleanup */
    for (int i = 0; i < IPC_CONCURRENT_INSTANCES; i++) {
        ipc_bus_helper_shutdown(helpers[i]);
    }

    PASS();
}

/* ============================================================================
 * Main
 * ============================================================================ */

int main(void) {
    printf("=== C-L09 Integration Tests: IPC Bus → all daemons ===\n\n");

    test_normal_ipc_bus_lifecycle();
    test_normal_multiple_channels();
    test_error_null_handling();
    test_error_invalid_channel();
    test_request_nonexistent_target();
    test_concurrent_ipc_bus_helpers();

    printf("\n=== Results: %d/%d passed, %d failed ===\n",
           g_tests_passed, g_tests_total, g_tests_failed);
    return g_tests_failed > 0 ? 1 : 0;
}
