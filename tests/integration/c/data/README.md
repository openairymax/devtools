# C Integration Test Fixture Data

> **路径**: `devtools/tests/integration/c/data/` | **版本**: 0.1.1

## 概述

此目录包含 C 语言集成测试的测试夹具（fixture）二进制数据文件，用于 AgentRT 内存子系统（MemoryRovol）的集成测试。

### 数据文件

| 目录 | 内容 | 用途 |
|------|------|------|
| `agentos/memory/data/` | `rec-*.bin` 二进制记录文件 | 内存记录持久化与恢复的集成测试数据 |

所有 `.bin` 文件为预生成的测试记录，用于验证 MemoryRovol 四层记忆（L1-L4）的读写一致性和跨版本兼容性。

## 使用方式

这些数据文件由 `devtools/tests/integration/c/` 下的 C 集成测试代码自动加载，无需手动操作。

## 许可证

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved. 双许可证：AGPL-3.0-or-later OR Apache-2.0。

---

> **文档结束** | 0.1.1（C 集成测试夹具数据目录）