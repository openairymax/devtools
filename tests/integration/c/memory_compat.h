// SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
/**
 * @file memory_compat.h
 * @brief 集成测试内存兼容层 — 转发至标准 C 库
 *
 * 集成测试允许使用裸 malloc/free/memset（见 CMakeLists.txt 中的
 * AIRY_COMPLIANCE_IMPL 豁免）。本头文件提供与 airy_memory.h 中
 * AIRY_MEM* 宏的兼容转发，供集成测试在未链接完整 libairy_memory.a
 * 时使用。
 *
 * 新代码应直接使用 <stdlib.h> + <string.h>。
 */

#ifndef AIRY_RT_TEST_MEMORY_COMPAT_H
#define AIRY_RT_TEST_MEMORY_COMPAT_H

#include <stdlib.h>
#include <string.h>

/* AIRY_MEM* 宏 — 转发到标准 C 库函数 */
#define AIRY_MALLOC(size)        malloc((size))
#define AIRY_CALLOC(n, size)     calloc((n), (size))
#define AIRY_REALLOC(p, size)    realloc((p), (size))
#define AIRY_FREE(p)             free((p))

#define AIRY_MEMSET(s, c, n)     memset((s), (c), (n))
#define AIRY_MEMCPY(d, s, n)     memcpy((d), (s), (n))
#define AIRY_MEMMOVE(d, s, n)    memmove((d), (s), (n))
#define AIRY_MEMCMP(a, b, n)     memcmp((a), (b), (n))
#define AIRY_MEMZERO(s, n)       memset((s), 0, (n))

#endif /* AIRY_RT_TEST_MEMORY_COMPAT_H */
